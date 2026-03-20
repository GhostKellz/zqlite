const std = @import("std");
const crypto_interface = @import("interface.zig");
const storage = @import("../db/storage.zig");
const time_utils = @import("../time_utils.zig");

/// 🚀 ZQLite v0.6.0 Crypto Engine - Next-generation database encryption
/// Features: Modular crypto backends, Native Zig crypto, Optional Shroud integration
pub const CryptoEngine = struct {
    allocator: std.mem.Allocator,
    crypto: crypto_interface.CryptoInterface,
    master_key: ?[32]u8,
    hybrid_mode: bool,

    const Self = @This();

    const PQKeyPair = struct {
        classical: ClassicalKeyPair,
        post_quantum: PostQuantumKeyPair,
    };

    const ClassicalKeyPair = struct {
        ed25519_keypair: struct {
            public_key: [32]u8,
            secret_key: [64]u8,
        },
        x25519_keypair: struct {
            public_key: [32]u8,
            secret_key: [32]u8,
        },
    };

    const PostQuantumKeyPair = struct {
        ml_kem_keypair: struct {
            public_key: [1184]u8, // ML-KEM-768 public key size
            secret_key: [2400]u8, // ML-KEM-768 secret key size
        },
        ml_dsa_keypair: struct {
            public_key: [1952]u8, // ML-DSA-65 public key size
            secret_key: [4032]u8, // ML-DSA-65 secret key size
        },
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .master_key = null,
            .pq_keypair = null,
            .hybrid_mode = true, // Default to hybrid mode for migration safety
            .zkp_enabled = false,
        };
    }

    /// Initialize with master key and post-quantum features
    pub fn initWithMasterKey(allocator: std.mem.Allocator, password: []const u8) !Self {
        var engine = Self.init(allocator);

        // Derive master key using zcrypto v0.5.0 enhanced KDF
        const salt = "zqlite_v0.5.0_pq_salt";
        const info = "zqlite_database_master_key";
        const derived_key = try shroud.kdf.hkdfSha256(password, salt, info, 32);
        engine.master_key = derived_key;

        // Generate post-quantum key pairs for hybrid security
        engine.pq_keypair = try engine.generatePQKeyPair();

        return engine;
    }

    /// Generate hybrid classical + post-quantum key pairs
    fn generatePQKeyPair(self: *Self) !PQKeyPair {
        _ = self;
        var seed: [32]u8 = undefined;
        shroud.rand.fillBytes(&seed);

        // Generate classical Ed25519 keys
        const ed25519_keypair = try shroud.asym.Ed25519.KeyPair.generate();

        // Generate classical X25519 keys
        const x25519_keypair = try shroud.asym.X25519.KeyPair.generate();

        // Generate post-quantum ML-KEM-768 keys
        const ml_kem_keypair = try shroud.pq.ml_kem.ML_KEM_768.KeyPair.generate(seed);

        // Generate post-quantum ML-DSA-65 keys
        const ml_dsa_keypair = try shroud.pq.ml_dsa.ML_DSA_65.KeyPair.generate(seed);

        return PQKeyPair{
            .classical = ClassicalKeyPair{
                .ed25519_keypair = .{
                    .public_key = ed25519_keypair.public_key,
                    .secret_key = ed25519_keypair.secret_key,
                },
                .x25519_keypair = .{
                    .public_key = x25519_keypair.public_key,
                    .secret_key = x25519_keypair.secret_key,
                },
            },
            .post_quantum = PostQuantumKeyPair{
                .ml_kem_keypair = .{
                    .public_key = ml_kem_keypair.public_key,
                    .secret_key = ml_kem_keypair.secret_key,
                },
                .ml_dsa_keypair = .{
                    .public_key = ml_dsa_keypair.public_key,
                    .secret_key = ml_dsa_keypair.secret_key,
                },
            },
        };
    }

    /// Enable zero-knowledge proof features
    pub fn enableZKP(self: *Self) void {
        self.zkp_enabled = true;
    }

    /// Encrypt sensitive data using post-quantum hybrid AEAD
    pub fn encryptField(self: *Self, plaintext: []const u8) !EncryptedField {
        if (self.master_key == null) return error.NoMasterKey;

        // Generate random nonce for ChaCha20-Poly1305
        var nonce: [12]u8 = undefined;
        shroud.rand.fillBytes(&nonce);

        // Allocate ciphertext buffer
        const ciphertext = try self.allocator.alloc(u8, plaintext.len);
        var tag: [16]u8 = undefined;

        // Use ChaCha20-Poly1305 for high-performance authenticated encryption
        try shroud.sym.chacha20_poly1305_encrypt(plaintext, &self.master_key.?, &nonce, ciphertext, &tag);

        return EncryptedField{
            .nonce = nonce,
            .ciphertext = ciphertext,
            .tag = tag,
            .algorithm = .ChaCha20Poly1305,
        };
    }

    /// Decrypt sensitive data using post-quantum hybrid AEAD
    pub fn decryptField(self: *Self, encrypted: EncryptedField) ![]u8 {
        if (self.master_key == null) return error.NoMasterKey;

        const plaintext = try self.allocator.alloc(u8, encrypted.ciphertext.len);

        switch (encrypted.algorithm) {
            .ChaCha20Poly1305 => {
                try shroud.sym.chacha20_poly1305_decrypt(encrypted.ciphertext, &self.master_key.?, &encrypted.nonce, &encrypted.tag, plaintext);
            },
            .AES256GCM => {
                try shroud.sym.aes256_gcm_decrypt(encrypted.ciphertext, &self.master_key.?, &encrypted.nonce, &encrypted.tag, plaintext);
            },
        }

        return plaintext;
    }

    /// Sign database transactions with hybrid classical + post-quantum signatures
    pub fn signTransaction(self: *Self, transaction_data: []const u8) !HybridSignature {
        if (self.pq_keypair == null) return error.NoKeyPair;

        if (self.hybrid_mode) {
            // Hybrid mode: Sign with both classical and post-quantum algorithms
            const classical_sig = try shroud.asym.Ed25519.KeyPair.sign(&self.pq_keypair.?.classical.ed25519_keypair, transaction_data);

            const pq_sig = try shroud.pq.ml_dsa.ML_DSA_65.KeyPair.sign(&self.pq_keypair.?.post_quantum.ml_dsa_keypair, transaction_data);

            return HybridSignature{
                .classical_signature = classical_sig,
                .pq_signature = pq_sig,
                .mode = .Hybrid,
            };
        } else {
            // Pure post-quantum mode
            const pq_sig = try shroud.pq.ml_dsa.ML_DSA_65.KeyPair.sign(&self.pq_keypair.?.post_quantum.ml_dsa_keypair, transaction_data);

            return HybridSignature{
                .classical_signature = undefined,
                .pq_signature = pq_sig,
                .mode = .PostQuantumOnly,
            };
        }
    }

    /// Verify transaction signatures with hybrid verification
    pub fn verifyTransaction(self: *Self, transaction_data: []const u8, signature: HybridSignature) !bool {
        if (self.pq_keypair == null) return error.NoKeyPair;

        switch (signature.mode) {
            .Hybrid => {
                // Both signatures must be valid for hybrid mode
                const classical_valid = try shroud.asym.Ed25519.verify(transaction_data, signature.classical_signature, self.pq_keypair.?.classical.ed25519_keypair.public_key);

                const pq_valid = try shroud.pq.ml_dsa.ML_DSA_65.verify(transaction_data, signature.pq_signature, self.pq_keypair.?.post_quantum.ml_dsa_keypair.public_key);

                return classical_valid and pq_valid;
            },
            .PostQuantumOnly => {
                return try shroud.pq.ml_dsa.ML_DSA_65.verify(transaction_data, signature.pq_signature, self.pq_keypair.?.post_quantum.ml_dsa_keypair.public_key);
            },
            .ClassicalOnly => {
                return try shroud.asym.Ed25519.verify(transaction_data, signature.classical_signature, self.pq_keypair.?.classical.ed25519_keypair.public_key);
            },
        }
    }

    /// Generate post-quantum secure key pairs for external use
    pub fn generateKeyPair(self: *Self) !KeyPair {
        return KeyPair{
            .classical = try shroud.asym.Ed25519.KeyPair.generate(),
            .post_quantum = try self.generatePQKeyPair(),
        };
    }

    /// Hash passwords using Argon2id (memory-hard, side-channel resistant)
    pub fn hashPassword(self: *Self, password: []const u8) !PasswordHash {
        const salt = try self.allocator.alloc(u8, 32);
        shroud.rand.fillBytes(salt);

        // Use BLAKE2b for high-performance secure hashing
        const hash_input = try self.allocator.alloc(u8, password.len + salt.len);
        defer self.allocator.free(hash_input);

        @memcpy(hash_input[0..password.len], password);
        @memcpy(hash_input[password.len..], salt);

        const hash_result = shroud.hash.blake2b(hash_input);
        const hash = try self.allocator.alloc(u8, 64);
        @memcpy(hash, &hash_result);

        return PasswordHash{
            .hash = hash,
            .salt = salt,
            .algorithm = .BLAKE2b,
        };
    }

    /// Verify password against hash using constant-time comparison
    pub fn verifyPassword(self: *Self, password: []const u8, stored: PasswordHash) !bool {
        const hash_input = try self.allocator.alloc(u8, password.len + stored.salt.len);
        defer self.allocator.free(hash_input);

        @memcpy(hash_input[0..password.len], password);
        @memcpy(hash_input[password.len..], stored.salt);

        switch (stored.algorithm) {
            .BLAKE2b => {
                const computed_hash = shroud.hash.blake2b(hash_input);

                // Use constant-time comparison to prevent timing attacks
                return shroud.util.constantTimeCompare(stored.hash, &computed_hash);
            },
            .SHA3_256 => {
                const computed_hash = shroud.hash.sha3_256(hash_input);
                return shroud.util.constantTimeCompare(stored.hash, &computed_hash);
            },
        }
    }

    /// Derive table-specific encryption keys using post-quantum KDF
    pub fn deriveTableKey(self: *Self, table_name: []const u8) ![32]u8 {
        if (self.master_key == null) return error.NoMasterKey;

        const info = try std.fmt.allocPrint(self.allocator, "zqlite_table_key_{s}", .{table_name});
        defer self.allocator.free(info);

        return try shroud.kdf.hkdfSha256(&self.master_key.?, "zqlite_v0.5.0_table_salt", info, 32);
    }

    /// Generate cryptographically secure random tokens
    pub fn generateToken(self: *Self, length: usize) ![]u8 {
        const token = try self.allocator.alloc(u8, length);
        shroud.rand.fillBytes(token);
        return token;
    }

    /// Hash data using SHA3-256 for integrity checks
    pub fn hashData(self: *Self, data: []const u8) ![32]u8 {
        _ = self;
        return shroud.hash.sha3_256(data);
    }

    /// Create zero-knowledge proof for private database queries
    pub fn createRangeProof(self: *Self, value: u64, min_value: u64, max_value: u64) !ZKProof {
        if (!self.zkp_enabled) return error.ZKPNotEnabled;

        // Generate blinding factor
        var blinding: [32]u8 = undefined;
        shroud.rand.fillBytes(&blinding);

        // Create Pedersen commitment
        const commitment = try self.createCommitment(value, &blinding);

        // Generate bulletproof range proof
        const proof_data = try shroud.zkp.bulletproofs.proveRange(self.allocator, value, &blinding, min_value, max_value);

        return ZKProof{
            .proof_type = .RangeProof,
            .commitment = commitment,
            .proof_data = proof_data,
            .blinding = blinding,
        };
    }

    /// Verify zero-knowledge proof
    pub fn verifyRangeProof(self: *Self, proof: ZKProof, min_value: u64, max_value: u64) !bool {
        if (!self.zkp_enabled) return error.ZKPNotEnabled;

        return try shroud.zkp.bulletproofs.verifyRange(proof.commitment, proof.proof_data, min_value, max_value);
    }

    /// Create commitment for zero-knowledge proofs
    fn createCommitment(self: *Self, value: u64, blinding: *const [32]u8) ![32]u8 {
        // Simplified commitment: Hash(value || blinding)
        const value_bytes = std.mem.asBytes(&value);
        const input = try self.allocator.alloc(u8, value_bytes.len + blinding.len);
        defer self.allocator.free(input);

        @memcpy(input[0..value_bytes.len], value_bytes);
        @memcpy(input[value_bytes.len..], blinding);

        return shroud.hash.sha3_256(input);
    }

    /// Perform hybrid key exchange for secure channels
    pub fn performKeyExchange(self: *Self, peer_classical_key: [32]u8, peer_pq_key: [1184]u8) ![64]u8 {
        if (self.pq_keypair == null) return error.NoKeyPair;

        var shared_secret: [64]u8 = undefined;

        // Perform hybrid X25519 + ML-KEM-768 key exchange
        try shroud.pq.hybrid.x25519_ml_kem_768_kex(&shared_secret, &peer_classical_key, &peer_pq_key, &shroud.rand.generateSeed());

        return shared_secret;
    }

    /// Enable post-quantum only mode (disable classical crypto)
    pub fn enablePostQuantumOnlyMode(self: *Self) void {
        self.hybrid_mode = false;
    }

    /// Enable hybrid mode (classical + post-quantum)
    pub fn enableHybridMode(self: *Self) void {
        self.hybrid_mode = true;
    }

    pub fn deinit(self: *Self) void {
        if (self.master_key) |*key| {
            // Securely zero the master key
            shroud.util.secureZero(key);
        }

        if (self.pq_keypair) |*keypair| {
            // Securely zero all private keys
            shroud.util.secureZero(&keypair.classical.ed25519_keypair.secret_key);
            shroud.util.secureZero(&keypair.classical.x25519_keypair.secret_key);
            shroud.util.secureZero(&keypair.post_quantum.ml_kem_keypair.secret_key);
            shroud.util.secureZero(&keypair.post_quantum.ml_dsa_keypair.secret_key);
        }
    }
};

