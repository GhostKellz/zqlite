const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const time_utils = @import("../time_utils.zig");

pub const EncryptedStorage = struct {
    const Self = @This();

    pub const EncryptedSeed = struct {
        encrypted_data: []u8,
        iv: [16]u8,
        salt: [32]u8,
        iterations: u32,

        pub fn deinit(self: EncryptedSeed, allocator: Allocator) void {
            allocator.free(self.encrypted_data);
        }
    };

    pub const MasterKey = struct {
        key: [32]u8,

        pub fn fromPassword(password: []const u8, salt: [32]u8, iterations: u32) !MasterKey {
            var key: [32]u8 = undefined;
            crypto.pwhash.pbkdf2(&key, password, &salt, iterations, crypto.auth.hmac.HmacSha256);
            return MasterKey{ .key = key };
        }

        pub fn zeroize(self: *MasterKey) void {
            std.mem.set(u8, &self.key, 0);
        }
    };

    pub const SecureString = struct {
        data: []u8,
        allocator: Allocator,

        pub fn init(allocator: Allocator, data: []const u8) !SecureString {
            const secure_data = try allocator.alloc(u8, data.len);
            std.mem.copy(u8, secure_data, data);
            return SecureString{
                .data = secure_data,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *SecureString) void {
            // Zero out memory before freeing
            std.mem.set(u8, self.data, 0);
            self.allocator.free(self.data);
        }

        pub fn copy(self: SecureString, allocator: Allocator) !SecureString {
            return SecureString.init(allocator, self.data);
        }
    };

    pub fn encryptSeed(allocator: Allocator, seed: []const u8, password: []const u8) !EncryptedSeed {
        var salt: [32]u8 = undefined;
        crypto.random.bytes(&salt);

        var iv: [16]u8 = undefined;
        crypto.random.bytes(&iv);

        const iterations: u32 = 100000;
        const master_key = try MasterKey.fromPassword(password, salt, iterations);

        const encrypted_data = try allocator.alloc(u8, seed.len + 16); // 16 bytes for auth tag

        var aes = crypto.aead.aes_gcm.Aes256Gcm.init(master_key.key);
        const tag = aes.encrypt(encrypted_data[0..seed.len], seed, &iv, "");
        std.mem.copy(u8, encrypted_data[seed.len..], &tag);

        return EncryptedSeed{
            .encrypted_data = encrypted_data,
            .iv = iv,
            .salt = salt,
            .iterations = iterations,
        };
    }

    pub fn decryptSeed(allocator: Allocator, encrypted_seed: EncryptedSeed, password: []const u8) !SecureString {
        const master_key = try MasterKey.fromPassword(password, encrypted_seed.salt, encrypted_seed.iterations);

        if (encrypted_seed.encrypted_data.len < 16) {
            return error.InvalidEncryptedData;
        }

        const ciphertext_len = encrypted_seed.encrypted_data.len - 16;
        const ciphertext = encrypted_seed.encrypted_data[0..ciphertext_len];
        const tag = encrypted_seed.encrypted_data[ciphertext_len..];

        var aes = crypto.aead.aes_gcm.Aes256Gcm.init(master_key.key);

        const decrypted_data = try allocator.alloc(u8, ciphertext_len);
        errdefer allocator.free(decrypted_data);

        var tag_array: [16]u8 = undefined;
        std.mem.copy(u8, &tag_array, tag);

        aes.decrypt(decrypted_data, ciphertext, tag_array, &encrypted_seed.iv, "") catch {
            allocator.free(decrypted_data);
            return error.DecryptionFailed;
        };

        return SecureString{
            .data = decrypted_data,
            .allocator = allocator,
        };
    }

    pub fn encryptMnemonic(allocator: Allocator, mnemonic: []const u8, password: []const u8) !EncryptedSeed {
        return encryptSeed(allocator, mnemonic, password);
    }

    pub fn decryptMnemonic(allocator: Allocator, encrypted_mnemonic: EncryptedSeed, password: []const u8) !SecureString {
        return decryptSeed(allocator, encrypted_mnemonic, password);
    }
};

pub const WalletStorage = struct {
    const Self = @This();

    pub const StoredWallet = struct {
        id: []const u8,
        name: []const u8,
        coin_type: u32,
        encrypted_seed: EncryptedStorage.EncryptedSeed,
        created_at: i64,
        last_access: i64,

        pub fn deinit(self: StoredWallet, allocator: Allocator) void {
            self.encrypted_seed.deinit(allocator);
        }
    };

    allocator: Allocator,
    wallets: std.HashMap([]const u8, StoredWallet, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .wallets = std.HashMap([]const u8, StoredWallet, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.wallets.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.wallets.deinit();
    }

    pub fn storeWallet(self: *Self, wallet_id: []const u8, name: []const u8, coin_type: u32, mnemonic: []const u8, password: []const u8) !void {
        const encrypted_seed = try EncryptedStorage.encryptMnemonic(self.allocator, mnemonic, password);

        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const stored_wallet = StoredWallet{
            .id = try self.allocator.dupe(u8, wallet_id),
            .name = try self.allocator.dupe(u8, name),
            .coin_type = coin_type,
            .encrypted_seed = encrypted_seed,
            .created_at = timestamp,
            .last_access = timestamp,
        };

        try self.wallets.put(stored_wallet.id, stored_wallet);
    }

    pub fn loadWallet(self: *Self, wallet_id: []const u8, password: []const u8) !EncryptedStorage.SecureString {
        const stored_wallet = self.wallets.getPtr(wallet_id) orelse return error.WalletNotFound;

        // Update last access time
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        stored_wallet.last_access = timestamp;

        return EncryptedStorage.decryptMnemonic(self.allocator, stored_wallet.encrypted_seed, password);
    }

    pub fn walletExists(self: *Self, wallet_id: []const u8) bool {
        return self.wallets.contains(wallet_id);
    }

    pub fn deleteWallet(self: *Self, wallet_id: []const u8) bool {
        if (self.wallets.fetchRemove(wallet_id)) |kv| {
            kv.value.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn listWallets(self: *Self) ![]WalletInfo {
        var wallet_infos: std.ArrayList(WalletInfo) = .{};
        defer wallet_infos.deinit(self.allocator);

        var iterator = self.wallets.iterator();
        while (iterator.next()) |entry| {
            const wallet = entry.value_ptr;
            try wallet_infos.append(self.allocator, WalletInfo{
                .id = wallet.id,
                .name = wallet.name,
                .coin_type = wallet.coin_type,
                .created_at = wallet.created_at,
                .last_access = wallet.last_access,
            });
        }

        return wallet_infos.toOwnedSlice(self.allocator);
    }

    pub fn changePassword(self: *Self, wallet_id: []const u8, old_password: []const u8, new_password: []const u8) !void {
        const stored_wallet = self.wallets.getPtr(wallet_id) orelse return error.WalletNotFound;

        // Decrypt with old password
        var decrypted_mnemonic = try EncryptedStorage.decryptMnemonic(self.allocator, stored_wallet.encrypted_seed, old_password);
        defer decrypted_mnemonic.deinit();

        // Re-encrypt with new password
        stored_wallet.encrypted_seed.deinit(self.allocator);
        stored_wallet.encrypted_seed = try EncryptedStorage.encryptMnemonic(self.allocator, decrypted_mnemonic.data, new_password);
    }
};

pub const WalletInfo = struct {
    id: []const u8,
    name: []const u8,
    coin_type: u32,
    created_at: i64,
    last_access: i64,
};

pub const RecoveryManager = struct {
    const Self = @This();

    pub const RecoveryShare = struct {
        share_id: u8,
        data: []u8,
        threshold: u8,
        total_shares: u8,

        pub fn deinit(self: RecoveryShare, allocator: Allocator) void {
            allocator.free(self.data);
        }
    };

    pub fn splitSecret(allocator: Allocator, secret: []const u8, threshold: u8, total_shares: u8) ![]RecoveryShare {
        if (threshold > total_shares or threshold == 0) {
            return error.InvalidParameters;
        }

        var shares = try allocator.alloc(RecoveryShare, total_shares);
        errdefer allocator.free(shares);

        // Simplified Shamir's Secret Sharing implementation
        // In production, use a proper implementation
        for (shares, 0..) |*share, i| {
            share.* = RecoveryShare{
                .share_id = @intCast(i + 1),
                .data = try allocator.dupe(u8, secret), // Simplified: just duplicate
                .threshold = threshold,
                .total_shares = total_shares,
            };
        }

        return shares;
    }

    pub fn recoverSecret(allocator: Allocator, shares: []const RecoveryShare) ![]u8 {
        if (shares.len == 0) {
            return error.InsufficientShares;
        }

        const threshold = shares[0].threshold;
        if (shares.len < threshold) {
            return error.InsufficientShares;
        }

        // Simplified recovery - just return the first share's data
        // In production, implement proper Shamir's Secret Sharing reconstruction
        return allocator.dupe(u8, shares[0].data);
    }

    pub fn createRecoveryPlan(allocator: Allocator, wallet_id: []const u8, mnemonic: []const u8, threshold: u8, total_shares: u8) ![]RecoveryShare {
        const shares = try splitSecret(allocator, mnemonic, threshold, total_shares);

        // In production, you might want to store recovery metadata
        // or provide instructions for share distribution

        return shares;
    }
};

test "Encrypted storage" {
    const allocator = std.testing.allocator;

    const seed = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const password = "test_password_123";

    const encrypted_seed = try EncryptedStorage.encryptSeed(allocator, seed, password);
    defer encrypted_seed.deinit(allocator);

    var decrypted_seed = try EncryptedStorage.decryptSeed(allocator, encrypted_seed, password);
    defer decrypted_seed.deinit();

    try std.testing.expectEqualStrings(seed, decrypted_seed.data);

    // Test wrong password
    const wrong_password = "wrong_password";
    const decrypt_result = EncryptedStorage.decryptSeed(allocator, encrypted_seed, wrong_password);
    try std.testing.expectError(error.DecryptionFailed, decrypt_result);
}

test "Wallet storage" {
    const allocator = std.testing.allocator;

    var storage = WalletStorage.init(allocator);
    defer storage.deinit();

    const wallet_id = "test_wallet_123";
    const name = "Test Wallet";
    const coin_type: u32 = 0;
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const password = "test_password_123";

    try storage.storeWallet(wallet_id, name, coin_type, mnemonic, password);

    try std.testing.expect(storage.walletExists(wallet_id));

    var decrypted_mnemonic = try storage.loadWallet(wallet_id, password);
    defer decrypted_mnemonic.deinit();

    try std.testing.expectEqualStrings(mnemonic, decrypted_mnemonic.data);

    // Test password change
    const new_password = "new_password_456";
    try storage.changePassword(wallet_id, password, new_password);

    var decrypted_with_new_password = try storage.loadWallet(wallet_id, new_password);
    defer decrypted_with_new_password.deinit();

    try std.testing.expectEqualStrings(mnemonic, decrypted_with_new_password.data);

    // Test wallet deletion
    try std.testing.expect(storage.deleteWallet(wallet_id));
    try std.testing.expect(!storage.walletExists(wallet_id));
}

test "Recovery manager" {
    const allocator = std.testing.allocator;

    const secret = "my_secret_data";
    const threshold: u8 = 3;
    const total_shares: u8 = 5;

    const shares = try RecoveryManager.splitSecret(allocator, secret, threshold, total_shares);
    defer {
        for (shares) |share| {
            share.deinit(allocator);
        }
        allocator.free(shares);
    }

    try std.testing.expect(shares.len == total_shares);

    // Test recovery with sufficient shares
    const recovery_shares = shares[0..threshold];
    const recovered_secret = try RecoveryManager.recoverSecret(allocator, recovery_shares);
    defer allocator.free(recovered_secret);

    try std.testing.expectEqualStrings(secret, recovered_secret);

    // Test recovery with insufficient shares
    const insufficient_shares = shares[0 .. threshold - 1];
    const insufficient_result = RecoveryManager.recoverSecret(allocator, insufficient_shares);
    try std.testing.expectError(error.InsufficientShares, insufficient_result);
}
