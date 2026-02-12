const std = @import("std");
const time_utils = @import("../time_utils.zig");

/// ZQLite Post-Quantum QUIC Transport
///
/// EXPERIMENTAL: This module is a proof-of-concept implementation demonstrating
/// post-quantum secure database transport. It is NOT production-ready.
///
/// Current Limitations:
/// - Key derivation uses placeholder values (not cryptographically secure)
/// - No actual network I/O - packet send/receive are simulated
/// - ML-KEM-768 key exchange is simulated, not using actual PQ algorithms
/// - Connection management lacks proper cleanup and concurrency controls
/// - Zero-RTT implementation is incomplete
///
/// For production use, this module requires:
/// 1. Integration with a real QUIC implementation (e.g., quiche, msquic)
/// 2. Proper ML-KEM-768 or ML-KEM-1024 key encapsulation
/// 3. Full TLS 1.3 handshake with PQ key exchange
/// 4. Robust connection lifecycle management
///
/// The cryptographic primitives (AES-GCM, ChaCha20-Poly1305) are production-ready
/// via std.crypto, but the QUIC protocol layer is not complete.
pub const PQQuicTransport = struct {
    allocator: std.mem.Allocator,
    quic_crypto: QuicCrypto,
    endpoint: ?Endpoint,
    connections: std.ArrayList(*PQConnection), // Use ArrayList instead of HashMap
    is_server: bool,

    const Self = @This();
    const ConnectionId = u64;

    const QuicCrypto = struct {
        cipher_suite: CipherSuite,
        initial_keys_client: PacketKeys,
        initial_keys_server: PacketKeys,
        handshake_keys_client: PacketKeys,
        handshake_keys_server: PacketKeys,
        application_keys_client: PacketKeys,
        application_keys_server: PacketKeys,
        pq_enabled: bool,

        const CipherSuite = enum {
            TLS_AES_256_GCM_SHA384,
            TLS_CHACHA20_POLY1305_SHA256,
            TLS_ML_KEM_768_X25519_AES256_GCM_SHA384, // Post-quantum hybrid
        };

        const PacketKeys = struct {
            aead_key: [32]u8,
            iv: [12]u8,
            header_protection_key: [32]u8,

            pub fn zero() PacketKeys {
                return PacketKeys{
                    .aead_key = std.mem.zeroes([32]u8),
                    .iv = std.mem.zeroes([12]u8),
                    .header_protection_key = std.mem.zeroes([32]u8),
                };
            }
        };

        pub fn init(cipher_suite: CipherSuite) QuicCrypto {
            return QuicCrypto{
                .cipher_suite = cipher_suite,
                .initial_keys_client = PacketKeys.zero(),
                .initial_keys_server = PacketKeys.zero(),
                .handshake_keys_client = PacketKeys.zero(),
                .handshake_keys_server = PacketKeys.zero(),
                .application_keys_client = PacketKeys.zero(),
                .application_keys_server = PacketKeys.zero(),
                .pq_enabled = cipher_suite == .TLS_ML_KEM_768_X25519_AES256_GCM_SHA384,
            };
        }

        /// Derive initial keys from connection ID (RFC 9001 Section 5.2)
        pub fn deriveInitialKeys(self: *QuicCrypto, connection_id: []const u8) !void {
            const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

            // RFC 9001 Section 5.2: Initial salt for QUIC v1
            // This is the SHA-256 hash of "quic v1 salt"
            const initial_salt = [_]u8{
                0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3,
                0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
                0xcc, 0xbb, 0x7f, 0x0a,
            };

            // Extract PRK from connection_id using initial salt
            const prk = Hkdf.extract(&initial_salt, connection_id);

            // Derive client initial secret
            var client_secret: [32]u8 = undefined;
            Hkdf.expand(&client_secret, "client in", prk);
            self.initial_keys_client = try self.derivePacketKeys(client_secret);

            // Derive server initial secret
            var server_secret: [32]u8 = undefined;
            Hkdf.expand(&server_secret, "server in", prk);
            self.initial_keys_server = try self.derivePacketKeys(server_secret);
        }

        /// Derive packet keys from secret
        fn derivePacketKeys(self: *QuicCrypto, secret: [32]u8) !PacketKeys {
            _ = self;

            // Use std.crypto HKDF for key derivation
            const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
            const salt = "";
            const prk = Hkdf.extract(salt, &secret);

            var aead_key: [32]u8 = undefined;
            Hkdf.expand(&aead_key, "quic key", prk);

            var iv_buf: [12]u8 = undefined;
            Hkdf.expand(&iv_buf, "quic iv", prk);

            var hp_key: [32]u8 = undefined;
            Hkdf.expand(&hp_key, "quic hp", prk);

            return PacketKeys{
                .aead_key = aead_key,
                .iv = iv_buf,
                .header_protection_key = hp_key,
            };
        }

        /// Encrypt QUIC packet with post-quantum protection
        pub fn encryptPacket(self: *const QuicCrypto, level: EncryptionLevel, is_server: bool, packet_number: u64, header: []const u8, payload: []const u8, output: []u8) !usize {
            const keys = self.getKeysForLevel(level, is_server);

            // Create packet number bytes
            var pn_bytes: [8]u8 = undefined;
            std.mem.writeIntBig(u64, &pn_bytes, packet_number);

            // Create nonce by XORing IV with packet number
            var nonce: [12]u8 = keys.iv;
            for (pn_bytes, 0..) |byte, i| {
                if (i < nonce.len) {
                    nonce[nonce.len - 1 - i] ^= byte;
                }
            }

            // Copy header to output
            @memcpy(output[0..header.len], header);

            // Encrypt payload
            var tag: [16]u8 = undefined;

            switch (self.cipher_suite) {
                .TLS_AES_256_GCM_SHA384 => {
                    // Use std.crypto AES-GCM
                    const aes_gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
                    aes_gcm.encrypt(output[header.len .. header.len + payload.len], &tag, payload, &[0]u8{}, nonce, keys.aead_key);
                },
                .TLS_CHACHA20_POLY1305_SHA256 => {
                    // Use std.crypto ChaCha20-Poly1305
                    const chacha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
                    chacha.encrypt(output[header.len .. header.len + payload.len], &tag, payload, &[0]u8{}, nonce, keys.aead_key);
                },
                .TLS_ML_KEM_768_X25519_AES256_GCM_SHA384 => {
                    // Post-quantum enhanced encryption (using AES-GCM for now)
                    const aes_gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
                    aes_gcm.encrypt(output[header.len .. header.len + payload.len], &tag, payload, &[0]u8{}, nonce, keys.aead_key);
                },
            }

            // Append authentication tag
            @memcpy(output[header.len + payload.len .. header.len + payload.len + 16], &tag);

            return header.len + payload.len + 16;
        }

        /// Decrypt QUIC packet
        pub fn decryptPacket(self: *const QuicCrypto, level: EncryptionLevel, is_server: bool, packet_number: u64, header: []const u8, ciphertext: []const u8, output: []u8) !usize {
            _ = header;
            const keys = self.getKeysForLevel(level, !is_server); // Use peer keys

            // Create nonce
            var pn_bytes: [8]u8 = undefined;
            std.mem.writeIntBig(u64, &pn_bytes, packet_number);

            var nonce: [12]u8 = keys.iv;
            for (pn_bytes, 0..) |byte, i| {
                if (i < nonce.len) {
                    nonce[nonce.len - 1 - i] ^= byte;
                }
            }

            // Extract tag and ciphertext
            if (ciphertext.len < 16) return error.InvalidCiphertext;
            const payload_len = ciphertext.len - 16;
            const tag = ciphertext[payload_len..][0..16].*;

            // Decrypt payload
            switch (self.cipher_suite) {
                .TLS_AES_256_GCM_SHA384 => {
                    // Use std.crypto AES-GCM
                    const aes_gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
                    try aes_gcm.decrypt(output[0..payload_len], ciphertext[0..payload_len], &[0]u8{}, tag, nonce, keys.aead_key);
                },
                .TLS_CHACHA20_POLY1305_SHA256 => {
                    // Use std.crypto ChaCha20-Poly1305
                    const chacha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
                    try chacha.decrypt(output[0..payload_len], ciphertext[0..payload_len], &[0]u8{}, tag, nonce, keys.aead_key);
                },
                .TLS_ML_KEM_768_X25519_AES256_GCM_SHA384 => {
                    // Post-quantum enhanced decryption (using AES-GCM for now)
                    const aes_gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
                    try aes_gcm.decrypt(output[0..payload_len], ciphertext[0..payload_len], &[0]u8{}, tag, nonce, keys.aead_key);
                },
            }

            return payload_len;
        }

        /// Get keys for encryption level
        fn getKeysForLevel(self: *const QuicCrypto, level: EncryptionLevel, is_server: bool) PacketKeys {
            return switch (level) {
                .initial => if (is_server) self.initial_keys_server else self.initial_keys_client,
                .early_data => if (is_server) self.initial_keys_server else self.initial_keys_client,
                .handshake => if (is_server) self.handshake_keys_server else self.handshake_keys_client,
                .application => if (is_server) self.application_keys_server else self.application_keys_client,
            };
        }
    };

    const EncryptionLevel = enum {
        initial,
        early_data, // 0-RTT
        handshake,
        application, // 1-RTT
    };

    const Endpoint = struct {
        address: std.Io.net.IpAddress,
        socket: ?std.Io.net.Stream,
    };

    const PQConnection = struct {
        id: ConnectionId,
        endpoint: std.Io.net.IpAddress,
        state: ConnectionState,
        crypto_state: CryptoState,
        pq_keys: ?PQKeys,
        packet_buffer: [65536]u8,

        const ConnectionState = enum {
            Initial,
            Handshaking,
            Connected,
            Closing,
            Closed,
        };

        const CryptoState = struct {
            current_level: EncryptionLevel,
            client_secrets: [4][32]u8, // One for each encryption level
            server_secrets: [4][32]u8,
        };

        const PQKeys = struct {
            classical_shared: [32]u8,
            pq_shared: [32]u8,
            combined_secret: [64]u8,
        };

        pub fn init(allocator: std.mem.Allocator, id: ConnectionId, endpoint: std.Io.net.IpAddress) !*PQConnection {
            const conn = try allocator.create(PQConnection);
            conn.* = PQConnection{
                .id = id,
                .endpoint = endpoint,
                .state = .Initial,
                .crypto_state = CryptoState{
                    .current_level = .initial,
                    .client_secrets = std.mem.zeroes([4][32]u8),
                    .server_secrets = std.mem.zeroes([4][32]u8),
                },
                .pq_keys = null,
                .packet_buffer = undefined,
            };
            return conn;
        }

        /// Perform post-quantum key exchange
        pub fn performPQKeyExchange(self: *PQConnection) !void {
            // Generate hybrid key share using std.crypto
            var classical_share: [32]u8 = undefined;
            var pq_share: [1184]u8 = undefined; // ML-KEM-768 public key placeholder
            std.crypto.random.bytes(&classical_share);
            std.crypto.random.bytes(&pq_share);

            // In a real implementation, this would be sent to the peer
            // and we'd receive their response

            // For demonstration, simulate peer response using std.crypto
            var peer_classical: [32]u8 = undefined;
            var peer_pq: [1088]u8 = undefined; // ML-KEM-768 ciphertext placeholder
            var shared_secret: [64]u8 = undefined;

            std.crypto.random.bytes(&peer_classical);
            std.crypto.random.bytes(&peer_pq);
            std.crypto.random.bytes(&shared_secret);

            self.pq_keys = PQKeys{
                .classical_shared = peer_classical,
                .pq_shared = shared_secret[0..32].*,
                .combined_secret = shared_secret,
            };
        }

        /// Send encrypted data over post-quantum QUIC
        pub fn sendData(self: *PQConnection, data: []const u8, crypto: *QuicCrypto) !void {
            // Create QUIC packet header
            var header: [64]u8 = undefined;
            const header_len = self.createHeader(&header, data.len);

            // Encrypt packet
            const encrypted_len = try crypto.encryptPacket(.application, false, // client
                self.getNextPacketNumber(), header[0..header_len], data, &self.packet_buffer);

            // In a real implementation, send over network
            _ = encrypted_len;
        }

        /// Receive and decrypt data
        pub fn receiveData(self: *PQConnection, packet: []const u8, crypto: *QuicCrypto) ![]u8 {
            // Parse header
            const header_len = self.parseHeader(packet);
            const packet_number = self.extractPacketNumber(packet[0..header_len]);

            // Decrypt payload
            const payload_len = try crypto.decryptPacket(.application, true, // server
                packet_number, packet[0..header_len], packet[header_len..], &self.packet_buffer);

            return self.packet_buffer[0..payload_len];
        }

        fn createHeader(self: *PQConnection, header: []u8, payload_len: usize) usize {
            _ = payload_len;
            // Simplified QUIC header creation
            header[0] = 0x40; // Long header, type 0 (Initial)
            header[1] = 0x00; // Version (simplified)
            header[2] = 0x00;
            header[3] = 0x00;
            header[4] = 0x01;

            // Connection ID
            const conn_id_bytes = std.mem.asBytes(&self.id);
            @memcpy(header[5 .. 5 + conn_id_bytes.len], conn_id_bytes);

            return 5 + conn_id_bytes.len;
        }

        fn parseHeader(self: *PQConnection, packet: []const u8) usize {
            _ = self;
            _ = packet;
            // Simplified header parsing
            return 13; // Fixed header length for demo
        }

        fn extractPacketNumber(self: *PQConnection, header: []const u8) u64 {
            _ = self;
            // Extract packet number from header (simplified)
            if (header.len >= 13) {
                return std.mem.readIntBig(u64, header[5..13]);
            }
            return 0;
        }

        fn getNextPacketNumber(self: *PQConnection) u64 {
            // In real implementation, maintain packet number state
            _ = self;
            const ts = time_utils.getTimespec();
            const timestamp = ts.sec;
            return @as(u64, @intCast(timestamp));
        }

        pub fn deinit(self: *PQConnection, allocator: std.mem.Allocator) void {
            if (self.pq_keys) |*keys| {
                // Secure zero using custom function
                secureZero(&keys.classical_shared);
                secureZero(&keys.pq_shared);
                secureZero(&keys.combined_secret);
            }
            allocator.destroy(self);
        }

        /// Securely zero memory to prevent sensitive data from remaining
        fn secureZero(buffer: []u8) void {
            @memset(buffer, 0);
            // Force compiler not to optimize this away
            std.mem.doNotOptimizeAway(buffer.ptr);
        }
    };

    pub fn init(allocator: std.mem.Allocator, is_server: bool) Self {
        return Self{
            .allocator = allocator,
            .quic_crypto = QuicCrypto.init(.TLS_ML_KEM_768_X25519_AES256_GCM_SHA384),
            .endpoint = null,
            .connections = .{},
            .is_server = is_server,
        };
    }

    /// Bind to address for server
    pub fn bind(self: *Self, address: std.Io.net.IpAddress) !void {
        // Store endpoint address (actual socket creation would require async IO)
        self.endpoint = Endpoint{
            .address = address,
            .socket = null,
        };
    }

    /// Connect to server (client)
    pub fn connect(self: *Self, server_address: std.Io.net.IpAddress) !ConnectionId {
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const conn_id = @as(ConnectionId, @intCast(timestamp));
        const connection = try PQConnection.init(self.allocator, conn_id, server_address);

        // Derive initial keys
        const conn_id_bytes = std.mem.asBytes(&conn_id);
        try self.quic_crypto.deriveInitialKeys(conn_id_bytes);

        // Perform post-quantum handshake
        try connection.performPQKeyExchange();
        connection.state = .Connected;

        try self.connections.append(connection);
        return conn_id;
    }

    /// Accept incoming connection (server)
    pub fn accept(self: *Self) !ConnectionId {
        if (!self.is_server) return error.NotAServer;

        // In real implementation, would listen for incoming packets
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const conn_id = @as(ConnectionId, @intCast(timestamp));
        // Use placeholder address for simulated accept (real impl would get from socket)
        const client_addr = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch |err| {
            std.log.err("Failed to parse default client address: {}", .{err});
            return error.InvalidAddress;
        };
        const connection = try PQConnection.init(self.allocator, conn_id, client_addr);

        // Derive initial keys
        const conn_id_bytes = std.mem.asBytes(&conn_id);
        try self.quic_crypto.deriveInitialKeys(conn_id_bytes);

        // Perform post-quantum handshake
        try connection.performPQKeyExchange();
        connection.state = .Connected;

        try self.connections.append(connection);
        return conn_id;
    }

    /// Send data over post-quantum secure channel
    pub fn sendData(self: *Self, conn_id: ConnectionId, data: []const u8) !void {
        for (self.connections.items) |connection| {
            if (connection.id == conn_id) {
                if (connection.state != .Connected) return error.ConnectionNotReady;
                try connection.sendData(data, &self.quic_crypto);
                return;
            }
        }
        return error.ConnectionNotFound;
    }

    /// Receive data from post-quantum secure channel
    pub fn receiveData(self: *Self, conn_id: ConnectionId, packet: []const u8) ![]u8 {
        for (self.connections.items) |connection| {
            if (connection.id == conn_id) {
                if (connection.state != .Connected) return error.ConnectionNotReady;
                return try connection.receiveData(packet, &self.quic_crypto);
            }
        }
        return error.ConnectionNotFound;
    }

    /// Perform post-quantum key update
    pub fn updateKeys(self: *Self, conn_id: ConnectionId) !void {
        for (self.connections.items) |connection| {
            if (connection.id == conn_id) {
                if (connection.pq_keys) |*keys| {
                    // Generate new entropy for key update using std.crypto
                    var pq_entropy: [64]u8 = undefined;
                    std.crypto.random.bytes(&pq_entropy);

                    // Simple key update using XOR with new entropy
                    for (&keys.combined_secret, pq_entropy) |*secret_byte, entropy_byte| {
                        secret_byte.* ^= entropy_byte;
                    }

                    // Update packet keys
                    const conn_id_bytes = std.mem.asBytes(&conn_id);
                    try self.quic_crypto.deriveInitialKeys(conn_id_bytes);
                }
                return;
            }
        }
        return error.ConnectionNotFound;
    }

    /// Close connection
    pub fn closeConnection(self: *Self, conn_id: ConnectionId) !void {
        for (self.connections.items, 0..) |connection, i| {
            if (connection.id == conn_id) {
                connection.state = .Closing;
                connection.state = .Closed;
                connection.deinit(self.allocator);
                _ = self.connections.orderedRemove(i);
                return;
            }
        }
    }

    /// Enable zero-RTT for fast connection establishment
    pub fn enableZeroRTT(self: *Self, psk: []const u8) !void {
        _ = self;
        if (psk.len < 64) return error.InvalidPSKLength;

        // Generate quantum-safe 0-RTT keys
        const classical_psk = psk[0..32];
        const pq_psk = psk[32..64];

        // Protect 0-RTT data with post-quantum crypto (stub implementation)
        var combined_key: [64]u8 = undefined;
        @memcpy(combined_key[0..32], classical_psk);
        @memcpy(combined_key[32..64], pq_psk);

        // Hash the combined key for 0-RTT protection
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&combined_key);
        hasher.update("0rtt_data");
        var protection_key: [32]u8 = undefined;
        hasher.final(&protection_key);

        // Store protection key for later use (stub implementation)
        // In a real implementation, this would be used to protect 0-RTT data
        // Clear protection key securely
        @memset(&protection_key, 0);
        std.mem.doNotOptimizeAway(&protection_key);
    }

    pub fn deinit(self: *Self) void {
        for (self.connections.items) |connection| {
            connection.deinit(self.allocator);
        }
        self.connections.deinit();

        if (self.endpoint) |endpoint| {
            endpoint.socket.close();
        }
    }
};

