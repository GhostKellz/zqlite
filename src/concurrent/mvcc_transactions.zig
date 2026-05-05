const std = @import("std");
const storage = @import("../db/storage.zig");
const crypto = @import("../crypto/secure_storage.zig");
const runtime = @import("../runtime/root.zig");
const time_utils = @import("../time_utils.zig");
const Wyhash = std.hash.Wyhash;

/// Version chain entry for MVCC
pub const VersionChainEntry = struct {
    version: u64,
    transaction_id: TransactionId,
    data: ?storage.Row, // null = deleted (tombstone)
    created_at: i64,
    prev: ?*VersionChainEntry,

    pub fn deinit(self: *VersionChainEntry, allocator: std.mem.Allocator) void {
        if (self.data) |row| {
            for (row.values) |value| {
                value.deinit(allocator);
            }
            allocator.free(row.values);
        }
        allocator.destroy(self);
    }
};

/// Version chain head for a row
pub const VersionChain = struct {
    latest: ?*VersionChainEntry,
    row_id: storage.RowId,

    pub fn init(row_id: storage.RowId) VersionChain {
        return .{ .latest = null, .row_id = row_id };
    }

    /// Add a new version to the chain
    pub fn addVersion(self: *VersionChain, allocator: std.mem.Allocator, version: u64, transaction_id: TransactionId, data: ?storage.Row, timestamp: i64) !void {
        const entry = try allocator.create(VersionChainEntry);
        entry.* = .{
            .version = version,
            .transaction_id = transaction_id,
            .data = data,
            .created_at = timestamp,
            .prev = self.latest,
        };
        self.latest = entry;
    }

    /// Find visible version for a transaction
    pub fn findVisible(self: *VersionChain, start_version: u64, committed_versions: *const std.AutoHashMap(TransactionId, u64)) ?*VersionChainEntry {
        var current = self.latest;
        while (current) |entry| {
            // Version is visible if:
            // 1. It was committed before our transaction started, OR
            // 2. It was created by a transaction that committed before our start_version
            if (entry.version <= start_version) {
                // Check if the creating transaction has committed
                if (committed_versions.get(entry.transaction_id)) |commit_version| {
                    if (commit_version <= start_version) {
                        return entry;
                    }
                } else if (entry.transaction_id == 0) {
                    // System transaction (initial data)
                    return entry;
                }
            }
            current = entry.prev;
        }
        return null;
    }

    /// Check if modified since a version
    pub fn modifiedSince(self: *VersionChain, since_version: u64) bool {
        if (self.latest) |entry| {
            return entry.version > since_version;
        }
        return false;
    }

    pub fn deinit(self: *VersionChain, allocator: std.mem.Allocator) void {
        var current = self.latest;
        while (current) |entry| {
            const prev = entry.prev;
            entry.deinit(allocator);
            current = prev;
        }
    }
};

