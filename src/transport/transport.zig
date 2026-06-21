const std = @import("std");

// Export post-quantum QUIC transport
pub const PQQuicTransport = @import("pq_quic.zig").PQQuicTransport;
pub const PQDatabaseTransport = @import("pq_quic.zig").PQDatabaseTransport;

/// ZQLite Transport Layer
/// High-performance networking with optional post-quantum features
pub const Transport = struct {
    allocator: std.mem.Allocator,
    endpoint: ?Endpoint,
    connections: std.ArrayListUnmanaged(*Connection),
    is_server: bool,
    crypto_enabled: bool,
    next_connection_id: ConnectionId,

    const Self = @This();
    const ConnectionId = u64;

    const Endpoint = struct {
        address: std.Io.net.IpAddress,
        handle: ?std.Io.net.Socket.Handle,
    };

    const Connection = struct {
        id: ConnectionId,
        address: std.Io.net.IpAddress,
        state: ConnectionState,
        write_buffer: std.ArrayListUnmanaged(u8),
        read_buffer: std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,

        const ConnectionState = enum {
            connecting,
            connected,
            closing,
            closed,
        };

        pub fn init(allocator: std.mem.Allocator, id: ConnectionId, address: std.Io.net.IpAddress) !*Connection {
            const conn = try allocator.create(Connection);
            conn.* = Connection{
                .id = id,
                .address = address,
                .state = .connecting,
                .write_buffer = .empty,
                .read_buffer = .empty,
                .allocator = allocator,
            };
            return conn;
        }

        pub fn deinit(self: *Connection) void {
            self.write_buffer.deinit(self.allocator);
            self.read_buffer.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn appendWriteData(self: *Connection, data: []const u8) !void {
            try self.write_buffer.appendSlice(self.allocator, data);
        }
    };

    pub fn init(allocator: std.mem.Allocator, is_server: bool) Self {
        return Self{
            .allocator = allocator,
            .endpoint = null,
            .connections = .empty,
            .is_server = is_server,
            .crypto_enabled = false,
            .next_connection_id = 1,
        };
    }

    pub fn bind(self: *Self, address: std.Io.net.IpAddress) !void {
        self.endpoint = Endpoint{
            .address = address,
            .handle = null,
        };
    }

    pub fn connect(self: *Self, server_address: std.Io.net.IpAddress) !ConnectionId {
        const conn_id = self.next_connection_id;
        self.next_connection_id +%= 1;
        const connection = try Connection.init(self.allocator, conn_id, server_address);
        connection.state = .connected;
        try self.connections.append(self.allocator, connection);
        return conn_id;
    }

    pub fn sendData(self: *Self, conn_id: ConnectionId, data: []const u8) !void {
        for (self.connections.items) |conn| {
            if (conn.id == conn_id) {
                try conn.appendWriteData(data);
                return;
            }
        }
        return error.ConnectionNotFound;
    }

    pub fn receiveData(self: *Self, conn_id: ConnectionId) ![]u8 {
        for (self.connections.items) |conn| {
            if (conn.id == conn_id) {
                const data = try self.allocator.dupe(u8, conn.read_buffer.items);
                conn.read_buffer.clearRetainingCapacity();
                return data;
            }
        }
        return error.ConnectionNotFound;
    }

    pub fn closeConnection(self: *Self, conn_id: ConnectionId) !void {
        for (self.connections.items, 0..) |conn, i| {
            if (conn.id == conn_id) {
                conn.state = .closed;
                conn.deinit();
                _ = self.connections.orderedRemove(i);
                return;
            }
        }
    }

    pub fn getStats(self: Self) TransportStats {
        return TransportStats{
            .active_connections = self.connections.items.len,
            .total_bytes_sent = 0,
            .total_bytes_received = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.connections.items) |conn| {
            conn.deinit();
        }
        self.connections.deinit(self.allocator);
        self.endpoint = null;
    }
};

pub const TransportStats = struct {
    active_connections: usize,
    total_bytes_sent: u64,
    total_bytes_received: u64,
};

test "transport basic functionality" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var transport = Transport.init(allocator, false);
    defer transport.deinit();

    // Parse a loopback address for the transport smoke test.
    const server_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);
    const conn_id = try transport.connect(server_addr);

    try testing.expect(conn_id != 0);
    try testing.expect(transport.getStats().active_connections == 1);

    try transport.closeConnection(conn_id);
    try testing.expect(transport.getStats().active_connections == 0);
}
