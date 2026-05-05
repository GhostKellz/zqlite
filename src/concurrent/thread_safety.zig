const std = @import("std");
const zqlite = @import("../zqlite.zig");
const compat = @import("../runtime/compat/thread.zig");

/// Thread-safe connection pool for concurrent database access
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayList(*zqlite.db.Connection),
    available: std.ArrayList(bool),
    mutex: compat.Mutex = .{},
    condition: compat.Condition = .{},
    database_path: []const u8,
    max_connections: u32,
    is_memory: bool,

    const Self = @This();

    /// Initialize connection pool
    pub fn init(allocator: std.mem.Allocator, database_path: []const u8, max_connections: u32) !*Self {
        var pool = try allocator.create(Self);
        pool.* = Self{
            .allocator = allocator,
            .connections = .{},
            .available = .{},
            .mutex = .{},
            .condition = .{},
            .database_path = try allocator.dupe(u8, database_path),
            .max_connections = max_connections,
            .is_memory = std.mem.eql(u8, database_path, ":memory:"),
        };

        // Pre-allocate connections
        try pool.connections.ensureTotalCapacity(allocator, max_connections);
        try pool.available.ensureTotalCapacity(allocator, max_connections);

        for (0..max_connections) |_| {
            const conn = if (pool.is_memory)
                try zqlite.openMemory()
            else
                try zqlite.open(database_path);

            try pool.connections.append(allocator, conn);
            try pool.available.append(allocator, true);
        }

        return pool;
    }

    /// Acquire a connection from the pool (blocks if none available)
    pub fn acquire(self: *Self) !*zqlite.db.Connection {
        const io = std.io.getStdIo();
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);

        while (true) {
            // Look for available connection
            for (self.available.items, 0..) |is_available, i| {
                if (is_available) {
                    self.available.items[i] = false;
                    return self.connections.items[i];
                }
            }

            // No connections available, wait
            self.condition.wait(io, &self.mutex);
        }
    }

    /// Try to acquire a connection without blocking
    pub fn tryAcquire(self: *Self) ?*zqlite.db.Connection {
        const io = std.io.getStdIo();
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);

        // Look for available connection
        for (self.available.items, 0..) |is_available, i| {
            if (is_available) {
                self.available.items[i] = false;
                return self.connections.items[i];
            }
        }

        return null;
    }

    /// Release a connection back to the pool
    pub fn release(self: *Self, conn: *zqlite.db.Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find the connection and mark as available
        for (self.connections.items, 0..) |pool_conn, i| {
            if (pool_conn == conn) {
                self.available.items[i] = true;
                self.condition.signal();
                return;
            }
        }
    }

    /// Execute a function with an acquired connection
    pub fn withConnection(self: *Self, comptime func: anytype, args: anytype) !@TypeOf(@call(.auto, func, .{self.connections.items[0]} ++ args)) {
        const conn = try self.acquire();
        defer self.release(conn);

        return @call(.auto, func, .{conn} ++ args);
    }

    /// Get pool statistics
    pub fn getStats(self: *Self) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var available_count: u32 = 0;
        for (self.available.items) |is_available| {
            if (is_available) available_count += 1;
        }

        return PoolStats{
            .total_connections = @intCast(self.connections.items.len),
            .available_connections = available_count,
            .active_connections = @as(u32, @intCast(self.connections.items.len)) - available_count,
        };
    }

    /// Clean up connection pool
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |conn| {
            conn.close();
        }

        self.connections.deinit(self.allocator);
        self.available.deinit(self.allocator);
        self.allocator.free(self.database_path);
        self.allocator.destroy(self);
    }
};

/// Pool statistics
pub const PoolStats = struct {
    total_connections: u32,
    available_connections: u32,
    active_connections: u32,
};

/// Thread-safe database wrapper
pub const ThreadSafeDatabase = struct {
    pool: *ConnectionPool,

    const Self = @This();

    /// Initialize thread-safe database
    pub fn init(allocator: std.mem.Allocator, database_path: []const u8, max_connections: u32) !Self {
        const pool = try ConnectionPool.init(allocator, database_path, max_connections);
        return Self{ .pool = pool };
    }

    /// Execute SQL statement (thread-safe)
    pub fn execute(self: *Self, sql: []const u8) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        try conn.execute(sql);
    }

    /// Execute SQL query with callback (thread-safe)
    /// The callback is invoked for each row in the result set
    pub fn query(self: *Self, sql: []const u8, callback: anytype) !void {
        const conn = try self.pool.acquire();
        defer self.pool.release(conn);

        var result_set = try conn.query(sql);
        defer result_set.deinit();

        // Iterate through rows and invoke callback for each
        while (result_set.next()) |row| {
            callback(row);
        }
    }

    /// Begin transaction (thread-safe)
    pub fn begin(self: *Self) !TransactionHandle {
        const conn = try self.pool.acquire();
        try conn.begin();

        return TransactionHandle{
            .pool = self.pool,
            .connection = conn,
            .committed = false,
        };
    }

    /// Get database statistics
    pub fn getStats(self: *Self) PoolStats {
        return self.pool.getStats();
    }

    /// Clean up
    pub fn deinit(self: *Self) void {
        self.pool.deinit();
    }
};