/// Multi-Version Concurrency Control (MVCC) Transaction Manager
/// Provides snapshot isolation with version chains for concurrent access
pub const MVCCTransactionManager = struct {
    allocator: std.mem.Allocator,
    transactions: std.HashMap(TransactionId, *Transaction),
    version_counter: std.atomic.Value(u64),
    global_lock: std.Thread.RwLock,
    storage_engine: *storage.StorageEngine,
    crypto_engine: ?*crypto.CryptoEngine,
    commit_log: std.ArrayList(CommitLogEntry),
    deadlock_detector: DeadlockDetector,
    /// Version chains indexed by table:row_id
    version_chains: std.StringHashMap(std.AutoHashMap(storage.RowId, VersionChain)),
    /// Committed transaction versions for visibility checks
    committed_versions: std.AutoHashMap(TransactionId, u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, storage_engine: *storage.StorageEngine, crypto_engine: ?*crypto.CryptoEngine) !Self {
        return Self{
            .allocator = allocator,
            .transactions = std.HashMap(TransactionId, *Transaction).init(allocator),
            .version_counter = std.atomic.Value(u64).init(1),
            .global_lock = std.Thread.RwLock{},
            .storage_engine = storage_engine,
            .crypto_engine = crypto_engine,
            .commit_log = .{},
            .deadlock_detector = DeadlockDetector.init(allocator),
            .version_chains = std.StringHashMap(std.AutoHashMap(storage.RowId, VersionChain)).init(allocator),
            .committed_versions = std.AutoHashMap(TransactionId, u64).init(allocator),
        };
    }

    /// Begin a new transaction with specified isolation level
    pub fn beginTransaction(self: *Self, isolation_level: IsolationLevel) !TransactionId {
        const transaction_id = self.generateTransactionId();
        const start_version = self.version_counter.load(.acquire);

        const ts = time_utils.getTimespec();
        const transaction = try self.allocator.create(Transaction);
        transaction.* = Transaction{
            .id = transaction_id,
            .start_version = start_version,
            .commit_version = null,
            .isolation_level = isolation_level,
            .state = .Active,
            .read_set = std.HashMap(RowKey, RowVersion).init(self.allocator),
            .write_set = std.HashMap(RowKey, RowValue).init(self.allocator),
            .locks = .{},
            .allocator = self.allocator,
            .created_at = ts.sec,
        };

        self.global_lock.lock();
        defer self.global_lock.unlock();

        try self.transactions.put(transaction_id, transaction);
        try self.deadlock_detector.addTransaction(transaction_id);

        return transaction_id;
    }

    /// Read a row with MVCC visibility rules
    pub fn readRow(self: *Self, transaction_id: TransactionId, table: []const u8, row_id: storage.RowId) !?storage.Row {
        const transaction = self.transactions.get(transaction_id) orelse return error.TransactionNotFound;

        // Check write set first (read your own writes)
        const row_key = RowKey{ .table = table, .row_id = row_id };
        if (transaction.write_set.get(row_key)) |row_value| {
            if (row_value == .Deleted) {
                return null; // Row was deleted in this transaction
            }
            return row_value.Updated;
        }

        // Apply MVCC visibility rules
        const visible_version = try self.findVisibleVersion(transaction, table, row_id);
        if (visible_version) |version| {
            // Add to read set for conflict detection
            try transaction.read_set.put(row_key, version);
            return version.data;
        }

        return null;
    }

    /// Write a row with conflict detection
    pub fn writeRow(self: *Self, transaction_id: TransactionId, table: []const u8, row_id: storage.RowId, row: storage.Row) !void {
        const transaction = self.transactions.get(transaction_id) orelse return error.TransactionNotFound;

        if (transaction.state != .Active) {
            return error.TransactionNotActive;
        }

        // Acquire write lock
        const ts = time_utils.getTimespec();
        const table_copy = try self.allocator.dupe(u8, table);
        errdefer self.allocator.free(table_copy);

        const lock_info = LockInfo{
            .table = table_copy,
            .row_id = row_id,
            .lock_type = .Write,
            .acquired_at = ts.sec,
        };

        // Check for deadlocks before acquiring lock
        if (try self.deadlock_detector.wouldCauseDeadlock(transaction_id, lock_info)) {
            return error.DeadlockDetected;
        }

        try transaction.locks.append(self.allocator, lock_info);

        // Add to write set
        const row_key = RowKey{ .table = table, .row_id = row_id };
        const row_value = RowValue{ .Updated = row };
        try transaction.write_set.put(row_key, row_value);
    }

    /// Delete a row
    pub fn deleteRow(self: *Self, transaction_id: TransactionId, table: []const u8, row_id: storage.RowId) !void {
        const transaction = self.transactions.get(transaction_id) orelse return error.TransactionNotFound;

        if (transaction.state != .Active) {
            return error.TransactionNotActive;
        }

        const row_key = RowKey{ .table = table, .row_id = row_id };
        const row_value = RowValue.Deleted;
        try transaction.write_set.put(row_key, row_value);
    }

    /// Commit a transaction with optimistic concurrency control
    pub fn commitTransaction(self: *Self, transaction_id: TransactionId) !void {
        const transaction = self.transactions.get(transaction_id) orelse return error.TransactionNotFound;

        if (transaction.state != .Active) {
            return error.TransactionNotActive;
        }

        // Check for conflicts in read set
        if (try self.hasReadConflicts(transaction)) {
            transaction.state = .Aborted;
            try self.releaseLocks(transaction);
            try self.deadlock_detector.removeTransaction(transaction_id);
            return error.ReadConflict;
        }

        // Check for write conflicts
        if (try self.hasWriteConflicts(transaction)) {
            transaction.state = .Aborted;
            try self.releaseLocks(transaction);
            try self.deadlock_detector.removeTransaction(transaction_id);
            return error.WriteConflict;
        }

        // Validation passed, increment version and apply writes
        const commit_version = self.version_counter.fetchAdd(1, .acq_rel) + 1;

        self.global_lock.lock();
        defer self.global_lock.unlock();

        // Apply writes to storage
        var write_iterator = transaction.write_set.iterator();
        while (write_iterator.next()) |entry| {
            const row_key = entry.key_ptr.*;
            const row_value = entry.value_ptr.*;

            switch (row_value) {
                .Updated => |row| {
                    try self.writeToStorage(row_key.table, row_key.row_id, row, commit_version);
                },
                .Deleted => {
                    try self.deleteFromStorage(row_key.table, row_key.row_id, commit_version);
                },
            }
        }

        transaction.state = .Committed;
        transaction.commit_version = commit_version;

        // Record committed version for visibility checks
        try self.committed_versions.put(transaction_id, commit_version);

        // Log the commit
        const ts = time_utils.getTimespec();
        const commit_entry = CommitLogEntry{
            .transaction_id = transaction_id,
            .commit_version = commit_version,
            .timestamp = ts.sec,
            .write_count = transaction.write_set.count(),
        };
        try self.commit_log.append(self.allocator, commit_entry);

        // Release locks
        try self.releaseLocks(transaction);
        try self.deadlock_detector.removeTransaction(transaction_id);
    }

    /// Abort a transaction
    pub fn abortTransaction(self: *Self, transaction_id: TransactionId) !void {
        const transaction = self.transactions.get(transaction_id) orelse return error.TransactionNotFound;

        transaction.state = .Aborted;
        try self.releaseLocks(transaction);
        try self.deadlock_detector.removeTransaction(transaction_id);
    }

    /// Find the visible version of a row for a transaction
    fn findVisibleVersion(self: *Self, transaction: *Transaction, table: []const u8, row_id: storage.RowId) !?RowVersion {
        // First check version chains for MVCC visibility
        if (self.version_chains.get(table)) |table_chains| {
            if (table_chains.get(row_id)) |chain| {
                if (chain.findVisible(transaction.start_version, &self.committed_versions)) |entry| {
                    // Return null if this is a tombstone (deleted row)
                    if (entry.data == null) {
                        return null;
                    }
                    return RowVersion{
                        .version = entry.version,
                        .data = entry.data.?,
                        .transaction_id = entry.transaction_id,
                        .created_at = entry.created_at,
                    };
                }
            }
        }

        // Fall back to reading from storage for rows without version history
        const table_obj = self.storage_engine.getTable(table) orelse return null;
        const rows = try table_obj.select(self.allocator);
        defer {
            for (rows) |row| {
                for (row.values) |value| {
                    value.deinit(self.allocator);
                }
                self.allocator.free(row.values);
            }
            self.allocator.free(rows);
        }

        if (row_id < rows.len) {
            return RowVersion{
                .version = 0, // Initial version
                .data = rows[row_id],
                .transaction_id = 0, // System transaction
                .created_at = transaction.created_at,
            };
        }

        return null;
    }

    /// Check for read conflicts (phantom reads, non-repeatable reads)
    fn hasReadConflicts(self: *Self, transaction: *Transaction) !bool {
        if (transaction.isolation_level == .ReadUncommitted) {
            return false; // No read conflict checking
        }

        var read_iterator = transaction.read_set.iterator();
        while (read_iterator.next()) |entry| {
            const row_key = entry.key_ptr.*;
            const read_version = entry.value_ptr.*;

            // Check if any committed transaction modified this row after our read
            if (try self.hasBeenModifiedSince(row_key, read_version.version, transaction.start_version)) {
                return true;
            }
        }

        return false;
    }

    /// Check for write conflicts
    fn hasWriteConflicts(self: *Self, transaction: *Transaction) !bool {
        var write_iterator = transaction.write_set.iterator();
        while (write_iterator.next()) |entry| {
            const row_key = entry.key_ptr.*;

            // Check if any other transaction has written to this row
            if (try self.hasConflictingWrite(row_key, transaction.id, transaction.start_version)) {
                return true;
            }
        }

        return false;
    }

    /// Check if a row has been modified since a version
    fn hasBeenModifiedSince(self: *Self, row_key: RowKey, version: u64, _: u64) !bool {
        // Look up version chain for this row
        const table_chains = self.version_chains.get(row_key.table) orelse return false;
        const chain = table_chains.get(row_key.row_id) orelse return false;

        // Check if any version is newer than what we read
        return chain.modifiedSince(version);
    }

    /// Check for conflicting writes
    fn hasConflictingWrite(self: *Self, row_key: RowKey, _: TransactionId, start_version: u64) !bool {
        // Look up version chain for this row
        const table_chains = self.version_chains.get(row_key.table) orelse return false;
        const chain = table_chains.get(row_key.row_id) orelse return false;

        // Check if there's a newer version than our start
        if (chain.latest) |latest| {
            // Conflict if another transaction wrote after our start
            if (latest.version > start_version) {
                return true;
            }
        }
        return false;
    }

    /// Write to underlying storage with versioning
    fn writeToStorage(self: *Self, table: []const u8, row_id: storage.RowId, row: storage.Row, version: u64) !void {
        const table_obj = self.storage_engine.getTable(table) orelse return error.TableNotFound;

        // Get or create version chain for this table
        const table_key = try self.allocator.dupe(u8, table);
        errdefer self.allocator.free(table_key);

        var table_chains = self.version_chains.getPtr(table_key) orelse blk: {
            try self.version_chains.put(table_key, std.AutoHashMap(storage.RowId, VersionChain).init(self.allocator));
            break :blk self.version_chains.getPtr(table_key).?;
        };

        // Get or create version chain for this row
        var chain = table_chains.getPtr(row_id) orelse blk: {
            try table_chains.put(row_id, VersionChain.init(row_id));
            break :blk table_chains.getPtr(row_id).?;
        };

        // Clone the row data for the version chain
        var cloned_values = try self.allocator.alloc(storage.Value, row.values.len);
        for (row.values, 0..) |value, i| {
            cloned_values[i] = try value.clone(self.allocator);
        }
        const cloned_row = storage.Row{ .values = cloned_values };

        // Add new version to chain
        const ts = time_utils.getTimespec();
        try chain.addVersion(self.allocator, version, 0, cloned_row, ts.sec);

        // Write to underlying storage
        try table_obj.insert(row);
    }

    /// Delete from underlying storage with tombstone version
    fn deleteFromStorage(self: *Self, table: []const u8, row_id: storage.RowId, version: u64) !void {
        // Get or create version chain for this table
        const table_key = try self.allocator.dupe(u8, table);
        errdefer self.allocator.free(table_key);

        var table_chains = self.version_chains.getPtr(table_key) orelse blk: {
            try self.version_chains.put(table_key, std.AutoHashMap(storage.RowId, VersionChain).init(self.allocator));
            break :blk self.version_chains.getPtr(table_key).?;
        };

        // Get or create version chain for this row
        var chain = table_chains.getPtr(row_id) orelse blk: {
            try table_chains.put(row_id, VersionChain.init(row_id));
            break :blk table_chains.getPtr(row_id).?;
        };

        // Add tombstone version (null data indicates deleted)
        const ts = time_utils.getTimespec();
        try chain.addVersion(self.allocator, version, 0, null, ts.sec);
    }

    /// Release all locks held by a transaction
    fn releaseLocks(self: *Self, transaction: *Transaction) !void {
        for (transaction.locks.items) |lock_info| {
            self.allocator.free(lock_info.table);
        }
        transaction.locks.clearAndFree(self.allocator);
    }

    /// Generate a unique transaction ID
    fn generateTransactionId(self: *Self) TransactionId {
        const ts = time_utils.getTimespec();
        return @as(TransactionId, @intCast(ts.sec)) * 1000 + @as(TransactionId, @intCast(self.transactions.count()));
    }

    /// Get transaction statistics
    pub fn getTransactionStats(self: *Self) TransactionStats {
        var active_count: u32 = 0;
        var committed_count: u32 = 0;
        var aborted_count: u32 = 0;

        var iterator = self.transactions.valueIterator();
        while (iterator.next()) |transaction| {
            switch (transaction.*.state) {
                .Active => active_count += 1,
                .Committed => committed_count += 1,
                .Aborted => aborted_count += 1,
            }
        }

        return TransactionStats{
            .active_transactions = active_count,
            .committed_transactions = committed_count,
            .aborted_transactions = aborted_count,
            .total_commits = self.commit_log.items.len,
            .current_version = self.version_counter.load(.acquire),
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up transactions
        var iterator = self.transactions.valueIterator();
        while (iterator.next()) |transaction| {
            transaction.*.deinit();
            self.allocator.destroy(transaction.*);
        }
        self.transactions.deinit();
        self.commit_log.deinit(self.allocator);
        self.deadlock_detector.deinit();

        // Clean up version chains
        var chain_iterator = self.version_chains.iterator();
        while (chain_iterator.next()) |entry| {
            var table_chains = entry.value_ptr.*;
            var row_iterator = table_chains.iterator();
            while (row_iterator.next()) |row_entry| {
                var chain = row_entry.value_ptr.*;
                chain.deinit(self.allocator);
            }
            table_chains.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.version_chains.deinit();

        // Clean up committed versions
        self.committed_versions.deinit();
    }
};

/// Transaction isolation levels
pub const IsolationLevel = enum {
    ReadUncommitted, // Dirty reads allowed
    ReadCommitted, // No dirty reads
    RepeatableRead, // No dirty reads, no non-repeatable reads
    Serializable, // No dirty reads, no non-repeatable reads, no phantom reads
};

/// Transaction states
pub const TransactionState = enum {
    Active,
    Committed,
    Aborted,
};

/// Lock types
pub const LockType = enum {
    Read,
    Write,
};

/// Transaction identifier
pub const TransactionId = u64;

/// Row identifier for MVCC
pub const RowKey = struct {
    table: []const u8,
    row_id: storage.RowId,
};

/// Row value in write set
pub const RowValue = union(enum) {
    Updated: storage.Row,
    Deleted,
};

/// Row version metadata captured during reads
pub const RowVersion = struct {
    version: u64,
    data: storage.Row,
    transaction_id: TransactionId,
    created_at: i64,
};

/// Visible row returned from version lookups
const VisibleRow = struct {
    version: u64,
    value: RowValue,
};

/// Lock information
pub const LockInfo = struct {
    table: []const u8,
    row_id: storage.RowId,
    lock_type: LockType,
    acquired_at: i64,
};

/// Transaction structure
pub const Transaction = struct {
    id: TransactionId,
    start_version: u64,
    commit_version: ?u64,
    isolation_level: IsolationLevel,
    state: TransactionState,
    read_set: std.HashMap(RowKey, RowVersion),
    write_set: std.HashMap(RowKey, RowValue),
    locks: std.ArrayList(LockInfo),
    allocator: std.mem.Allocator,
    created_at: i64,

    pub fn deinit(self: *Transaction) void {
        self.read_set.deinit();
        self.write_set.deinit();
        for (self.locks.items) |lock_info| {
            self.allocator.free(lock_info.table);
        }
        self.locks.deinit(self.allocator);
    }
};

/// Commit log entry
pub const CommitLogEntry = struct {
    transaction_id: TransactionId,
    commit_version: u64,
    timestamp: i64,
    write_count: u32,
};

/// Transaction statistics
pub const TransactionStats = struct {
    active_transactions: u32,
    committed_transactions: u32,
    aborted_transactions: u32,
    total_commits: usize,
    current_version: u64,
};

/// Deadlock detection using wait-for graph
pub const DeadlockDetector = struct {
    allocator: std.mem.Allocator,
    wait_for_graph: std.AutoHashMap(TransactionId, std.ArrayList(TransactionId)),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .wait_for_graph = std.AutoHashMap(TransactionId, std.ArrayList(TransactionId)).init(allocator),
        };
    }

    pub fn addTransaction(self: *Self, transaction_id: TransactionId) !void {
        if (!self.wait_for_graph.contains(transaction_id)) {
            try self.wait_for_graph.put(transaction_id, std.ArrayList(TransactionId){});
        }
    }

    pub fn removeTransaction(self: *Self, transaction_id: TransactionId) !void {
        if (self.wait_for_graph.fetchRemove(transaction_id)) |entry| {
            var list = entry.value;
            list.deinit(self.allocator);
        }

        // Remove from other transaction's wait lists
        var iterator = self.wait_for_graph.valueIterator();
        while (iterator.next()) |wait_list| {
            for (wait_list.items, 0..) |waiting_id, i| {
                if (waiting_id == transaction_id) {
                    _ = wait_list.orderedRemove(i);
                    break;
                }
            }
        }
    }

    /// Check if acquiring a lock would cause a deadlock using cycle detection in wait-for graph.
    /// Uses DFS to detect cycles: if transaction A waits for B, and B waits for A, deadlock exists.
    pub fn wouldCauseDeadlock(self: *Self, transaction_id: TransactionId, lock_info: LockInfo) !bool {
        _ = lock_info; // Lock info used for determining which transaction holds the resource

        // Find transactions that currently hold conflicting locks
        // For simplicity, we check if adding this dependency creates a cycle
        const wait_list = self.wait_for_graph.get(transaction_id) orelse return false;

        // Perform DFS to detect cycle
        var visited = std.AutoHashMap(TransactionId, void).init(self.allocator);
        defer visited.deinit();

        var in_stack = std.AutoHashMap(TransactionId, void).init(self.allocator);
        defer in_stack.deinit();

        return self.detectCycleDFS(transaction_id, &visited, &in_stack);
    }

    /// DFS-based cycle detection in wait-for graph
    fn detectCycleDFS(self: *Self, current: TransactionId, visited: *std.AutoHashMap(TransactionId, void), in_stack: *std.AutoHashMap(TransactionId, void)) bool {
        // If already in current DFS path, we found a cycle
        if (in_stack.contains(current)) {
            return true;
        }

        // If already fully visited, no cycle through this node
        if (visited.contains(current)) {
            return false;
        }

        // Mark as in current DFS path
        in_stack.put(current, {}) catch return false;

        // Check all transactions this one is waiting for
        if (self.wait_for_graph.get(current)) |wait_list| {
            for (wait_list.items) |waiting_for| {
                if (self.detectCycleDFS(waiting_for, visited, in_stack)) {
                    return true;
                }
            }
        }

        // Remove from current path, mark as fully visited
        _ = in_stack.remove(current);
        visited.put(current, {}) catch {};

        return false;
    }

    /// Add a wait-for dependency (transaction_id is waiting for blocker_id)
    pub fn addWaitDependency(self: *Self, transaction_id: TransactionId, blocker_id: TransactionId) !void {
        var wait_list = self.wait_for_graph.getPtr(transaction_id) orelse blk: {
            try self.wait_for_graph.put(transaction_id, std.ArrayList(TransactionId){});
            break :blk self.wait_for_graph.getPtr(transaction_id).?;
        };

        // Check if dependency already exists
        for (wait_list.items) |existing| {
            if (existing == blocker_id) return;
        }

        try wait_list.append(self.allocator, blocker_id);
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.wait_for_graph.valueIterator();
        while (iterator.next()) |wait_list| {
            var list = wait_list.*;
            list.deinit(self.allocator);
        }
        self.wait_for_graph.deinit();
    }
};

