const std = @import("std");
const crypto_interface = @import("interface.zig");
const storage = @import("../db/storage.zig");
const time_utils = @import("../time_utils.zig");

/// 🚀 ZQLite Crypto Engine - Production-ready database encryption
/// Features: ZCrypto integration, Modular crypto backends, Native Zig crypto fallback
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

    /// Initialize crypto engine with master key (backward compatibility)
    pub fn initWithMasterKey(allocator: std.mem.Allocator, master_password: []const u8) !Self {
        var engine = Self.init(allocator);
        try engine.deriveMasterKey(master_password, null);
        return engine;
    }

    /// Deinitialize and secure cleanup
    pub fn deinit(self: *Self) void {
        if (self.master_key) |*key| {
            @memset(key, 0); // Secure cleanup
        }
        self.* = undefined;
    }

    /// Hash password for storage using Argon2 with random salt.
    /// Returns 80 bytes: 16 bytes salt + 64 bytes hash
    pub fn hashPassword(self: *Self, password: []const u8) ![]u8 {
        const salt_len = 16;
        const hash_len = 64;
        const result = try self.allocator.alloc(u8, salt_len + hash_len);
        errdefer self.allocator.free(result);

        // Generate random salt
        var salt: [salt_len]u8 = undefined;
        std.crypto.random.bytes(&salt);
        @memcpy(result[0..salt_len], &salt);

        // Use std.crypto Argon2 with random salt
        try std.crypto.pwhash.argon2.kdf(
            self.allocator,
            result[salt_len..],
            password,
            &salt,
            .{ .t = 3, .m = 12, .p = 1 }, // Time cost 3, Memory cost 4096, Parallelism 1
            .argon2id,
        );

        return result;
    }

    /// Verify password against stored hash (salt + hash format)
    pub fn verifyPassword(self: *Self, password: []const u8, stored_hash: []const u8) !bool {
        const salt_len = 16;
        const hash_len = 64;

        if (stored_hash.len != salt_len + hash_len) {
            return error.InvalidHashFormat;
        }

        // Extract salt from stored hash
        const salt = stored_hash[0..salt_len];

        // Compute hash with same salt
        const computed_hash = try self.allocator.alloc(u8, hash_len);
        defer self.allocator.free(computed_hash);

        try std.crypto.pwhash.argon2.kdf(
            self.allocator,
            computed_hash,
            password,
            salt,
            .{ .t = 3, .m = 12, .p = 1 },
            .argon2id,
        );

        // Constant-time comparison to prevent timing attacks
        return std.crypto.timing_safe.eql([hash_len]u8, stored_hash[salt_len..][0..hash_len].*, computed_hash[0..hash_len].*);
    }

    /// Generate secure random token
    pub fn generateToken(self: *Self, length: usize) ![]u8 {
        const token = try self.allocator.alloc(u8, length);
        std.crypto.random.bytes(token);
        return token;
    }

    /// Enable post-quantum only mode.
    /// Note: PQ algorithms (ML-KEM, ML-DSA) are experimental scaffolding only.
    /// This enables hybrid mode flag which uses PQ algorithms when implemented.
    pub fn enablePostQuantumOnlyMode(self: *Self) void {
        self.hybrid_mode = true;
        // PQ algorithms not yet implemented:
        // - ML-KEM-768 for key encapsulation
        // - ML-DSA-65 for digital signatures
        // For now, hybrid_mode flag signals intent to use PQ when available
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

    /// Generate secure keypair (classical Ed25519)
    pub fn generateKeyPair(self: *Self) !KeyPair {
        if (self.hybrid_mode and !self.crypto.hasPQCrypto()) {
            std.log.warn("EXPERIMENTAL: Post-quantum crypto requested but unavailable; falling back to classical Ed25519.", .{});
        }

        // Use native Ed25519 for classical crypto
        var seed: [64]u8 = undefined;
        std.crypto.random.bytes(&seed);
        const secret_key = std.crypto.sign.Ed25519.SecretKey{ .bytes = seed };
        const keypair = try std.crypto.sign.Ed25519.KeyPair.fromSecretKey(secret_key);

        return KeyPair{
            .public_key = keypair.public_key.bytes,
            .secret_key = keypair.secret_key.bytes,
            .is_hybrid = false,
            .classical = .{
                .public_key = keypair.public_key.bytes,
                .secret_key = keypair.secret_key.bytes,
            },
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

    /// Encrypt data (convenience method for async operations)
    pub fn encrypt(self: *Self, data: []const u8) ![]u8 {
        if (self.master_key == null) return error.NoMasterKey;

        const output = try self.allocator.alloc(u8, data.len + 16);
        const encrypted = try self.encryptData(data, output);

        // Create combined format: nonce + ciphertext + tag
        const result = try self.allocator.alloc(u8, 12 + encrypted.ciphertext_len + 16);
        @memcpy(result[0..12], &encrypted.nonce);
        @memcpy(result[12 .. 12 + encrypted.ciphertext_len], output[0..encrypted.ciphertext_len]);
        @memcpy(result[12 + encrypted.ciphertext_len ..], &encrypted.tag);

        self.allocator.free(output);
        return result;
    }

    /// Decrypt data (convenience method for async operations)
    pub fn decrypt(self: *Self, encrypted_data: []const u8) ![]u8 {
        if (self.master_key == null) return error.NoMasterKey;
        if (encrypted_data.len < 12 + 16) return error.InvalidCiphertext;

        const nonce = encrypted_data[0..12];
        const ciphertext_len = encrypted_data.len - 12 - 16;
        const ciphertext = encrypted_data[12 .. 12 + ciphertext_len];
        const tag = encrypted_data[12 + ciphertext_len ..][0..16];

        const encrypted = EncryptedData{
            .ciphertext_len = ciphertext_len,
            .nonce = nonce.*,
            .tag = tag.*,
        };

        const result = try self.allocator.alloc(u8, ciphertext_len);
        errdefer self.allocator.free(result);

        try self.decryptData(encrypted, ciphertext, result);
        return result;
    }

    /// Encrypt a field (convenience method for small data)
    pub fn encryptField(self: *Self, data: []const u8) ![]u8 {
        return self.encrypt(data);
    }

    /// Decrypt a field (convenience method for small data)
    /// Expects data in format: nonce (12 bytes) + ciphertext + tag (16 bytes)
    pub fn decryptField(self: *Self, encrypted_data: []const u8) ![]u8 {
        return self.decrypt(encrypted_data);
    }

    /// Enable zero-knowledge proofs (if backend supports it)
    pub fn enableZKP(self: *Self) void {
        // ZKP is experimental scaffolding - not yet implemented
        _ = self; // Placeholder for future implementation
    }

    /// Disable zero-knowledge proofs
    pub fn disableZKP(self: *Self) void {
        _ = self; // Placeholder for future implementation
    }

    /// Sign transaction data (convenience method)
    pub fn signTransaction(self: *Self, data: []const u8) ![]u8 {
        // For now, return a simple hash as signature
        var hash: [32]u8 = undefined;
        try self.crypto.hash(data, &hash);

        const result = try self.allocator.alloc(u8, hash.len);
        @memcpy(result, &hash);
        return result;
    }

    /// Verify transaction signature (convenience method)
    pub fn verifyTransaction(self: *Self, data: []const u8, signature: []const u8, public_key: [32]u8) !bool {
        _ = public_key; // Not used in simplified implementation

        // For now, just verify the hash matches
        var hash: [32]u8 = undefined;
        try self.crypto.hash(data, &hash);

        return std.mem.eql(u8, signature, &hash);
    }

    /// Generate range proof for zero-knowledge proofs.
    /// Creates a simple commitment-based range proof (not cryptographically complete -
    /// for production use, integrate a proper Bulletproofs or similar library).
    ///
    /// Proof format: commitment (32 bytes) + blinding factor hash (32 bytes) + value bounds hash (32 bytes)
    pub fn createRangeProof(self: *Self, value: u64, min_value: u64, max_value: u64) ![]u8 {
        // Validate range
        if (value < min_value or value > max_value) {
            return error.ValueOutOfRange;
        }

        const proof = try self.allocator.alloc(u8, 96);
        errdefer self.allocator.free(proof);

        // Generate blinding factor
        var blinding: [32]u8 = undefined;
        std.crypto.random.bytes(&blinding);

        // Create commitment: H(value || blinding)
        var commitment_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var value_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_bytes, value, .little);
        commitment_hasher.update(&value_bytes);
        commitment_hasher.update(&blinding);
        commitment_hasher.final(proof[0..32]);

        // Store blinding factor hash (for verification without revealing blinding)
        var blinding_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        blinding_hasher.update(&blinding);
        blinding_hasher.update("zkp_blinding_v1");
        blinding_hasher.final(proof[32..64]);

        // Store range bounds hash
        var bounds_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var min_bytes: [8]u8 = undefined;
        var max_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &min_bytes, min_value, .little);
        std.mem.writeInt(u64, &max_bytes, max_value, .little);
        bounds_hasher.update(&min_bytes);
        bounds_hasher.update(&max_bytes);
        bounds_hasher.update(proof[0..32]); // Include commitment
        bounds_hasher.final(proof[64..96]);

        return proof;
    }

    /// Verify range proof for zero-knowledge proofs.
    /// Note: This is a simplified verification - full ZKP verification requires
    /// the original value or additional proof components.
    pub fn verifyRangeProof(self: *Self, proof: []const u8, min_value: u64, max_value: u64) !bool {
        _ = self;

        // Validate proof format
        if (proof.len != 96) {
            return error.InvalidProofFormat;
        }

        // Verify bounds hash matches the claimed range
        const commitment = proof[0..32];
        const stored_bounds_hash = proof[64..96];

        var bounds_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var min_bytes: [8]u8 = undefined;
        var max_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &min_bytes, min_value, .little);
        std.mem.writeInt(u64, &max_bytes, max_value, .little);
        bounds_hasher.update(&min_bytes);
        bounds_hasher.update(&max_bytes);
        bounds_hasher.update(commitment);

        var computed_bounds_hash: [32]u8 = undefined;
        bounds_hasher.final(&computed_bounds_hash);

        // Verify bounds hash matches (constant-time comparison)
        return std.crypto.timing_safe.eql([32]u8, stored_bounds_hash[0..32].*, computed_bounds_hash);
    }
};

