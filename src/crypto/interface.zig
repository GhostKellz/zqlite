const std = @import("std");
const build_options = @import("build_options");
pub const pqc_backend = @import("pqc_backend.zig");

/// ZQLite Crypto Abstraction Layer
/// Supports multiple backends: native (std.crypto), none
pub const CryptoBackend = enum {
    native, // Zig std.crypto (default, no dependencies)
    none, // Disabled crypto features
};

pub const CryptoConfig = struct {
    backend: CryptoBackend = .native,
    enable_pq: bool = false, // Post-quantum crypto (experimental scaffolding)
    enable_zkp: bool = false, // Zero-knowledge proofs (experimental scaffolding)
    hybrid_mode: bool = true, // Classical + PQ hybrid
    pq_mode: PQMode = .disabled,
    pq_provider: PQProviderPreference = .auto,
    allow_classical_fallback: bool = false,
};

pub const PQProviderPreference = enum {
    auto,
    stdlib,
    liboqs,
};

pub const PQMode = enum {
    disabled,
    classical_fallback,
    simulated,
    hybrid,
    pqc,
};

pub const PQRuntimeState = enum {
    unavailable,
    classical_fallback,
    simulated,
    hybrid_active,
    pqc_active,
};

pub const PQBackendProbe = enum {
    none,
    simulated,
    real,
};

pub const PQDecisionReason = enum {
    disabled,
    not_compiled,
    backend_missing,
    fallback_explicit,
    fallback_allowed,
    simulated,
    backend_active,
    provider_not_configured,
    configured_but_unlinked,
};

pub const PQAlgorithms = struct {
    ml_kem_768: bool, // Key encapsulation
    ml_dsa_65: bool, // Digital signatures
    hybrid_signatures: bool, // Classical + PQ hybrid
};