/// Transaction handle that ensures connection is held for transaction duration
pub const TransactionHandle = struct {
    pool: *ConnectionPool,
    connection: *zqlite.db.Connection,
    committed: bool,

    const Self = @This();

    /// Execute SQL within transaction
    pub fn execute(self: *Self, sql: []const u8) !void {
        if (self.committed) return error.TransactionFinished;
        try self.connection.execute(sql);
    }

    /// Commit transaction
    pub fn commit(self: *Self) !void {
        if (self.committed) return error.TransactionFinished;

        try self.connection.commit();
        self.committed = true;
        self.pool.release(self.connection);
    }

    /// Rollback transaction
    pub fn rollback(self: *Self) !void {
        if (self.committed) return error.TransactionFinished;

        try self.connection.rollback();
        self.committed = true;
        self.pool.release(self.connection);
    }

    /// Auto-rollback on deinit if not committed
    pub fn deinit(self: *Self) void {
        if (!self.committed) {
            self.connection.rollback() catch {};
            self.pool.release(self.connection);
        }
    }
};

/// Read-Write lock for fine-grained concurrency control
pub const RWLock = struct {
    mutex: compat.Mutex = .{},
    read_condition: compat.Condition = .{},
    write_condition: compat.Condition = .{},
    readers: u32,
    writers: u32,
    write_requests: u32,

    const Self = @This();

    /// Initialize RW lock
    pub fn init() Self {
        return Self{
            .mutex = .{},
            .read_condition = .{},
            .write_condition = .{},
            .readers = 0,
            .writers = 0,
            .write_requests = 0,
        };
    }

    /// Acquire read lock
    pub fn lockRead(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.writers > 0 or self.write_requests > 0) {
            self.read_condition.wait(&self.mutex);
        }

        self.readers += 1;
    }

    /// Release read lock
    pub fn unlockRead(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.readers -= 1;
        if (self.readers == 0) {
            self.write_condition.signal();
        }
    }

    /// Acquire write lock
    pub fn lockWrite(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.write_requests += 1;

        while (self.readers > 0 or self.writers > 0) {
            self.write_condition.wait(&self.mutex);
        }

        self.write_requests -= 1;
        self.writers += 1;
    }

    /// Release write lock
    pub fn unlockWrite(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.writers -= 1;
        if (self.write_requests > 0) {
            self.write_condition.signal();
        } else {
            self.read_condition.broadcast();
        }
    }

    /// Execute function with read lock
    pub fn withReadLock(self: *Self, comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
        self.lockRead();
        defer self.unlockRead();
        return @call(.auto, func, args);
    }

    /// Execute function with write lock
    pub fn withWriteLock(self: *Self, comptime func: anytype, args: anytype) @TypeOf(@call(.auto, func, args)) {
        self.lockWrite();
        defer self.unlockWrite();
        return @call(.auto, func, args);
    }
};

test "connection pool basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var pool = try ConnectionPool.init(allocator, ":memory:", 3);
    defer pool.deinit();

    // Test acquiring connections
    const conn1 = try pool.acquire();
    const conn2 = try pool.acquire();
    const conn3 = try pool.acquire();

    // Pool should be full now
    const conn4 = pool.tryAcquire();
    try testing.expect(conn4 == null);

    // Release one and try again
    pool.release(conn1);
    const conn5 = pool.tryAcquire();
    try testing.expect(conn5 != null);

    pool.release(conn2);
    pool.release(conn3);
    pool.release(conn5.?);
}

test "thread safe database" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var db = try ThreadSafeDatabase.init(allocator, ":memory:", 2);
    defer db.deinit();

    // Test basic operations
    try db.execute("CREATE TABLE test (id INTEGER, name TEXT)");
    try db.execute("INSERT INTO test VALUES (1, 'Alice')");

    // Test transaction
    var tx = try db.begin();
    defer tx.deinit();

    try tx.execute("INSERT INTO test VALUES (2, 'Bob')");
    try tx.commit();
}

test "rw lock functionality" {
    const testing = std.testing;

    var rw_lock = RWLock.init();

    // Test read lock
    rw_lock.lockRead();
    rw_lock.unlockRead();

    // Test write lock
    rw_lock.lockWrite();
    rw_lock.unlockWrite();

    // Test with function calls
    const result = rw_lock.withReadLock(struct {
        fn testFunc(value: i32) i32 {
            return value * 2;
        }
    }.testFunc, .{42});

    try testing.expectEqual(@as(i32, 84), result);
}