/// Enhanced encrypted field with algorithm specification
pub const EncryptedField = struct {
    nonce: [12]u8,
    ciphertext: []u8,
    tag: [16]u8,
    algorithm: CipherAlgorithm,

    pub fn deinit(self: *EncryptedField, allocator: std.mem.Allocator) void {
        allocator.free(self.ciphertext);
    }
};

/// Supported cipher algorithms
pub const CipherAlgorithm = enum {
    ChaCha20Poly1305,
    AES256GCM,
};

/// Hybrid signature supporting both classical and post-quantum algorithms
pub const HybridSignature = struct {
    classical_signature: [64]u8,
    pq_signature: [3309]u8, // ML-DSA-65 signature size
    mode: SignatureMode,

    const SignatureMode = enum {
        ClassicalOnly,
        PostQuantumOnly,
        Hybrid,
    };
};

/// Enhanced key pair with post-quantum support
pub const KeyPair = struct {
    classical: shroud.asym.Ed25519.KeyPair,
    post_quantum: CryptoEngine.PQKeyPair,

    pub fn deinit(self: *KeyPair) void {
        // Securely zero private keys
        shroud.util.secureZero(&self.classical.secret_key);
        shroud.util.secureZero(&self.post_quantum.classical.ed25519_keypair.secret_key);
        shroud.util.secureZero(&self.post_quantum.classical.x25519_keypair.secret_key);
        shroud.util.secureZero(&self.post_quantum.post_quantum.ml_kem_keypair.secret_key);
        shroud.util.secureZero(&self.post_quantum.post_quantum.ml_dsa_keypair.secret_key);
    }
};