/// Unified crypto interface - backend agnostic
pub const CryptoInterface = struct {
    backend: CryptoBackend,
    config: CryptoConfig,

    const Self = @This();

    pub fn init(config: CryptoConfig) Self {
        return Self{
            .backend = config.backend,
            .config = config,
        };
    }

    /// Generate secure random bytes
    pub fn randomBytes(self: Self, buffer: []u8) !void {
        switch (self.backend) {
            .native => {
                std.crypto.random.bytes(buffer);
            },
            .none => {
                @memset(buffer, 0); // Insecure fallback
            },
        }
    }

    /// Hash function (SHA-256)
    pub fn hash(self: Self, data: []const u8, output: *[32]u8) !void {
        switch (self.backend) {
            .native => {
                var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                hasher.update(data);
                hasher.final(output);
            },
            .none => {
                @memset(output, 0); // Insecure fallback
            },
        }
    }

    /// HKDF key derivation
    pub fn hkdf(self: Self, ikm: []const u8, salt: []const u8, info: []const u8, output: []u8) !void {
        switch (self.backend) {
            .native => {
                const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
                const prk = Hkdf.extract(salt, ikm);
                Hkdf.expand(output, info, prk);
            },
            .none => {
                @memset(output, 0); // Insecure fallback
            },
        }
    }

    /// Symmetric encryption (ChaCha20-Poly1305)
    pub fn encrypt(self: Self, key: [32]u8, nonce: [12]u8, plaintext: []const u8, ciphertext: []u8, tag: *[16]u8) !void {
        if (ciphertext.len != plaintext.len) return error.InvalidLength;

        switch (self.backend) {
            .native => {
                const cipher = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
                cipher.encrypt(ciphertext, tag, plaintext, &[0]u8{}, nonce, key);
            },
            .none => {
                @memcpy(ciphertext, plaintext); // No encryption
                @memset(tag, 0);
            },
        }
    }

    /// Symmetric decryption (ChaCha20-Poly1305)
    pub fn decrypt(self: Self, key: [32]u8, nonce: [12]u8, ciphertext: []const u8, tag: [16]u8, plaintext: []u8) !void {
        if (plaintext.len != ciphertext.len) return error.InvalidLength;

        switch (self.backend) {
            .native => {
                const cipher = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
                try cipher.decrypt(plaintext, ciphertext, &[0]u8{}, tag, nonce, key);
            },
            .none => {
                @memcpy(plaintext, ciphertext); // No decryption
            },
        }
    }

    /// Check if post-quantum crypto is available
    /// True only when crypto is compiled, PQC/hybrid mode is requested, and the real backend is active.
    pub fn hasPQCrypto(self: Self) bool {
        return self.pqCapability().isAvailable();
    }

    /// Check if zero-knowledge proofs are available
    /// Currently returns false - ZKP is experimental scaffolding only
    pub fn hasZKP(self: Self) bool {
        _ = self;
        return false;
    }

    pub fn pqCapability(self: Self) PQCapability {
        return evaluatePQCapability(build_options.enable_crypto, self.config, compiledBackendProbe());
    }

    fn requirePQSignaturePolicy(self: Self) !PQCapability {
        const capability = self.pqCapability();
        return switch (capability.state) {
            .pqc_active, .hybrid_active => capability,
            .classical_fallback => capability,
            .unavailable => if (capability.requested_mode == .disabled)
                error.PQCDisabled
            else
                error.PQCBackendUnavailable,
            .simulated => error.SimulatedPQCNotAllowed,
        };
    }

    /// Post-quantum signature verification.
    /// Uses Ed25519 only when classical fallback was explicitly selected/allowed.
    pub fn verifyPQ(self: Self, message: []const u8, signature: []const u8, public_key: []const u8) !bool {
        const capability = try self.requirePQSignaturePolicy();
        if (capability.state == .pqc_active or capability.state == .hybrid_active) {
            return pqc_backend.MlDsa65.verify(message, signature, public_key);
        }
        if (capability.state != .classical_fallback) return error.PQCBackendUnavailable;

        // Validate input sizes
        if (signature.len != 64) return error.InvalidSignatureLength;
        if (public_key.len != 32) return error.InvalidPublicKeyLength;

        // Use Ed25519 for classical verification
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature[0..64].*);
        const pubkey = try std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key[0..32].*);

        // Verify signature
        sig.verify(message, pubkey) catch return false;
        return true;
    }

    /// Post-quantum signing.
    /// Uses Ed25519 only when classical fallback was explicitly selected/allowed.
    pub fn signPQ(self: Self, message: []const u8, private_key: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const capability = try self.requirePQSignaturePolicy();
        if (capability.state == .pqc_active or capability.state == .hybrid_active) {
            const signature = try pqc_backend.MlDsa65.signDeterministic(message, private_key);
            const sig_bytes = try allocator.alloc(u8, signature.len);
            @memcpy(sig_bytes, &signature);
            return sig_bytes;
        }
        if (capability.state != .classical_fallback) return error.PQCBackendUnavailable;

        // Validate input size
        if (private_key.len != 64) return error.InvalidPrivateKeyLength;

        // Use Ed25519 for classical signing
        const secret_key = std.crypto.sign.Ed25519.SecretKey{ .bytes = private_key[0..64].* };
        const key_pair = try std.crypto.sign.Ed25519.KeyPair.fromSecretKey(secret_key);
        const signature = try key_pair.sign(message, null);

        // Return signature as allocated slice
        const signature_bytes = signature.toBytes();
        const sig_bytes = try allocator.alloc(u8, 64);
        @memcpy(sig_bytes, &signature_bytes);
        return sig_bytes;
    }
};

/// Feature detection for runtime configuration
pub fn detectAvailableFeatures() CryptoConfig {
    var config = CryptoConfig{};

    // Default to native std.crypto backend
    config.backend = .native;
    config.enable_pq = false;
    config.enable_zkp = false;

    return config;
}

