const std = @import("std");
const crypto = std.crypto;
const linux = std.os.linux;

/// Get random bytes using Linux getrandom syscall
fn getRandomBytes(buf: []u8) void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const rc = linux.getrandom(buf.ptr + offset, buf.len - offset, 0);
        const signed_rc = @as(isize, @bitCast(rc));
        if (signed_rc < 0) {
            // EINTR, retry
            continue;
        }
        offset += @as(usize, @bitCast(signed_rc));
    }
}

/// Simple encryption module for database files
pub const Encryption = struct {
    key: [32]u8, // 256-bit key
    salt: [32]u8, // 256-bit salt for key derivation
    enabled: bool,

    const Self = @This();

    /// Initialize with a password and optional salt (generates random if not provided)
    pub fn init(password: []const u8, salt_opt: ?[]const u8) !Self {
        var encryption = Self{
            .key = undefined,
            .salt = undefined,
            .enabled = true,
        };

        // Use provided salt or generate random one
        if (salt_opt) |provided_salt| {
            if (provided_salt.len != 32) {
                return error.InvalidSaltLength;
            }
            @memcpy(&encryption.salt, provided_salt);
        } else {
            // Generate cryptographically secure random salt
            getRandomBytes(&encryption.salt);
        }

        // Derive key from password using PBKDF2 with random salt
        try crypto.pwhash.pbkdf2(
            &encryption.key,
            password,
            &encryption.salt,
            4096, // iterations
            crypto.auth.hmac.sha2.HmacSha256,
        );

        return encryption;
    }

    /// Initialize with existing salt (for loading existing database)
    pub fn initWithSalt(password: []const u8, salt: [32]u8) !Self {
        var encryption = Self{
            .key = undefined,
            .salt = salt,
            .enabled = true,
        };

        // Derive key using existing salt
        try crypto.pwhash.pbkdf2(
            &encryption.key,
            password,
            &salt,
            4096, // iterations
            crypto.auth.hmac.sha2.HmacSha256,
        );

        return encryption;
    }

    /// Initialize without encryption
    /// SECURITY WARNING: Data will not be encrypted at rest. Use init() with a password
    /// for production deployments handling sensitive data.
    pub fn initPlain() Self {
        // Note: Security warning is intentionally omitted from runtime output.
        // The warning is documented here and in the API docs.
        // Use init() with encryption for production deployments.
        return Self{
            .key = undefined,
            .salt = undefined,
            .enabled = false,
        };
    }

    /// Explicitly named function for insecure initialization (makes security audit easier)
    /// SECURITY WARNING: Only use for testing or when encryption is handled externally
    pub fn initInsecureNoEncryption() Self {
        return initPlain();
    }

    /// Get the salt for storage in database header
    pub fn getSalt(self: *const Self) [32]u8 {
        return self.salt;
    }

    /// Securely clear sensitive data from memory
    pub fn deinit(self: *Self) void {
        // Zero out sensitive data
        secureZero(&self.key);
        secureZero(&self.salt);
    }

    /// Securely zero memory to prevent sensitive data from remaining
    fn secureZero(buffer: []u8) void {
        @memset(buffer, 0);
        // Force compiler not to optimize this away
        std.mem.doNotOptimizeAway(buffer.ptr);
    }

    /// Encrypt data
    pub fn encrypt(self: *const Self, data: []const u8, output: []u8) !void {
        if (!self.enabled) {
            // No encryption, just copy
            @memcpy(output[0..data.len], data);
            return;
        }

        if (output.len < data.len + 16) { // 16 bytes for nonce
            return error.OutputBufferTooSmall;
        }

        // Generate random nonce
        var nonce: [12]u8 = undefined;
        getRandomBytes(&nonce);

        // Copy nonce to output
        @memcpy(output[0..12], &nonce);

        // Encrypt data
        const cipher = crypto.aead.chacha_poly.ChaCha20Poly1305;
        var tag: [16]u8 = undefined;

        cipher.encrypt(
            output[16 .. data.len + 16], // encrypted data
            &tag,
            data, // plaintext
            &[_]u8{}, // additional data
            nonce,
            self.key,
        );

        // Append tag
        @memcpy(output[data.len + 16 .. data.len + 32], &tag);
    }

    /// Decrypt data
    pub fn decrypt(self: *const Self, encrypted_data: []const u8, output: []u8) !void {
        if (!self.enabled) {
            // No encryption, just copy
            @memcpy(output[0..encrypted_data.len], encrypted_data);
            return;
        }

        if (encrypted_data.len < 32) { // 12 + 16 minimum
            return error.InvalidEncryptedData;
        }

        const data_len = encrypted_data.len - 32; // subtract nonce + tag
        if (output.len < data_len) {
            return error.OutputBufferTooSmall;
        }

        // Extract nonce
        const nonce = encrypted_data[0..12];

        // Extract tag
        const tag = encrypted_data[encrypted_data.len - 16 ..];

        // Extract encrypted data
        const ciphertext = encrypted_data[16 .. encrypted_data.len - 16];

        // Decrypt
        const cipher = crypto.aead.chacha_poly.ChaCha20Poly1305;
        try cipher.decrypt(
            output[0..data_len],
            ciphertext,
            tag[0..16].*,
            &[_]u8{}, // additional data
            nonce[0..12].*,
            self.key,
        );
    }

    /// Get encrypted size for a given plaintext size
    pub fn getEncryptedSize(self: *const Self, plaintext_size: usize) usize {
        if (!self.enabled) {
            return plaintext_size;
        }
        return plaintext_size + 32; // 12 bytes nonce + 16 bytes tag + 4 bytes padding
    }

    /// Get decrypted size for a given encrypted size
    pub fn getDecryptedSize(self: *const Self, encrypted_size: usize) usize {
        if (!self.enabled) {
            return encrypted_size;
        }
        if (encrypted_size < 32) return 0;
        return encrypted_size - 32;
    }
};