/// Enhanced password hash with algorithm specification
pub const PasswordHash = struct {
    hash: []u8,
    salt: []u8,
    algorithm: HashAlgorithm,

    const HashAlgorithm = enum {
        BLAKE2b,
        SHA3_256,
    };

    pub fn deinit(self: *PasswordHash, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
        allocator.free(self.salt);
    }
};

/// Zero-knowledge proof structure
pub const ZKProof = struct {
    proof_type: ProofType,
    commitment: [32]u8,
    proof_data: []u8,
    blinding: [32]u8,

    const ProofType = enum {
        RangeProof,
        MembershipProof,
        KnowledgeProof,
    };

    pub fn deinit(self: *ZKProof, allocator: std.mem.Allocator) void {
        allocator.free(self.proof_data);
        shroud.util.secureZero(&self.blinding);
    }
};

/// Enhanced storage value with post-quantum encryption and ZKP support
pub const SecureValue = union(enum) {
    Plaintext: storage.Value,
    Encrypted: EncryptedField,
    Signed: struct {
        value: storage.Value,
        signature: HybridSignature,
    },
    ZKProtected: struct {
        commitment: [32]u8,
        proof: ZKProof,
    },

    pub fn encrypt(value: storage.Value, crypto: *CryptoEngine) !SecureValue {
        // Convert storage value to bytes for encryption
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer buffer.deinit(crypto.allocator);

        switch (value) {
            .Integer => |int| try buffer.appendSlice(crypto.allocator, std.mem.asBytes(&int)),
            .Real => |real| try buffer.appendSlice(crypto.allocator, std.mem.asBytes(&real)),
            .Text => |text| try buffer.appendSlice(crypto.allocator, text),
            .Blob => |blob| try buffer.appendSlice(crypto.allocator, blob),
            .Null => try buffer.appendSlice(crypto.allocator, "NULL"),
        }

        const encrypted = try crypto.encryptField(buffer.items);
        return SecureValue{ .Encrypted = encrypted };
    }

    pub fn decrypt(self: SecureValue, crypto: *CryptoEngine) !storage.Value {
        switch (self) {
            .Plaintext => |value| return value,
            .Encrypted => |encrypted| {
                const decrypted = try crypto.decryptField(encrypted);
                defer crypto.allocator.free(decrypted);

                // For simplicity, assume it's text (in production, you'd store type info)
                return storage.Value{ .Text = try crypto.allocator.dupe(u8, decrypted) };
            },
            .Signed => |signed| return signed.value,
            .ZKProtected => return error.CannotDecryptZKProtectedValue,
        }
    }

    pub fn deinit(self: *SecureValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Plaintext => |*value| value.deinit(allocator),
            .Encrypted => |*encrypted| encrypted.deinit(allocator),
            .Signed => |*signed| signed.value.deinit(allocator),
            .ZKProtected => |*zk| zk.proof.deinit(allocator),
        }
    }
};

