const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const time_utils = @import("../time_utils.zig");

pub const HDWallet = struct {
    const Self = @This();

    pub const DerivationPath = struct {
        purpose: u32,
        coin_type: u32,
        account: u32,
        change: u32,
        address_index: u32,

        pub fn fromString(path: []const u8) !DerivationPath {
            // Parse BIP44 path like "m/44'/0'/0'/0/0"
            var parts = std.mem.split(u8, path, "/");
            _ = parts.next(); // skip "m"

            const purpose = try std.fmt.parseInt(u32, std.mem.trimEnd(u8, parts.next().?, "'"), 10);
            const coin_type = try std.fmt.parseInt(u32, std.mem.trimEnd(u8, parts.next().?, "'"), 10);
            const account = try std.fmt.parseInt(u32, std.mem.trimEnd(u8, parts.next().?, "'"), 10);
            const change = try std.fmt.parseInt(u32, parts.next().?, 10);
            const address_index = try std.fmt.parseInt(u32, parts.next().?, 10);

            return DerivationPath{
                .purpose = purpose,
                .coin_type = coin_type,
                .account = account,
                .change = change,
                .address_index = address_index,
            };
        }

        pub fn toString(self: DerivationPath, allocator: Allocator) ![]u8 {
            return std.fmt.allocPrint(allocator, "m/{d}'/{d}'/{d}'/{d}/{d}", .{ self.purpose, self.coin_type, self.account, self.change, self.address_index });
        }
    };

    pub const ExtendedKey = struct {
        key: [32]u8,
        chain_code: [32]u8,
        depth: u8,
        parent_fingerprint: [4]u8,
        child_index: u32,

        pub fn deriveChild(self: ExtendedKey, index: u32, hardened: bool) !ExtendedKey {
            var hmac = crypto.auth.hmac.HmacSha512.init(&self.chain_code);

            if (hardened) {
                hmac.update(&[_]u8{0});
                hmac.update(&self.key);
                hmac.update(&std.mem.toBytes(std.mem.nativeToBig(u32, index | 0x80000000)));
            } else {
                // For non-hardened derivation, we'd need the public key
                // This is a simplified implementation
                hmac.update(&self.key);
                hmac.update(&std.mem.toBytes(std.mem.nativeToBig(u32, index)));
            }

            var result: [64]u8 = undefined;
            hmac.final(&result);

            var child_key: [32]u8 = undefined;
            var child_chain_code: [32]u8 = undefined;
            std.mem.copy(u8, &child_key, result[0..32]);
            std.mem.copy(u8, &child_chain_code, result[32..64]);

            var parent_fingerprint: [4]u8 = undefined;
            std.mem.copy(u8, &parent_fingerprint, self.key[0..4]);

            return ExtendedKey{
                .key = child_key,
                .chain_code = child_chain_code,
                .depth = self.depth + 1,
                .parent_fingerprint = parent_fingerprint,
                .child_index = index,
            };
        }
    };

    pub const Wallet = struct {
        id: []const u8,
        name: []const u8,
        master_key: ExtendedKey,
        coin_type: u32,
        created_at: i64,

        pub fn deriveAccount(self: Wallet, account_index: u32) !ExtendedKey {
            const purpose_key = try self.master_key.deriveChild(44, true);
            const coin_key = try purpose_key.deriveChild(self.coin_type, true);
            return coin_key.deriveChild(account_index, true);
        }

        pub fn deriveAddress(self: Wallet, account_index: u32, change: u32, address_index: u32) !ExtendedKey {
            const account_key = try self.deriveAccount(account_index);
            const change_key = try account_key.deriveChild(change, false);
            return change_key.deriveChild(address_index, false);
        }

        pub fn getReceiveAddress(self: Wallet, account_index: u32, address_index: u32) !ExtendedKey {
            return self.deriveAddress(account_index, 0, address_index);
        }

        pub fn getChangeAddress(self: Wallet, account_index: u32, address_index: u32) !ExtendedKey {
            return self.deriveAddress(account_index, 1, address_index);
        }
    };

    pub fn generateMnemonic(allocator: Allocator, entropy_bits: u16) ![]u8 {
        const entropy_bytes = entropy_bits / 8;
        var entropy = try allocator.alloc(u8, entropy_bytes);
        defer allocator.free(entropy);

        crypto.random.bytes(entropy);

        // Convert entropy to mnemonic (simplified implementation)
        // In a real implementation, you'd use BIP39 wordlist
        var mnemonic: std.ArrayListUnmanaged(u8) = .empty;
        defer mnemonic.deinit(allocator);

        for (entropy) |byte| {
            try mnemonic.writer(allocator).print("{x:02} ", .{byte});
        }

        return mnemonic.toOwnedSlice(allocator);
    }

    pub fn seedFromMnemonic(mnemonic: []const u8, passphrase: []const u8) ![64]u8 {
        var seed: [64]u8 = undefined;

        // PBKDF2 with HMAC-SHA512
        const salt = try std.fmt.allocPrint(std.heap.page_allocator, "mnemonic{s}", .{passphrase});
        defer std.heap.page_allocator.free(salt);

        crypto.pwhash.pbkdf2(&seed, mnemonic, salt, 2048, crypto.auth.hmac.HmacSha512);

        return seed;
    }

    pub fn masterKeyFromSeed(seed: [64]u8) !ExtendedKey {
        const hmac_key = "ed25519 seed";
        var hmac = crypto.auth.hmac.HmacSha512.init(hmac_key);
        hmac.update(&seed);

        var result: [64]u8 = undefined;
        hmac.final(&result);

        var master_key: [32]u8 = undefined;
        var chain_code: [32]u8 = undefined;
        std.mem.copy(u8, &master_key, result[0..32]);
        std.mem.copy(u8, &chain_code, result[32..64]);

        return ExtendedKey{
            .key = master_key,
            .chain_code = chain_code,
            .depth = 0,
            .parent_fingerprint = [4]u8{ 0, 0, 0, 0 },
            .child_index = 0,
        };
    }

    pub fn createWallet(allocator: Allocator, name: []const u8, coin_type: u32, mnemonic: []const u8, passphrase: []const u8) !Wallet {
        const seed = try seedFromMnemonic(mnemonic, passphrase);
        const master_key = try masterKeyFromSeed(seed);

        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const wallet_id = try std.fmt.allocPrint(allocator, "wallet_{d}", .{timestamp});

        return Wallet{
            .id = wallet_id,
            .name = try allocator.dupe(u8, name),
            .master_key = master_key,
            .coin_type = coin_type,
            .created_at = timestamp,
        };
    }
};

