const std = @import("std");

pub const Provider = enum {
    none,
    stdlib,
    liboqs,
    simulated,

    pub fn name(self: Provider) []const u8 {
        return @tagName(self);
    }
};

pub const LibOQSProviderStatus = enum {
    not_configured,
    configured_but_unlinked,
    linked_active,

    pub fn tag(self: LibOQSProviderStatus) []const u8 {
        return @tagName(self);
    }
};

pub const Algorithms = struct {
    ml_kem_768: bool = false,
    ml_dsa_65: bool = false,
};

pub const Algorithm = enum {
    ml_kem_768,
    ml_dsa_65,

    pub fn tag(self: Algorithm) []const u8 {
        return @tagName(self);
    }
};

pub const AlgorithmPolicy = struct {
    allow_ml_kem_768: bool = true,
    allow_ml_dsa_65: bool = true,
    require_real_backend: bool = true,

    pub const experimental_default = AlgorithmPolicy{};

    pub fn allows(self: AlgorithmPolicy, algorithm: Algorithm) bool {
        return switch (algorithm) {
            .ml_kem_768 => self.allow_ml_kem_768,
            .ml_dsa_65 => self.allow_ml_dsa_65,
        };
    }

    pub fn validateBackend(self: AlgorithmPolicy, backend: PQCBackend) Error!void {
        if (backend.algorithms.ml_kem_768 and !self.allow_ml_kem_768) return error.AlgorithmDisabledByPolicy;
        if (backend.algorithms.ml_dsa_65 and !self.allow_ml_dsa_65) return error.AlgorithmDisabledByPolicy;
        if (self.require_real_backend and (backend.provider == .none or backend.provider == .simulated)) return error.BackendUnavailable;
    }
};

pub const ProviderRuntimeStatus = enum {
    unavailable,
    ready,
    configured_but_unlinked,

    pub fn tag(self: ProviderRuntimeStatus) []const u8 {
        return @tagName(self);
    }
};

pub const ProviderHandle = struct {
    backend: PQCBackend,
    status: ProviderRuntimeStatus,

    pub fn deinit(self: *ProviderHandle) void {
        _ = self;
    }
};

pub const Error = error{
    BackendUnavailable,
    UnsupportedAlgorithm,
    InvalidSeedLength,
    InvalidPublicKeyLength,
    InvalidSecretKeyLength,
    InvalidCiphertextLength,
    InvalidSignatureLength,
    InvalidPublicKey,
    InvalidSecretKey,
    InvalidSignature,
    DecapsulationFailed,
    SigningFailed,
    AlgorithmDisabledByPolicy,
    InvalidKatFixture,
    InvalidHex,
};

pub const OwnedKeyPair = struct {
    public_key: []u8,
    secret_key: []u8,

    pub fn deinit(self: OwnedKeyPair, allocator: std.mem.Allocator) void {
        allocator.free(self.public_key);
        secureZero(self.secret_key);
        allocator.free(self.secret_key);
    }
};

pub const OwnedEncapsulatedSecret = struct {
    ciphertext: []u8,
    shared_secret: []u8,

    pub fn deinit(self: OwnedEncapsulatedSecret, allocator: std.mem.Allocator) void {
        allocator.free(self.ciphertext);
        secureZero(self.shared_secret);
        allocator.free(self.shared_secret);
    }
};