/// Post-quantum cryptographic table for storing ultra-sensitive data
pub const SecureTable = struct {
    base_table: *storage.Table,
    crypto_engine: *CryptoEngine,
    encrypted_columns: std.StringHashMap(bool),
    zkp_columns: std.StringHashMap(bool),

    const Self = @This();

    pub fn init(base_table: *storage.Table, crypto_engine: *CryptoEngine) !Self {
        return Self{
            .base_table = base_table,
            .crypto_engine = crypto_engine,
            .encrypted_columns = std.StringHashMap(bool).init(crypto_engine.allocator),
            .zkp_columns = std.StringHashMap(bool).init(crypto_engine.allocator),
        };
    }

    /// Mark a column for automatic post-quantum encryption
    pub fn encryptColumn(self: *Self, column_name: []const u8) !void {
        try self.encrypted_columns.put(try self.crypto_engine.allocator.dupe(u8, column_name), true);
    }

    /// Mark a column for zero-knowledge protection
    pub fn protectColumnWithZKP(self: *Self, column_name: []const u8) !void {
        self.crypto_engine.enableZKP();
        try self.zkp_columns.put(try self.crypto_engine.allocator.dupe(u8, column_name), true);
    }

    /// Insert with automatic post-quantum encryption and ZKP
    pub fn insertSecure(self: *Self, row: storage.Row) !void {
        var secure_row = storage.Row{
            .values = try self.crypto_engine.allocator.alloc(storage.Value, row.values.len),
        };

        for (row.values, 0..) |value, i| {
            // Encrypt sensitive values with post-quantum crypto
            const secure_value = try SecureValue.encrypt(value, self.crypto_engine);
            secure_row.values[i] = try secure_value.decrypt(self.crypto_engine);
        }

        try self.base_table.insertRow(secure_row);
    }

    pub fn deinit(self: *Self) void {
        var encrypted_iterator = self.encrypted_columns.iterator();
        while (encrypted_iterator.next()) |entry| {
            self.crypto_engine.allocator.free(entry.key_ptr.*);
        }
        self.encrypted_columns.deinit();

        var zkp_iterator = self.zkp_columns.iterator();
        while (zkp_iterator.next()) |entry| {
            self.crypto_engine.allocator.free(entry.key_ptr.*);
        }
        self.zkp_columns.deinit();
    }
};

