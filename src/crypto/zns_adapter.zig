const std = @import("std");
const crypto_interface = @import("interface.zig");
const time_utils = @import("../time_utils.zig");

/// ZNS (Zcrypto Name System) Adapter for ZQLite v0.8.0
/// Provides specialized crypto operations for Ghostchain ENS integration
pub const ZNSAdapter = struct {
    crypto: crypto_interface.CryptoInterface,
    allocator: std.mem.Allocator,
    domain_salt: [32]u8,

    const Self = @This();

    pub const ZNSRecord = struct {
        domain: []const u8,
        record_type: RecordType,
        value: []const u8,
        signature: ?[]const u8,
        timestamp: u64,

        pub const RecordType = enum {
            A,
            AAAA,
            CNAME,
            TXT,
            MX,
            NS,
            SRV,
            GHOSTCHAIN_ADDR,
            GHOSTCHAIN_PUBKEY,
        };
    };

    pub fn init(allocator: std.mem.Allocator, config: crypto_interface.CryptoConfig) !Self {
        const crypto = crypto_interface.CryptoInterface.init(config);

        // Generate domain-specific salt for ZNS operations
        var domain_salt: [32]u8 = undefined;
        try crypto.randomBytes(&domain_salt);

        return Self{
            .crypto = crypto,
            .allocator = allocator,
            .domain_salt = domain_salt,
        };
    }

    /// Generate domain-specific hash for ZNS records
    pub fn domainHash(self: Self, domain: []const u8, record_type: ZNSRecord.RecordType) ![32]u8 {
        const type_bytes = @as(u8, @backingInt(record_type));

        // Combine domain, record type, and salt
        const combined_len = domain.len + 1 + self.domain_salt.len;
        const combined = try self.allocator.alloc(u8, combined_len);
        defer self.allocator.free(combined);

        @memcpy(combined[0..domain.len], domain);
        combined[domain.len] = type_bytes;
        @memcpy(combined[domain.len + 1 ..], &self.domain_salt);

        var hash: [32]u8 = undefined;
        try self.crypto.hash(combined, &hash);

        return hash;
    }

    /// Verify domain ownership using post-quantum signatures
    pub fn verifyDomainOwnership(self: Self, domain: []const u8, signature: []const u8, public_key: []const u8) !bool {
        const domain_hash = try self.domainHash(domain, .GHOSTCHAIN_ADDR);

        // Use post-quantum verification if available
        if (self.crypto.hasPQCrypto()) {
            return self.crypto.verifyPQ(&domain_hash, signature, public_key);
        }

        // Fallback to classical verification
        return self.verifyClassicalSignature(&domain_hash, signature, public_key);
    }

    /// Sign domain record with hybrid signatures
    pub fn signDomainRecord(self: Self, record: ZNSRecord, private_key: []const u8) ![]u8 {
        // Create record hash
        const record_data = try self.serializeRecord(record);
        defer self.allocator.free(record_data);

        var record_hash: [32]u8 = undefined;
        try self.crypto.hash(record_data, &record_hash);

        // Use post-quantum signing if available
        if (self.crypto.hasPQCrypto()) {
            return self.crypto.signPQ(&record_hash, private_key, self.allocator);
        }

        // Fallback to classical signing
        return self.signClassical(&record_hash, private_key);
    }

    /// Encrypt sensitive ZNS data for storage
    pub fn encryptZNSData(self: Self, data: []const u8, domain: []const u8) !EncryptedZNSData {
        // Derive encryption key from domain
        const domain_key = try self.deriveDomainKey(domain);

        // Generate random nonce
        var nonce: [12]u8 = undefined;
        try self.crypto.randomBytes(&nonce);

        // Encrypt data
        const ciphertext = try self.allocator.alloc(u8, data.len);
        var tag: [16]u8 = undefined;

        try self.crypto.encrypt(domain_key, nonce, data, ciphertext, &tag);

        return EncryptedZNSData{
            .ciphertext = ciphertext,
            .nonce = nonce,
            .tag = tag,
        };
    }

    /// Decrypt ZNS data using domain-derived key
    pub fn decryptZNSData(self: Self, encrypted: EncryptedZNSData, domain: []const u8) ![]u8 {
        const domain_key = try self.deriveDomainKey(domain);

        const plaintext = try self.allocator.alloc(u8, encrypted.ciphertext.len);
        try self.crypto.decrypt(domain_key, encrypted.nonce, encrypted.ciphertext, encrypted.tag, plaintext);

        return plaintext;
    }

    /// Generate ZNS-compatible address from public key
    pub fn generateZNSAddress(self: Self, public_key: []const u8) ![32]u8 {
        // ZNS addresses are BLAKE3 hashes of public keys with ZNS prefix
        const zns_prefix = "zns:ghostchain:";
        const combined_len = zns_prefix.len + public_key.len;
        const combined = try self.allocator.alloc(u8, combined_len);
        defer self.allocator.free(combined);

        @memcpy(combined[0..zns_prefix.len], zns_prefix);
        @memcpy(combined[zns_prefix.len..], public_key);

        var address: [32]u8 = undefined;
        try self.crypto.hash(combined, &address);

        return address;
    }

    /// Validate ZNS record integrity
    pub fn validateRecord(self: Self, record: ZNSRecord) !bool {
        // Check timestamp is reasonable (within 24 hours)
        const ts = time_utils.getTimespec();
        const current_time = ts.sec;
        if (@abs(current_time - @as(i64, @intCast(record.timestamp))) > 86400) {
            return false;
        }

        // Verify signature if present
        if (record.signature) |sig| {
            const record_hash = try self.domainHash(record.domain, record.record_type);
            // Would need public key to verify - this is a placeholder
            _ = record_hash;
            _ = sig;
        }

        return true;
    }

    pub const EncryptedZNSData = struct {
        ciphertext: []u8,
        nonce: [12]u8,
        tag: [16]u8,
    };

    // Private helper functions
    fn deriveDomainKey(self: Self, domain: []const u8) ![32]u8 {
        const info = "zns_domain_encryption_key";
        var key: [32]u8 = undefined;
        try self.crypto.hkdf(domain, &self.domain_salt, info, &key);
        return key;
    }

    fn serializeRecord(self: Self, record: ZNSRecord) ![]u8 {
        // Simple serialization - in production would use proper format
        const total_len = record.domain.len + record.value.len + 16; // extra for metadata
        const serialized = try self.allocator.alloc(u8, total_len);

        var offset: usize = 0;

        // Write domain length and domain
        std.mem.writeInt(u32, serialized[offset .. offset + 4], @as(u32, @intCast(record.domain.len)), .little);
        offset += 4;
        @memcpy(serialized[offset .. offset + record.domain.len], record.domain);
        offset += record.domain.len;

        // Write record type
        serialized[offset] = @backingInt(record.record_type);
        offset += 1;

        // Write value length and value
        std.mem.writeInt(u32, serialized[offset .. offset + 4], @as(u32, @intCast(record.value.len)), .little);
        offset += 4;
        @memcpy(serialized[offset .. offset + record.value.len], record.value);
        offset += record.value.len;

        // Write timestamp
        std.mem.writeInt(u64, serialized[offset .. offset + 8], record.timestamp, .little);

        return serialized;
    }

    fn verifyClassicalSignature(self: Self, message: []const u8, signature: []const u8, public_key: []const u8) !bool {
        // Placeholder for classical signature verification
        // In production, would use Ed25519 or similar
        _ = self;
        _ = message;
        _ = signature;
        _ = public_key;
        return true;
    }

    fn signClassical(self: Self, message: []const u8, private_key: []const u8) ![]u8 {
        // Placeholder for classical signing
        // In production, would use Ed25519 or similar
        _ = message;
        _ = private_key;
        const signature = try self.allocator.alloc(u8, 64);
        @memset(signature, 0);
        return signature;
    }
};

