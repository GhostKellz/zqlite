const std = @import("std");
const crypto_interface = @import("interface.zig");
const storage = @import("../db/storage.zig");

/// 🚀 ZQLite v0.6.0 Crypto Engine - Next-generation database encryption
/// Features: Modular crypto backends, Native Zig crypto, Optional Shroud integration
pub const CryptoEngine = struct {
    allocator: std.mem.Allocator,
    crypto: crypto_interface.CryptoInterface,
    master_key: ?[32]u8,
    hybrid_mode: bool,

    const Self = @This();

    /// Initialize crypto engine with auto-detected configuration
    pub fn init(allocator: std.mem.Allocator) Self {
        const config = crypto_interface.detectAvailableFeatures();
        return Self{
            .allocator = allocator,
            .crypto = crypto_interface.CryptoInterface.init(config),
            .master_key = null,
            .hybrid_mode = config.enable_pq,
        };
    }

    /// Initialize crypto engine with custom configuration
    pub fn initWithConfig(allocator: std.mem.Allocator, config: crypto_interface.CryptoConfig) Self {
        return Self{
            .allocator = allocator,
            .crypto = crypto_interface.CryptoInterface.init(config),
            .master_key = null,
            .hybrid_mode = config.enable_pq,
        };
    }

    /// Deinitialize and secure cleanup
    pub fn deinit(self: *Self) void {
        if (self.master_key) |*key| {
            @memset(key, 0); // Secure cleanup
        }
        self.* = undefined;
    }

    /// Derive master key from password using HKDF
    pub fn deriveMasterKey(self: *Self, password: []const u8, salt: ?[]const u8) !void {
        var key: [32]u8 = undefined;
        var actual_salt: [32]u8 = undefined;

        if (salt) |s| {
            if (s.len >= 32) {
                @memcpy(actual_salt[0..32], s[0..32]);
            } else {
                @memcpy(actual_salt[0..s.len], s);
                @memset(actual_salt[s.len..], 0);
            }
        } else {
            // Generate random salt
            try self.crypto.randomBytes(&actual_salt);
        }

        const info = "ZQLite v0.6.0 Master Key";
        try self.crypto.hkdf(password, &actual_salt, info, &key);

        self.master_key = key;
    }

    /// Generate secure keypair (classical or hybrid)
    /// Note: Full post-quantum (ML-KEM-768) support requires Shroud library integration.
    /// Currently falls back to Ed25519 when PQ crypto is requested but unavailable.
    pub fn generateKeyPair(self: *Self) !KeyPair {
        if (self.crypto.hasPQCrypto() and self.hybrid_mode) {
            // Post-quantum hybrid mode requested but Shroud library not integrated
            // Fall back to classical Ed25519 with a warning
            std.log.warn("Post-quantum crypto requested but not available (requires Shroud library). Falling back to Ed25519.", .{});
        }

        // Use native Ed25519 for classical crypto (or as PQ fallback)
        const keypair = std.crypto.sign.Ed25519.KeyPair.create(null) catch |err| {
            std.log.err("Failed to generate Ed25519 keypair: {}", .{err});
            return err;
        };

        return KeyPair{
            .public_key = keypair.public_key.bytes,
            .secret_key = keypair.secret_key.bytes,
            .is_hybrid = false,
        };
    }

    /// Encrypt data with master key
    pub fn encryptData(self: *Self, plaintext: []const u8, output: []u8) !EncryptedData {
        if (self.master_key == null) return error.NoMasterKey;
        if (output.len < plaintext.len + 16) return error.OutputTooSmall;

        var nonce: [12]u8 = undefined;
        var tag: [16]u8 = undefined;

        try self.crypto.randomBytes(&nonce);
        try self.crypto.encrypt(self.master_key.?, nonce, plaintext, output[0..plaintext.len], &tag);

        return EncryptedData{
            .ciphertext_len = plaintext.len,
            .nonce = nonce,
            .tag = tag,
        };
    }

    /// Decrypt data with master key
    pub fn decryptData(self: *Self, encrypted: EncryptedData, ciphertext: []const u8, output: []u8) !void {
        if (self.master_key == null) return error.NoMasterKey;
        if (output.len < encrypted.ciphertext_len) return error.OutputTooSmall;
        if (ciphertext.len < encrypted.ciphertext_len) return error.InvalidCiphertext;

        try self.crypto.decrypt(self.master_key.?, encrypted.nonce, ciphertext[0..encrypted.ciphertext_len], encrypted.tag, output[0..encrypted.ciphertext_len]);
    }

    /// Hash data for integrity verification
    pub fn hashData(self: *Self, data: []const u8) ![32]u8 {
        var output: [32]u8 = undefined;
        try self.crypto.hash(data, &output);
        return output;
    }

    /// Check if post-quantum crypto is available
    pub fn isPostQuantumEnabled(self: Self) bool {
        return self.crypto.hasPQCrypto();
    }

    /// Check if zero-knowledge proofs are available
    pub fn isZKPEnabled(self: Self) bool {
        return self.crypto.hasZKP();
    }

    /// Get crypto backend information
    pub fn getBackendInfo(self: Self) BackendInfo {
        return BackendInfo{
            .backend = self.crypto.backend,
            .pq_crypto = self.crypto.hasPQCrypto(),
            .zkp = self.crypto.hasZKP(),
            .hybrid_mode = self.hybrid_mode,
        };
    }
};

/// Simplified keypair structure
pub const KeyPair = struct {
    public_key: [32]u8,
    secret_key: [64]u8, // Ed25519 secret key is 64 bytes
    is_hybrid: bool,

    pub fn deinit(self: *KeyPair) void {
        @memset(&self.secret_key, 0); // Secure cleanup
    }
};

/// Encrypted data container
pub const EncryptedData = struct {
    ciphertext_len: usize,
    nonce: [12]u8,
    tag: [16]u8,
};

/// Backend information
pub const BackendInfo = struct {
    backend: crypto_interface.CryptoBackend,
    pq_crypto: bool,
    zkp: bool,
    hybrid_mode: bool,
};

/// Test function for crypto engine
pub fn testCryptoEngine() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = CryptoEngine.init(allocator);
    defer engine.deinit();

    // Test key derivation
    try engine.deriveMasterKey("test_password", "test_salt_12345678901234567890");

    // Test encryption/decryption
    const plaintext = "Hello, ZQLite v0.6.0!";
    var ciphertext_buffer: [64]u8 = undefined;
    var plaintext_buffer: [64]u8 = undefined;

    const encrypted = try engine.encryptData(plaintext, &ciphertext_buffer);
    try engine.decryptData(encrypted, &ciphertext_buffer, &plaintext_buffer);

    // Verify decryption
    if (!std.mem.eql(u8, plaintext, plaintext_buffer[0..plaintext.len])) {
        return error.DecryptionFailed;
    }

    std.log.info("✅ ZQLite v0.6.0 Crypto Engine test passed!");
    std.log.info("Backend: {}, PQ: {}, ZKP: {}", .{
        engine.getBackendInfo().backend,
        engine.isPostQuantumEnabled(),
        engine.isZKPEnabled(),
    });
}