/// Post-quantum capability status
pub const PQCapability = struct {
    /// Whether PQ crypto module is compiled in
    compiled: bool,
    /// Whether PQ features are enabled at runtime
    enabled: bool,
    /// Requested PQ mode after compatibility normalization
    requested_mode: PQMode,
    /// Explicit runtime state used for diagnostics and tests
    state: PQRuntimeState,
    /// Whether classical fallback was explicitly allowed by configuration
    fallback_allowed: bool,
    /// Whether the active state is production PQC rather than fallback/simulation
    production_ready: bool,
    /// Machine-readable reason for the selected state
    reason: PQDecisionReason,
    /// Available PQ algorithms
    algorithms: PQAlgorithms,
    /// Backend providing PQ features
    backend: PQBackend,
    /// Provider implementation selected for the active PQ backend, if any
    provider: pqc_backend.Provider,
    /// Provider requested by runtime config.
    requested_provider: PQProviderPreference,
    /// liboqs provider link/configuration status.
    liboqs_status: pqc_backend.LibOQSProviderStatus,
    /// Human-readable status message
    status_message: []const u8,

    pub const PQBackend = enum {
        none, // No PQ support
        native_fallback, // Ed25519 fallback (classical only)
        simulated, // Deterministic test/demo state, not production PQC
        hybrid, // Real hybrid backend
        pqc, // Real PQC backend
    };

    /// Check if any PQ features are available
    pub fn isAvailable(self: PQCapability) bool {
        return self.compiled and self.enabled and self.production_ready;
    }

    pub fn isFallback(self: PQCapability) bool {
        return self.state == .classical_fallback;
    }

    pub fn isSimulated(self: PQCapability) bool {
        return self.state == .simulated;
    }

    pub fn reasonTag(self: PQCapability) []const u8 {
        return @tagName(self.reason);
    }

    /// Get a summary of available algorithms
    pub fn algorithmSummary(self: PQCapability) []const u8 {
        if (!self.isAvailable()) return "none";
        if (self.algorithms.hybrid_signatures) return "ML-KEM-768, ML-DSA-65, Hybrid";
        if (self.algorithms.ml_kem_768 and self.algorithms.ml_dsa_65) return "ML-KEM-768, ML-DSA-65";
        if (self.algorithms.ml_kem_768) return "ML-KEM-768";
        if (self.algorithms.ml_dsa_65) return "ML-DSA-65";
        return "none";
    }

    pub fn providerName(self: PQCapability) []const u8 {
        return self.provider.name();
    }
};

/// Query the post-quantum cryptography capability status
/// This provides runtime introspection of PQ features
pub fn getPQCapability() PQCapability {
    return evaluatePQCapabilityWithBuild(build_options.enable_crypto, build_options.enable_liboqs, .{}, compiledBackendProbe());
}

pub fn getPQCapabilityForConfig(config: CryptoConfig) PQCapability {
    return evaluatePQCapabilityWithBuild(build_options.enable_crypto, build_options.enable_liboqs, config, compiledBackendProbe());
}

pub fn getLibOQSProviderStatus() pqc_backend.LibOQSProviderStatus {
    return if (build_options.enable_liboqs) .configured_but_unlinked else .not_configured;
}

pub fn getLibOQSIncludePath() []const u8 {
    return build_options.liboqs_include_path;
}

pub fn getLibOQSLibraryPath() []const u8 {
    return build_options.liboqs_library_path;
}

pub fn pqDiagnosticsJson(allocator: std.mem.Allocator, capability: PQCapability) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"compiled\":{},\"enabled\":{},\"available\":{},\"production_ready\":{},\"requested_mode\":\"{s}\",\"requested_provider\":\"{s}\",\"state\":\"{s}\",\"backend\":\"{s}\",\"provider\":\"{s}\",\"liboqs_status\":\"{s}\",\"fallback_allowed\":{},\"reason\":\"{s}\",\"algorithms\":{{\"ml_kem_768\":{},\"ml_dsa_65\":{},\"hybrid_signatures\":{}}},\"status\":\"{s}\"}}",
        .{
            capability.compiled,
            capability.enabled,
            capability.isAvailable(),
            capability.production_ready,
            @tagName(capability.requested_mode),
            @tagName(capability.requested_provider),
            @tagName(capability.state),
            @tagName(capability.backend),
            capability.providerName(),
            capability.liboqs_status.tag(),
            capability.fallback_allowed,
            capability.reasonTag(),
            capability.algorithms.ml_kem_768,
            capability.algorithms.ml_dsa_65,
            capability.algorithms.hybrid_signatures,
            capability.status_message,
        },
    );
}

pub fn evaluatePQCapability(compiled: bool, config: CryptoConfig, probe: PQBackendProbe) PQCapability {
    return evaluatePQCapabilityWithBuild(compiled, false, config, probe);
}