test "encryption with random salt" {
    _ = std.testing.allocator;

    // Test encryption with random salt
    var enc1 = try Encryption.init("test_password", null);
    defer enc1.deinit();

    var enc2 = try Encryption.init("test_password", null);
    defer enc2.deinit();

    // Different instances should have different salts
    try std.testing.expect(!std.mem.eql(u8, &enc1.salt, &enc2.salt));

    // Test encryption/decryption
    const plaintext = "Hello, ZQLite encryption!";
    var encrypted_buf: [1024]u8 = undefined;
    var decrypted_buf: [1024]u8 = undefined;

    try enc1.encrypt(plaintext, &encrypted_buf);
    const encrypted_size = enc1.getEncryptedSize(plaintext.len);

    try enc1.decrypt(encrypted_buf[0..encrypted_size], &decrypted_buf);
    const decrypted_size = enc1.getDecryptedSize(encrypted_size);

    try std.testing.expectEqualStrings(plaintext, decrypted_buf[0..decrypted_size]);
}

test "encryption with provided salt" {
    const test_salt = [_]u8{1} ** 32;

    var enc1 = try Encryption.init("password123", &test_salt);
    defer enc1.deinit();

    var enc2 = try Encryption.initWithSalt("password123", test_salt);
    defer enc2.deinit();

    // Both should have the same salt and key
    try std.testing.expectEqualSlices(u8, &enc1.salt, &enc2.salt);
    try std.testing.expectEqualSlices(u8, &enc1.key, &enc2.key);
}

test "plaintext mode" {
    var enc = Encryption.initPlain();
    defer enc.deinit();

    try std.testing.expect(!enc.enabled);

    const data = "unencrypted data";
    var output: [100]u8 = undefined;

    try enc.encrypt(data, &output);
    try std.testing.expectEqualStrings(data, output[0..data.len]);
}
