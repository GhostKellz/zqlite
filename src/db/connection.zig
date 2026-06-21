const std = @import("std");
const storage = @import("storage.zig");
const wal = @import("wal.zig");
const btree = @import("btree.zig");
const ast = @import("../parser/ast.zig");
const parser = @import("../parser/parser.zig");
const tokenizer = @import("../parser/tokenizer.zig");
const planner = @import("../executor/planner.zig");
const vm = @import("../executor/vm.zig");
const cache_manager = @import("../performance/cache_manager.zig");
const query_cache = @import("../performance/query_cache.zig");
const posix = std.posix;

/// Context for WAL page write callback during transactions
const WalCallbackContext = struct {
    wal_ref: *wal.WriteAheadLog,
};

/// Callback function for btree to log page writes to WAL
fn walPageWriteCallback(ctx_ptr: *anyopaque, page_id: u32, old_data: []const u8) anyerror!void {
    const ctx: *WalCallbackContext = @ptrCast(@alignCast(ctx_ptr));
    // Log the entire page as old_data with offset 0
    // new_data is empty since we're just recording what to restore on rollback
    try ctx.wal_ref.logPageWrite(page_id, 0, old_data, &.{});
}

/// SECURITY: Path policy for ATTACH DATABASE operations
/// Controls which paths can be attached to prevent path traversal attacks
pub const AttachPathPolicy = struct {
    /// Allowed root directories for ATTACH operations
    /// If empty, all paths are allowed (insecure - use only for testing)
    allowed_roots: []const []const u8,
    /// Whether to allow :memory: databases
    allow_memory: bool,
    /// Whether to allow relative paths (resolved relative to current working directory)
    allow_relative: bool,

    pub const ALLOW_ALL = AttachPathPolicy{
        .allowed_roots = &[_][]const u8{},
        .allow_memory = true,
        .allow_relative = true,
    };

    pub const SECURE_DEFAULT = AttachPathPolicy{
        .allowed_roots = &[_][]const u8{},
        .allow_memory = true,
        .allow_relative = false, // Require absolute paths
    };

    /// Check if a path is under a root directory with proper segment boundary checking
    /// Prevents "/var/db" from matching "/var/database" (must have separator or end)
    fn isPathUnderRoot(path: []const u8, root: []const u8) bool {
        if (!std.mem.startsWith(u8, path, root)) return false;

        // Exact match is allowed
        if (path.len == root.len) return true;

        // Must have path separator after root
        // Handle root with trailing separator
        const root_len = if (root.len > 0 and root[root.len - 1] == std.fs.path.sep)
            root.len - 1
        else
            root.len;

        if (path.len <= root_len) return false;
        return path[root_len] == std.fs.path.sep;
    }

    /// Validate and canonicalize a path against this policy
    pub fn validatePath(self: AttachPathPolicy, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        // Allow :memory: if permitted
        if (std.mem.eql(u8, path, ":memory:")) {
            if (self.allow_memory) {
                return try allocator.dupe(u8, path);
            }
            return error.MemoryDatabaseNotAllowed;
        }

        // Check for path traversal attempts (.. sequences)
        if (std.mem.indexOf(u8, path, "..") != null) {
            return error.PathTraversalDetected;
        }

        // Check for null bytes (path injection)
        for (path) |c| {
            if (c == 0) {
                return error.InvalidPathCharacter;
            }
        }

        // Check if path is absolute
        const is_absolute = std.fs.path.isAbsolute(path);
        if (!is_absolute and !self.allow_relative) {
            return error.RelativePathNotAllowed;
        }

        // Normalize the path (remove redundant separators, etc.)
        // For security, we work with the path as-is after basic validation
        const validated_path = try allocator.dupe(u8, path);
        errdefer allocator.free(validated_path);

        // If allowed_roots is empty, allow all paths
        if (self.allowed_roots.len == 0) {
            return validated_path;
        }

        // For relative paths with allowed_roots, we need absolute path to check
        if (!is_absolute) {
            allocator.free(validated_path);
            return error.RelativePathWithRootsNotSupported;
        }

        // Check if path is under an allowed root (segment-aware boundary check)
        for (self.allowed_roots) |allowed_root| {
            if (isPathUnderRoot(validated_path, allowed_root)) {
                return validated_path;
            }
        }

        allocator.free(validated_path);
        return error.PathNotInAllowedRoots;
    }
};

/// Connection options for security and behavior configuration
pub const ConnectionOptions = struct {
    /// Enable secure mode: uses SECURE_DEFAULT attach policy, stricter validation
    secure_mode: bool = false,
    /// Custom attach path policy (overrides secure_mode if set)
    attach_policy: ?AttachPathPolicy = null,

    pub const DEFAULT = ConnectionOptions{};
    pub const SECURE = ConnectionOptions{ .secure_mode = true };
};

/// Undo log entry for transaction rollback
pub const UndoEntry = struct {
    operation: enum { Insert, Delete, Update },
    table_name: []const u8,
    row_id: i64,
    new_row_id: ?i64, // For UPDATE: the new row that was inserted
    old_values: ?[]storage.Value, // For DELETE/UPDATE: values to restore (not used with logical deletes)

    pub fn deinit(self: *UndoEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        if (self.old_values) |values| {
            for (values) |value| {
                value.deinit(allocator);
            }
            allocator.free(values);
        }
    }
};