/// ZNS Database Integration
pub const ZNSDatabase = struct {
    adapter: ZNSAdapter,
    records: std.HashMap([32]u8, ZNSAdapter.ZNSRecord, HashContext, std.hash_map.default_max_load_percentage),

    const Self = @This();
    const HashContext = struct {
        pub fn hash(self: @This(), s: [32]u8) u64 {
            _ = self;
            return std.hash_map.hashString(std.mem.asBytes(&s));
        }
        pub fn eql(self: @This(), a: [32]u8, b: [32]u8) bool {
            _ = self;
            return std.mem.eql(u8, &a, &b);
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: crypto_interface.CryptoConfig) !Self {
        const adapter = try ZNSAdapter.init(allocator, config);
        const records = std.HashMap([32]u8, ZNSAdapter.ZNSRecord, HashContext, std.hash_map.default_max_load_percentage).init(allocator);

        return Self{
            .adapter = adapter,
            .records = records,
        };
    }

    pub fn deinit(self: *Self) void {
        self.records.deinit();
    }

    pub fn storeRecord(self: *Self, record: ZNSAdapter.ZNSRecord) !void {
        const record_hash = try self.adapter.domainHash(record.domain, record.record_type);
        try self.records.put(record_hash, record);
    }

    pub fn getRecord(self: Self, domain: []const u8, record_type: ZNSAdapter.ZNSRecord.RecordType) ?ZNSAdapter.ZNSRecord {
        const record_hash = self.adapter.domainHash(domain, record_type) catch return null;
        return self.records.get(record_hash);
    }

    pub fn resolveGhostchainAddress(self: Self, domain: []const u8) ?[]const u8 {
        if (self.getRecord(domain, .GHOSTCHAIN_ADDR)) |record| {
            return record.value;
        }
        return null;
    }
};