pub const WalletManager = struct {
    const Self = @This();

    allocator: Allocator,
    wallets: std.HashMap([]const u8, HDWallet.Wallet, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .wallets = std.HashMap([]const u8, HDWallet.Wallet, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.wallets.deinit();
    }

    pub fn addWallet(self: *Self, wallet: HDWallet.Wallet) !void {
        try self.wallets.put(wallet.id, wallet);
    }

    pub fn getWallet(self: *Self, wallet_id: []const u8) ?HDWallet.Wallet {
        return self.wallets.get(wallet_id);
    }

    pub fn listWallets(self: *Self) []const HDWallet.Wallet {
        var wallets: std.ArrayListUnmanaged(HDWallet.Wallet) = .empty;
        defer wallets.deinit(self.allocator);

        var iterator = self.wallets.iterator();
        while (iterator.next()) |entry| {
            wallets.append(self.allocator, entry.value_ptr.*) catch continue;
        }

        return wallets.toOwnedSlice(self.allocator) catch &[_]HDWallet.Wallet{};
    }

    pub fn removeWallet(self: *Self, wallet_id: []const u8) bool {
        return self.wallets.remove(wallet_id);
    }
};

pub const CoinTypes = struct {
    pub const BITCOIN: u32 = 0;
    pub const ETHEREUM: u32 = 60;
    pub const LITECOIN: u32 = 2;
    pub const DOGECOIN: u32 = 3;
    pub const DASH: u32 = 5;
    pub const ZCASH: u32 = 133;
    pub const MONERO: u32 = 128;
    pub const RIPPLE: u32 = 144;
    pub const CARDANO: u32 = 1815;
    pub const POLKADOT: u32 = 354;
    pub const SOLANA: u32 = 501;
    pub const AVALANCHE: u32 = 9000;
    pub const POLYGON: u32 = 966;
    pub const BINANCE_SMART_CHAIN: u32 = 9006;
};

test "HD Wallet creation and derivation" {
    const allocator = std.testing.allocator;

    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const passphrase = "";

    const wallet = try HDWallet.createWallet(allocator, "Test Wallet", CoinTypes.BITCOIN, mnemonic, passphrase);
    defer allocator.free(wallet.id);
    defer allocator.free(wallet.name);

    const receive_address = try wallet.getReceiveAddress(0, 0);
    const change_address = try wallet.getChangeAddress(0, 0);

    // Keys should be different
    try std.testing.expect(!std.mem.eql(u8, &receive_address.key, &change_address.key));

    // Depth should be 5 (m/44'/0'/0'/0/0)
    try std.testing.expect(receive_address.depth == 5);
    try std.testing.expect(change_address.depth == 5);
}

test "Wallet manager" {
    const allocator = std.testing.allocator;

    var manager = WalletManager.init(allocator);
    defer manager.deinit();

    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const wallet = try HDWallet.createWallet(allocator, "Test Wallet", CoinTypes.BITCOIN, mnemonic, "");

    try manager.addWallet(wallet);

    const retrieved = manager.getWallet(wallet.id);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings(wallet.name, retrieved.?.name);

    const removed = manager.removeWallet(wallet.id);
    try std.testing.expect(removed);

    const not_found = manager.getWallet(wallet.id);
    try std.testing.expect(not_found == null);
}
