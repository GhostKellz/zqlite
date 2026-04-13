const std = @import("std");
const zsync = @import("zsync");
const compat = @import("../zsync/compat/thread.zig");
const storage = @import("../db/storage.zig");
const connection = @import("../db/connection.zig");
const time_utils = @import("../time_utils.zig");

// Enhanced zsync v0.5.4 features
const IoUringConfig = struct {
    entries: u32 = 256,
    flags: u32 = 0,
};

// Future combinators for complex async patterns
const FutureCombinators = struct {
    pub fn race(comptime T: type, futures: []zsync.Future(T)) !T {
        return zsync.race(T, futures);
    }

    pub fn all(comptime T: type, futures: []zsync.Future(T)) ![]T {
        return zsync.all(T, futures);
    }

    pub fn timeout(comptime T: type, future: zsync.Future(T), ms: u64) !T {
        return zsync.timeout(T, future, ms);
    }
};

/// Enhanced async database operations with zsync v0.5.4 features
/// Perfect for AI agents, VPN servers, and real-time applications
pub const AsyncDatabase = struct {
    allocator: std.mem.Allocator,
    connection_pool: ConnectionPool,
    io: zsync.Runtime,
    use_io_uring: bool,
    query_timeout_ms: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8, pool_size: u32) !Self {
        const connection_pool = try ConnectionPool.init(allocator, db_path, pool_size);

        // Auto-detect best runtime (io_uring on Linux if available)
        const runtime = zsync.Runtime.autoDetect(.{
            .thread_pool_size = @intCast(pool_size),
            .io_uring_config = if (std.builtin.os.tag == .linux) IoUringConfig{} else null,
        });

        return Self{
            .allocator = allocator,
            .connection_pool = connection_pool,
            .io = runtime,
            .use_io_uring = std.builtin.os.tag == .linux,
            .query_timeout_ms = 30000, // 30 second default timeout
        };
    }

    /// Execute SQL asynchronously with timeout support
    pub fn executeAsync(self: *Self, sql: []const u8) !QueryResult {
        return self.executeAsyncWithTimeout(sql, self.query_timeout_ms);
    }

    /// Execute SQL asynchronously with custom timeout
    pub fn executeAsyncWithTimeout(self: *Self, sql: []const u8, timeout_ms: u64) !QueryResult {
        const future = zsync.spawn(executeSqlWorker, .{ self, sql });
        return FutureCombinators.timeout(QueryResult, future, timeout_ms) catch |err| switch (err) {
            error.Timeout => QueryResult{
                .rows = &[_]storage.Row{},
                .affected_rows = 0,
                .success = false,
                .error_message = try std.fmt.allocPrint(self.allocator, "Query timed out after {}ms", .{timeout_ms}),
            },
            else => err,
        };
    }

    /// Batch execute multiple queries using vectorized operations
    pub fn batchExecuteAsync(self: *Self, queries: [][]const u8) ![]QueryResult {
        return self.batchExecuteAsyncWithTimeout(queries, self.query_timeout_ms);
    }

    /// Vectorized batch execution with zsync channels for high throughput
    pub fn batchExecuteAsyncWithTimeout(self: *Self, queries: [][]const u8, timeout_ms: u64) ![]QueryResult {
        if (queries.len == 0) return &[_]QueryResult{};

        // Create futures for all queries
        var futures = try self.allocator.alloc(zsync.Future(QueryResult), queries.len);
        defer self.allocator.free(futures);

        for (queries, 0..) |query, i| {
            futures[i] = zsync.spawn(executeSqlWorker, .{ self, query });
        }

        // Wait for all queries to complete or timeout
        const all_future = zsync.spawn(struct {
            fn waitAll(fs: []zsync.Future(QueryResult)) ![]QueryResult {
                return FutureCombinators.all(QueryResult, fs);
            }
        }.waitAll, .{futures});

        return FutureCombinators.timeout([]QueryResult, all_future, timeout_ms) catch |err| switch (err) {
            error.Timeout => blk: {
                const results = try self.allocator.alloc(QueryResult, queries.len);
                for (results) |*result| {
                    result.* = QueryResult{
                        .rows = &[_]storage.Row{},
                        .affected_rows = 0,
                        .success = false,
                        .error_message = try std.fmt.allocPrint(self.allocator, "Batch query timed out after {}ms", .{timeout_ms}),
                    };
                }
                break :blk results;
            },
            else => err,
        };
    }

    /// Transaction processing with enhanced error handling
    pub fn transactionAsync(self: *Self, queries: [][]const u8) !QueryResult {
        const future = zsync.spawn(transactionWorker, .{ self, queries });
        return FutureCombinators.timeout(QueryResult, future, self.query_timeout_ms) catch |err| switch (err) {
            error.Timeout => QueryResult{
                .rows = &[_]storage.Row{},
                .affected_rows = 0,
                .success = false,
                .error_message = try std.fmt.allocPrint(self.allocator, "Transaction timed out after {}ms", .{self.query_timeout_ms}),
            },
            else => err,
        };
    }

    /// Bulk insert optimization using zsync channels
    pub fn bulkInsertAsync(self: *Self, table_name: []const u8, rows: []storage.Row) !QueryResult {
        if (rows.len == 0) return QueryResult{ .rows = &[_]storage.Row{}, .affected_rows = 0, .success = true, .error_message = null };

        // Create channel for coordinating bulk insert
        const channel = try zsync.bounded(storage.Row, self.allocator, @intCast(rows.len));
        defer channel.deinit();

        // Send all rows to channel
        for (rows) |row| {
            try channel.send(row);
        }

        const future = zsync.spawn(bulkInsertWorker, .{ self, table_name, channel, rows.len });
        return FutureCombinators.timeout(QueryResult, future, self.query_timeout_ms) catch |err| switch (err) {
            error.Timeout => QueryResult{
                .rows = &[_]storage.Row{},
                .affected_rows = 0,
                .success = false,
                .error_message = try std.fmt.allocPrint(self.allocator, "Bulk insert timed out after {}ms", .{self.query_timeout_ms}),
            },
            else => err,
        };
    }

    fn executeSqlWorker(self: *AsyncDatabase, sql: []const u8) !QueryResult {
        defer zsync.yieldNow();

        const conn = try self.connection_pool.acquire();
        defer self.connection_pool.release(conn);

        // Parse and execute SQL
        const parser = @import("../parser/parser.zig");
        const vm = @import("../executor/vm.zig");

        var parsed = parser.parse(self.allocator, sql) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Parse error: {}", .{err});
            return QueryResult{
                .rows = &[_]storage.Row{},
                .affected_rows = 0,
                .success = false,
                .error_message = error_msg,
            };
        };
        defer parsed.deinit(self.allocator);

        var virtual_machine = vm.VirtualMachine.init(self.allocator, conn);
        defer virtual_machine.deinitVM();
        var planner = @import("../executor/planner.zig").Planner.init(self.allocator);

        var plan = planner.plan(&parsed) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Planning error: {}", .{err});
            return QueryResult{
                .rows = &[_]storage.Row{},
                .affected_rows = 0,
                .success = false,
                .error_message = error_msg,
            };
        };
        defer plan.deinit();

        var result = virtual_machine.execute(&plan) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Execution error: {}", .{err});
            return QueryResult{
                .rows = &[_]storage.Row{},
                .affected_rows = 0,
                .success = false,
                .error_message = error_msg,
            };
        };

        // Convert ExecutionResult to QueryResult
        var rows = try self.allocator.alloc(storage.Row, result.rows.items.len);
        for (result.rows.items, 0..) |src_row, i| {
            // Clone the row values
            var values = try self.allocator.alloc(storage.Value, src_row.values.len);
            for (src_row.values, 0..) |value, j| {
                values[j] = try cloneValue(self.allocator, value);
            }
            rows[i] = storage.Row{ .values = values };
        }

        result.deinit(self.allocator);

        return QueryResult{
            .rows = rows,
            .affected_rows = result.affected_rows,
            .success = true,
            .error_message = null,
        };
    }

    fn cloneValue(allocator: std.mem.Allocator, value: storage.Value) !storage.Value {
        return switch (value) {
            .Integer => |i| storage.Value{ .Integer = i },
            .Real => |r| storage.Value{ .Real = r },
            .Text => |t| storage.Value{ .Text = try allocator.dupe(u8, t) },
            .Blob => |b| storage.Value{ .Blob = try allocator.dupe(u8, b) },
            .Null => storage.Value.Null,
            .Parameter => |p| storage.Value{ .Parameter = p },
        };
    }

    fn bulkInsertWorker(self: *AsyncDatabase, table_name: []const u8, channel: zsync.Channel(storage.Row), row_count: usize) !QueryResult {
        defer zsync.yieldNow();

        const conn = try self.connection_pool.acquire();
        defer self.connection_pool.release(conn);

        var affected_rows: u64 = 0;
        var batch_size: usize = 0;
        const max_batch_size = 1000; // Process in batches of 1000

        var batch = try self.allocator.alloc(storage.Row, max_batch_size);
        defer self.allocator.free(batch);

        while (batch_size < row_count) {
            const current_batch_size = @min(max_batch_size, row_count - batch_size);

            // Receive batch of rows from channel
            for (0..current_batch_size) |i| {
                batch[i] = try channel.receive();
            }

            // Execute batch insert
            const sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO {s} VALUES ", .{table_name});
            defer self.allocator.free(sql);

            // Use prepared statement for better performance
            // This is a simplified version - real implementation would use proper prepared statements
            var values_str: std.ArrayListUnmanaged(u8) = .empty;
            defer values_str.deinit(self.allocator);

            for (batch[0..current_batch_size], 0..) |row, i| {
                if (i > 0) try values_str.appendSlice(self.allocator, ", ");
                try values_str.appendSlice(self.allocator, "(");
                for (row.values, 0..) |value, j| {
                    if (j > 0) try values_str.appendSlice(self.allocator, ", ");
                    switch (value) {
                        .Integer => |int| {
                            const int_str = try std.fmt.allocPrint(self.allocator, "{}", .{int});
                            defer self.allocator.free(int_str);
                            try values_str.appendSlice(self.allocator, int_str);
                        },
                        .Real => |real| {
                            const real_str = try std.fmt.allocPrint(self.allocator, "{d}", .{real});
                            defer self.allocator.free(real_str);
                            try values_str.appendSlice(self.allocator, real_str);
                        },
                        .Text => |text| {
                            const text_str = try std.fmt.allocPrint(self.allocator, "'{s}'", .{text});
                            defer self.allocator.free(text_str);
                            try values_str.appendSlice(self.allocator, text_str);
                        },
                        .Null => try values_str.appendSlice(self.allocator, "NULL"),
                        else => try values_str.appendSlice(self.allocator, "?"),
                    }
                }
                try values_str.appendSlice(self.allocator, ")");
            }

            const full_sql = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ sql, values_str.items });
            defer self.allocator.free(full_sql);

            const result = try self.executeSqlWorker(full_sql);
            defer result.deinit(self.allocator);

            if (!result.success) {
                return QueryResult{
                    .rows = &[_]storage.Row{},
                    .affected_rows = affected_rows,
                    .success = false,
                    .error_message = result.error_message,
                };
            }

            affected_rows += result.affected_rows;
            batch_size += current_batch_size;

            // Yield after each batch to allow other tasks
            zsync.yieldNow();
        }

        return QueryResult{
            .rows = &[_]storage.Row{},
            .affected_rows = affected_rows,
            .success = true,
            .error_message = null,
        };
    }

    fn transactionWorker(self: *AsyncDatabase, queries: [][]const u8) !QueryResult {
        defer zsync.yieldNow();

        const conn = try self.connection_pool.acquire();
        defer self.connection_pool.release(conn);

        // Begin transaction
        try conn.beginTransaction();

        var total_affected: u32 = 0;
        errdefer conn.rollbackTransaction() catch {};

        // Execute all queries in transaction
        for (queries) |query| {
            const result = try self.executeSqlWorker(query);
            defer result.deinit(self.allocator);

            if (!result.success) {
                try conn.rollbackTransaction();
                return QueryResult{
                    .rows = &[_]storage.Row{},
                    .affected_rows = 0,
                    .success = false,
                    .error_message = result.error_message,
                };
            }

            total_affected += result.affected_rows;
        }

        // Commit transaction
        try conn.commitTransaction();

        return QueryResult{
            .rows = &[_]storage.Row{},
            .affected_rows = total_affected,
            .success = true,
            .error_message = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.connection_pool.deinit();
    }
};