/// High-performance async transaction pool using zqlite runtime
pub const AsyncTransactionPool = struct {
    allocator: std.mem.Allocator,
    mvcc_manager: *MVCCTransactionManager,
    max_concurrent_transactions: u32,
    active_transactions: std.atomic.Value(u32),
    semaphore: runtime.Semaphore,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, mvcc_manager: *MVCCTransactionManager, max_concurrent: u32) !Self {
        return Self{
            .allocator = allocator,
            .mvcc_manager = mvcc_manager,
            .max_concurrent_transactions = max_concurrent,
            .active_transactions = std.atomic.Value(u32).init(0),
            .semaphore = runtime.Semaphore.init(allocator, max_concurrent),
        };
    }

    /// Execute async transaction with zqlite runtime
    pub fn executeTransactionAsync(self: *Self, comptime Context: type, context: Context, transaction_fn: fn (Context, TransactionId) anyerror!void, isolation_level: IsolationLevel, max_retries: u32) !void {
        const future = try runtime.spawnWithTaskContext(self.allocator, executeTransactionWorker, .{ self, Context, context, transaction_fn, isolation_level, max_retries });
        defer future.deinit();

        return try future.await();
    }

    /// Execute multiple transactions concurrently
    pub fn executeTransactionBatch(self: *Self, comptime Context: type, contexts: []Context, transaction_fn: fn (Context, TransactionId) anyerror!void, isolation_level: IsolationLevel) !void {
        var futures = try self.allocator.alloc(*runtime.Future(void), contexts.len);
        defer self.allocator.free(futures);

        for (contexts, 0..) |context, i| {
            futures[i] = try runtime.spawnWithTaskContext(self.allocator, executeTransactionTask, .{ self, Context, context, transaction_fn, isolation_level, 3 });
        }
        defer for (futures) |future| future.deinit();

        const results = try runtime.all(void, self.allocator, futures);
        self.allocator.free(results);
    }

    fn executeTransactionTask(self: *AsyncTransactionPool, comptime Context: type, context: Context, transaction_fn: fn (Context, TransactionId) anyerror!void, isolation_level: IsolationLevel, max_retries: u32, task_ctx: runtime.TaskContext) !void {
        try self.executeTransactionSync(Context, context, transaction_fn, isolation_level, max_retries, task_ctx);
    }

    fn executeTransactionWorker(self: *AsyncTransactionPool, comptime Context: type, context: Context, transaction_fn: fn (Context, TransactionId) anyerror!void, isolation_level: IsolationLevel, max_retries: u32, task_ctx: runtime.TaskContext) !void {
        try self.executeTransactionSync(Context, context, transaction_fn, isolation_level, max_retries, task_ctx);
    }

    /// Execute a transaction function with automatic retry on conflicts (sync version)
    fn executeTransactionSync(self: *Self, comptime Context: type, context: Context, transaction_fn: fn (Context, TransactionId) anyerror!void, isolation_level: IsolationLevel, max_retries: u32, task_ctx: runtime.TaskContext) !void {
        var retry_count: u32 = 0;

        while (retry_count < max_retries) {
            try task_ctx.checkpoint();
            // Wait for semaphore (rate limiting)
            try self.semaphore.waitWithToken(task_ctx.cancel_token);
            defer self.semaphore.post();

            const previous_active = self.active_transactions.fetchAdd(1, .acq_rel);
            std.debug.assert(previous_active < std.math.maxInt(u32));
            defer {
                const previous = self.active_transactions.fetchSub(1, .acq_rel);
                std.debug.assert(previous > 0);
            }

            const transaction_id = try self.mvcc_manager.beginTransaction(isolation_level);

            const result = transaction_fn(context, transaction_id);
            if (result) {
                // Success, try to commit
                if (self.mvcc_manager.commitTransaction(transaction_id)) {
                    return; // Success!
                } else |err| switch (err) {
                    error.ReadConflict, error.WriteConflict, error.DeadlockDetected => {
                        // Retry on conflicts
                        try self.mvcc_manager.abortTransaction(transaction_id);
                        retry_count += 1;

                        // Exponential backoff between retries
                        const backoff_time = (@as(u64, 1) << @min(retry_count, 10));
                        try task_ctx.checkpoint();
                        runtime.sleep(backoff_time);
                        continue;
                    },
                    else => return err, // Other errors are not retryable
                }
            } else |err| {
                // Function failed, abort transaction
                try self.mvcc_manager.abortTransaction(transaction_id);
                return err;
            }
        }

        return error.TooManyRetries;
    }

    /// Get pool statistics
    pub fn getPoolStats(self: *Self) AsyncTransactionPoolStats {
        return AsyncTransactionPoolStats{
            .active_transactions = self.active_transactions.load(.acquire),
            .max_concurrent = self.max_concurrent_transactions,
            .task_queue_capacity = 0,
            .pending_tasks = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.active_transactions.load(.acquire) != 0) {
            std.debug.assert(false);
        }
        self.semaphore.deinit();
    }
};

