const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const hd_wallet = @import("hd_wallet.zig");
const encrypted_storage = @import("encrypted_storage.zig");
const time_utils = @import("../time_utils.zig");

pub const KeyManager = struct {
    const Self = @This();

    pub const KeyType = enum {
        SECP256K1,
        ED25519,
        BLS12_381,
        DILITHIUM, // Post-quantum
    };

    pub const PrivateKey = struct {
        key_type: KeyType,
        key_data: []u8,
        public_key: []u8,

        pub fn deinit(self: PrivateKey, allocator: Allocator) void {
            allocator.free(self.key_data);
            allocator.free(self.public_key);
        }

        pub fn sign(self: PrivateKey, message: []const u8, allocator: Allocator) ![]u8 {
            return switch (self.key_type) {
                .SECP256K1 => self.signSecp256k1(message, allocator),
                .ED25519 => self.signEd25519(message, allocator),
                .BLS12_381 => self.signBls(message, allocator),
                .DILITHIUM => self.signDilithium(message, allocator),
            };
        }

        fn signSecp256k1(self: PrivateKey, message: []const u8, allocator: Allocator) ![]u8 {
            // Simplified SECP256K1 signing - use proper implementation in production
            const hash = crypto.hash.sha2.Sha256.hash(message);

            // Create signature (simplified - use proper ECDSA in production)
            const signature = try allocator.alloc(u8, 64);
            std.mem.copy(u8, signature[0..32], &hash);
            std.mem.copy(u8, signature[32..64], self.key_data[0..32]);

            return signature;
        }

        fn signEd25519(self: PrivateKey, message: []const u8, allocator: Allocator) ![]u8 {
            if (self.key_data.len != 32) return error.InvalidKeyLength;

            const keypair = try crypto.sign.Ed25519.KeyPair.fromSecretKey(self.key_data[0..32].*);
            const signature = try keypair.sign(message, null);

            return allocator.dupe(u8, &signature.toBytes());
        }

        fn signBls(self: PrivateKey, message: []const u8, allocator: Allocator) ![]u8 {
            // Simplified BLS signing - use proper BLS implementation in production
            const hash = crypto.hash.sha2.Sha256.hash(message);

            const signature = try allocator.alloc(u8, 96); // BLS signature is 96 bytes
            std.mem.copy(u8, signature[0..32], &hash);
            std.mem.copy(u8, signature[32..64], self.key_data[0..32]);
            std.mem.set(u8, signature[64..96], 0);

            return signature;
        }

        fn signDilithium(self: PrivateKey, message: []const u8, allocator: Allocator) ![]u8 {
            // Simplified post-quantum signing - use proper Dilithium in production
            const hash = crypto.hash.sha2.Sha256.hash(message);

            const signature = try allocator.alloc(u8, 2420); // Dilithium signature size
            std.mem.copy(u8, signature[0..32], &hash);
            std.mem.copy(u8, signature[32..64], self.key_data[0..32]);
            std.mem.set(u8, signature[64..], 0);

            return signature;
        }
    };

    pub const PublicKey = struct {
        key_type: KeyType,
        key_data: []u8,

        pub fn deinit(self: PublicKey, allocator: Allocator) void {
            allocator.free(self.key_data);
        }

        pub fn verify(self: PublicKey, message: []const u8, signature: []const u8) !bool {
            return switch (self.key_type) {
                .SECP256K1 => self.verifySecp256k1(message, signature),
                .ED25519 => self.verifyEd25519(message, signature),
                .BLS12_381 => self.verifyBls(message, signature),
                .DILITHIUM => self.verifyDilithium(message, signature),
            };
        }

        fn verifySecp256k1(self: PublicKey, message: []const u8, signature: []const u8) !bool {
            // Simplified SECP256K1 verification
            if (signature.len != 64) return false;

            const hash = crypto.hash.sha2.Sha256.hash(message);
            return std.mem.eql(u8, signature[0..32], &hash);
        }

        fn verifyEd25519(self: PublicKey, message: []const u8, signature: []const u8) !bool {
            if (self.key_data.len != 32 or signature.len != 64) return false;

            const public_key = crypto.sign.Ed25519.PublicKey.fromBytes(self.key_data[0..32].*) catch return false;
            const sig = crypto.sign.Ed25519.Signature.fromBytes(signature[0..64].*) catch return false;

            public_key.verify(message, sig, null) catch return false;
            return true;
        }

        fn verifyBls(self: PublicKey, message: []const u8, signature: []const u8) !bool {
            // Simplified BLS verification
            if (signature.len != 96) return false;

            const hash = crypto.hash.sha2.Sha256.hash(message);
            return std.mem.eql(u8, signature[0..32], &hash);
        }

        fn verifyDilithium(self: PublicKey, message: []const u8, signature: []const u8) !bool {
            // Simplified post-quantum verification
            if (signature.len != 2420) return false;

            const hash = crypto.hash.sha2.Sha256.hash(message);
            return std.mem.eql(u8, signature[0..32], &hash);
        }
    };

    pub const MasterKey = struct {
        seed: [64]u8,
        key_type: KeyType,

        pub fn deriveKey(self: MasterKey, path: []const u32, allocator: Allocator) !PrivateKey {
            // Derive key using HMAC-based key derivation
            var current_key = self.seed;

            for (path) |index| {
                var hmac = crypto.auth.hmac.HmacSha512.init(&current_key);
                hmac.update("key_derivation");
                hmac.update(&std.mem.toBytes(std.mem.nativeToBig(u32, index)));
                hmac.final(&current_key);
            }

            const private_key_data = try allocator.alloc(u8, 32);
            std.mem.copy(u8, private_key_data, current_key[0..32]);

            const public_key_data = try self.derivePublicKey(private_key_data, allocator);

            return PrivateKey{
                .key_type = self.key_type,
                .key_data = private_key_data,
                .public_key = public_key_data,
            };
        }

        fn derivePublicKey(self: MasterKey, private_key: []const u8, allocator: Allocator) ![]u8 {
            return switch (self.key_type) {
                .SECP256K1 => self.deriveSecp256k1PublicKey(private_key, allocator),
                .ED25519 => self.deriveEd25519PublicKey(private_key, allocator),
                .BLS12_381 => self.deriveBlsPublicKey(private_key, allocator),
                .DILITHIUM => self.deriveDilithiumPublicKey(private_key, allocator),
            };
        }

        fn deriveSecp256k1PublicKey(self: MasterKey, private_key: []const u8, allocator: Allocator) ![]u8 {
            _ = self;
            // Simplified SECP256K1 public key derivation
            const public_key = try allocator.alloc(u8, 33);
            public_key[0] = 0x02; // Compressed point prefix
            const hash = crypto.hash.sha2.Sha256.hash(private_key);
            std.mem.copy(u8, public_key[1..], &hash);
            return public_key;
        }

        fn deriveEd25519PublicKey(self: MasterKey, private_key: []const u8, allocator: Allocator) ![]u8 {
            _ = self;
            if (private_key.len != 32) return error.InvalidKeyLength;

            const keypair = try crypto.sign.Ed25519.KeyPair.fromSecretKey(private_key[0..32].*);
            return allocator.dupe(u8, &keypair.public_key.bytes);
        }

        fn deriveBlsPublicKey(self: MasterKey, private_key: []const u8, allocator: Allocator) ![]u8 {
            _ = self;
            // Simplified BLS public key derivation
            const public_key = try allocator.alloc(u8, 48);
            const hash = crypto.hash.sha2.Sha256.hash(private_key);
            std.mem.copy(u8, public_key[0..32], &hash);
            std.mem.set(u8, public_key[32..], 0);
            return public_key;
        }

        fn deriveDilithiumPublicKey(self: MasterKey, private_key: []const u8, allocator: Allocator) ![]u8 {
            _ = self;
            // Simplified post-quantum public key derivation
            const public_key = try allocator.alloc(u8, 1312); // Dilithium public key size
            const hash = crypto.hash.sha2.Sha256.hash(private_key);
            std.mem.copy(u8, public_key[0..32], &hash);
            std.mem.set(u8, public_key[32..], 0);
            return public_key;
        }
    };

    allocator: Allocator,
    wallet_storage: encrypted_storage.WalletStorage,
    master_keys: std.HashMap([]const u8, MasterKey, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .wallet_storage = encrypted_storage.WalletStorage.init(allocator),
            .master_keys = std.HashMap([]const u8, MasterKey, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.wallet_storage.deinit();
        self.master_keys.deinit();
    }

    pub fn createMasterKey(self: *Self, wallet_id: []const u8, key_type: KeyType, mnemonic: []const u8, password: []const u8) !void {
        const seed = try hd_wallet.HDWallet.seedFromMnemonic(mnemonic, password);

        const master_key = MasterKey{
            .seed = seed,
            .key_type = key_type,
        };

        const owned_wallet_id = try self.allocator.dupe(u8, wallet_id);
        try self.master_keys.put(owned_wallet_id, master_key);
    }

    pub fn deriveKey(self: *Self, wallet_id: []const u8, path: []const u32) !PrivateKey {
        const master_key = self.master_keys.get(wallet_id) orelse return error.WalletNotFound;
        return master_key.deriveKey(path, self.allocator);
    }

    pub fn signMessage(self: *Self, wallet_id: []const u8, path: []const u32, message: []const u8) ![]u8 {
        const key = try self.deriveKey(wallet_id, path);
        defer key.deinit(self.allocator);

        return key.sign(message, self.allocator);
    }

    pub fn verifySignature(self: *Self, public_key: PublicKey, message: []const u8, signature: []const u8) !bool {
        return public_key.verify(message, signature);
    }

    pub fn rotateKey(self: *Self, wallet_id: []const u8, old_path: []const u32, new_path: []const u32) !PrivateKey {
        // Derive new key
        const new_key = try self.deriveKey(wallet_id, new_path);

        // In a real implementation, you might want to:
        // 1. Update any stored references to the old key
        // 2. Invalidate the old key
        // 3. Log the key rotation for audit purposes

        return new_key;
    }

    pub fn exportPublicKey(self: *Self, wallet_id: []const u8, path: []const u32) !PublicKey {
        const key = try self.deriveKey(wallet_id, path);
        defer key.deinit(self.allocator);

        const public_key_data = try self.allocator.dupe(u8, key.public_key);

        return PublicKey{
            .key_type = key.key_type,
            .key_data = public_key_data,
        };
    }

    pub fn listWallets(self: *Self) ![][]const u8 {
        var wallet_ids: std.ArrayList([]const u8) = .{};
        defer wallet_ids.deinit(self.allocator);

        var iterator = self.master_keys.iterator();
        while (iterator.next()) |entry| {
            try wallet_ids.append(self.allocator, entry.key_ptr.*);
        }

        return wallet_ids.toOwnedSlice(self.allocator);
    }

    pub fn deleteWallet(self: *Self, wallet_id: []const u8) bool {
        if (self.master_keys.fetchRemove(wallet_id)) |kv| {
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }
};

pub const KeyStorage = struct {
    const Self = @This();

    pub const StoredKey = struct {
        key_id: []const u8,
        wallet_id: []const u8,
        derivation_path: []const u32,
        key_type: KeyManager.KeyType,
        public_key: []const u8,
        metadata: ?[]const u8,
        created_at: i64,
        last_used: i64,

        pub fn deinit(self: StoredKey, allocator: Allocator) void {
            allocator.free(self.key_id);
            allocator.free(self.wallet_id);
            allocator.free(self.derivation_path);
            allocator.free(self.public_key);
            if (self.metadata) |metadata| {
                allocator.free(metadata);
            }
        }
    };

    allocator: Allocator,
    keys: std.HashMap([]const u8, StoredKey, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .keys = std.HashMap([]const u8, StoredKey, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.keys.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.keys.deinit();
    }

    pub fn storeKey(self: *Self, key: StoredKey) !void {
        const key_id = try self.allocator.dupe(u8, key.key_id);
        try self.keys.put(key_id, key);
    }

    pub fn getKey(self: *Self, key_id: []const u8) ?StoredKey {
        return self.keys.get(key_id);
    }

    pub fn listKeys(self: *Self) ![]StoredKey {
        var keys: std.ArrayList(StoredKey) = .{};
        defer keys.deinit(self.allocator);

        var iterator = self.keys.iterator();
        while (iterator.next()) |entry| {
            try keys.append(self.allocator, entry.value_ptr.*);
        }

        return keys.toOwnedSlice(self.allocator);
    }

    pub fn deleteKey(self: *Self, key_id: []const u8) bool {
        if (self.keys.fetchRemove(key_id)) |kv| {
            kv.value.deinit(self.allocator);
            return true;
        }
        return false;
    }
};

test "Key manager operations" {
    const allocator = std.testing.allocator;

    var key_manager = KeyManager.init(allocator);
    defer key_manager.deinit();

    const wallet_id = "test_wallet";
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const password = "test_password";

    // Create master key
    try key_manager.createMasterKey(wallet_id, .ED25519, mnemonic, password);

    // Derive a key
    const path = [_]u32{ 44, 0, 0, 0, 0 };
    const key = try key_manager.deriveKey(wallet_id, &path);
    defer key.deinit(allocator);

    // Sign a message
    const message = "Hello, World!";
    const signature = try key_manager.signMessage(wallet_id, &path, message);
    defer allocator.free(signature);

    // Export public key
    const public_key = try key_manager.exportPublicKey(wallet_id, &path);
    defer public_key.deinit(allocator);

    // Verify signature
    const is_valid = try key_manager.verifySignature(public_key, message, signature);
    try std.testing.expect(is_valid);

    // Test key rotation
    const new_path = [_]u32{ 44, 0, 0, 0, 1 };
    const new_key = try key_manager.rotateKey(wallet_id, &path, &new_path);
    defer new_key.deinit(allocator);

    // Keys should be different
    try std.testing.expect(!std.mem.eql(u8, key.key_data, new_key.key_data));
}

test "Key storage operations" {
    const allocator = std.testing.allocator;

    var key_storage = KeyStorage.init(allocator);
    defer key_storage.deinit();

    const ts = time_utils.getTimespec();
    const timestamp = ts.sec;
    const stored_key = KeyStorage.StoredKey{
        .key_id = try allocator.dupe(u8, "test_key_123"),
        .wallet_id = try allocator.dupe(u8, "test_wallet"),
        .derivation_path = try allocator.dupe(u32, &[_]u32{ 44, 0, 0, 0, 0 }),
        .key_type = .ED25519,
        .public_key = try allocator.dupe(u8, "test_public_key"),
        .metadata = try allocator.dupe(u8, "test metadata"),
        .created_at = timestamp,
        .last_used = timestamp,
    };

    // Store key
    try key_storage.storeKey(stored_key);

    // Retrieve key
    const retrieved = key_storage.getKey("test_key_123");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("test_wallet", retrieved.?.wallet_id);

    // List keys
    const keys = try key_storage.listKeys();
    defer allocator.free(keys);
    try std.testing.expect(keys.len == 1);

    // Delete key
    const deleted = key_storage.deleteKey("test_key_123");
    try std.testing.expect(deleted);

    const not_found = key_storage.getKey("test_key_123");
    try std.testing.expect(not_found == null);
}
