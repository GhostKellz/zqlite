const std = @import("std");

/// Crypto engine for secure storage operations
pub const CryptoEngine = struct {
    allocator: std.mem.Allocator,
    key: [32]u8,
    nonce_counter: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var key: [32]u8 = undefined;
        std.crypto.random.bytes(&key);

        return Self{
            .allocator = allocator,
            .key = key,
            .nonce_counter = std.atomic.Value(u64).init(0),
        };
    }

    pub fn initWithKey(allocator: std.mem.Allocator, key: [32]u8) Self {
        return Self{
            .allocator = allocator,
            .key = key,
            .nonce_counter = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        // Securely clear the key
        secureZero(&self.key);
    }

    /// Securely zero memory to prevent sensitive data from remaining
    fn secureZero(buffer: []u8) void {
        @memset(buffer, 0);
        // Force compiler not to optimize this away
        std.mem.doNotOptimizeAway(buffer.ptr);
    }

    pub fn encrypt(self: *Self, data: []const u8) ![]u8 {
        const encrypted_size = data.len + 12 + 16; // nonce + tag
        const encrypted = try self.allocator.alloc(u8, encrypted_size);

        // Generate unique nonce
        const nonce_val = self.nonce_counter.fetchAdd(1, .acq_rel);
        var nonce: [12]u8 = undefined;
        std.mem.writeInt(u64, nonce[0..8], nonce_val, .little);
        std.crypto.random.bytes(nonce[8..]);

        // Copy nonce to output
        @memcpy(encrypted[0..12], &nonce);

        // Encrypt using ChaCha20-Poly1305
        std.crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(encrypted[12 .. data.len + 12], encrypted[data.len + 12 ..], data, "", nonce, self.key);

        return encrypted;
    }

    pub fn decrypt(self: *Self, encrypted_data: []const u8) ![]u8 {
        if (encrypted_data.len < 28) return error.InvalidCiphertext; // min size: 12 + 16

        const nonce = encrypted_data[0..12];
        const ciphertext = encrypted_data[12 .. encrypted_data.len - 16];
        const tag = encrypted_data[encrypted_data.len - 16 ..];

        const decrypted = try self.allocator.alloc(u8, ciphertext.len);

        std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(decrypted, ciphertext, tag.*, "", nonce.*, self.key) catch return error.AuthenticationFailed;

        return decrypted;
    }

    /// Generate a secure hash of data
    pub fn hash(self: *Self, data: []const u8) [32]u8 {
        _ = self;
        var hasher = std.crypto.hash.blake3.Blake3.init(.{});
        hasher.update(data);
        return hasher.finalResult();
    }

    /// Derive a key from a password using PBKDF2
    pub fn deriveKey(password: []const u8, salt: []const u8) ![32]u8 {
        var key: [32]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&key, password, salt, 100000, std.crypto.auth.hmac.sha2.HmacSha256);
        return key;
    }
};