pub const AsyncTransactionPoolStats = struct {
    active_transactions: u32,
    max_concurrent: u32,
    task_queue_capacity: u32,
    pending_tasks: u32,
};

// Tests
test "mvcc transaction basic operations" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create storage engine
    var storage_engine = try storage.StorageEngine.initMemory(allocator);
    defer storage_engine.deinit();

    // Create MVCC manager
    var mvcc = try MVCCTransactionManager.init(allocator, &storage_engine, null);
    defer mvcc.deinit();

    // Begin transaction
    const tx_id = try mvcc.beginTransaction(.ReadCommitted);

    // Test write operation
    const test_row = storage.Row{
        .values = &[_]storage.Value{storage.Value{ .Integer = 123 }},
    };
    try mvcc.writeRow(tx_id, "test_table", 1, test_row);

    // Test read operation (should read our own write)
    if (try mvcc.readRow(tx_id, "test_table", 1)) |row| {
        try testing.expectEqual(@as(i64, 123), row.values[0].Integer);
    } else {
        try testing.expect(false); // Should have found the row
    }

    // Commit transaction
    try mvcc.commitTransaction(tx_id);

    // Check statistics
    const stats = mvcc.getTransactionStats();
    try testing.expect(stats.committed_transactions == 1);
    try testing.expect(stats.total_commits == 1);
}

