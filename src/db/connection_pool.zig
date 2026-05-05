const std = @import("std");
const time_utils = @import("../time_utils.zig");
const compat = @import("../runtime/compat/thread.zig");
const connection = @import("connection.zig");
const storage = @import("storage.zig");

/// Connection pool for managing database connections efficiently
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayListUnmanaged(*PooledConnection),
    available_connections: std.ArrayListUnmanaged(*PooledConnection),
    // Use compat blocking primitives to avoid requiring Io context
    mutex: compat.Mutex = .{},
    condition: compat.Condition = .{},
    max_connections: u32,
    min_connections: u32,
    current_connections: u32,
    database_path: ?[]const u8, // null for in-memory
    is_memory: bool,
    shared_storage: *storage.StorageEngine, // Shared storage for all connections

    const Self = @This();

    /// Initialize connection pool
    pub fn init(allocator: std.mem.Allocator, database_path: ?[]const u8, min_connections: u32, max_connections: u32) !*Self {
        var pool = try allocator.create(Self);
        pool.allocator = allocator;
        pool.connections = .empty;
        pool.available_connections = .empty;
        pool.mutex = .{};
        pool.condition = .{};
        pool.max_connections = max_connections;
        pool.min_connections = min_connections;
        pool.current_connections = 0;
        pool.is_memory = database_path == null;

        if (database_path) |path| {
            pool.database_path = try allocator.dupe(u8, path);
            pool.shared_storage = try storage.StorageEngine.init(allocator, path);
        } else {
            pool.database_path = null;
            pool.shared_storage = try storage.StorageEngine.initMemory(allocator);
        }

        // Create minimum connections
        try pool.createInitialConnections();

        return pool;
    }

    /// Create initial connections to meet minimum requirements
    fn createInitialConnections(self: *Self) !void {
        for (0..self.min_connections) |_| {
            const pooled_conn = try self.createConnection();
            try self.connections.append(self.allocator, pooled_conn);
            try self.available_connections.append(self.allocator, pooled_conn);
            self.current_connections += 1;
        }
    }

    /// Create a new pooled connection
    fn createConnection(self: *Self) !*PooledConnection {
        const pooled_conn = try self.allocator.create(PooledConnection);

        // Use shared storage for all connections
        pooled_conn.connection = try connection.Connection.openWithSharedStorage(self.allocator, self.shared_storage);

        pooled_conn.pool = self;
        pooled_conn.is_in_use = false;
        const ts = time_utils.getTimespec();
        pooled_conn.last_used = ts.sec;
        pooled_conn.id = self.generateConnectionId();

        return pooled_conn;
    }

    /// Generate unique connection ID
    fn generateConnectionId(self: *Self) u64 {
        _ = self;
        const ts = time_utils.getTimespec();
        return @intCast(ts.sec);
    }

    /// Acquire a connection from the pool
    pub fn acquire(self: *Self) !*PooledConnection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to get an available connection
        if (self.available_connections.items.len > 0) {
            const conn = self.available_connections.orderedRemove(0);
            conn.is_in_use = true;
            const ts = time_utils.getTimespec();
            conn.last_used = ts.sec;
            return conn;
        }

        // Create new connection if under max limit
        if (self.current_connections < self.max_connections) {
            const new_conn = try self.createConnection();
            try self.connections.append(self.allocator, new_conn);
            new_conn.is_in_use = true;
            const ts = time_utils.getTimespec();
            new_conn.last_used = ts.sec;
            self.current_connections += 1;
            return new_conn;
        }

        // Wait for a connection to become available
        while (self.available_connections.items.len == 0) {
            self.condition.wait(&self.mutex);
        }

        const conn = self.available_connections.orderedRemove(0);
        conn.is_in_use = true;
        const ts = time_utils.getTimespec();
        conn.last_used = ts.sec;
        return conn;
    }

    /// Release a connection back to the pool
    pub fn release(self: *Self, pooled_conn: *PooledConnection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!pooled_conn.is_in_use) {
            return error.ConnectionNotInUse;
        }

        pooled_conn.is_in_use = false;
        const ts = time_utils.getTimespec();
        pooled_conn.last_used = ts.sec;

        try self.available_connections.append(self.allocator, pooled_conn);
        self.condition.signal();
    }

    /// Get pool statistics
    pub fn getStats(self: *Self) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return PoolStats{
            .total_connections = self.current_connections,
            .available_connections = @intCast(self.available_connections.items.len),
            .in_use_connections = self.current_connections - @as(u32, @intCast(self.available_connections.items.len)),
            .max_connections = self.max_connections,
            .min_connections = self.min_connections,
        };
    }

    /// Clean up idle connections (call periodically)
    pub fn cleanup(self: *Self, max_idle_seconds: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ts = time_utils.getTimespec();
        const current_time = ts.sec;
        var i: usize = 0;

        while (i < self.available_connections.items.len) {
            const conn = self.available_connections.items[i];

            if (current_time - conn.last_used > max_idle_seconds and self.current_connections > self.min_connections) {
                // Remove from available list
                _ = self.available_connections.orderedRemove(i);

                // Find and remove from all connections list
                for (self.connections.items, 0..) |connection_ptr, j| {
                    if (connection_ptr == conn) {
                        _ = self.connections.orderedRemove(j);
                        break;
                    }
                }

                // Cleanup the connection
                conn.connection.close();
                self.allocator.destroy(conn);
                self.current_connections -= 1;
            } else {
                i += 1;
            }
        }
    }

    /// Shutdown the connection pool
    pub fn deinit(self: *Self) void {
        // Close all connections
        for (self.connections.items) |conn| {
            conn.connection.close();
            self.allocator.destroy(conn);
        }

        self.connections.deinit(self.allocator);
        self.available_connections.deinit(self.allocator);

        // Clean up shared storage
        self.shared_storage.deinit();

        if (self.database_path) |path| {
            self.allocator.free(path);
        }

        self.allocator.destroy(self);
    }
};