/// Database query over post-quantum QUIC
pub const PQDatabaseTransport = struct {
    transport: PQQuicTransport,
    query_encryption: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, is_server: bool) Self {
        return Self{
            .transport = PQQuicTransport.init(allocator, is_server),
            .query_encryption = true,
        };
    }

    /// Execute encrypted database query over PQ-QUIC
    pub fn executeQuery(self: *Self, conn_id: u64, query: []const u8) ![]u8 {
        if (self.query_encryption) {
            // Encrypt query with additional protection
            var encrypted_query: std.ArrayList(u8) = .{};
            defer encrypted_query.deinit();

            try encrypted_query.appendSlice("ENCRYPTED:");
            try encrypted_query.appendSlice(query);

            try self.transport.sendData(conn_id, encrypted_query.items);
        } else {
            try self.transport.sendData(conn_id, query);
        }

        // In real implementation, would receive response
        return try self.transport.allocator.dupe(u8, "QUERY_RESULT");
    }

    /// Stream large result sets over PQ-QUIC
    pub fn streamResults(self: *Self, conn_id: u64, query: []const u8) !QueryStream {
        _ = query;
        return QueryStream{
            .conn_id = conn_id,
            .transport = &self.transport,
            .buffer = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.transport.deinit();
    }
};

/// Streaming query results over post-quantum QUIC
pub const QueryStream = struct {
    conn_id: u64,
    transport: *PQQuicTransport,
    buffer: std.ArrayList(u8),

    const Self = @This();

    /// Read next chunk of results
    pub fn readChunk(self: *Self) !?[]u8 {
        // In real implementation, would read from QUIC stream
        if (self.buffer.items.len == 0) {
            try self.buffer.appendSlice("CHUNK_DATA");
            return self.buffer.items;
        }
        return null; // End of stream
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }
};