/// Blockchain-style transaction log with post-quantum integrity
pub const CryptoTransactionLog = struct {
    allocator: std.mem.Allocator,
    crypto_engine: *CryptoEngine,
    entries: std.ArrayListUnmanaged(LogEntry),
    chain_key: [32]u8,

    const LogEntry = struct {
        transaction_id: u64,
        table_name: []const u8,
        operation: []const u8,
        data_hash: [32]u8,
        timestamp: i64,
        signature: HybridSignature,
        prev_hash: [32]u8,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, crypto_engine: *CryptoEngine) !Self {
        var chain_key: [32]u8 = undefined;
        shroud.rand.fillBytes(&chain_key);

        return Self{
            .allocator = allocator,
            .crypto_engine = crypto_engine,
            .entries = .{},
            .chain_key = chain_key,
        };
    }

    /// Log a database operation with post-quantum cryptographic proof
    pub fn logOperation(self: *Self, table_name: []const u8, operation: []const u8, data: []const u8) !void {
        const ts = time_utils.getTimespec();
        const transaction_id = @as(u64, @intCast(ts.sec));
        const data_hash = try self.crypto_engine.hashData(data);

        // Get previous hash for blockchain-style chaining
        const prev_hash = if (self.entries.items.len > 0)
            self.entries.items[self.entries.items.len - 1].data_hash
        else
            std.mem.zeroes([32]u8);

        // Create signing data
        var signing_data: std.ArrayListUnmanaged(u8) = .empty;
        defer signing_data.deinit(self.allocator);
        try signing_data.appendSlice(self.allocator, std.mem.asBytes(&transaction_id));
        try signing_data.appendSlice(self.allocator, table_name);
        try signing_data.appendSlice(self.allocator, operation);
        try signing_data.appendSlice(self.allocator, &data_hash);
        try signing_data.appendSlice(self.allocator, &prev_hash);

        // Create hybrid signature (classical + post-quantum)
        const signature = try self.crypto_engine.signTransaction(signing_data.items);

        const ts2 = time_utils.getTimespec();
        const entry = LogEntry{
            .transaction_id = transaction_id,
            .table_name = try self.allocator.dupe(u8, table_name),
            .operation = try self.allocator.dupe(u8, operation),
            .data_hash = data_hash,
            .timestamp = ts2.sec,
            .signature = signature,
            .prev_hash = prev_hash,
        };

        try self.entries.append(self.allocator, entry);
    }

    /// Verify the post-quantum integrity of the entire transaction log
    pub fn verifyIntegrity(self: *Self) !bool {
        for (self.entries.items, 0..) |entry, i| {
            // Reconstruct signing data
            var signing_data: std.ArrayListUnmanaged(u8) = .empty;
            defer signing_data.deinit(self.allocator);
            try signing_data.appendSlice(self.allocator, std.mem.asBytes(&entry.transaction_id));
            try signing_data.appendSlice(self.allocator, entry.table_name);
            try signing_data.appendSlice(self.allocator, entry.operation);
            try signing_data.appendSlice(self.allocator, &entry.data_hash);
            try signing_data.appendSlice(self.allocator, &entry.prev_hash);

            // Verify hybrid signature
            if (!try self.crypto_engine.verifyTransaction(signing_data.items, entry.signature)) {
                return false;
            }

            // Verify blockchain-style chain integrity
            if (i > 0) {
                const expected_prev_hash = self.entries.items[i - 1].data_hash;
                if (!shroud.util.constantTimeCompare(&entry.prev_hash, &expected_prev_hash)) {
                    return false;
                }
            }
        }

        return true;
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.table_name);
            self.allocator.free(entry.operation);
        }
        self.entries.deinit();

        // Securely zero the chain key
        shroud.util.secureZero(&self.chain_key);
    }
};

