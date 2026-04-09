const std = @import("std");

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
    /// Currently returns false - PQ is experimental scaffolding only
    pub fn hasPQCrypto(self: Self) bool {
        _ = self;
        return false;
    }

    /// Check if zero-knowledge proofs are available
    /// Currently returns false - ZKP is experimental scaffolding only
    pub fn hasZKP(self: Self) bool {
        _ = self;
        return false;
    }

    /// Post-quantum signature verification (using Ed25519 as classical fallback)
    pub fn verifyPQ(self: Self, message: []const u8, signature: []const u8, public_key: []const u8) !bool {
        _ = self;

        // Validate input sizes
        if (signature.len != 64) return error.InvalidSignatureLength;
        if (public_key.len != 32) return error.InvalidPublicKeyLength;

        // Use Ed25519 for classical verification
        const sig = std.crypto.sign.Ed25519.Signature{ .bytes = signature[0..64].* };
        const pubkey = std.crypto.sign.Ed25519.PublicKey{ .bytes = public_key[0..32].* };

        // Verify signature
        sig.verify(message, pubkey) catch return false;
        return true;
    }

    /// Post-quantum signing (using Ed25519 as classical fallback)
    pub fn signPQ(self: Self, message: []const u8, private_key: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = self;

        // Validate input size
        if (private_key.len != 64) return error.InvalidPrivateKeyLength;

        // Use Ed25519 for classical signing
        const secret_key = std.crypto.sign.Ed25519.SecretKey{ .bytes = private_key[0..64].* };
        const signature = try secret_key.sign(message, null);

        // Return signature as allocated slice
        const sig_bytes = try allocator.alloc(u8, 64);
        @memcpy(sig_bytes, &signature.bytes);
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
    /// Available PQ algorithms
    algorithms: struct {
        ml_kem_768: bool, // Key encapsulation
        ml_dsa_65: bool, // Digital signatures
        hybrid_signatures: bool, // Classical + PQ hybrid
    },
    /// Backend providing PQ features
    backend: PQBackend,
    /// Human-readable status message
    status_message: []const u8,

    pub const PQBackend = enum {
        none, // No PQ support
        native_fallback, // Ed25519 fallback (classical only)
    };

    /// Check if any PQ features are available
    pub fn isAvailable(self: PQCapability) bool {
        return self.compiled and self.enabled;
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
};

/// Query the post-quantum cryptography capability status
/// This provides runtime introspection of PQ features
pub fn getPQCapability() PQCapability {
    const build_options = @import("build_options");

    // Check if crypto module is compiled in
    const compiled = build_options.enable_crypto;

    if (!compiled) {
        return PQCapability{
            .compiled = false,
            .enabled = false,
            .algorithms = .{
                .ml_kem_768 = false,
                .ml_dsa_65 = false,
                .hybrid_signatures = false,
            },
            .backend = .none,
            .status_message = "Post-quantum crypto not compiled (use -Dcrypto=true)",
        };
    }

    // Crypto compiled but PQ is experimental scaffolding only
    // Classical Ed25519 signatures are used as fallback
    return PQCapability{
        .compiled = true,
        .enabled = false,
        .algorithms = .{
            .ml_kem_768 = false,
            .ml_dsa_65 = false,
            .hybrid_signatures = false,
        },
        .backend = .native_fallback,
        .status_message = "Classical crypto only (Ed25519). PQ is experimental scaffolding.",
    };
}

/// Get crypto module status summary
pub fn getCryptoStatus() struct {
    symmetric_encryption: bool,
    hashing: bool,
    key_derivation: bool,
    digital_signatures: bool,
    post_quantum: PQCapability,
} {
    const build_options = @import("build_options");
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
}