pub const SavepointEntry = struct {
    name: []const u8,
    undo_len: usize,
    started_transaction: bool,

    pub fn deinit(self: *SavepointEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Database connection handle
pub const Connection = struct {
    allocator: std.mem.Allocator,
    storage_engine: *storage.StorageEngine,
    wal: ?*wal.WriteAheadLog,
    is_memory: bool,
    path: ?[]const u8,
    owns_storage: bool, // Whether this connection owns and should clean up the storage engine
    in_transaction: bool,
    undo_log: std.ArrayListUnmanaged(UndoEntry),
    savepoints: std.ArrayListUnmanaged(SavepointEntry),
    plan_cache: ?cache_manager.QueryPlanCache,
    result_cache: ?*query_cache.QueryCache, // Optional result cache for SELECT queries
    attached_databases: std.StringHashMap(*Self), // ATTACH DATABASE schema_name -> connection
    /// SECURITY: Path policy for ATTACH operations (default allows all for backwards compatibility)
    attach_path_policy: AttachPathPolicy,
    /// WAL callback context for transaction page logging
    wal_callback_ctx: ?*WalCallbackContext,

    const Self = @This();

    /// Open a database file with default options (backwards compatible)
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Self {
        return openWithOptions(allocator, path, ConnectionOptions.DEFAULT);
    }

    /// Open a database file with options
    pub fn openWithOptions(allocator: std.mem.Allocator, path: []const u8, options: ConnectionOptions) !*Self {
        var conn = try allocator.create(Self);
        errdefer allocator.destroy(conn);

        conn.allocator = allocator;
        conn.storage_engine = try storage.StorageEngine.init(allocator, path);
        errdefer conn.storage_engine.deinit();

        conn.wal = try wal.WriteAheadLog.init(allocator, path);
        errdefer if (conn.wal) |w| w.deinit();

        conn.is_memory = false;
        conn.path = try allocator.dupe(u8, path);
        errdefer allocator.free(conn.path.?);

        conn.owns_storage = true;
        conn.in_transaction = false;
        conn.undo_log = .empty;
        conn.savepoints = .empty;
        conn.plan_cache = try cache_manager.QueryPlanCache.init(allocator, 100);
        errdefer if (conn.plan_cache) |*cache| cache.deinit();

        conn.result_cache = null; // Caller can set via setResultCache()
        conn.attached_databases = std.StringHashMap(*Self).init(allocator);
        conn.wal_callback_ctx = null;

        // Apply security options
        if (options.attach_policy) |policy| {
            conn.attach_path_policy = policy;
        } else if (options.secure_mode) {
            conn.attach_path_policy = AttachPathPolicy.SECURE_DEFAULT;
        } else {
            conn.attach_path_policy = AttachPathPolicy.ALLOW_ALL;
        }

        // Replay WAL on startup to recover any uncommitted changes
        if (conn.wal) |w| {
            try w.checkpointToPager(conn.storage_engine.pager);
        }

        return conn;
    }

    /// Open an in-memory database with default options (backwards compatible)
    pub fn openMemory(allocator: std.mem.Allocator) !*Self {
        return openMemoryWithOptions(allocator, ConnectionOptions.DEFAULT);
    }

    /// Open an in-memory database with options
    pub fn openMemoryWithOptions(allocator: std.mem.Allocator, options: ConnectionOptions) !*Self {
        var conn = try allocator.create(Self);
        conn.allocator = allocator;
        conn.storage_engine = try storage.StorageEngine.initMemory(allocator);
        conn.wal = null; // No WAL for in-memory databases
        conn.is_memory = true;
        conn.path = null;
        conn.owns_storage = true;
        conn.in_transaction = false;
        conn.undo_log = .empty;
        conn.savepoints = .empty;
        conn.plan_cache = try cache_manager.QueryPlanCache.init(allocator, 100);
        conn.result_cache = null;
        conn.attached_databases = std.StringHashMap(*Self).init(allocator);
        conn.wal_callback_ctx = null;

        // Apply security options
        if (options.attach_policy) |policy| {
            conn.attach_path_policy = policy;
        } else if (options.secure_mode) {
            conn.attach_path_policy = AttachPathPolicy.SECURE_DEFAULT;
        } else {
            conn.attach_path_policy = AttachPathPolicy.ALLOW_ALL;
        }

        return conn;
    }

    /// Create connection with shared storage engine (for connection pools)
    pub fn openWithSharedStorage(allocator: std.mem.Allocator, shared_storage: *storage.StorageEngine) !*Self {
        return openWithSharedStorageAndOptions(allocator, shared_storage, ConnectionOptions.DEFAULT);
    }

    /// Create connection with shared storage engine and options
    pub fn openWithSharedStorageAndOptions(allocator: std.mem.Allocator, shared_storage: *storage.StorageEngine, options: ConnectionOptions) !*Self {
        var conn = try allocator.create(Self);
        conn.allocator = allocator;
        conn.storage_engine = shared_storage;
        conn.wal = null; // Shared connections don't manage WAL independently
        conn.is_memory = true; // Assume shared storage is memory-based for simplicity
        conn.path = null;
        conn.owns_storage = false; // This connection doesn't own the storage
        conn.in_transaction = false;
        conn.undo_log = .empty;
        conn.savepoints = .empty;
        conn.plan_cache = try cache_manager.QueryPlanCache.init(allocator, 100);
        conn.result_cache = null;
        conn.attached_databases = std.StringHashMap(*Self).init(allocator);
        conn.wal_callback_ctx = null;

        // Apply security options
        if (options.attach_policy) |policy| {
            conn.attach_path_policy = policy;
        } else if (options.secure_mode) {
            conn.attach_path_policy = AttachPathPolicy.SECURE_DEFAULT;
        } else {
            conn.attach_path_policy = AttachPathPolicy.ALLOW_ALL;
        }

        return conn;
    }

    /// Execute a SQL statement
    pub fn execute(self: *Self, sql: []const u8) !void {
        // Parse the SQL
        var parsed = try parser.parse(self.allocator, sql);
        defer parsed.deinit();

        // Execute via virtual machine
        try vm.execute(self, &parsed.statement);
    }

    /// Begin a transaction
    pub fn beginTransaction(self: *Self) !void {
        if (self.in_transaction) return error.TransactionAlreadyActive;
        if (self.wal) |w| {
            try w.beginTransaction();

            // Set up WAL callback context for btree page logging
            const ctx = try self.allocator.create(WalCallbackContext);
            ctx.wal_ref = w;
            self.wal_callback_ctx = ctx;

            // Set write callback on all table btrees
            var table_iter = self.storage_engine.tables.iterator();
            while (table_iter.next()) |entry| {
                entry.value_ptr.*.btree.setWriteCallback(walPageWriteCallback, ctx);
            }
        }
        self.in_transaction = true;
    }

    /// Begin a transaction (alias)
    pub fn begin(self: *Self) !void {
        try self.beginTransaction();
    }

    /// Clear btree write callbacks and free context
    fn clearTransactionCallbacks(self: *Self) void {
        // Clear callbacks on all table btrees
        var table_iter = self.storage_engine.tables.iterator();
        while (table_iter.next()) |entry| {
            entry.value_ptr.*.btree.clearWriteCallback();
        }

        // Free callback context
        if (self.wal_callback_ctx) |ctx| {
            self.allocator.destroy(ctx);
            self.wal_callback_ctx = null;
        }
    }

    /// Commit a transaction
    pub fn commitTransaction(self: *Self) !void {
        // Clear btree callbacks first
        self.clearTransactionCallbacks();

        if (self.wal) |w| {
            try w.commit();
            // Once the WAL commit record passes its durability barrier, the
            // transaction is committed even if a later checkpoint fails.
            self.in_transaction = false;
            // Checkpoint WAL (truncates the file, data already in btree)
            try w.checkpointToPager(self.storage_engine.pager);
        }

        // Save metadata including deleted_keys for file-backed storage
        if (!self.is_memory) {
            try self.storage_engine.saveAllMetadata();
            try self.storage_engine.pager.flush();
        }

        // Clear undo log - changes are now permanent
        for (self.undo_log.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.undo_log.clearRetainingCapacity();
        self.clearSavepoints();
        self.in_transaction = false;
    }

    /// Commit a transaction (alias)
    pub fn commit(self: *Self) !void {
        try self.commitTransaction();
    }

    /// Persist all pending database, metadata, and WAL state.
    /// Flush is rejected while a transaction is active; commit or rollback it first.
    pub fn flush(self: *Self) !void {
        if (self.in_transaction) return error.TransactionActive;

        if (self.wal) |w| {
            try w.checkpointToPager(self.storage_engine.pager);
        }
        if (self.owns_storage and !self.is_memory) {
            try self.storage_engine.saveAllMetadata();
        }
        if (self.owns_storage) {
            try self.storage_engine.pager.flush();
        }
    }

    /// Rollback a transaction
    pub fn rollbackTransaction(self: *Self) !void {
        // Clear btree callbacks first
        self.clearTransactionCallbacks();

        // Use WAL-based physical page restoration for file-backed storage
        if (self.wal) |w| {
            // Restore original page data from WAL old_data entries
            try w.rollbackWithPager(self.storage_engine.pager);

            // Also clear any logical deletes from this transaction
            var table_iter = self.storage_engine.tables.iterator();
            while (table_iter.next()) |entry| {
                entry.value_ptr.*.deleted_keys.clearRetainingCapacity();
            }
        } else {
            // In-memory: use logical delete mechanism (undo log)
            while (self.undo_log.items.len > 0) {
                if (self.undo_log.pop()) |entry_val| {
                    var entry = entry_val;
                    self.applyUndo(&entry) catch |err| {
                        std.log.err("Failed to apply undo: {}", .{err});
                    };
                    entry.deinit(self.allocator);
                }
            }
        }

        // Clear undo log
        for (self.undo_log.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.undo_log.clearRetainingCapacity();
        self.clearSavepoints();
        self.in_transaction = false;
    }

    fn clearSavepoints(self: *Self) void {
        for (self.savepoints.items) |*savepoint| {
            savepoint.deinit(self.allocator);
        }
        self.savepoints.clearRetainingCapacity();
    }

    fn findSavepointIndex(self: *Self, name: []const u8) ?usize {
        var i = self.savepoints.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.savepoints.items[i].name, name)) return i;
        }
        return null;
    }

    pub fn hasActiveSavepoints(self: *const Self) bool {
        return self.savepoints.items.len > 0;
    }

    pub fn createSavepoint(self: *Self, name: []const u8) !void {
        const started_transaction = !self.in_transaction;
        if (started_transaction) {
            try self.beginTransaction();
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.savepoints.append(self.allocator, SavepointEntry{
            .name = owned_name,
            .undo_len = self.undo_log.items.len,
            .started_transaction = started_transaction,
        });
    }

    pub fn releaseSavepoint(self: *Self, name: []const u8) !void {
        const index = self.findSavepointIndex(name) orelse return error.SavepointNotFound;
        const commits_outer_savepoint = index == 0 and self.savepoints.items[index].started_transaction;

        for (self.savepoints.items[index..]) |*savepoint| {
            savepoint.deinit(self.allocator);
        }
        self.savepoints.shrinkRetainingCapacity(index);

        if (commits_outer_savepoint) {
            try self.commitTransaction();
        }
    }

    pub fn rollbackToSavepoint(self: *Self, name: []const u8) !void {
        const index = self.findSavepointIndex(name) orelse return error.SavepointNotFound;
        const undo_len = self.savepoints.items[index].undo_len;

        try self.rollbackUndoTo(undo_len);

        if (index + 1 < self.savepoints.items.len) {
            for (self.savepoints.items[index + 1 ..]) |*savepoint| {
                savepoint.deinit(self.allocator);
            }
            self.savepoints.shrinkRetainingCapacity(index + 1);
        }

        try self.refreshAllIndexesAndCaches();
    }

    fn rollbackUndoTo(self: *Self, target_len: usize) !void {
        while (self.undo_log.items.len > target_len) {
            if (self.undo_log.pop()) |entry_val| {
                var entry = entry_val;
                self.applyUndo(&entry) catch |err| {
                    entry.deinit(self.allocator);
                    return err;
                };
                entry.deinit(self.allocator);
            }
        }
    }

    fn refreshAllIndexesAndCaches(self: *Self) !void {
        var table_iter = self.storage_engine.tables.iterator();
        while (table_iter.next()) |entry| {
            try self.storage_engine.refreshIndexesForTable(entry.key_ptr.*);
            self.invalidateResultCache(entry.key_ptr.*);
        }
    }

    /// Apply a single undo entry (for in-memory rollback)
    fn applyUndo(self: *Self, entry: *UndoEntry) !void {
        const table = self.storage_engine.getTable(entry.table_name) orelse return error.TableNotFound;

        switch (entry.operation) {
            .Insert => {
                // Undo INSERT by deleting the row (logical delete)
                try table.delete(self.allocator, entry.row_id);
            },
            .Delete => {
                // Undo DELETE by undeleting the row (it's still in the btree)
                table.undelete(entry.row_id);
            },
            .Update => {
                // Undo UPDATE: undelete the old row and delete the new row
                table.undelete(entry.row_id);
                if (entry.new_row_id) |new_id| {
                    try table.delete(self.allocator, new_id);
                }
            },
        }
    }

    /// Log an undo entry for transaction rollback
    pub fn logUndo(self: *Self, entry: UndoEntry) !void {
        if (self.in_transaction) {
            try self.undo_log.append(self.allocator, entry);
        } else {
            // Not in a transaction, free the entry immediately
            var mutable_entry = entry;
            mutable_entry.deinit(self.allocator);
        }
    }

    /// Rollback a transaction (alias)
    pub fn rollback(self: *Self) !void {
        try self.rollbackTransaction();
    }

    /// Execute a function within a transaction with automatic rollback on error
    pub fn transaction(self: *Self, comptime context_type: type, function: *const fn (self: *Self, context: context_type) anyerror!void, context: context_type) !void {
        try self.begin();
        errdefer self.rollback() catch |err| {
            std.log.err("Failed to rollback transaction: {}", .{err});
        };

        try function(self, context);
        try self.commit();
    }

    /// Execute a function within a transaction (no context parameter)
    pub fn transactionSimple(self: *Self, function: *const fn (self: *Self) anyerror!void) !void {
        try self.begin();
        errdefer self.rollback() catch |err| {
            std.log.err("Failed to rollback transaction: {}", .{err});
        };

        try function(self);
        try self.commit();
    }

    /// Execute multiple SQL statements within a transaction
    pub fn transactionExec(self: *Self, sql_statements: []const []const u8) !void {
        try self.begin();
        errdefer self.rollback() catch |err| {
            std.log.err("Failed to rollback transaction: {}", .{err});
        };

        for (sql_statements) |sql| {
            try self.execute(sql);
        }

        try self.commit();
    }

    /// Prepare a SQL statement
    pub fn prepare(self: *Self, sql: []const u8) !*PreparedStatement {
        return PreparedStatement.prepare(self.allocator, self, sql);
    }

    // ========== BROAD API SURFACES (v1.2.2) ==========

    /// Execute SQL and return structured results (SQLite-style)
    pub fn query(self: *Self, sql: []const u8) !ResultSet {
        if (self.result_cache) |cache| {
            const sql_hash = query_cache.QueryHasher.hashQuery(sql);
            if (cache.get(sql_hash)) |cached_result| {
                return ResultSet{
                    .allocator = self.allocator,
                    .connection = self,
                    .rows = try cloneCachedRows(self.allocator, cached_result.rows),
                    .current_index = 0,
                    .column_names = try self.extractColumnNamesFromSql(sql),
                };
            }
        }

        // Parse the SQL
        var parsed = try parser.parse(self.allocator, sql);
        defer parsed.deinit();

        // Try to get cached plan first
        var plan_ptr: *planner.ExecutionPlan = undefined;
        var owns_plan = false;

        if (self.plan_cache) |*cache| {
            if (cache.get(sql)) |cached_plan| {
                plan_ptr = cached_plan;
            } else {
                // Cache miss - create new plan and cache it
                var query_planner = planner.Planner.init(self.allocator);
                const new_plan = try query_planner.plan(&parsed.statement);
                try cache.put(sql, new_plan);
                // Get pointer from cache (cache now owns the plan)
                plan_ptr = cache.get(sql).?;
            }
        } else {
            // No cache - create plan that we own
            var query_planner = planner.Planner.init(self.allocator);
            const owned_plan = try self.allocator.create(planner.ExecutionPlan);
            owned_plan.* = try query_planner.plan(&parsed.statement);
            plan_ptr = owned_plan;
            owns_plan = true;
        }
        defer if (owns_plan) {
            plan_ptr.deinit();
            self.allocator.destroy(plan_ptr);
        };

        // Execute and get results
        var virtual_machine = vm.VirtualMachine.init(self.allocator, self);
        defer virtual_machine.deinitVM();
        var result = try virtual_machine.execute(plan_ptr);
        defer result.deinit();

        // Convert to ResultSet (copy the rows so result can be cleaned up)
        var result_set = ResultSet{
            .allocator = self.allocator,
            .connection = self,
            .rows = .empty,
            .current_index = 0,
            .column_names = try self.extractColumnNames(&parsed.statement),
        };

        // Transfer ownership of rows to ResultSet
        result_set.rows = result.rows;
        // Prevent result.deinit from freeing the rows (we've transferred ownership)
        result.rows = .empty;

        if (self.result_cache != null and parsed.statement == .Select) {
            const sql_hash = query_cache.QueryHasher.hashQuery(sql);
            self.result_cache.?.put(sql_hash, sql, result_set.rows.items) catch {};
        }

        return result_set;
    }

    /// Execute SQL and return single row (or null)
    pub fn queryRow(self: *Self, sql: []const u8) !?Row {
        var result_set = try self.query(sql);
        defer result_set.deinit();

        return result_set.next();
    }

    /// Execute SQL statement and return affected row count
    pub fn exec(self: *Self, sql: []const u8) !u32 {
        // Parse the SQL
        var parsed = try parser.parse(self.allocator, sql);
        defer parsed.deinit();

        // Create execution plan
        var query_planner = planner.Planner.init(self.allocator);
        var plan = try query_planner.plan(&parsed.statement);
        defer plan.deinit();

        // Execute and get results
        var virtual_machine = vm.VirtualMachine.init(self.allocator, self);
        defer virtual_machine.deinitVM();
        var result = try virtual_machine.execute(&plan);
        defer result.deinit();

        return result.affected_rows;
    }

    /// Get table schema information
    pub fn getTableSchema(self: *Self, table_name: []const u8) !?TableSchema {
        const table = self.storage_engine.getTable(table_name) orelse return null;

        // Clone the schema for safe return
        var cloned_columns = try self.allocator.alloc(ColumnInfo, table.schema.columns.len);
        for (table.schema.columns, 0..) |column, i| {
            cloned_columns[i] = ColumnInfo{
                .name = try self.allocator.dupe(u8, column.name),
                .data_type = column.data_type,
                .is_primary_key = column.is_primary_key,
                .is_nullable = column.is_nullable,
                .has_default = column.default_value != null,
            };
        }

        return TableSchema{
            .allocator = self.allocator,
            .table_name = try self.allocator.dupe(u8, table_name),
            .columns = cloned_columns,
        };
    }

    /// List all table names in the database
    pub fn getTableNames(self: *Self) ![][]const u8 {
        return self.storage_engine.getTableNames(self.allocator);
    }

    /// Extract column names from parsed statement (helper)
    fn extractColumnNames(self: *Self, statement: *const ast.Statement) ![][]const u8 {
        switch (statement.*) {
            .Select => |select| {
                if (select.columns.len == 1 and std.mem.eql(u8, select.columns[0].name, "*")) {
                    // SELECT * - get columns from table schema
                    const table_name = select.table orelse return &.{};
                    const table = self.storage_engine.getTable(table_name);
                    if (table) |t| {
                        var column_names = try self.allocator.alloc([]const u8, t.schema.columns.len);
                        for (t.schema.columns, 0..) |column, i| {
                            column_names[i] = try self.allocator.dupe(u8, column.name);
                        }
                        return column_names;
                    }
                }

                // Explicit column list
                var column_names = try self.allocator.alloc([]const u8, select.columns.len);
                for (select.columns, 0..) |column, i| {
                    column_names[i] = try self.allocator.dupe(u8, column.name);
                }
                return column_names;
            },
            .Insert => |insert| {
                if (insert.returning) |ret| {
                    return try self.extractReturningColumnNames(insert.table, ret.columns);
                }
                return try self.allocator.alloc([]const u8, 0);
            },
            .Update => |update| {
                if (update.returning) |ret| {
                    return try self.extractReturningColumnNames(update.table, ret.columns);
                }
                return try self.allocator.alloc([]const u8, 0);
            },
            .Delete => |delete| {
                if (delete.returning) |ret| {
                    return try self.extractReturningColumnNames(delete.table, ret.columns);
                }
                return try self.allocator.alloc([]const u8, 0);
            },
            else => {
                // Non-SELECT statements have no columns
                return try self.allocator.alloc([]const u8, 0);
            },
        }
    }

    fn extractReturningColumnNames(self: *Self, table_name: []const u8, columns: [][]const u8) ![][]const u8 {
        if (columns.len == 1 and std.mem.eql(u8, columns[0], "*")) {
            const table = self.storage_engine.getTable(table_name);
            if (table) |t| {
                var all_columns = try self.allocator.alloc([]const u8, t.schema.columns.len);
                for (t.schema.columns, 0..) |column, i| {
                    all_columns[i] = try self.allocator.dupe(u8, column.name);
                }
                return all_columns;
            }
        }

        var names = try self.allocator.alloc([]const u8, columns.len);
        for (columns, 0..) |column, i| {
            names[i] = try self.allocator.dupe(u8, column);
        }
        return names;
    }

    fn extractColumnNamesFromSql(self: *Self, sql: []const u8) ![][]const u8 {
        var parsed = try parser.parse(self.allocator, sql);
        defer parsed.deinit();
        return try self.extractColumnNames(&parsed.statement);
    }

    fn cloneCachedRows(allocator: std.mem.Allocator, rows: []storage.Row) !std.ArrayListUnmanaged(storage.Row) {
        var cloned: std.ArrayListUnmanaged(storage.Row) = .empty;
        errdefer {
            for (cloned.items) |row| {
                for (row.values) |value| {
                    value.deinit(allocator);
                }
                allocator.free(row.values);
            }
            cloned.deinit(allocator);
        }

        try cloned.ensureTotalCapacity(allocator, rows.len);
        for (rows) |row| {
            var values = try allocator.alloc(storage.Value, row.values.len);
            var values_initialized: usize = 0;
            errdefer {
                for (values[0..values_initialized]) |value| {
                    value.deinit(allocator);
                }
                allocator.free(values);
            }

            for (row.values, 0..) |value, i| {
                values[i] = try value.clone(allocator);
                values_initialized = i + 1;
            }
            cloned.appendAssumeCapacity(storage.Row{ .values = values });
        }

        return cloned;
    }

    // ========== END BROAD API SURFACES ==========

    /// Close the database connection and report persistence failures.
    /// Cleanup always completes; the first durability error is returned afterward.
    pub fn closeFallible(self: *Self) !void {
        var first_error: ?anyerror = null;

        // Close all attached databases
        var attached_iter = self.attached_databases.iterator();
        while (attached_iter.next()) |entry| {
            // Free the schema name key
            self.allocator.free(entry.key_ptr.*);
            // Close the attached connection
            entry.value_ptr.*.closeFallible() catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        self.attached_databases.deinit();

        // Clean up WAL callback context if still active (transaction not committed/rolled back)
        if (self.wal_callback_ctx) |ctx| {
            // Clear btree callbacks before freeing context
            var table_iter = self.storage_engine.tables.iterator();
            while (table_iter.next()) |entry| {
                entry.value_ptr.*.btree.clearWriteCallback();
            }
            self.allocator.destroy(ctx);
            self.wal_callback_ctx = null;
        }

        // Clean up plan cache
        if (self.plan_cache) |*cache| {
            cache.deinit();
        }

        // Roll back an unfinished transaction before attempting a checkpoint.
        // This must happen before the undo log is freed because rollback consumes
        // and frees the undo entries itself; freeing them first would double-free.
        if (self.in_transaction) {
            self.rollbackTransaction() catch |err| {
                if (first_error == null) first_error = err;
            };
        }

        // Clean up any remaining undo log entries
        for (self.undo_log.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.undo_log.deinit(self.allocator);

        for (self.savepoints.items) |*savepoint| {
            savepoint.deinit(self.allocator);
        }
        self.savepoints.deinit(self.allocator);

        // Checkpoint any remaining WAL entries before closing.
        if (self.wal) |w| {
            w.checkpointToPager(self.storage_engine.pager) catch |err| {
                if (first_error == null) first_error = err;
            };
            w.deinit();
        }

        // Persist table metadata on close so non-transaction file-backed writes
        // keep the latest row counts and B-tree root pages after splits.
        if (self.owns_storage) {
            if (!self.is_memory) {
                self.storage_engine.saveAllMetadata() catch |err| {
                    if (first_error == null) first_error = err;
                };
            }
            self.storage_engine.pager.flush() catch |err| {
                if (first_error == null) first_error = err;
            };
            self.storage_engine.deinit();
        }

        if (self.path) |p| {
            self.allocator.free(p);
        }
        self.allocator.destroy(self);

        if (first_error) |err| return err;
    }

    /// Convenience cleanup for defer sites. Use closeFallible() when durability
    /// failures must be handled programmatically.
    pub fn close(self: *Self) void {
        self.closeFallible() catch |err| {
            std.log.err("database close persistence failure: {s}", .{@errorName(err)});
        };
    }

    /// Get database info
    pub fn info(self: *Self) ConnectionInfo {
        return ConnectionInfo{
            .is_memory = self.is_memory,
            .path = self.path,
            .has_wal = self.wal != null,
        };
    }

    /// Set query result cache for this connection
    pub fn setResultCache(self: *Self, cache: *query_cache.QueryCache) void {
        self.result_cache = cache;
    }

    /// Invalidate query result cache entries for a specific table
    /// Called by VM after INSERT/UPDATE/DELETE operations
    pub fn invalidateResultCache(self: *Self, table_name: []const u8) void {
        if (self.result_cache) |cache| {
            cache.invalidateTable(table_name) catch {};
        }
    }

    /// Attach an external database file with a schema name
    /// SECURITY: Path is validated against the connection's attach_path_policy
    pub fn attachDatabase(self: *Self, file_path: []const u8, schema_name: []const u8) !void {
        // Check if schema name is already in use
        if (self.attached_databases.get(schema_name) != null) {
            return error.SchemaAlreadyAttached;
        }

        // Reserved schema names
        if (std.mem.eql(u8, schema_name, "main") or std.mem.eql(u8, schema_name, "temp")) {
            return error.ReservedSchemaName;
        }

        // SECURITY: Validate and canonicalize the path against the policy
        const validated_path = try self.attach_path_policy.validatePath(self.allocator, file_path);
        defer self.allocator.free(validated_path);

        // Open connection to the external database using validated path.
        // Keep :memory: attachments on the in-memory path so ATTACH DATABASE ':memory:'
        // does not go through file-backed startup and leak/load bogus state.
        const attached_conn = if (std.mem.eql(u8, validated_path, ":memory:"))
            try Self.openMemoryWithOptions(self.allocator, .{ .attach_policy = self.attach_path_policy })
        else
            try Self.openWithOptions(self.allocator, validated_path, .{ .attach_policy = self.attach_path_policy });
        errdefer attached_conn.close();

        // Inherit the same path policy to attached databases
        attached_conn.attach_path_policy = self.attach_path_policy;

        // Store with duplicated schema name as key
        const schema_key = try self.allocator.dupe(u8, schema_name);
        errdefer self.allocator.free(schema_key);

        try self.attached_databases.put(schema_key, attached_conn);
    }

    /// Set the path policy for ATTACH operations
    /// SECURITY: Use this to restrict which paths can be attached
    pub fn setAttachPathPolicy(self: *Self, policy: AttachPathPolicy) void {
        self.attach_path_policy = policy;
    }

    /// Detach a previously attached database
    pub fn detachDatabase(self: *Self, schema_name: []const u8) !void {
        // Check if schema exists
        if (self.attached_databases.fetchRemove(schema_name)) |kv| {
            // Free the schema name key
            self.allocator.free(kv.key);
            // Close the attached connection
            try kv.value.closeFallible();
        } else {
            return error.SchemaNotFound;
        }
    }

    /// Get attached database connection by schema name
    pub fn getAttachedDatabase(self: *Self, schema_name: []const u8) ?*Self {
        return self.attached_databases.get(schema_name);
    }
};

pub const ConnectionInfo = struct {
    is_memory: bool,
    path: ?[]const u8,
    has_wal: bool,
};

// ========== BROAD API TYPES (v1.2.2) ==========

/// Result set for query iteration
pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    rows: std.ArrayListUnmanaged(storage.Row),
    current_index: usize,
    column_names: [][]const u8,

    const Self = @This();

    /// Get next row (returns null when done)
    pub fn next(self: *Self) ?Row {
        if (self.current_index >= self.rows.items.len) {
            return null;
        }

        const storage_row = &self.rows.items[self.current_index];
        self.current_index += 1;

        // Create a copy of column_names for the Row to own
        var owned_column_names = self.allocator.alloc([]const u8, self.column_names.len) catch return null;
        for (self.column_names, 0..) |name, i| {
            owned_column_names[i] = self.allocator.dupe(u8, name) catch {
                // Clean up partially allocated names on error
                for (owned_column_names[0..i]) |allocated_name| {
                    self.allocator.free(allocated_name);
                }
                self.allocator.free(owned_column_names);
                return null;
            };
        }

        // Create a copy of values for the Row to own
        var owned_values = self.allocator.alloc(storage.Value, storage_row.values.len) catch {
            // Clean up column names on allocation failure
            for (owned_column_names) |name| {
                self.allocator.free(name);
            }
            self.allocator.free(owned_column_names);
            return null;
        };

        for (storage_row.values, 0..) |value, i| {
            owned_values[i] = value.clone(self.allocator) catch {
                // Clean up partially cloned values on error
                for (owned_values[0..i]) |cloned_value| {
                    cloned_value.deinit(self.allocator);
                }
                self.allocator.free(owned_values);
                // Clean up column names
                for (owned_column_names) |name| {
                    self.allocator.free(name);
                }
                self.allocator.free(owned_column_names);
                return null;
            };
        }

        return Row{
            .allocator = self.allocator,
            .values = owned_values,
            .column_names = owned_column_names,
        };
    }

    /// Reset to beginning
    pub fn reset(self: *Self) void {
        self.current_index = 0;
    }

    /// Get total row count
    pub fn count(self: *Self) usize {
        return self.rows.items.len;
    }

    /// Get column count
    pub fn columnCount(self: *Self) usize {
        return self.column_names.len;
    }

    /// Get column name by index
    pub fn columnName(self: *Self, index: usize) ?[]const u8 {
        if (index >= self.column_names.len) return null;
        return self.column_names[index];
    }

    /// Clean up result set
    pub fn deinit(self: *Self) void {
        // Clean up column names
        for (self.column_names) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.column_names);

        // Clean up rows and their values (ownership was transferred from ExecutionResult)
        for (self.rows.items) |row| {
            for (row.values) |value| {
                value.deinit(self.allocator);
            }
            self.allocator.free(row.values);
        }
        self.rows.deinit(self.allocator);
    }
};

/// Single row with type-safe value access
pub const Row = struct {
    allocator: std.mem.Allocator,
    values: []storage.Value,
    column_names: [][]const u8,

    const Self = @This();

    /// Get value by column index
    pub fn getValue(self: *const Self, index: usize) ?storage.Value {
        if (index >= self.values.len) return null;
        return self.values[index];
    }

    /// Get value by column name
    pub fn getValueByName(self: *const Self, name: []const u8) ?storage.Value {
        for (self.column_names, 0..) |col_name, i| {
            if (std.mem.eql(u8, col_name, name)) {
                return self.getValue(i);
            }
        }
        return null;
    }

    /// Get integer value by index
    pub fn getInt(self: *const Self, index: usize) ?i64 {
        const value = self.getValue(index) orelse return null;
        return switch (value) {
            .Integer => |i| i,
            .Real => |r| @intFromFloat(r),
            else => null,
        };
    }

    /// Get integer value by column name
    pub fn getIntByName(self: *const Self, name: []const u8) ?i64 {
        const value = self.getValueByName(name) orelse return null;
        return switch (value) {
            .Integer => |i| i,
            .Real => |r| @intFromFloat(r),
            else => null,
        };
    }

    /// Get real/float value by index
    pub fn getReal(self: *const Self, index: usize) ?f64 {
        const value = self.getValue(index) orelse return null;
        return switch (value) {
            .Real => |r| r,
            .Integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Get real/float value by column name
    pub fn getRealByName(self: *const Self, name: []const u8) ?f64 {
        const value = self.getValueByName(name) orelse return null;
        return switch (value) {
            .Real => |r| r,
            .Integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Get text value by index
    pub fn getText(self: *const Self, index: usize) ?[]const u8 {
        const value = self.getValue(index) orelse return null;
        return switch (value) {
            .Text => |t| t,
            else => null,
        };
    }

    /// Get text value by column name
    pub fn getTextByName(self: *const Self, name: []const u8) ?[]const u8 {
        const value = self.getValueByName(name) orelse return null;
        return switch (value) {
            .Text => |t| t,
            else => null,
        };
    }

    /// Get blob value by index
    pub fn getBlob(self: *const Self, index: usize) ?[]const u8 {
        const value = self.getValue(index) orelse return null;
        return switch (value) {
            .Blob => |b| b,
            else => null,
        };
    }

    /// Get blob value by column name
    pub fn getBlobByName(self: *const Self, name: []const u8) ?[]const u8 {
        const value = self.getValueByName(name) orelse return null;
        return switch (value) {
            .Blob => |b| b,
            else => null,
        };
    }

    /// Check if value is null by index
    pub fn isNull(self: *const Self, index: usize) bool {
        const value = self.getValue(index) orelse return true;
        return value == .Null;
    }

    /// Check if value is null by column name
    pub fn isNullByName(self: *const Self, name: []const u8) bool {
        const value = self.getValueByName(name) orelse return true;
        return value == .Null;
    }

    /// Get column count
    pub fn columnCount(self: *const Self) usize {
        return self.values.len;
    }

    /// Clean up owned resources
    pub fn deinit(self: *Self) void {
        // Clean up column names
        for (self.column_names) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(self.column_names);

        // Clean up values
        for (self.values) |value| {
            value.deinit(self.allocator);
        }
        self.allocator.free(self.values);
    }
};

/// Table schema information
pub const TableSchema = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    columns: []ColumnInfo,

    const Self = @This();

    /// Find column by name
    pub fn getColumn(self: *const Self, name: []const u8) ?ColumnInfo {
        for (self.columns) |column| {
            if (std.mem.eql(u8, column.name, name)) {
                return column;
            }
        }
        return null;
    }

    /// Get column count
    pub fn columnCount(self: *const Self) usize {
        return self.columns.len;
    }

    /// Clean up table schema
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.table_name);
        for (self.columns) |column| {
            self.allocator.free(column.name);
        }
        self.allocator.free(self.columns);
    }
};

/// Column metadata
pub const ColumnInfo = struct {
    name: []const u8,
    data_type: storage.DataType,
    is_primary_key: bool,
    is_nullable: bool,
    has_default: bool,
};

// ========== END BROAD API TYPES ==========

/// Prepared statement for optimized execution
pub const PreparedStatement = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    sql: []const u8,
    parsed_statement: ast.Statement,
    execution_plan: planner.ExecutionPlan,
    parameter_count: u32,
    parameter_names: []?[]const u8,
    parameters: []storage.Value,

    const Self = @This();

    /// Prepare a SQL statement
    pub fn prepare(allocator: std.mem.Allocator, connection: *Connection, sql: []const u8) !*Self {
        var stmt = try allocator.create(Self);
        stmt.allocator = allocator;
        stmt.connection = connection;
        stmt.sql = try allocator.dupe(u8, sql);

        // Parse the SQL
        var parsed_result = try parser.parse(allocator, sql);
        stmt.parsed_statement = parsed_result.statement;
        parsed_result.parser.deinit(); // Clean up parser resources

        // Create execution plan
        var query_planner = planner.Planner.init(allocator);
        stmt.execution_plan = try query_planner.plan(&stmt.parsed_statement);

        stmt.parameter_names = try collectParameterNames(allocator, sql);
        stmt.parameter_count = @intCast(stmt.parameter_names.len);
        stmt.parameters = try allocator.alloc(storage.Value, stmt.parameter_count);

        // Initialize parameters to NULL
        for (stmt.parameters) |*param| {
            param.* = storage.Value.Null;
        }

        return stmt;
    }

    /// Bind a parameter value
    pub fn bindParameter(self: *Self, index: u32, value: storage.Value) !void {
        if (index >= self.parameter_count) {
            return error.InvalidParameterIndex;
        }

        // Clean up old value
        self.parameters[index].deinit(self.allocator);

        // Clone the new value
        self.parameters[index] = try cloneValue(self.allocator, value);
    }

    /// Simplified parameter binding with auto-type detection
    pub fn bind(self: *Self, index: u32, value: anytype) !void {
        try self.bindParameter(index, storageValueFromAny(value));
    }

    /// Bind NULL value
    pub fn bindNull(self: *Self, index: u32) !void {
        try self.bindParameter(index, storage.Value.Null);
    }

    pub fn bindNamed(self: *Self, name: []const u8, value: anytype) !void {
        try self.bindNamedParameter(name, storageValueFromAny(value));
    }

    pub fn bindNamedParameter(self: *Self, name: []const u8, value: storage.Value) !void {
        var matched = false;
        for (self.parameter_names, 0..) |maybe_param_name, i| {
            const param_name = maybe_param_name orelse continue;
            if (parameterNamesMatch(param_name, name)) {
                try self.bindParameter(@intCast(i), value);
                matched = true;
            }
        }
        if (!matched) return error.NamedParameterNotFound;
    }

    /// Execute the prepared statement
    pub fn execute(self: *Self) !vm.ExecutionResult {
        var virtual_machine = vm.VirtualMachine.init(self.connection.allocator, self.connection);
        defer virtual_machine.deinitVM();
        return virtual_machine.executeWithParameters(&self.execution_plan, self.parameters);
    }

    /// Execute the prepared statement with explicit connection (for backwards compatibility)
    pub fn executeWithConnection(self: *Self, connection: *Connection) !vm.ExecutionResult {
        var virtual_machine = vm.VirtualMachine.init(connection.allocator, connection);
        defer virtual_machine.deinitVM();
        return virtual_machine.executeWithParameters(&self.execution_plan, self.parameters);
    }

    /// Reset parameters
    pub fn reset(self: *Self) void {
        for (self.parameters) |*param| {
            param.deinit(self.allocator);
            param.* = storage.Value.Null;
        }
    }

    /// Clean up prepared statement
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sql);
        self.parsed_statement.deinit(self.allocator);
        self.execution_plan.deinit();

        for (self.parameters) |param| {
            param.deinit(self.allocator);
        }
        self.allocator.free(self.parameters);

        for (self.parameter_names) |maybe_name| {
            if (maybe_name) |name| self.allocator.free(name);
        }
        self.allocator.free(self.parameter_names);

        self.allocator.destroy(self);
    }

    fn storageValueFromAny(value: anytype) storage.Value {
        const value_type = @TypeOf(value);
        return switch (value_type) {
            i8, i16, i32, i64, u8, u16, u32 => storage.Value{ .Integer = @intCast(value) },
            comptime_int => storage.Value{ .Integer = value },
            f32, f64 => storage.Value{ .Real = @floatCast(value) },
            comptime_float => storage.Value{ .Real = value },
            []const u8 => storage.Value{ .Text = value },
            *const [5:0]u8, *const [4:0]u8, *const [3:0]u8, *const [6:0]u8, *const [7:0]u8, *const [8:0]u8, *const [9:0]u8, *const [10:0]u8, *const [11:0]u8, *const [12:0]u8, *const [13:0]u8, *const [14:0]u8, *const [15:0]u8, *const [16:0]u8, *const [17:0]u8, *const [18:0]u8, *const [19:0]u8, *const [20:0]u8 => storage.Value{ .Text = value },
            else => @compileError("Unsupported type for bind: " ++ @typeName(value_type) ++ " - use bindParameter() instead"),
        };
    }

    fn collectParameterNames(allocator: std.mem.Allocator, sql: []const u8) ![]?[]const u8 {
        var names: std.ArrayListUnmanaged(?[]const u8) = .empty;
        errdefer {
            for (names.items) |maybe_name| {
                if (maybe_name) |name| allocator.free(name);
            }
            names.deinit(allocator);
        }

        var tkn = tokenizer.Tokenizer.init(sql);
        while (true) {
            const token = try tkn.nextToken(allocator);
            defer token.deinit(allocator);

            switch (token) {
                .QuestionMark => try names.append(allocator, null),
                .NamedParameter => |name| try names.append(allocator, try allocator.dupe(u8, name)),
                .EOF => break,
                else => {},
            }
        }

        return names.toOwnedSlice(allocator);
    }

    fn parameterNamesMatch(stored: []const u8, requested: []const u8) bool {
        if (std.mem.eql(u8, stored, requested)) return true;
        const stored_bare = if (stored.len > 0 and (stored[0] == ':' or stored[0] == '@' or stored[0] == '$')) stored[1..] else stored;
        const requested_bare = if (requested.len > 0 and (requested[0] == ':' or requested[0] == '@' or requested[0] == '$')) requested[1..] else requested;
        return std.mem.eql(u8, stored_bare, requested_bare);
    }

    /// Clone a storage function call
    fn cloneStorageFunctionCall(allocator: std.mem.Allocator, function_call: storage.Column.FunctionCall) std.mem.Allocator.Error!storage.Column.FunctionCall {
        var cloned_args = try allocator.alloc(storage.Column.FunctionArgument, function_call.arguments.len);
        for (function_call.arguments, 0..) |arg, i| {
            cloned_args[i] = try cloneStorageFunctionArgument(allocator, arg);
        }

        return storage.Column.FunctionCall{
            .name = try allocator.dupe(u8, function_call.name),
            .arguments = cloned_args,
        };
    }

    /// Clone a storage function argument
    fn cloneStorageFunctionArgument(allocator: std.mem.Allocator, arg: storage.Column.FunctionArgument) std.mem.Allocator.Error!storage.Column.FunctionArgument {
        return switch (arg) {
            .Literal => |literal| {
                const cloned_literal = try cloneValue(allocator, literal);
                return storage.Column.FunctionArgument{ .Literal = cloned_literal };
            },
            .Column => |column| {
                return storage.Column.FunctionArgument{ .Column = try allocator.dupe(u8, column) };
            },
            .Parameter => |param_index| {
                return storage.Column.FunctionArgument{ .Parameter = param_index };
            },
        };
    }

    /// Clone a storage value
    fn cloneValue(allocator: std.mem.Allocator, value: storage.Value) std.mem.Allocator.Error!storage.Value {
        return switch (value) {
            .Integer => |i| storage.Value{ .Integer = i },
            .Real => |r| storage.Value{ .Real = r },
            .Text => |t| storage.Value{ .Text = try allocator.dupe(u8, t) },
            .Blob => |b| storage.Value{ .Blob = try allocator.dupe(u8, b) },
            .Null => storage.Value.Null,
            .Parameter => |param_index| storage.Value{ .Parameter = param_index },
            .FunctionCall => |func| storage.Value{ .FunctionCall = try cloneStorageFunctionCall(allocator, func) },
            .JSON => |j| storage.Value{ .JSON = try allocator.dupe(u8, j) },
            .JSONB => |jsonb| storage.Value{ .JSONB = storage.JSONBValue.init(allocator, try jsonb.toString(allocator)) catch return storage.Value.Null },
            .UUID => |uuid| storage.Value{ .UUID = uuid },
            .Array => |array| storage.Value{ .Array = storage.ArrayValue{
                .element_type = array.element_type,
                .elements = blk: {
                    var cloned_elements = try allocator.alloc(storage.Value, array.elements.len);
                    for (array.elements, 0..) |elem, k| {
                        cloned_elements[k] = try cloneValue(allocator, elem);
                    }
                    break :blk cloned_elements;
                },
            } },
            .Boolean => |b| storage.Value{ .Boolean = b },
            .Timestamp => |ts| storage.Value{ .Timestamp = ts },
            .TimestampTZ => |tstz| storage.Value{ .TimestampTZ = storage.TimestampTZValue{
                .timestamp = tstz.timestamp,
                .timezone = try allocator.dupe(u8, tstz.timezone),
            } },
            .Date => |d| storage.Value{ .Date = d },
            .Time => |t| storage.Value{ .Time = t },
            .Interval => |interval| storage.Value{ .Interval = interval },
            .Numeric => |n| storage.Value{ .Numeric = storage.NumericValue{
                .precision = n.precision,
                .scale = n.scale,
                .digits = try allocator.dupe(u8, n.digits),
                .is_negative = n.is_negative,
            } },
            .SmallInt => |si| storage.Value{ .SmallInt = si },
            .BigInt => |bi| storage.Value{ .BigInt = bi },
        };
    }
};