/// Get current time in milliseconds using POSIX clock
fn getMilliTimestamp() i64 {
    const ts = time_utils.getTimespec();
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Enhanced connection pool with health monitoring
const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayListUnmanaged(*connection.Connection),
    connection_health: std.ArrayListUnmanaged(ConnectionHealth),
    available: std.Thread.Semaphore,
    mutex: compat.Mutex = .{},
    health_check_interval_ms: u64,
    last_health_check: i64,

    const ConnectionHealth = struct {
        connection: *connection.Connection,
        last_used: i64,
        error_count: u32,
        is_healthy: bool,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8, pool_size: u32) !Self {
        var connections: std.ArrayListUnmanaged(*connection.Connection) = .empty;
        var health_info: std.ArrayListUnmanaged(ConnectionHealth) = .empty;
        const current_time = getMilliTimestamp();

        // Create connections with health monitoring
        for (0..pool_size) |_| {
            const conn = try connection.Connection.open(db_path);
            try connections.append(allocator, conn);
            try health_info.append(allocator, ConnectionHealth{
                .connection = conn,
                .last_used = current_time,
                .error_count = 0,
                .is_healthy = true,
            });
        }

        return Self{
            .allocator = allocator,
            .connections = connections,
            .connection_health = health_info,
            .available = std.Thread.Semaphore{ .permits = pool_size },
            .mutex = .init,
            .health_check_interval_ms = 300000, // 5 minutes
            .last_health_check = current_time,
        };
    }

    pub fn acquire(self: *Self) !*connection.Connection {
        // Perform periodic health check
        try self.performHealthCheck();

        self.available.wait();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Find a healthy connection
        var conn_index: ?usize = null;
        for (self.connection_health.items, 0..) |*health, i| {
            if (health.is_healthy) {
                conn_index = i;
                health.last_used = getMilliTimestamp();
                break;
            }
        }

        if (conn_index) |index| {
            const conn = self.connections.swapRemove(index);
            _ = self.connection_health.swapRemove(index);
            return conn;
        }

        // If no healthy connections, try to repair one
        if (self.connections.items.len > 0) {
            const conn = self.connections.pop();
            _ = self.connection_health.pop();
            // Attempt to repair connection
            if (self.repairConnection(conn)) {
                return conn;
            }
        }

        return error.NoHealthyConnections;
    }

    pub fn release(self: *Self, conn: *connection.Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Update connection health on release
        const current_time = getMilliTimestamp();
        self.connections.append(self.allocator, conn) catch {};
        self.connection_health.append(self.allocator, ConnectionHealth{
            .connection = conn,
            .last_used = current_time,
            .error_count = 0,
            .is_healthy = true,
        }) catch {};

        self.available.post();
    }

    /// Mark connection as unhealthy due to error
    pub fn markConnectionError(self: *Self, conn: *connection.Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connection_health.items) |*health| {
            if (health.connection == conn) {
                health.error_count += 1;
                if (health.error_count > 5) {
                    health.is_healthy = false;
                }
                break;
            }
        }
    }

    /// Perform health check on connections
    fn performHealthCheck(self: *Self) !void {
        const current_time = getMilliTimestamp();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (current_time - self.last_health_check < @as(i64, @intCast(self.health_check_interval_ms))) {
            return;
        }

        self.last_health_check = current_time;

        // Check each connection's health
        for (self.connection_health.items) |*health| {
            if (!health.is_healthy) {
                // Try to repair unhealthy connections
                if (self.repairConnection(health.connection)) {
                    health.is_healthy = true;
                    health.error_count = 0;
                }
            }
        }
    }

    /// Attempt to repair a connection
    fn repairConnection(self: *Self, conn: *connection.Connection) bool {
        _ = self; // Remove unused variable warning

        // Simple health check - execute a basic query
        const test_sql = "SELECT 1";
        conn.execute(test_sql) catch {
            return false;
        };

        return true;
    }

    pub fn deinit(self: *Self) void {
        for (self.connections.items) |conn| {
            conn.close();
        }
        self.connections.deinit(self.allocator);
        self.connection_health.deinit(self.allocator);
    }
};