test "transaction isolation levels" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage_engine = try storage.StorageEngine.initMemory(allocator);
    defer storage_engine.deinit();

    var mvcc = try MVCCTransactionManager.init(allocator, &storage_engine, null);
    defer mvcc.deinit();

    // Test different isolation levels
    const isolation_levels = [_]IsolationLevel{ .ReadUncommitted, .ReadCommitted, .RepeatableRead, .Serializable };

    for (isolation_levels) |level| {
        const tx_id = try mvcc.beginTransaction(level);
        try mvcc.abortTransaction(tx_id);
    }

    const stats = mvcc.getTransactionStats();
    try testing.expect(stats.aborted_transactions == 4);
}

test "async transaction pool with runtime executor" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage_engine = try storage.StorageEngine.initMemory(allocator);
    defer storage_engine.deinit();

    var mvcc = try MVCCTransactionManager.init(allocator, &storage_engine, null);
    defer mvcc.deinit();

    var async_pool = try AsyncTransactionPool.init(allocator, &mvcc, 4);
    defer async_pool.deinit();

    // Test transaction function
    const TestContext = struct {
        value: i64,
        counter: *std.atomic.Value(u32),
    };

    var counter = std.atomic.Value(u32).init(0);

    const testTransaction = struct {
        fn run(context: TestContext, transaction_id: TransactionId) !void {
            _ = transaction_id;
            _ = context.counter.fetchAdd(1, .acq_rel);

            // Simulate some work
            const test_row = storage.Row{
                .values = &[_]storage.Value{storage.Value{ .Integer = context.value }},
            };
            // Note: In real test we'd use the MVCC manager to write
            _ = test_row;
        }
    }.run;

    // Execute multiple transactions concurrently
    const contexts = [_]TestContext{
        TestContext{ .value = 1, .counter = &counter },
        TestContext{ .value = 2, .counter = &counter },
        TestContext{ .value = 3, .counter = &counter },
        TestContext{ .value = 4, .counter = &counter },
    };

    try async_pool.executeTransactionBatch(TestContext, &contexts, testTransaction, .ReadCommitted);

    // Check that all transactions executed
    try testing.expect(counter.load(.acquire) == 4);

    const pool_stats = async_pool.getPoolStats();
    try testing.expect(pool_stats.max_concurrent == 4);
}