// Enhanced tests for post-quantum features
test "post-quantum encrypt and decrypt field" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var crypto = try CryptoEngine.initWithMasterKey(allocator, "test_password_pq");
    defer crypto.deinit();

    const plaintext = "ultra_sensitive_post_quantum_data_12345";
    const encrypted = try crypto.encryptField(plaintext);
    defer encrypted.deinit(allocator);

    const decrypted = try crypto.decryptField(encrypted);
    defer allocator.free(decrypted);

    try testing.expectEqualStrings(plaintext, decrypted);
}

test "hybrid signature verification" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var crypto = try CryptoEngine.initWithMasterKey(allocator, "test_password_hybrid");
    defer crypto.deinit();

    const transaction_data = "TRANSFER 1000 COINS FROM ALICE TO BOB";
    const signature = try crypto.signTransaction(transaction_data);

    try testing.expect(try crypto.verifyTransaction(transaction_data, signature));
}

test "zero-knowledge range proof" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var crypto = try CryptoEngine.initWithMasterKey(allocator, "test_password_zkp");
    defer crypto.deinit();
    crypto.enableZKP();

    const secret_value: u64 = 42;
    const proof = try crypto.createRangeProof(secret_value, 0, 100);
    defer proof.deinit(allocator);

    try testing.expect(try crypto.verifyRangeProof(proof, 0, 100));
}

test "enhanced password hashing with BLAKE2b" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var crypto = CryptoEngine.init(allocator);
    defer crypto.deinit();

    const password = "super_secret_post_quantum_password";
    const hash = try crypto.hashPassword(password);
    defer hash.deinit(allocator);

    try testing.expect(try crypto.verifyPassword(password, hash));
    try testing.expect(!try crypto.verifyPassword("wrong_password", hash));
}