pub const PQCBackend = struct {
    provider: Provider,
    name: []const u8,
    algorithms: Algorithms,
    kemKeypairFn: *const fn (std.mem.Allocator, []const u8) anyerror!OwnedKeyPair,
    kemEncapsFn: *const fn (std.mem.Allocator, []const u8, []const u8) anyerror!OwnedEncapsulatedSecret,
    kemDecapsFn: *const fn (std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    signKeypairFn: *const fn (std.mem.Allocator, []const u8) anyerror!OwnedKeyPair,
    signFn: *const fn (std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
    verifyFn: *const fn ([]const u8, []const u8, []const u8) anyerror!bool,

    pub fn supportedAlgorithms(self: PQCBackend) Algorithms {
        return self.algorithms;
    }

    pub fn kemKeypair(self: PQCBackend, allocator: std.mem.Allocator, seed: []const u8) !OwnedKeyPair {
        return self.kemKeypairFn(allocator, seed);
    }

    pub fn kemEncaps(self: PQCBackend, allocator: std.mem.Allocator, public_key: []const u8, seed: []const u8) !OwnedEncapsulatedSecret {
        return self.kemEncapsFn(allocator, public_key, seed);
    }

    pub fn kemDecaps(self: PQCBackend, allocator: std.mem.Allocator, secret_key: []const u8, ciphertext: []const u8) ![]u8 {
        return self.kemDecapsFn(allocator, secret_key, ciphertext);
    }

    pub fn signKeypair(self: PQCBackend, allocator: std.mem.Allocator, seed: []const u8) !OwnedKeyPair {
        return self.signKeypairFn(allocator, seed);
    }

    pub fn sign(self: PQCBackend, allocator: std.mem.Allocator, message: []const u8, secret_key: []const u8) ![]u8 {
        return self.signFn(allocator, message, secret_key);
    }

    pub fn verify(self: PQCBackend, message: []const u8, signature: []const u8, public_key: []const u8) !bool {
        return self.verifyFn(message, signature, public_key);
    }
};

pub const StdlibPQCBackend = struct {
    pub const provider = Provider.stdlib;
    pub const backend = PQCBackend{
        .provider = provider,
        .name = provider.name(),
        .algorithms = .{
            .ml_kem_768 = true,
            .ml_dsa_65 = true,
        },
        .kemKeypairFn = kemKeypair,
        .kemEncapsFn = kemEncaps,
        .kemDecapsFn = kemDecaps,
        .signKeypairFn = signKeypair,
        .signFn = sign,
        .verifyFn = verify,
    };

    pub fn initProvider(policy: AlgorithmPolicy) Error!ProviderHandle {
        try policy.validateBackend(backend);
        return .{
            .backend = backend,
            .status = .ready,
        };
    }

    pub const MlKem768 = struct {
        const Kem = std.crypto.kem.ml_kem.MLKem768;

        pub const public_key_length = Kem.PublicKey.encoded_length;
        pub const secret_key_length = Kem.SecretKey.encoded_length;
        pub const ciphertext_length = Kem.ciphertext_length;
        pub const shared_secret_length = Kem.shared_length;
        pub const key_seed_length = Kem.seed_length;
        pub const encaps_seed_length = Kem.encaps_seed_length;

        pub const KeyPair = struct {
            public_key: [public_key_length]u8,
            secret_key: [secret_key_length]u8,
        };

        pub const EncapsulatedSecret = struct {
            ciphertext: [ciphertext_length]u8,
            shared_secret: [shared_secret_length]u8,
        };

        pub fn generateDeterministic(seed: [key_seed_length]u8) !KeyPair {
            const kp = try Kem.KeyPair.generateDeterministic(seed);
            return .{
                .public_key = kp.public_key.toBytes(),
                .secret_key = kp.secret_key.toBytes(),
            };
        }

        pub fn encapsulateDeterministic(public_key: []const u8, seed: [encaps_seed_length]u8) Error!EncapsulatedSecret {
            if (public_key.len != public_key_length) return error.InvalidPublicKeyLength;

            const pk = Kem.PublicKey.fromBytes(public_key[0..public_key_length]) catch return error.InvalidPublicKey;
            const encapsulated = pk.encapsDeterministic(&seed);
            return .{
                .ciphertext = encapsulated.ciphertext,
                .shared_secret = encapsulated.shared_secret,
            };
        }

        pub fn decapsulate(secret_key: []const u8, ciphertext: []const u8) Error![shared_secret_length]u8 {
            if (secret_key.len != secret_key_length) return error.InvalidSecretKeyLength;
            if (ciphertext.len != ciphertext_length) return error.InvalidCiphertextLength;

            const sk = Kem.SecretKey.fromBytes(secret_key[0..secret_key_length]) catch return error.InvalidSecretKey;
            return sk.decaps(ciphertext[0..ciphertext_length]) catch error.DecapsulationFailed;
        }
    };

    pub const MlDsa65 = struct {
        const Sig = std.crypto.sign.mldsa.MLDSA65;

        pub const public_key_length = Sig.PublicKey.encoded_length;
        pub const secret_key_length = Sig.SecretKey.encoded_length;
        pub const signature_length = Sig.Signature.encoded_length;
        pub const seed_length = Sig.KeyPair.seed_length;
        pub const noise_length = Sig.noise_length;

        pub const KeyPair = struct {
            public_key: [public_key_length]u8,
            secret_key: [secret_key_length]u8,
        };

        pub fn generateDeterministic(seed: [seed_length]u8) !KeyPair {
            const kp = try Sig.KeyPair.generateDeterministic(seed);
            return .{
                .public_key = kp.public_key.toBytes(),
                .secret_key = kp.secret_key.toBytes(),
            };
        }

        pub fn signDeterministic(message: []const u8, secret_key: []const u8) Error![signature_length]u8 {
            if (secret_key.len != secret_key_length) return error.InvalidSecretKeyLength;

            const sk = Sig.SecretKey.fromBytes(secret_key[0..secret_key_length].*) catch return error.InvalidSecretKey;
            const kp = Sig.KeyPair.fromSecretKey(sk) catch return error.InvalidSecretKey;
            const signature = kp.sign(message, null) catch return error.SigningFailed;
            return signature.toBytes();
        }

        pub fn verify(message: []const u8, signature: []const u8, public_key: []const u8) Error!bool {
            if (public_key.len != public_key_length) return error.InvalidPublicKeyLength;
            if (signature.len != signature_length) return error.InvalidSignatureLength;

            const pk = Sig.PublicKey.fromBytes(public_key[0..public_key_length].*) catch return error.InvalidPublicKey;
            const sig = Sig.Signature.fromBytes(signature[0..signature_length].*) catch return error.InvalidSignature;
            sig.verify(message, pk) catch return false;
            return true;
        }
    };

    fn kemKeypair(allocator: std.mem.Allocator, seed: []const u8) !OwnedKeyPair {
        if (seed.len != StdlibPQCBackend.MlKem768.key_seed_length) return error.InvalidSeedLength;
        const kp = try StdlibPQCBackend.MlKem768.generateDeterministic(seed[0..StdlibPQCBackend.MlKem768.key_seed_length].*);
        return ownedKeyPairFromArrays(allocator, &kp.public_key, &kp.secret_key);
    }

    fn kemEncaps(allocator: std.mem.Allocator, public_key: []const u8, seed: []const u8) !OwnedEncapsulatedSecret {
        if (seed.len != StdlibPQCBackend.MlKem768.encaps_seed_length) return error.InvalidSeedLength;
        const encapsulated = try StdlibPQCBackend.MlKem768.encapsulateDeterministic(public_key, seed[0..StdlibPQCBackend.MlKem768.encaps_seed_length].*);
        const ciphertext = try allocator.dupe(u8, &encapsulated.ciphertext);
        errdefer allocator.free(ciphertext);
        const shared_secret = try allocator.dupe(u8, &encapsulated.shared_secret);
        return .{
            .ciphertext = ciphertext,
            .shared_secret = shared_secret,
        };
    }

    fn kemDecaps(allocator: std.mem.Allocator, secret_key: []const u8, ciphertext: []const u8) ![]u8 {
        const shared_secret = try StdlibPQCBackend.MlKem768.decapsulate(secret_key, ciphertext);
        return allocator.dupe(u8, &shared_secret);
    }

    fn signKeypair(allocator: std.mem.Allocator, seed: []const u8) !OwnedKeyPair {
        if (seed.len != StdlibPQCBackend.MlDsa65.seed_length) return error.InvalidSeedLength;
        const kp = try StdlibPQCBackend.MlDsa65.generateDeterministic(seed[0..StdlibPQCBackend.MlDsa65.seed_length].*);
        return ownedKeyPairFromArrays(allocator, &kp.public_key, &kp.secret_key);
    }

    fn sign(allocator: std.mem.Allocator, message: []const u8, secret_key: []const u8) ![]u8 {
        const signature = try StdlibPQCBackend.MlDsa65.signDeterministic(message, secret_key);
        return allocator.dupe(u8, &signature);
    }

    fn verify(message: []const u8, signature: []const u8, public_key: []const u8) !bool {
        return StdlibPQCBackend.MlDsa65.verify(message, signature, public_key);
    }
};

pub const LibOQSPQCBackend = struct {
    pub const provider = Provider.liboqs;
    pub const backend = PQCBackend{
        .provider = provider,
        .name = provider.name(),
        .algorithms = .{},
        .kemKeypairFn = unavailableKeypair,
        .kemEncapsFn = unavailableEncaps,
        .kemDecapsFn = unavailableDecaps,
        .signKeypairFn = unavailableKeypair,
        .signFn = unavailableSign,
        .verifyFn = unavailableVerify,
    };

    pub fn initProvider(_: AlgorithmPolicy) Error!ProviderHandle {
        return .{
            .backend = backend,
            .status = .configured_but_unlinked,
        };
    }
};

pub const MlKem768 = StdlibPQCBackend.MlKem768;
pub const MlDsa65 = StdlibPQCBackend.MlDsa65;
pub const default_backend = StdlibPQCBackend.backend;

pub const KemKatFixture = struct {
    name: []const u8,
    key_seed: []const u8,
    encaps_seed: []const u8,
    expected_public_key: ?[]const u8 = null,
    expected_secret_key: ?[]const u8 = null,
    expected_ciphertext: ?[]const u8 = null,
    expected_shared_secret: ?[]const u8 = null,
};

pub const LoadedKemKatFixture = struct {
    fixture: KemKatFixture,
    key_seed: []u8,
    encaps_seed: []u8,
    expected_public_key: ?[]u8 = null,
    expected_secret_key: ?[]u8 = null,
    expected_ciphertext: ?[]u8 = null,
    expected_shared_secret: ?[]u8 = null,

    pub fn deinit(self: *LoadedKemKatFixture, allocator: std.mem.Allocator) void {
        secureZero(self.key_seed);
        allocator.free(self.key_seed);
        secureZero(self.encaps_seed);
        allocator.free(self.encaps_seed);
        if (self.expected_public_key) |value| allocator.free(value);
        if (self.expected_secret_key) |value| {
            secureZero(value);
            allocator.free(value);
        }
        if (self.expected_ciphertext) |value| allocator.free(value);
        if (self.expected_shared_secret) |value| {
            secureZero(value);
            allocator.free(value);
        }
    }
};

pub const SignKatFixture = struct {
    name: []const u8,
    seed: []const u8,
    message: []const u8,
    expected_public_key: ?[]const u8 = null,
    expected_secret_key: ?[]const u8 = null,
    expected_signature: ?[]const u8 = null,
};

pub const LoadedSignKatFixture = struct {
    fixture: SignKatFixture,
    seed: []u8,
    message: []u8,
    expected_public_key: ?[]u8 = null,
    expected_secret_key: ?[]u8 = null,
    expected_signature: ?[]u8 = null,

    pub fn deinit(self: *LoadedSignKatFixture, allocator: std.mem.Allocator) void {
        secureZero(self.seed);
        allocator.free(self.seed);
        allocator.free(self.message);
        if (self.expected_public_key) |value| allocator.free(value);
        if (self.expected_secret_key) |value| {
            secureZero(value);
            allocator.free(value);
        }
        if (self.expected_signature) |value| allocator.free(value);
    }
};

pub fn loadKemKatFixture(allocator: std.mem.Allocator, name: []const u8, data: []const u8) !LoadedKemKatFixture {
    var loaded = LoadedKemKatFixture{
        .fixture = undefined,
        .key_seed = try readRequiredHex(allocator, data, "key_seed"),
        .encaps_seed = try readRequiredHex(allocator, data, "encaps_seed"),
    };
    errdefer loaded.deinit(allocator);

    loaded.expected_public_key = try readOptionalHex(allocator, data, "expected_public_key");
    loaded.expected_secret_key = try readOptionalHex(allocator, data, "expected_secret_key");
    loaded.expected_ciphertext = try readOptionalHex(allocator, data, "expected_ciphertext");
    loaded.expected_shared_secret = try readOptionalHex(allocator, data, "expected_shared_secret");
    loaded.fixture = .{
        .name = name,
        .key_seed = loaded.key_seed,
        .encaps_seed = loaded.encaps_seed,
        .expected_public_key = loaded.expected_public_key,
        .expected_secret_key = loaded.expected_secret_key,
        .expected_ciphertext = loaded.expected_ciphertext,
        .expected_shared_secret = loaded.expected_shared_secret,
    };
    return loaded;
}

pub fn loadSignKatFixture(allocator: std.mem.Allocator, name: []const u8, data: []const u8) !LoadedSignKatFixture {
    var loaded = LoadedSignKatFixture{
        .fixture = undefined,
        .seed = try readRequiredHex(allocator, data, "seed"),
        .message = try readRequiredText(allocator, data, "message"),
    };
    errdefer loaded.deinit(allocator);

    loaded.expected_public_key = try readOptionalHex(allocator, data, "expected_public_key");
    loaded.expected_secret_key = try readOptionalHex(allocator, data, "expected_secret_key");
    loaded.expected_signature = try readOptionalHex(allocator, data, "expected_signature");
    loaded.fixture = .{
        .name = name,
        .seed = loaded.seed,
        .message = loaded.message,
        .expected_public_key = loaded.expected_public_key,
        .expected_secret_key = loaded.expected_secret_key,
        .expected_signature = loaded.expected_signature,
    };
    return loaded;
}

pub fn runKemKatFixture(backend: PQCBackend, allocator: std.mem.Allocator, fixture: KemKatFixture) !void {
    if (!backend.algorithms.ml_kem_768) return error.UnsupportedAlgorithm;

    const kp = try backend.kemKeypair(allocator, fixture.key_seed);
    defer kp.deinit(allocator);
    if (fixture.expected_public_key) |expected| try std.testing.expectEqualSlices(u8, expected, kp.public_key);
    if (fixture.expected_secret_key) |expected| try std.testing.expectEqualSlices(u8, expected, kp.secret_key);

    const encapsulated = try backend.kemEncaps(allocator, kp.public_key, fixture.encaps_seed);
    defer encapsulated.deinit(allocator);
    if (fixture.expected_ciphertext) |expected| try std.testing.expectEqualSlices(u8, expected, encapsulated.ciphertext);
    if (fixture.expected_shared_secret) |expected| try std.testing.expectEqualSlices(u8, expected, encapsulated.shared_secret);

    const decapsulated = try backend.kemDecaps(allocator, kp.secret_key, encapsulated.ciphertext);
    defer allocator.free(decapsulated);
    try std.testing.expectEqualSlices(u8, encapsulated.shared_secret, decapsulated);
}

pub fn runSignKatFixture(backend: PQCBackend, allocator: std.mem.Allocator, fixture: SignKatFixture) !void {
    if (!backend.algorithms.ml_dsa_65) return error.UnsupportedAlgorithm;

    const kp = try backend.signKeypair(allocator, fixture.seed);
    defer kp.deinit(allocator);
    if (fixture.expected_public_key) |expected| try std.testing.expectEqualSlices(u8, expected, kp.public_key);
    if (fixture.expected_secret_key) |expected| try std.testing.expectEqualSlices(u8, expected, kp.secret_key);

    const signature = try backend.sign(allocator, fixture.message, kp.secret_key);
    defer allocator.free(signature);
    if (fixture.expected_signature) |expected| try std.testing.expectEqualSlices(u8, expected, signature);

    try std.testing.expect(try backend.verify(fixture.message, signature, kp.public_key));
}

fn ownedKeyPairFromArrays(allocator: std.mem.Allocator, public_key: []const u8, secret_key: []const u8) !OwnedKeyPair {
    const public_copy = try allocator.dupe(u8, public_key);
    errdefer allocator.free(public_copy);
    const secret_copy = try allocator.dupe(u8, secret_key);
    return .{
        .public_key = public_copy,
        .secret_key = secret_copy,
    };
}

pub fn secureZero(buffer: []u8) void {
    std.crypto.secureZero(u8, buffer);
}

fn readRequiredHex(allocator: std.mem.Allocator, data: []const u8, key: []const u8) ![]u8 {
    return try parseHexAlloc(allocator, findKatValue(data, key) orelse return error.InvalidKatFixture);
}

fn readOptionalHex(allocator: std.mem.Allocator, data: []const u8, key: []const u8) !?[]u8 {
    const value = findKatValue(data, key) orelse return null;
    return try parseHexAlloc(allocator, value);
}

fn readRequiredText(allocator: std.mem.Allocator, data: []const u8, key: []const u8) ![]u8 {
    return try allocator.dupe(u8, findKatValue(data, key) orelse return error.InvalidKatFixture);
}

fn findKatValue(data: []const u8, wanted_key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

fn parseHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, hex, " \t\r\n");
    if (trimmed.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, trimmed.len / 2);
    errdefer allocator.free(out);
    for (out, 0..) |*byte, i| {
        byte.* = try std.fmt.parseInt(u8, trimmed[i * 2 .. i * 2 + 2], 16);
    }
    return out;
}

fn unavailableKeypair(_: std.mem.Allocator, _: []const u8) anyerror!OwnedKeyPair {
    return error.BackendUnavailable;
}

fn unavailableEncaps(_: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!OwnedEncapsulatedSecret {
    return error.BackendUnavailable;
}

fn unavailableDecaps(_: std.mem.Allocator, _: []const u8, _: []const u8) anyerror![]u8 {
    return error.BackendUnavailable;
}

fn unavailableSign(_: std.mem.Allocator, _: []const u8, _: []const u8) anyerror![]u8 {
    return error.BackendUnavailable;
}

fn unavailableVerify(_: []const u8, _: []const u8, _: []const u8) anyerror!bool {
    return error.BackendUnavailable;
}