/// Query result type
pub const QueryResult = struct {
    rows: []storage.Row,
    affected_rows: u64,
    success: bool,
    error_message: ?[]const u8,

    pub fn deinit(self: *QueryResult, allocator: std.mem.Allocator) void {
        for (self.rows) |row| {
            for (row.values) |value| {
                switch (value) {
                    .Text => |t| allocator.free(t),
                    .Blob => |b| allocator.free(b),
                    else => {},
                }
            }
            allocator.free(row.values);
        }
        if (self.rows.len > 0) {
            allocator.free(self.rows);
        }
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

/// AI Agent Database - High-performance encrypted database for AI applications
pub const AIAgentDatabase = struct {
    async_db: *AsyncDatabase,
    crypto: *@import("secure_storage.zig").CryptoEngine,

    const Self = @This();

    pub fn init(async_db: *AsyncDatabase, crypto: *@import("secure_storage.zig").CryptoEngine) Self {
        return Self{
            .async_db = async_db,
            .crypto = crypto,
        };
    }

    /// Store encrypted AI agent credentials
    pub fn storeAgentCredentials(self: *Self, agent_id: []const u8, credentials: []const u8) !void {
        const encrypted = try self.crypto.encrypt(credentials);
        defer self.crypto.allocator.free(encrypted);

        const sql = try std.fmt.allocPrint(self.async_db.allocator, "INSERT INTO agent_credentials (agent_id, encrypted_data) VALUES ('{}', '{}')", .{ agent_id, std.fmt.fmtSliceHexLower(encrypted) });
        defer self.async_db.allocator.free(sql);

        _ = try self.async_db.executeAsync(sql);
    }

    /// Retrieve and decrypt AI agent credentials
    pub fn getAgentCredentials(self: *Self, agent_id: []const u8) ![]u8 {
        const sql = try std.fmt.allocPrint(self.async_db.allocator, "SELECT encrypted_data FROM agent_credentials WHERE agent_id = '{}'", .{agent_id});
        defer self.async_db.allocator.free(sql);

        const result = try self.async_db.executeAsync(sql);
        defer result.deinit(self.async_db.allocator);

        if (!result.success) {
            return error.QueryFailed;
        }

        if (result.rows.len == 0) {
            return error.AgentNotFound;
        }

        // Get encrypted data from first row, first column
        const encrypted_data = switch (result.rows[0].values[0]) {
            .Text => |t| t,
            .Blob => |b| b,
            else => return error.InvalidData,
        };

        // Decrypt the data
        return try self.crypto.decrypt(encrypted_data);
    }
};