pub fn evaluatePQCapabilityWithBuild(compiled: bool, liboqs_configured: bool, config: CryptoConfig, probe: PQBackendProbe) PQCapability {
    const requested_mode = normalizePQMode(config);
    const selected_provider = selectedProviderForConfig(config);
    const liboqs_status = liboqsStatus(liboqs_configured, selected_provider, false);
    if (!compiled) {
        return unavailableCapability(false, requested_mode, config.pq_provider, selected_provider, liboqs_status, config.allow_classical_fallback, .not_compiled, "Post-quantum crypto not compiled (use -Dcrypto=true)");
    }

    if ((requested_mode == .hybrid or requested_mode == .pqc) and selected_provider == .liboqs) {
        if (!liboqs_configured) {
            return if (config.allow_classical_fallback)
                fallbackCapability(requested_mode, config.pq_provider, selected_provider, .not_configured, true, .fallback_allowed, "liboqs provider requested but -Dliboqs=true is not configured; explicit classical fallback active.")
            else
                unavailableCapability(true, requested_mode, config.pq_provider, selected_provider, .not_configured, false, .provider_not_configured, "liboqs provider requested but -Dliboqs=true is not configured.");
        }

        return if (config.allow_classical_fallback)
            fallbackCapability(requested_mode, config.pq_provider, selected_provider, .configured_but_unlinked, true, .fallback_allowed, "liboqs provider configured but not linked; explicit classical fallback active.")
        else
            unavailableCapability(true, requested_mode, config.pq_provider, selected_provider, .configured_but_unlinked, false, .configured_but_unlinked, "liboqs provider configured but not linked.");
    }

    return switch (requested_mode) {
        .disabled => unavailableCapability(true, requested_mode, config.pq_provider, .none, .not_configured, config.allow_classical_fallback, .disabled, "Post-quantum crypto disabled"),
        .classical_fallback => fallbackCapability(requested_mode, config.pq_provider, selected_provider, liboqs_status, config.allow_classical_fallback, .fallback_explicit, "Classical crypto fallback explicitly selected; no production PQC active."),
        .simulated => simulatedCapability(requested_mode, config.pq_provider, selected_provider, liboqs_status, config.allow_classical_fallback),
        .hybrid => switch (probe) {
            .real => activeCapability(.hybrid_active, .hybrid, requested_mode, config.pq_provider, selected_provider, liboqs_status, true, "Hybrid ML-KEM/ML-DSA backend active"),
            .simulated => simulatedCapability(requested_mode, config.pq_provider, selected_provider, liboqs_status, config.allow_classical_fallback),
            .none => if (config.allow_classical_fallback)
                fallbackCapability(requested_mode, config.pq_provider, selected_provider, liboqs_status, true, .fallback_allowed, "Hybrid PQC requested but no backend is available; explicit classical fallback active.")
            else
                unavailableCapability(true, requested_mode, config.pq_provider, .none, .not_configured, false, .backend_missing, "Hybrid PQC requested but no backend is available; fallback disabled."),
        },
        .pqc => switch (probe) {
            .real => activeCapability(.pqc_active, .pqc, requested_mode, config.pq_provider, selected_provider, liboqs_status, false, "Production PQC backend active"),
            .simulated => simulatedCapability(requested_mode, config.pq_provider, selected_provider, liboqs_status, config.allow_classical_fallback),
            .none => if (config.allow_classical_fallback)
                fallbackCapability(requested_mode, config.pq_provider, selected_provider, liboqs_status, true, .fallback_allowed, "PQC requested but no backend is available; explicit classical fallback active.")
            else
                unavailableCapability(true, requested_mode, config.pq_provider, .none, .not_configured, false, .backend_missing, "PQC requested but no backend is available; fallback disabled."),
        },
    };
}

fn normalizePQMode(config: CryptoConfig) PQMode {
    if (config.pq_mode != .disabled) return config.pq_mode;
    if (config.enable_pq) return if (config.hybrid_mode) .hybrid else .pqc;
    return .disabled;
}

fn unavailableCapability(
    compiled: bool,
    requested_mode: PQMode,
    requested_provider: PQProviderPreference,
    provider: pqc_backend.Provider,
    liboqs_status: pqc_backend.LibOQSProviderStatus,
    fallback_allowed: bool,
    reason: PQDecisionReason,
    status_message: []const u8,
) PQCapability {
    return .{
        .compiled = compiled,
        .enabled = false,
        .requested_mode = requested_mode,
        .state = .unavailable,
        .fallback_allowed = fallback_allowed,
        .production_ready = false,
        .reason = reason,
        .algorithms = noAlgorithms(),
        .backend = .none,
        .provider = provider,
        .requested_provider = requested_provider,
        .liboqs_status = liboqs_status,
        .status_message = status_message,
    };
}