test "connection creation" {
    // Test will be implemented when storage engine is ready
    try std.testing.expect(true);
}

test "memory connection" {
    // Test will be implemented when storage engine is ready
    try std.testing.expect(true);
}

test "UPDATE SET resolves positional prepared parameters" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, n INTEGER)");
    try conn.execute("INSERT INTO t (id, name, n) VALUES (1, 'orig', 10)");

    var stmt = try conn.prepare("UPDATE t SET name = ?, n = ? WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindParameter(0, storage.Value{ .Text = "updated" });
    try stmt.bindParameter(1, storage.Value{ .Integer = 42 });
    try stmt.bindParameter(2, storage.Value{ .Integer = 1 });
    var update_result = try stmt.execute();
    defer update_result.deinit();

    var rows = try conn.query("SELECT name, n FROM t WHERE id = 1");
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRowReturned;
    try std.testing.expectEqualStrings("updated", row.getText(0) orelse return error.NullName);
    try std.testing.expectEqual(@as(i64, 42), row.getInt(1) orelse return error.NullN);
}

test "UPDATE SET resolves named prepared parameters" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, n INTEGER)");
    try conn.execute("INSERT INTO t (id, name, n) VALUES (1, 'orig', 10)");

    var stmt = try conn.prepare("UPDATE t SET name = :name, n = @n WHERE id = $id");
    defer stmt.deinit();
    try stmt.bindNamed(":name", "named");
    try stmt.bindNamed("n", @as(i64, 77));
    try stmt.bindNamed("$id", @as(i64, 1));
    var update_result = try stmt.execute();
    defer update_result.deinit();

    var rows = try conn.query("SELECT name, n FROM t WHERE id = 1");
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRowReturned;
    try std.testing.expectEqualStrings("named", row.getText(0) orelse return error.NullName);
    try std.testing.expectEqual(@as(i64, 77), row.getInt(1) orelse return error.NullN);
}

test "SQL escaped single quote literals execute correctly" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, msg TEXT)");
    try conn.execute("INSERT INTO t (id, msg) VALUES (1, 'it''s a test')");

    var rows = try conn.query("SELECT msg FROM t WHERE msg = 'it''s a test'");
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRowReturned;
    try std.testing.expectEqualStrings("it's a test", row.getText(0) orelse return error.NullMsg);
}