/// Pooled connection wrapper
pub const PooledConnection = struct {
    connection: *connection.Connection,
    pool: *ConnectionPool,
    is_in_use: bool,
    last_used: i64,
    id: u64,

    const Self = @This();

    /// Execute SQL statement on this connection
    pub fn execute(self: *Self, sql: []const u8) !void {
        if (!self.is_in_use) {
            return error.ConnectionNotInUse;
        }
        return self.connection.execute(sql);
    }

    /// Prepare statement on this connection
    pub fn prepare(self: *Self, sql: []const u8) !*connection.PreparedStatement {
        if (!self.is_in_use) {
            return error.ConnectionNotInUse;
        }
        return self.connection.prepare(sql);
    }

    /// Get connection info
    pub fn info(self: *Self) connection.ConnectionInfo {
        return self.connection.info();
    }

    /// Release this connection back to the pool
    pub fn release(self: *Self) !void {
        return self.pool.release(self);
    }
};

/// Pool statistics
pub const PoolStats = struct {
    total_connections: u32,
    available_connections: u32,
    in_use_connections: u32,
    max_connections: u32,
    min_connections: u32,
};

/// Pool configuration
pub const PoolConfig = struct {
    min_connections: u32 = 2,
    max_connections: u32 = 10,
    idle_timeout_seconds: i64 = 600, // 10 minutes
    connection_timeout_seconds: i64 = 30,
};

test "connection pool basic operations" {
    const allocator = std.testing.allocator;

    // Test in-memory pool
    const pool = try ConnectionPool.init(allocator, null, 2, 5);
    defer pool.deinit();

    // Test acquiring connections
    const conn1 = try pool.acquire();
    const conn2 = try pool.acquire();

    // Test pool stats
    const stats = pool.getStats();
    try std.testing.expect(stats.in_use_connections == 2);
    try std.testing.expect(stats.available_connections == 0);

    // Test releasing connections
    try conn1.release();
    try conn2.release();

    const stats2 = pool.getStats();
    try std.testing.expect(stats2.in_use_connections == 0);
    try std.testing.expect(stats2.available_connections == 2);
}

test "connection pool with SQL execution" {
    const allocator = std.testing.allocator;

    const pool = try ConnectionPool.init(allocator, null, 1, 3);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer conn.release() catch {};

    // Test executing SQL through pooled connection
    try conn.execute("CREATE TABLE test (id INTEGER, name TEXT);");
    try conn.execute("INSERT INTO test VALUES (1, 'Hello');");
}