fn fallbackCapability(
    requested_mode: PQMode,
    requested_provider: PQProviderPreference,
    provider: pqc_backend.Provider,
    liboqs_status: pqc_backend.LibOQSProviderStatus,
    fallback_allowed: bool,
    reason: PQDecisionReason,
    status_message: []const u8,
) PQCapability {
    return .{
        .compiled = true,
        .enabled = false,
        .requested_mode = requested_mode,
        .state = .classical_fallback,
        .fallback_allowed = fallback_allowed,
        .production_ready = false,
        .reason = reason,
        .algorithms = noAlgorithms(),
        .backend = .native_fallback,
        .provider = provider,
        .requested_provider = requested_provider,
        .liboqs_status = liboqs_status,
        .status_message = status_message,
    };
}

fn simulatedCapability(
    requested_mode: PQMode,
    requested_provider: PQProviderPreference,
    provider: pqc_backend.Provider,
    liboqs_status: pqc_backend.LibOQSProviderStatus,
    fallback_allowed: bool,
) PQCapability {
    return .{
        .compiled = true,
        .enabled = false,
        .requested_mode = requested_mode,
        .state = .simulated,
        .fallback_allowed = fallback_allowed,
        .production_ready = false,
        .reason = .simulated,
        .algorithms = noAlgorithms(),
        .backend = .simulated,
        .provider = if (provider == .none) .simulated else provider,
        .requested_provider = requested_provider,
        .liboqs_status = liboqs_status,
        .status_message = "Simulated PQC diagnostics active; not production cryptography.",
    };
}

fn activeCapability(
    state: PQRuntimeState,
    backend: PQCapability.PQBackend,
    requested_mode: PQMode,
    requested_provider: PQProviderPreference,
    provider: pqc_backend.Provider,
    liboqs_status: pqc_backend.LibOQSProviderStatus,
    hybrid: bool,
    status_message: []const u8,
) PQCapability {
    return .{
        .compiled = true,
        .enabled = true,
        .requested_mode = requested_mode,
        .state = state,
        .fallback_allowed = false,
        .production_ready = true,
        .reason = .backend_active,
        .algorithms = .{
            .ml_kem_768 = true,
            .ml_dsa_65 = true,
            .hybrid_signatures = hybrid,
        },
        .backend = backend,
        .provider = provider,
        .requested_provider = requested_provider,
        .liboqs_status = liboqs_status,
        .status_message = status_message,
    };
}

fn noAlgorithms() PQAlgorithms {
    return .{
        .ml_kem_768 = false,
        .ml_dsa_65 = false,
        .hybrid_signatures = false,
    };
}

fn compiledBackendProbe() PQBackendProbe {
    return if (build_options.enable_crypto) .real else .none;
}

fn selectedProviderForConfig(config: CryptoConfig) pqc_backend.Provider {
    return switch (config.pq_provider) {
        .auto, .stdlib => .stdlib,
        .liboqs => .liboqs,
    };
}

fn liboqsStatus(liboqs_configured: bool, provider: pqc_backend.Provider, linked: bool) pqc_backend.LibOQSProviderStatus {
    _ = linked;
    if (provider != .liboqs) return .not_configured;
    return if (liboqs_configured) .configured_but_unlinked else .not_configured;
}

/// Get crypto module status summary
pub fn getCryptoStatus() struct {
    symmetric_encryption: bool,
    hashing: bool,
    key_derivation: bool,
    digital_signatures: bool,
    post_quantum: PQCapability,
} {
    const compiled = build_options.enable_crypto;

    return .{
        .symmetric_encryption = compiled, // ChaCha20-Poly1305
        .hashing = true, // Always available via std.crypto
        .key_derivation = true, // HKDF always available
        .digital_signatures = compiled, // Ed25519
        .post_quantum = getPQCapability(),
    };
}

test "PQ capability reports scaffolding status" {
    const pq = getPQCapability();
    const testing = @import("std").testing;

    // PQ is not enabled - only scaffolding exists
    try testing.expect(!pq.enabled);
    try testing.expect(!pq.algorithms.ml_kem_768);
    try testing.expect(!pq.algorithms.ml_dsa_65);
    try testing.expectEqualStrings("none", pq.algorithmSummary());
    try testing.expect(pq.backend == .native_fallback or pq.backend == .none);
    try testing.expect(!pq.production_ready);
}