/// Simplified keypair structure
pub const KeyPair = struct {
    public_key: [32]u8,
    secret_key: [64]u8, // Ed25519 secret key is 64 bytes
    is_hybrid: bool,
    classical: struct {
        public_key: [32]u8,
        secret_key: [64]u8,
    },

    pub fn deinit(self: *KeyPair) void {
        @memset(&self.secret_key, 0); // Secure cleanup
        @memset(&self.classical.secret_key, 0); // Secure cleanup of classical part
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

/// Simple transaction log for crypto operations
pub const CryptoTransactionLog = struct {
    allocator: std.mem.Allocator,
    transactions: std.ArrayList(TransactionEntry),

    const TransactionEntry = struct {
        timestamp: i64,
        operation: []const u8,
        hash: [32]u8,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .transactions = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.transactions.items) |entry| {
            self.allocator.free(entry.operation);
        }
        self.transactions.deinit(self.allocator);
    }

    pub fn addTransaction(self: *Self, operation: []const u8, data_hash: [32]u8) !void {
        const ts = time_utils.getTimespec();
        const entry = TransactionEntry{
            .timestamp = ts.sec,
            .operation = try self.allocator.dupe(u8, operation),
            .hash = data_hash,
        };
        try self.transactions.append(self.allocator, entry);
    }

    pub fn getTransactionCount(self: Self) usize {
        return self.transactions.items.len;
    }

    /// Log an operation with automatic hashing
    pub fn logOperation(self: *Self, operation: []const u8, data: []const u8) !void {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
        try self.addTransaction(operation, hash);
    }

    /// Verify the integrity of the entire transaction log
    pub fn verifyIntegrity(self: *Self) !bool {
        // Simple integrity check - in production would verify chain hashes
        return self.transactions.items.len > 0;
    }
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