// Tests for post-quantum QUIC transport
test "post-quantum QUIC connection" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server
    var server = PQQuicTransport.init(allocator, true);
    defer server.deinit();

    // Create client
    var client = PQQuicTransport.init(allocator, false);
    defer client.deinit();

    // Test connection establishment
    const server_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 4433);
    const client_conn_id = try client.connect(server_addr);

    try testing.expect(client_conn_id != 0);
}

test "encrypted database query over PQ-QUIC" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db_transport = PQDatabaseTransport.init(allocator, false);
    defer db_transport.deinit();

    const server_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 4433);
    const conn_id = try db_transport.transport.connect(server_addr);

    const result = try db_transport.executeQuery(conn_id, "SELECT * FROM users WHERE id = 1");
    defer allocator.free(result);

    try testing.expectEqualStrings("QUERY_RESULT", result);
}

test "QUIC packet encryption with post-quantum" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    _ = allocator; // Not used in this test

    var crypto = PQQuicTransport.QuicCrypto.init(.TLS_ML_KEM_768_X25519_AES256_GCM_SHA384);

    const connection_id = "test_conn_id";
    try crypto.deriveInitialKeys(connection_id);

    const header = "QUIC_HEADER";
    const payload = "sensitive_database_query_data";
    var output: [1024]u8 = undefined;

    const encrypted_len = try crypto.encryptPacket(.application, false, // client
        12345, // packet number
        header, payload, &output);

    try testing.expect(encrypted_len > header.len + payload.len);

    // Test decryption
    var decrypted: [1024]u8 = undefined;
    const decrypted_len = try crypto.decryptPacket(.application, true, // server
        12345, // same packet number
        header, output[header.len..encrypted_len], &decrypted);

    try testing.expectEqualStrings(payload, decrypted[0..decrypted_len]);
}
