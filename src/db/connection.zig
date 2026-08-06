const std = @import("std");
const storage = @import("storage.zig");
const wal = @import("wal.zig");
const file_io = @import("file_io.zig");
const btree = @import("btree.zig");
const ast = @import("../parser/ast.zig");
const parser = @import("../parser/parser.zig");
const tokenizer = @import("../parser/tokenizer.zig");
const planner = @import("../executor/planner.zig");
const vm = @import("../executor/vm.zig");
const cache_manager = @import("../performance/cache_manager.zig");
const query_cache = @import("../performance/query_cache.zig");
const runtime_compat = @import("../runtime/compat/thread.zig");

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
    /// Filesystem ATTACH is denied when this is empty unless allow_any_path is set.
    allowed_roots: []const []const u8,
    /// Whether to allow :memory: databases
    allow_memory: bool,
    /// Whether to allow relative paths (resolved relative to current working directory)
    allow_relative: bool,
    /// Allow filesystem paths without root confinement. Intended only for compatibility mode.
    allow_any_path: bool = false,

    pub const ALLOW_ALL = AttachPathPolicy{
        .allowed_roots = &[_][]const u8{},
        .allow_memory = true,
        .allow_relative = true,
        .allow_any_path = true,
    };

    pub const SECURE_DEFAULT = AttachPathPolicy{
        .allowed_roots = &[_][]const u8{},
        .allow_memory = true,
        .allow_relative = false, // Require absolute paths
        .allow_any_path = false,
    };

    /// Check if a path is under a root directory with proper segment boundary checking
    /// Prevents "/var/db" from matching "/var/database" (must have separator or end)
    fn isPathUnderRoot(path: []const u8, root: []const u8) bool {
        const starts_with_root = if (@import("builtin").os.tag == .windows)
            std.ascii.startsWithIgnoreCase(path, root)
        else
            std.mem.startsWith(u8, path, root);
        if (!starts_with_root) return false;

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

    fn hasParentTraversal(path: []const u8) bool {
        var components = std.fs.path.componentIterator(path);
        while (components.next()) |component| {
            if (std.mem.eql(u8, component.name, "..")) return true;
        }
        return false;
    }

    fn canonicalizeExistingPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

        var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |dir_err| switch (dir_err) {
            error.NotDir => {
                var file = try std.Io.Dir.cwd().openFile(io, path, .{});
                defer file.close(io);
                const len = try file.realPath(io, &buffer);
                return allocator.dupe(u8, buffer[0..len]);
            },
            else => return dir_err,
        };
        defer dir.close(io);
        const dir_file = std.Io.File{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
        const len = try dir_file.realPath(io, &buffer);
        return allocator.dupe(u8, buffer[0..len]);
    }

    /// Resolve symlinks for an existing target, or resolve the existing parent
    /// directory before appending a not-yet-created database filename.
    fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return canonicalizeExistingPath(allocator, path) catch |err| switch (err) {
            error.FileNotFound => {
                const parent = std.fs.path.dirname(path) orelse ".";
                const canonical_parent = try canonicalizeExistingPath(allocator, parent);
                defer allocator.free(canonical_parent);
                return std.fs.path.join(allocator, &.{ canonical_parent, std.fs.path.basename(path) });
            },
            else => return err,
        };
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

        // Reject traversal components without rejecting legitimate names such as data..db.
        if (hasParentTraversal(path)) {
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

        const validated_path = try canonicalizePath(allocator, path);
        errdefer allocator.free(validated_path);

        if (self.allow_any_path) {
            return validated_path;
        }

        if (self.allowed_roots.len == 0) return error.PathNotInAllowedRoots;

        // For relative paths with allowed_roots, we need absolute path to check
        if (!is_absolute) {
            return error.RelativePathWithRootsNotSupported;
        }

        // Check if path is under an allowed root (segment-aware boundary check)
        for (self.allowed_roots) |allowed_root| {
            const canonical_root = try canonicalizeExistingPath(allocator, allowed_root);
            defer allocator.free(canonical_root);
            if (isPathUnderRoot(validated_path, canonical_root)) {
                return validated_path;
            }
        }

        return error.PathNotInAllowedRoots;
    }
};

/// Connection options for security and behavior configuration
pub const ConnectionOptions = struct {
    pub const AccessMode = enum {
        read_write,
        read_only,
        immutable,
    };

    /// Enable secure mode: uses SECURE_DEFAULT attach policy, stricter validation
    secure_mode: bool = false,
    /// Custom attach path policy (overrides secure_mode if set)
    attach_policy: ?AttachPathPolicy = null,
    /// File access mode. Read-only and immutable connections do not open WAL,
    /// do not replay WAL, and reject mutating statements.
    access_mode: AccessMode = .read_write,
    /// Optional per-operation timeout in milliseconds. Applies to parse, plan,
    /// and VM execution for connection-level and prepared-statement execution.
    busy_timeout_ms: ?u64 = null,
    resource_limits: ResourceLimits = .{},
    progress_callback: ?ProgressCallback = null,
    progress_context: ?*anyopaque = null,
    plan_cache_entries: usize = 100,

    pub const DEFAULT = ConnectionOptions{};
    pub const SECURE = ConnectionOptions{ .secure_mode = true };
    pub const READ_ONLY = ConnectionOptions{ .access_mode = .read_only };
    pub const IMMUTABLE = ConnectionOptions{ .access_mode = .immutable };
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

pub const ScalarFunction = *const fn (allocator: std.mem.Allocator, arguments: []const storage.Value) anyerror!storage.Value;
pub const AggregateFunction = *const fn (allocator: std.mem.Allocator, values: []const storage.Value) anyerror!storage.Value;

pub const ResourceLimits = struct {
    max_scanned_rows: ?u64 = null,
    max_result_rows: ?usize = null,
    max_affected_rows: ?u64 = null,
    max_vm_steps: ?u64 = null,
    max_statement_bytes: ?usize = null,
    max_page_count: ?u32 = null,
    max_cache_pages: ?u32 = null,
    max_memory_bytes: ?usize = null,
    progress_interval_ops: ?u64 = null,

    pub const UNLIMITED = ResourceLimits{};
};

pub const ProgressEvent = struct {
    vm_steps: u64,
    scanned_rows: u64,
    result_rows: usize,
    affected_rows: u64,
    work_units: u64,
    estimated_memory_bytes: usize,
};

pub const ProgressCallback = *const fn (context: ?*anyopaque, event: ProgressEvent) bool;

const ResourceUsage = struct {
    vm_steps: u64 = 0,
    scanned_rows: u64 = 0,
    result_rows: usize = 0,
    affected_rows: u64 = 0,
    work_units: u64 = 0,
    estimated_memory_bytes: usize = 0,
    next_progress_units: u64 = 0,
};

const DatabaseStamp = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,

    fn fromStat(stat: std.Io.File.Stat) DatabaseStamp {
        return .{
            .inode = stat.inode,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
            .ctime_ns = stat.ctime.nanoseconds,
        };
    }

    fn eql(a: DatabaseStamp, b: DatabaseStamp) bool {
        return a.inode == b.inode and a.size == b.size and a.mtime_ns == b.mtime_ns and a.ctime_ns == b.ctime_ns;
    }
};

pub const PlannerTableStats = planner.PlannerTableStats;
pub const PlannerIndexStats = planner.PlannerIndexStats;

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
    access_mode: ConnectionOptions.AccessMode,
    busy_timeout_ms: ?u64,
    operation_deadline_ns: ?i128,
    interrupted: std.atomic.Value(bool),
    resource_limits: ResourceLimits,
    resource_usage: ResourceUsage,
    progress_callback: ?ProgressCallback,
    progress_context: ?*anyopaque,
    scalar_functions: std.StringHashMap(ScalarFunction),
    aggregate_functions: std.StringHashMap(AggregateFunction),
    aggregate_function_names: std.StringHashMap(void),
    planner_table_stats: std.ArrayListUnmanaged(PlannerTableStats),
    planner_index_stats: std.ArrayListUnmanaged(PlannerIndexStats),
    /// WAL callback context for transaction page logging
    wal_callback_ctx: ?*WalCallbackContext,
    /// A separate handle keeps advisory locks independent from pager lifecycle.
    database_lock_file: ?file_io.File,
    database_lock_held: bool,
    database_lock_mode: file_io.Lock,
    writer_lock_held: bool,
    database_stamp: ?DatabaseStamp,
    closing: bool,
    shared_storage_mutex: ?*runtime_compat.Mutex,
    shared_storage_lock_held: bool,

    const Self = @This();

    fn acquireInitialDatabaseLock(file: file_io.File, mode: file_io.Lock, timeout_ms: ?u64) !void {
        const started = (runtime_compat.Instant.now() catch unreachable).timestamp;
        const deadline = if (timeout_ms) |timeout|
            started + @as(i128, timeout) * std.time.ns_per_ms
        else
            null;

        while (!try file_io.tryLock(file, mode)) {
            const limit = deadline orelse return error.DatabaseBusy;
            if ((runtime_compat.Instant.now() catch unreachable).timestamp >= limit) {
                return error.OperationTimedOut;
            }
            try file_io.waitForLockRetry();
        }
    }

    fn acquireDatabaseLock(self: *Self, mode: file_io.Lock) !bool {
        const file = self.database_lock_file orelse return false;
        if (self.database_lock_held) {
            if (self.database_lock_mode != .exclusive and mode == .exclusive) {
                return error.DatabaseBusy;
            }
            return false;
        }

        const started = (runtime_compat.Instant.now() catch unreachable).timestamp;
        const deadline = self.operation_deadline_ns orelse if (self.busy_timeout_ms) |timeout|
            started + @as(i128, timeout) * std.time.ns_per_ms
        else
            null;

        while (!try file_io.tryLock(file, mode)) {
            if (self.interrupted.load(.acquire)) return error.Interrupted;
            const limit = deadline orelse return error.DatabaseBusy;
            if ((runtime_compat.Instant.now() catch unreachable).timestamp >= limit) {
                return error.OperationTimedOut;
            }
            try file_io.waitForLockRetry();
        }

        self.database_lock_held = true;
        self.database_lock_mode = mode;
        return true;
    }

    fn releaseDatabaseLock(self: *Self) void {
        if (!self.database_lock_held) return;
        file_io.unlock(self.database_lock_file.?);
        self.database_lock_held = false;
        self.database_lock_mode = .none;
    }

    fn lockDatabaseForClose(self: *Self, mode: file_io.Lock) !void {
        if (self.database_lock_held) return;
        const file = self.database_lock_file orelse return;
        try file_io.lock(file, mode);
        self.database_lock_held = true;
        self.database_lock_mode = mode;
    }

    fn acquireWriterLock(self: *Self) !bool {
        if (self.writer_lock_held or self.wal == null) return false;

        const started = (runtime_compat.Instant.now() catch unreachable).timestamp;
        const deadline = self.operation_deadline_ns orelse if (self.busy_timeout_ms) |timeout|
            started + @as(i128, timeout) * std.time.ns_per_ms
        else
            null;

        while (!try self.wal.?.tryLockWriter()) {
            if (self.interrupted.load(.acquire)) return error.Interrupted;
            const limit = deadline orelse return error.DatabaseBusy;
            if ((runtime_compat.Instant.now() catch unreachable).timestamp >= limit) {
                return error.OperationTimedOut;
            }
            try file_io.waitForLockRetry();
        }

        self.writer_lock_held = true;
        return true;
    }

    fn releaseWriterLock(self: *Self) void {
        if (!self.writer_lock_held) return;
        self.wal.?.unlockWriter();
        self.writer_lock_held = false;
    }

    fn readDatabaseStamp(self: *const Self) !?DatabaseStamp {
        const path = self.path orelse return null;
        return DatabaseStamp.fromStat(try file_io.statPath(path));
    }

    fn recordDatabaseStamp(self: *Self) !void {
        self.database_stamp = try self.readDatabaseStamp();
    }

    fn refreshStorageFromDisk(self: *Self) !void {
        if (self.is_memory or !self.owns_storage or self.path == null or self.in_transaction) return;

        const current_stamp = try self.readDatabaseStamp();
        if (self.database_stamp != null and current_stamp != null and DatabaseStamp.eql(self.database_stamp.?, current_stamp.?)) return;

        const old_schema_version = self.storage_engine.getSchemaVersion();
        const pager_mode: @import("pager.zig").Pager.OpenMode = if (self.access_mode == .read_write) .read_write else .read_only;
        const refreshed = try storage.StorageEngine.initWithMode(self.allocator, self.path.?, pager_mode);
        errdefer refreshed.deinit();
        try refreshed.pager.setMaxPageCount(self.resource_limits.max_page_count);
        refreshed.pager.setCachePageLimit(self.resource_limits.max_cache_pages);

        if (self.wal) |w| try w.checkpointToPager(refreshed.pager);

        self.storage_engine.deinit();
        self.storage_engine = refreshed;
        self.clearPlannerStats();
        if (self.result_cache) |cache| cache.clear();

        if (old_schema_version != refreshed.getSchemaVersion()) {
            if (self.plan_cache) |*cache| {
                cache.deinit();
                self.plan_cache = try cache_manager.QueryPlanCache.init(self.allocator, 100);
            }
        }
        try self.recordDatabaseStamp();
    }

    fn openOwnedStorage(self: *Self) !*storage.StorageEngine {
        const pager_mode: @import("pager.zig").Pager.OpenMode = if (self.access_mode == .read_write) .read_write else .read_only;
        const reopened = try storage.StorageEngine.initWithMode(self.allocator, self.path.?, pager_mode);
        errdefer reopened.deinit();
        try reopened.pager.setMaxPageCount(self.resource_limits.max_page_count);
        reopened.pager.setCachePageLimit(self.resource_limits.max_cache_pages);
        return reopened;
    }

    fn beginStatementAccess(self: *Self, statement: *const ast.Statement) !bool {
        if (self.is_memory or !self.owns_storage or self.in_transaction) return false;
        switch (statement.*) {
            .BeginTransaction => return false,
            else => {},
        }
        const mode: file_io.Lock = if (statementIsReadOnly(statement.*)) .shared else .exclusive;
        const writer_acquired = if (mode == .exclusive) try self.acquireWriterLock() else false;
        errdefer if (writer_acquired) self.releaseWriterLock();
        const acquired = try self.acquireDatabaseLock(mode);
        errdefer if (acquired) self.releaseDatabaseLock();
        try self.refreshStorageFromDisk();
        return acquired;
    }

    fn finishStatementAccess(self: *Self, acquired: bool, statement: *const ast.Statement) !void {
        if (!statementIsReadOnly(statement.*) and !self.in_transaction) {
            try self.flush();
            try self.recordDatabaseStamp();
        }
        if (!self.in_transaction) {
            if (acquired) self.releaseDatabaseLock();
            self.releaseWriterLock();
        }
    }

    fn abortStatementAccess(self: *Self, acquired: bool) void {
        if (self.in_transaction) return;
        if (acquired) self.releaseDatabaseLock();
        self.releaseWriterLock();
    }

    fn acquireSharedStorageLock(self: *Self) bool {
        const mutex = self.shared_storage_mutex orelse return false;
        if (self.shared_storage_lock_held) return false;
        mutex.lock();
        self.shared_storage_lock_held = true;
        return true;
    }

    fn releaseSharedStorageLock(self: *Self) void {
        if (!self.shared_storage_lock_held) return;
        self.shared_storage_mutex.?.unlock();
        self.shared_storage_lock_held = false;
    }

    fn ensureSharedStorageLock(self: *Self) void {
        if (self.acquireSharedStorageLock()) return;
    }

    pub fn setSharedStorageMutex(self: *Self, mutex: *runtime_compat.Mutex) void {
        self.shared_storage_mutex = mutex;
    }

    /// Open a database file with default options (backwards compatible)
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Self {
        return openWithOptions(allocator, path, ConnectionOptions.DEFAULT);
    }

    /// Open a database file with options
    pub fn openWithOptions(allocator: std.mem.Allocator, path: []const u8, options: ConnectionOptions) !*Self {
        var conn = try allocator.create(Self);
        errdefer allocator.destroy(conn);

        conn.allocator = allocator;
        const pager_mode: @import("pager.zig").Pager.OpenMode = if (options.access_mode == .read_write) .read_write else .read_only;
        const lock_path = try std.fmt.allocPrint(allocator, "{s}-lock", .{path});
        defer allocator.free(lock_path);
        conn.database_lock_file = try file_io.open(allocator, lock_path, .read_write_create);
        conn.database_lock_held = false;
        conn.database_lock_mode = .none;
        conn.writer_lock_held = false;
        conn.database_stamp = null;
        conn.closing = false;
        conn.shared_storage_mutex = null;
        conn.shared_storage_lock_held = false;
        errdefer if (conn.database_lock_file) |file| {
            if (conn.database_lock_held) file_io.unlock(file);
            file_io.close(file);
        };
        const initial_lock_mode: file_io.Lock = if (options.access_mode == .read_write) .exclusive else .shared;
        try acquireInitialDatabaseLock(conn.database_lock_file.?, initial_lock_mode, options.busy_timeout_ms);
        conn.database_lock_held = true;
        conn.database_lock_mode = initial_lock_mode;

        conn.storage_engine = try storage.StorageEngine.initWithMode(allocator, path, pager_mode);
        errdefer conn.storage_engine.deinit();
        try conn.storage_engine.pager.setMaxPageCount(options.resource_limits.max_page_count);
        conn.storage_engine.pager.setCachePageLimit(options.resource_limits.max_cache_pages);

        conn.wal = if (options.access_mode == .read_write) try wal.WriteAheadLog.init(allocator, path) else null;
        errdefer if (conn.wal) |w| w.deinit();

        conn.is_memory = false;
        conn.path = try allocator.dupe(u8, path);
        errdefer allocator.free(conn.path.?);

        conn.owns_storage = true;
        conn.in_transaction = false;
        conn.undo_log = .empty;
        conn.savepoints = .empty;
        conn.plan_cache = if (options.plan_cache_entries == 0)
            null
        else
            try cache_manager.QueryPlanCache.init(allocator, options.plan_cache_entries);
        errdefer if (conn.plan_cache) |*cache| cache.deinit();

        conn.result_cache = null; // Caller can set via setResultCache()
        conn.attached_databases = std.StringHashMap(*Self).init(allocator);
        conn.wal_callback_ctx = null;
        conn.access_mode = options.access_mode;
        conn.busy_timeout_ms = options.busy_timeout_ms;
        conn.operation_deadline_ns = null;
        conn.interrupted = std.atomic.Value(bool).init(false);
        conn.resource_limits = options.resource_limits;
        conn.resource_usage = .{};
        conn.progress_callback = options.progress_callback;
        conn.progress_context = options.progress_context;
        conn.scalar_functions = std.StringHashMap(ScalarFunction).init(allocator);
        conn.aggregate_functions = std.StringHashMap(AggregateFunction).init(allocator);
        conn.aggregate_function_names = std.StringHashMap(void).init(allocator);
        conn.planner_table_stats = .empty;
        conn.planner_index_stats = .empty;

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

        try conn.recordDatabaseStamp();
        conn.releaseDatabaseLock();

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
        try conn.storage_engine.pager.setMaxPageCount(options.resource_limits.max_page_count);
        conn.storage_engine.pager.setCachePageLimit(options.resource_limits.max_cache_pages);
        conn.wal = null; // No WAL for in-memory databases
        conn.is_memory = true;
        conn.path = null;
        conn.owns_storage = true;
        conn.in_transaction = false;
        conn.undo_log = .empty;
        conn.savepoints = .empty;
        conn.plan_cache = if (options.plan_cache_entries == 0)
            null
        else
            try cache_manager.QueryPlanCache.init(allocator, options.plan_cache_entries);
        conn.result_cache = null;
        conn.attached_databases = std.StringHashMap(*Self).init(allocator);
        conn.wal_callback_ctx = null;
        conn.database_lock_file = null;
        conn.database_lock_held = false;
        conn.database_lock_mode = .none;
        conn.writer_lock_held = false;
        conn.database_stamp = null;
        conn.closing = false;
        conn.shared_storage_mutex = null;
        conn.shared_storage_lock_held = false;
        conn.access_mode = options.access_mode;
        conn.busy_timeout_ms = options.busy_timeout_ms;
        conn.operation_deadline_ns = null;
        conn.interrupted = std.atomic.Value(bool).init(false);
        conn.resource_limits = options.resource_limits;
        conn.resource_usage = .{};
        conn.progress_callback = options.progress_callback;
        conn.progress_context = options.progress_context;
        conn.scalar_functions = std.StringHashMap(ScalarFunction).init(allocator);
        conn.aggregate_functions = std.StringHashMap(AggregateFunction).init(allocator);
        conn.aggregate_function_names = std.StringHashMap(void).init(allocator);
        conn.planner_table_stats = .empty;
        conn.planner_index_stats = .empty;

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
        try conn.storage_engine.pager.setMaxPageCount(options.resource_limits.max_page_count);
        conn.storage_engine.pager.setCachePageLimit(options.resource_limits.max_cache_pages);
        conn.wal = null; // Shared connections don't manage WAL independently
        conn.is_memory = true; // Assume shared storage is memory-based for simplicity
        conn.path = null;
        conn.owns_storage = false; // This connection doesn't own the storage
        conn.in_transaction = false;
        conn.undo_log = .empty;
        conn.savepoints = .empty;
        conn.plan_cache = if (options.plan_cache_entries == 0)
            null
        else
            try cache_manager.QueryPlanCache.init(allocator, options.plan_cache_entries);
        conn.result_cache = null;
        conn.attached_databases = std.StringHashMap(*Self).init(allocator);
        conn.wal_callback_ctx = null;
        conn.database_lock_file = null;
        conn.database_lock_held = false;
        conn.database_lock_mode = .none;
        conn.writer_lock_held = false;
        conn.database_stamp = null;
        conn.closing = false;
        conn.shared_storage_mutex = null;
        conn.shared_storage_lock_held = false;
        conn.access_mode = options.access_mode;
        conn.busy_timeout_ms = options.busy_timeout_ms;
        conn.operation_deadline_ns = null;
        conn.interrupted = std.atomic.Value(bool).init(false);
        conn.resource_limits = options.resource_limits;
        conn.resource_usage = .{};
        conn.progress_callback = options.progress_callback;
        conn.progress_context = options.progress_context;
        conn.scalar_functions = std.StringHashMap(ScalarFunction).init(allocator);
        conn.aggregate_functions = std.StringHashMap(AggregateFunction).init(allocator);
        conn.aggregate_function_names = std.StringHashMap(void).init(allocator);
        conn.planner_table_stats = .empty;
        conn.planner_index_stats = .empty;

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
        const shared_storage_acquired = self.acquireSharedStorageLock();
        defer if (shared_storage_acquired and !self.in_transaction) self.releaseSharedStorageLock();
        self.beginOperation();
        defer self.endOperation();
        try self.checkStatementSize(sql);
        try self.checkOperation();

        // Parse the SQL
        var parsed = try parser.parse(self.allocator, sql);
        defer parsed.deinit();
        try self.checkOperation();
        try self.ensureStatementAllowed(&parsed.statement);

        const auto_transaction = !self.in_transaction and statementNeedsAutoTransaction(parsed.statement);
        const acquired = if (auto_transaction) blk: {
            try self.beginTransaction();
            break :blk false;
        } else try self.beginStatementAccess(&parsed.statement);
        errdefer if (auto_transaction and self.in_transaction) {
            self.rollbackTransaction() catch |rollback_err| {
                std.log.err("autocommit rollback failed: {s}", .{@errorName(rollback_err)});
            };
        } else self.abortStatementAccess(acquired);

        // Execute via virtual machine
        try vm.execute(self, &parsed.statement);
        if (auto_transaction) {
            try self.commitTransaction();
        } else {
            try self.finishStatementAccess(acquired, &parsed.statement);
        }
    }

    pub fn isReadOnly(self: *const Self) bool {
        return self.access_mode != .read_write;
    }

    pub fn isImmutable(self: *const Self) bool {
        return self.access_mode == .immutable;
    }

    pub fn ensureWritable(self: *const Self) !void {
        if (self.isReadOnly()) return error.ReadOnlyDatabase;
    }

    pub fn registerScalarFunction(self: *Self, name: []const u8, callback: ScalarFunction) !void {
        const normalized = try normalizeFunctionName(self.allocator, name);
        errdefer self.allocator.free(normalized);

        if (self.scalar_functions.fetchRemove(normalized)) |entry| {
            self.allocator.free(entry.key);
        }
        try self.scalar_functions.put(normalized, callback);
    }

    pub fn registerAggregateFunction(self: *Self, name: []const u8, callback: AggregateFunction) !void {
        const normalized = try normalizeFunctionName(self.allocator, name);
        errdefer self.allocator.free(normalized);

        if (self.aggregate_functions.fetchRemove(normalized)) |entry| {
            self.allocator.free(entry.key);
        }
        const name_for_set = try self.allocator.dupe(u8, normalized);
        errdefer self.allocator.free(name_for_set);

        if (self.aggregate_function_names.fetchRemove(normalized)) |entry| {
            self.allocator.free(entry.key);
        }

        try self.aggregate_functions.put(normalized, callback);
        try self.aggregate_function_names.put(name_for_set, {});

        if (self.plan_cache) |*cache| {
            cache.deinit();
            self.plan_cache = null;
            self.plan_cache = try cache_manager.QueryPlanCache.init(self.allocator, 100);
        }
    }

    pub fn getScalarFunction(self: *Self, name: []const u8) ?ScalarFunction {
        const normalized = std.ascii.allocLowerString(self.allocator, name) catch return null;
        defer self.allocator.free(normalized);
        return self.scalar_functions.get(normalized);
    }

    pub fn getAggregateFunction(self: *Self, name: []const u8) ?AggregateFunction {
        const normalized = std.ascii.allocLowerString(self.allocator, name) catch return null;
        defer self.allocator.free(normalized);
        return self.aggregate_functions.get(normalized);
    }

    pub fn hasAggregateFunction(self: *Self, name: []const u8) bool {
        return self.getAggregateFunction(name) != null;
    }

    pub fn analyze(self: *Self, table_name: ?[]const u8) !void {
        self.clearPlannerStats();

        if (table_name) |name| {
            const table = self.storage_engine.getTable(name) orelse return error.TableNotFound;
            try self.collectTableStats(table);
            try self.collectIndexStatsForTable(table.name);
        } else {
            var table_iter = self.storage_engine.tables.iterator();
            while (table_iter.next()) |entry| {
                const table = entry.value_ptr.*;
                try self.collectTableStats(table);
                try self.collectIndexStatsForTable(table.name);
            }
        }

        if (self.plan_cache) |*cache| {
            cache.deinit();
            self.plan_cache = null;
            self.plan_cache = try cache_manager.QueryPlanCache.init(self.allocator, 100);
        }
    }

    fn collectTableStats(self: *Self, table: *storage.Table) !void {
        const live_rows = table.selectWithKeys(self.allocator) catch |err| return err;
        defer {
            for (live_rows) |item| {
                for (item.row.values) |value| value.deinit(self.allocator);
                self.allocator.free(item.row.values);
            }
            self.allocator.free(live_rows);
        }

        try self.planner_table_stats.append(self.allocator, .{
            .table_name = try self.allocator.dupe(u8, table.name),
            .row_count = table.row_count,
            .live_rows = @intCast(live_rows.len),
            .deleted_rows = @intCast(table.deleted_keys.count()),
            .column_count = @intCast(table.schema.columns.len),
        });
    }

    fn collectIndexStatsForTable(self: *Self, table_name: []const u8) !void {
        const table = self.storage_engine.getTable(table_name) orelse return error.TableNotFound;
        const rows = try table.selectWithKeys(self.allocator);
        defer {
            for (rows) |item| {
                for (item.row.values) |value| value.deinit(self.allocator);
                self.allocator.free(item.row.values);
            }
            self.allocator.free(rows);
        }

        var index_iter = self.storage_engine.indexes.iterator();
        while (index_iter.next()) |entry| {
            const index = entry.value_ptr.*;
            if (!std.mem.eql(u8, index.table_name, table_name)) continue;

            const column_name = if (index.column_names.len > 0) index.column_names[0] else "<expr>";
            const column_idx = if (!std.mem.eql(u8, column_name, "<expr>")) table.getColumnIndex(column_name) else null;

            var distinct = std.StringHashMap(void).init(self.allocator);
            defer {
                var distinct_iter = distinct.iterator();
                while (distinct_iter.next()) |distinct_entry| {
                    self.allocator.free(distinct_entry.key_ptr.*);
                }
                distinct.deinit();
            }

            var indexed_rows: u64 = 0;
            if (column_idx) |idx| {
                for (rows) |item| {
                    if (idx >= item.row.values.len) continue;
                    indexed_rows += 1;

                    var key_buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer key_buf.deinit(self.allocator);
                    try appendPlannerStatsValueKey(self.allocator, &key_buf, item.row.values[idx]);
                    const key = try self.allocator.dupe(u8, key_buf.items);
                    const gop = try distinct.getOrPut(key);
                    if (gop.found_existing) self.allocator.free(key);
                }
            }

            try self.planner_index_stats.append(self.allocator, .{
                .index_name = try self.allocator.dupe(u8, index.name),
                .table_name = try self.allocator.dupe(u8, index.table_name),
                .column_name = try self.allocator.dupe(u8, column_name),
                .indexed_rows = indexed_rows,
                .distinct_values = @intCast(distinct.count()),
                .is_unique = index.is_unique,
                .is_partial = index.where_clause != null,
                .is_expression = std.mem.eql(u8, column_name, "<expr>"),
            });
        }
    }

    fn appendPlannerStatsValueKey(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), value: storage.Value) !void {
        switch (value) {
            .Null => try output.appendSlice(allocator, "null:"),
            .Integer => |v| try appendPlannerStatsFmt(allocator, output, "i:{d}", .{v}),
            .Real => |v| try appendPlannerStatsFmt(allocator, output, "r:{d}", .{v}),
            .Text => |v| {
                try output.appendSlice(allocator, "t:");
                try output.appendSlice(allocator, v);
            },
            .Boolean => |v| try output.appendSlice(allocator, if (v) "b:1" else "b:0"),
            .SmallInt => |v| try appendPlannerStatsFmt(allocator, output, "s:{d}", .{v}),
            .BigInt => |v| try appendPlannerStatsFmt(allocator, output, "bi:{d}", .{v}),
            else => try output.appendSlice(allocator, "other:"),
        }
    }

    fn appendPlannerStatsFmt(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(text);
        try output.appendSlice(allocator, text);
    }

    fn clearPlannerStats(self: *Self) void {
        for (self.planner_table_stats.items) |stats| stats.deinit(self.allocator);
        self.planner_table_stats.clearRetainingCapacity();

        for (self.planner_index_stats.items) |stats| stats.deinit(self.allocator);
        self.planner_index_stats.clearRetainingCapacity();
    }

    fn normalizeFunctionName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        if (name.len == 0) return error.InvalidFunctionName;
        return std.ascii.allocLowerString(allocator, name);
    }

    /// Configure a per-operation timeout in milliseconds. A value of zero
    /// disables timeout checks. The timeout is checked cooperatively while
    /// parsing/planning and during VM step and row loops.
    pub fn setBusyTimeout(self: *Self, timeout_ms: u64) void {
        self.busy_timeout_ms = if (timeout_ms == 0) null else timeout_ms;
    }

    pub fn getBusyTimeout(self: *const Self) ?u64 {
        return self.busy_timeout_ms;
    }

    pub fn setResourceLimits(self: *Self, limits: ResourceLimits) void {
        self.resource_limits = limits;
        self.storage_engine.pager.setCachePageLimit(limits.max_cache_pages);
    }

    pub fn configureResourceLimits(self: *Self, limits: ResourceLimits) !void {
        try self.storage_engine.pager.setMaxPageCount(limits.max_page_count);
        self.storage_engine.pager.setCachePageLimit(limits.max_cache_pages);
        self.resource_limits = limits;
    }

    pub fn getResourceLimits(self: *const Self) ResourceLimits {
        return self.resource_limits;
    }

    pub fn setPlanCacheCapacity(self: *Self, entries: usize) !void {
        if (self.plan_cache) |*cache| {
            cache.deinit();
            self.plan_cache = null;
        }
        if (entries > 0) {
            self.plan_cache = try cache_manager.QueryPlanCache.init(self.allocator, entries);
        }
    }

    fn checkStatementSize(self: *const Self, sql: []const u8) !void {
        if (self.resource_limits.max_statement_bytes) |limit| {
            if (sql.len > limit) return error.ResourceLimitExceeded;
        }
    }

    pub fn setProgressHandler(self: *Self, interval_ops: u64, callback: ?ProgressCallback, context: ?*anyopaque) void {
        self.resource_limits.progress_interval_ops = if (interval_ops == 0) null else interval_ops;
        self.progress_callback = callback;
        self.progress_context = context;
    }

    pub fn clearProgressHandler(self: *Self) void {
        self.progress_callback = null;
        self.progress_context = null;
        self.resource_limits.progress_interval_ops = null;
    }

    pub fn currentProgressEvent(self: *const Self) ProgressEvent {
        return .{
            .vm_steps = self.resource_usage.vm_steps,
            .scanned_rows = self.resource_usage.scanned_rows,
            .result_rows = self.resource_usage.result_rows,
            .affected_rows = self.resource_usage.affected_rows,
            .work_units = self.resource_usage.work_units,
            .estimated_memory_bytes = self.resource_usage.estimated_memory_bytes,
        };
    }

    /// Request cancellation for the current or next operation on this connection.
    /// The VM checks this flag cooperatively between plan steps and row loops.
    pub fn interrupt(self: *Self) void {
        self.interrupted.store(true, .release);
    }

    pub fn clearInterrupt(self: *Self) void {
        self.interrupted.store(false, .release);
    }

    pub fn isInterrupted(self: *const Self) bool {
        return self.interrupted.load(.acquire);
    }

    pub fn beginOperation(self: *Self) void {
        self.operation_deadline_ns = if (self.busy_timeout_ms) |timeout_ms|
            (runtime_compat.Instant.now() catch unreachable).timestamp + @as(i128, timeout_ms) * std.time.ns_per_ms
        else
            null;
        self.resource_usage = .{
            .next_progress_units = self.resource_limits.progress_interval_ops orelse 0,
        };
    }

    pub fn endOperation(self: *Self) void {
        self.operation_deadline_ns = null;
    }

    pub fn checkOperation(self: *const Self) !void {
        if (self.interrupted.load(.acquire)) return error.Interrupted;
        if (self.operation_deadline_ns) |deadline| {
            if ((runtime_compat.Instant.now() catch unreachable).timestamp >= deadline) return error.OperationTimedOut;
        }
    }

    pub fn recordVmStep(self: *Self) !void {
        self.resource_usage.vm_steps += 1;
        if (self.resource_limits.max_vm_steps) |limit| {
            if (self.resource_usage.vm_steps > limit) return error.ResourceLimitExceeded;
        }
        try self.recordWork(1);
    }

    pub fn recordRowsScanned(self: *Self, count: u64) !void {
        self.resource_usage.scanned_rows += count;
        if (self.resource_limits.max_scanned_rows) |limit| {
            if (self.resource_usage.scanned_rows > limit) return error.ResourceLimitExceeded;
        }
        try self.recordWork(count);
    }

    pub fn recordResultRows(self: *Self, count: usize) !void {
        self.resource_usage.result_rows = count;
        if (self.resource_limits.max_result_rows) |limit| {
            if (count > limit) return error.ResourceLimitExceeded;
        }
        if (self.resource_limits.max_memory_bytes) |limit| {
            const per_row_estimate = @sizeOf(storage.Row) + (@sizeOf(storage.Value) * 4);
            self.resource_usage.estimated_memory_bytes = count * per_row_estimate;
            if (self.resource_usage.estimated_memory_bytes > limit) return error.ResourceLimitExceeded;
        }
    }

    pub fn recordAffectedRows(self: *Self, count: u64) !void {
        self.resource_usage.affected_rows = count;
        if (self.resource_limits.max_affected_rows) |limit| {
            if (count > limit) return error.ResourceLimitExceeded;
        }
    }

    fn recordWork(self: *Self, count: u64) !void {
        self.resource_usage.work_units += count;
        try self.checkOperation();

        const interval = self.resource_limits.progress_interval_ops orelse return;
        if (interval == 0 or self.progress_callback == null) return;

        while (self.resource_usage.work_units >= self.resource_usage.next_progress_units) {
            const keep_going = self.progress_callback.?(self.progress_context, self.currentProgressEvent());
            if (!keep_going) {
                self.interrupt();
                return error.Interrupted;
            }
            self.resource_usage.next_progress_units += interval;
        }
    }

    fn ensureStatementAllowed(self: *const Self, statement: *const ast.Statement) !void {
        if (!self.isReadOnly()) return;
        if (!statementIsReadOnly(statement.*)) return error.ReadOnlyDatabase;
    }

    fn statementIsReadOnly(statement: ast.Statement) bool {
        return switch (statement) {
            .Select, .With, .CompoundSelect, .Explain, .Analyze => true,
            .Pragma => |pragma| pragma.value == null,
            else => false,
        };
    }

    fn statementNeedsAutoTransaction(statement: ast.Statement) bool {
        return switch (statement) {
            .Insert, .Update, .Delete => true,
            else => false,
        };
    }

    /// Begin a transaction
    pub fn beginTransaction(self: *Self) !void {
        const shared_storage_acquired = self.acquireSharedStorageLock();
        errdefer if (shared_storage_acquired and !self.in_transaction) self.releaseSharedStorageLock();
        try self.ensureWritable();
        if (self.in_transaction) return error.TransactionAlreadyActive;
        const writer_acquired = try self.acquireWriterLock();
        errdefer if (writer_acquired) self.releaseWriterLock();
        const database_acquired = try self.acquireDatabaseLock(.shared);
        errdefer if (database_acquired) self.releaseDatabaseLock();
        if (database_acquired) try self.refreshStorageFromDisk();
        if (database_acquired) self.releaseDatabaseLock();
        if (self.wal) |w| {
            try w.beginTransaction();
            self.storage_engine.pager.beginTransaction();
            errdefer self.storage_engine.pager.endTransactionForRollback();

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
        try self.ensureWritable();
        if (!self.in_transaction) return error.NoActiveTransaction;
        var constraint_vm = vm.VirtualMachine.init(self.allocator, self);
        defer constraint_vm.deinitVM();
        try constraint_vm.validateDeferredForeignKeys();
        const database_acquired = try self.acquireDatabaseLock(.exclusive);
        errdefer if (database_acquired) self.releaseDatabaseLock();
        defer if (!self.in_transaction and !self.closing) {
            self.releaseDatabaseLock();
            self.releaseWriterLock();
            self.releaseSharedStorageLock();
        };

        // Clear btree callbacks first
        self.clearTransactionCallbacks();

        if (self.wal) |w| {
            try w.commit();
            self.storage_engine.pager.endTransactionForCommit();
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
        try self.recordDatabaseStamp();
    }

    /// Commit a transaction (alias)
    pub fn commit(self: *Self) !void {
        try self.commitTransaction();
    }

    /// Persist all pending database, metadata, and WAL state.
    /// Flush is rejected while a transaction is active; commit or rollback it first.
    pub fn flush(self: *Self) !void {
        if (self.in_transaction) return error.TransactionActive;
        if (self.isReadOnly()) return;

        const writer_acquired = try self.acquireWriterLock();
        defer if (writer_acquired) self.releaseWriterLock();
        const database_acquired = try self.acquireDatabaseLock(.exclusive);
        defer if (database_acquired) self.releaseDatabaseLock();
        if (database_acquired) try self.refreshStorageFromDisk();

        if (self.wal) |w| {
            try w.checkpointToPager(self.storage_engine.pager);
        }
        if (self.owns_storage and !self.is_memory) {
            try self.storage_engine.saveAllMetadata();
        }
        if (self.owns_storage) {
            try self.storage_engine.pager.flush();
        }
        try self.recordDatabaseStamp();
    }

    pub fn getUserVersion(self: *const Self) u32 {
        return self.storage_engine.getUserVersion();
    }

    pub fn setUserVersion(self: *Self, version: u32) !void {
        try self.ensureWritable();
        if (self.in_transaction) return error.TransactionActive;
        const writer_acquired = try self.acquireWriterLock();
        defer if (writer_acquired) self.releaseWriterLock();
        const database_acquired = try self.acquireDatabaseLock(.exclusive);
        defer if (database_acquired) self.releaseDatabaseLock();
        if (database_acquired) try self.refreshStorageFromDisk();
        try self.storage_engine.setUserVersion(version);
        if (self.owns_storage and !self.is_memory) {
            try self.storage_engine.pager.flush();
        }
        try self.recordDatabaseStamp();
    }

    pub fn getSchemaVersion(self: *const Self) u32 {
        return self.storage_engine.getSchemaVersion();
    }

    pub fn integrityCheck(self: *Self) !storage.IntegrityCheckResult {
        const database_acquired = try self.acquireDatabaseLock(.shared);
        defer if (database_acquired) self.releaseDatabaseLock();
        if (database_acquired) try self.refreshStorageFromDisk();
        return self.storage_engine.validateIntegrity(self.allocator);
    }

    pub fn vacuum(self: *Self) !storage.IntegrityCheckResult {
        try self.ensureWritable();
        if (self.in_transaction) return error.TransactionActive;

        const writer_acquired = try self.acquireWriterLock();
        defer if (writer_acquired) self.releaseWriterLock();
        const database_acquired = try self.acquireDatabaseLock(.exclusive);
        defer if (database_acquired) self.releaseDatabaseLock();
        if (database_acquired) try self.refreshStorageFromDisk();

        try self.flush();
        if (self.is_memory) {
            var index_iter = self.storage_engine.indexes.iterator();
            while (index_iter.next()) |entry| {
                try self.storage_engine.refreshIndexesForTable(entry.value_ptr.*.table_name);
            }
            return self.storage_engine.validateIntegrity(self.allocator);
        }

        const nonce = (runtime_compat.Instant.now() catch unreachable).timestamp;
        const compact_path = try std.fmt.allocPrint(self.allocator, "{s}.vacuum-{d}", .{ self.path.?, nonce });
        defer self.allocator.free(compact_path);
        defer file_io.delete(compact_path) catch {};
        const backup_path = try std.fmt.allocPrint(self.allocator, "{s}.pre-vacuum-{d}", .{ self.path.?, nonce });
        defer self.allocator.free(backup_path);

        try self.storage_engine.compactTo(compact_path);
        // Validate the compact image before replacing the live database.
        const validation = try storage.StorageEngine.init(self.allocator, compact_path);
        var compact_check = try validation.validateIntegrity(self.allocator);
        validation.deinit();
        if (!compact_check.ok) {
            compact_check.deinit(self.allocator);
            return error.IntegrityCheckFailed;
        }
        compact_check.deinit(self.allocator);

        self.storage_engine.deinit();
        file_io.renamePreserve(self.path.?, backup_path) catch |err| {
            self.storage_engine = try self.openOwnedStorage();
            return err;
        };
        file_io.renamePreserve(compact_path, self.path.?) catch |err| {
            file_io.renamePreserve(backup_path, self.path.?) catch {};
            self.storage_engine = try self.openOwnedStorage();
            return err;
        };

        self.storage_engine = self.openOwnedStorage() catch |err| {
            file_io.renamePreserve(self.path.?, compact_path) catch {};
            file_io.renamePreserve(backup_path, self.path.?) catch {};
            self.storage_engine = try self.openOwnedStorage();
            return err;
        };
        file_io.delete(backup_path) catch |err| {
            std.log.warn("vacuum retained backup {s}: {s}", .{ backup_path, @errorName(err) });
        };
        self.clearPlannerStats();
        if (self.result_cache) |cache| cache.clear();
        if (self.plan_cache) |*plan_cache| {
            plan_cache.deinit();
            self.plan_cache = try cache_manager.QueryPlanCache.init(self.allocator, 100);
        }
        try self.recordDatabaseStamp();
        return self.storage_engine.validateIntegrity(self.allocator);
    }

    /// Run storage maintenance and write a flushed compact backup copy.
    /// This provides a VACUUM INTO-style API while keeping SQL path handling
    /// behind explicit embedder path policy decisions.
    pub fn vacuumInto(self: *Self, io: std.Io, dest_path: []const u8) !storage.IntegrityCheckResult {
        const check = try self.vacuum();
        if (!check.ok) return error.IntegrityCheckFailed;
        try self.backupToFile(io, dest_path);
        return check;
    }

    /// Explicitly checkpoint the WAL into the main database file and flush
    /// database metadata. This is rejected while a transaction is active.
    pub fn checkpoint(self: *Self) !void {
        try self.flush();
    }

    /// Return current WAL statistics for file-backed connections.
    pub fn getWalStats(self: *Self) !?wal.WriteAheadLog.Stats {
        if (self.wal) |w| {
            return try w.getStats();
        }
        return null;
    }

    /// Create a consistent file-level backup after checkpointing/flushing.
    /// In-memory databases cannot be backed up through this file-copy API.
    pub fn backupToFile(self: *Self, io: std.Io, dest_path: []const u8) !void {
        if (self.is_memory or self.path == null) return error.BackupRequiresFileDatabase;
        const writer_acquired = if (!self.isReadOnly()) try self.acquireWriterLock() else false;
        defer if (writer_acquired) self.releaseWriterLock();
        const database_mode: file_io.Lock = if (self.isReadOnly()) .shared else .exclusive;
        const database_acquired = try self.acquireDatabaseLock(database_mode);
        defer if (database_acquired) self.releaseDatabaseLock();
        if (database_acquired) try self.refreshStorageFromDisk();
        if (!self.isReadOnly()) try self.flush();
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.isAbsolute(self.path.?) and std.fs.path.isAbsolute(dest_path)) {
            try std.Io.Dir.copyFileAbsolute(self.path.?, dest_path, io, .{});
        } else {
            try std.Io.Dir.copyFile(cwd, self.path.?, cwd, dest_path, io, .{});
        }
    }

    /// Rollback a transaction
    pub fn rollbackTransaction(self: *Self) !void {
        try self.ensureWritable();
        if (!self.in_transaction) return error.NoActiveTransaction;
        defer if (!self.in_transaction and !self.closing) {
            self.releaseDatabaseLock();
            self.releaseWriterLock();
            self.releaseSharedStorageLock();
        };

        // Clear btree callbacks first
        self.clearTransactionCallbacks();

        // Use WAL-based physical page restoration for file-backed storage
        if (self.wal) |w| {
            self.storage_engine.pager.endTransactionForRollback();
            // Restore original page data from WAL old_data entries
            try w.rollbackWithPager(self.storage_engine.pager);

            // Restore in-memory logical row state for inserts/deletes/updates.
            try self.rollbackUndoTo(0);
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
        try self.refreshAllIndexesAndCaches();
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
        try self.ensureWritable();

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
        try self.ensureWritable();

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
        try self.ensureWritable();

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
        try self.checkStatementSize(sql);
        return PreparedStatement.prepare(self.allocator, self, sql);
    }

    // ========== BROAD API SURFACES (v1.2.2) ==========

    /// Execute SQL and return structured results (SQLite-style)
    pub fn query(self: *Self, sql: []const u8) !ResultSet {
        const shared_storage_acquired = self.acquireSharedStorageLock();
        defer if (shared_storage_acquired and !self.in_transaction) self.releaseSharedStorageLock();
        self.beginOperation();
        defer self.endOperation();
        try self.checkStatementSize(sql);
        try self.checkOperation();

        // Parse the SQL
        var parsed = try parser.parse(self.allocator, sql);
        defer parsed.deinit();
        try self.checkOperation();
        try self.ensureStatementAllowed(&parsed.statement);

        const auto_transaction = !self.in_transaction and statementNeedsAutoTransaction(parsed.statement);
        const acquired = if (auto_transaction) blk: {
            try self.beginTransaction();
            break :blk false;
        } else try self.beginStatementAccess(&parsed.statement);
        errdefer if (auto_transaction and self.in_transaction) {
            self.rollbackTransaction() catch |rollback_err| {
                std.log.err("autocommit rollback failed: {s}", .{@errorName(rollback_err)});
            };
        } else self.abortStatementAccess(acquired);

        if (self.result_cache) |cache| {
            const sql_hash = query_cache.QueryHasher.hashQuery(sql);
            if (cache.get(sql_hash)) |cached_result| {
                const result = ResultSet{
                    .allocator = self.allocator,
                    .connection = self,
                    .rows = try cloneCachedRows(self.allocator, cached_result.rows),
                    .current_index = 0,
                    .column_names = try self.extractColumnNamesFromSql(sql),
                };
                try self.finishStatementAccess(acquired, &parsed.statement);
                return result;
            }
        }

        // Try to get cached plan first
        var plan_ptr: *planner.ExecutionPlan = undefined;
        var owns_plan = false;

        if (self.plan_cache) |*cache| {
            if (cache.get(sql)) |cached_plan| {
                plan_ptr = cached_plan;
            } else {
                // Cache miss - create new plan and cache it
                var query_planner = planner.Planner.initWithContext(self.allocator, &self.aggregate_function_names, self.planner_table_stats.items, self.planner_index_stats.items);
                const new_plan = try query_planner.plan(&parsed.statement);
                try cache.put(sql, new_plan);
                // Get pointer from cache (cache now owns the plan)
                plan_ptr = cache.get(sql).?;
            }
        } else {
            // No cache - create plan that we own
            var query_planner = planner.Planner.initWithContext(self.allocator, &self.aggregate_function_names, self.planner_table_stats.items, self.planner_index_stats.items);
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

        if (auto_transaction) {
            try self.commitTransaction();
        } else {
            try self.finishStatementAccess(acquired, &parsed.statement);
        }

        return result_set;
    }

    /// Execute SQL and return single row (or null)
    pub fn queryRow(self: *Self, sql: []const u8) !?Row {
        var result_set = try self.query(sql);
        defer result_set.deinit();

        return result_set.next();
    }

    pub fn openCursor(self: *Self, sql: []const u8) !Cursor {
        const shared_storage_acquired = self.acquireSharedStorageLock();
        defer if (shared_storage_acquired and !self.in_transaction) self.releaseSharedStorageLock();
        try self.checkStatementSize(sql);
        var parsed = try parser.parse(self.allocator, sql);
        defer parsed.deinit();
        try self.ensureStatementAllowed(&parsed.statement);

        if (self.is_memory and self.shared_storage_mutex == null) if (try self.openSimpleTableCursor(&parsed.statement, null)) |cursor| {
            return cursor;
        };

        return Cursor{
            .mode = .{ .materialized = try self.query(sql) },
        };
    }

    fn openSimpleTableCursor(self: *Self, statement: *const ast.Statement, parameters: ?[]const storage.Value) !?Cursor {
        const select = switch (statement.*) {
            .Select => |select| select,
            else => return null,
        };
        if (select.table == null or select.joins.len != 0 or select.group_by != null or select.having != null or select.order_by != null or select.limit != null or select.offset != null or select.distinct) {
            return null;
        }
        const table_name = select.table.?;
        const table = self.storage_engine.getTable(table_name) orelse return error.TableNotFound;
        const projection = try self.buildSimpleCursorProjection(table, select.columns);
        errdefer projection.deinit(self.allocator);
        var predicate = self.buildSimpleCursorPredicate(table, select.where_clause, parameters) catch |err| switch (err) {
            error.UnsupportedCursorQuery => return null,
            else => return err,
        };
        errdefer if (predicate) |*pred| pred.deinit(self.allocator);

        var column_names = try self.allocator.alloc([]const u8, projection.column_indices.len);
        var column_names_loaded: usize = 0;
        errdefer {
            for (column_names[0..column_names_loaded]) |name| self.allocator.free(name);
            self.allocator.free(column_names);
        }
        for (projection.column_indices, 0..) |column_index, i| {
            column_names[i] = try self.allocator.dupe(u8, table.schema.columns[column_index].name);
            column_names_loaded = i + 1;
        }

        const owned_table_name = try self.allocator.dupe(u8, table_name);
        errdefer self.allocator.free(owned_table_name);

        return Cursor{
            .mode = .{ .simple_table_scan = .{
                .allocator = self.allocator,
                .connection = self,
                .table_name = owned_table_name,
                .column_names = column_names,
                .column_indices = projection.column_indices,
                .predicate = predicate,
                .next_key = 0,
                .row_count_snapshot = table.row_count,
                .rows_seen = 0,
            } },
        };
    }

    const CursorProjection = struct {
        column_indices: []usize,

        fn deinit(self: CursorProjection, allocator: std.mem.Allocator) void {
            allocator.free(self.column_indices);
        }
    };

    fn buildSimpleCursorProjection(self: *Self, table: *storage.Table, columns: []const ast.Column) !CursorProjection {
        if (columns.len == 1 and std.mem.eql(u8, columns[0].name, "*")) {
            const indices = try self.allocator.alloc(usize, table.schema.columns.len);
            for (indices, 0..) |*index, i| index.* = i;
            return .{ .column_indices = indices };
        }

        var indices = try self.allocator.alloc(usize, columns.len);
        errdefer self.allocator.free(indices);
        for (columns, 0..) |column, i| {
            const name = switch (column.expression) {
                .Simple => |simple| simple,
                else => return error.UnsupportedCursorQuery,
            };
            indices[i] = table.getColumnIndex(name) orelse return error.ColumnNotFound;
        }
        return .{ .column_indices = indices };
    }

    const SimpleCursorPredicate = struct {
        column_index: usize,
        operator: ast.ComparisonOperator,
        value: storage.Value,

        fn deinit(self: *SimpleCursorPredicate, allocator: std.mem.Allocator) void {
            self.value.deinit(allocator);
        }
    };

    fn buildSimpleCursorPredicate(self: *Self, table: *storage.Table, maybe_where: ?ast.WhereClause, parameters: ?[]const storage.Value) !?SimpleCursorPredicate {
        const where_clause = maybe_where orelse return null;
        const comparison = switch (where_clause.condition) {
            .Comparison => |comparison| comparison,
            else => return error.UnsupportedCursorQuery,
        };
        return try self.buildComparisonCursorPredicate(table, comparison, parameters);
    }

    fn buildComparisonCursorPredicate(self: *Self, table: *storage.Table, comparison: ast.ComparisonCondition, parameters: ?[]const storage.Value) !SimpleCursorPredicate {
        if (comparison.extra != null) return error.UnsupportedCursorQuery;
        const operator = switch (comparison.operator) {
            .Equal, .NotEqual, .LessThan, .LessThanOrEqual, .GreaterThan, .GreaterThanOrEqual => comparison.operator,
            else => return error.UnsupportedCursorQuery,
        };

        if (comparison.left == .Column) {
            const column_index = table.getColumnIndex(comparison.left.Column) orelse return error.ColumnNotFound;
            return .{
                .column_index = column_index,
                .operator = operator,
                .value = try self.cursorPredicateValue(comparison.right, parameters),
            };
        }

        if (comparison.right == .Column) {
            const column_index = table.getColumnIndex(comparison.right.Column) orelse return error.ColumnNotFound;
            return .{
                .column_index = column_index,
                .operator = invertComparisonOperator(operator),
                .value = try self.cursorPredicateValue(comparison.left, parameters),
            };
        }

        return error.UnsupportedCursorQuery;
    }

    fn cursorPredicateValue(self: *Self, expression: ast.Expression, parameters: ?[]const storage.Value) !storage.Value {
        return switch (expression) {
            .Literal => |literal| try self.storageValueFromAstValue(literal),
            .Parameter => |index| blk: {
                const params = parameters orelse return error.UnsupportedCursorQuery;
                if (index >= params.len) return error.InvalidParameterIndex;
                break :blk try params[index].clone(self.allocator);
            },
            else => error.UnsupportedCursorQuery,
        };
    }

    fn storageValueFromAstValue(self: *Self, value: ast.Value) !storage.Value {
        return switch (value) {
            .Integer => |v| storage.Value{ .Integer = v },
            .Text => |v| storage.Value{ .Text = try self.allocator.dupe(u8, v) },
            .Real => |v| storage.Value{ .Real = v },
            .Blob => |v| storage.Value{ .Blob = try self.allocator.dupe(u8, v) },
            .Null => storage.Value.Null,
            else => error.UnsupportedCursorQuery,
        };
    }

    fn invertComparisonOperator(operator: ast.ComparisonOperator) ast.ComparisonOperator {
        return switch (operator) {
            .LessThan => .GreaterThan,
            .LessThanOrEqual => .GreaterThanOrEqual,
            .GreaterThan => .LessThan,
            .GreaterThanOrEqual => .LessThanOrEqual,
            else => operator,
        };
    }

    /// Execute SQL statement and return affected row count
    pub fn exec(self: *Self, sql: []const u8) !u32 {
        self.beginOperation();
        defer self.endOperation();
        try self.checkStatementSize(sql);
        try self.checkOperation();

        // Parse the SQL
        var parsed = try parser.parse(self.allocator, sql);
        defer parsed.deinit();
        try self.checkOperation();
        try self.ensureStatementAllowed(&parsed.statement);

        // Create execution plan
        var query_planner = planner.Planner.initWithContext(self.allocator, &self.aggregate_function_names, self.planner_table_stats.items, self.planner_index_stats.items);
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
            .Pragma => |pragma| {
                var names = try self.allocator.alloc([]const u8, 1);
                if (std.ascii.eqlIgnoreCase(pragma.name, "integrity_check")) {
                    names[0] = try self.allocator.dupe(u8, "integrity_check");
                } else if (std.ascii.eqlIgnoreCase(pragma.name, "user_version")) {
                    names[0] = try self.allocator.dupe(u8, "user_version");
                } else if (std.ascii.eqlIgnoreCase(pragma.name, "schema_version")) {
                    names[0] = try self.allocator.dupe(u8, "schema_version");
                } else {
                    names[0] = try self.allocator.dupe(u8, pragma.name);
                }
                return names;
            },
            .Vacuum => {
                var names = try self.allocator.alloc([]const u8, 1);
                names[0] = try self.allocator.dupe(u8, "vacuum");
                return names;
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
        self.closing = true;
        self.ensureSharedStorageLock();
        const close_lock_mode: file_io.Lock = if (self.isReadOnly()) .shared else .exclusive;
        self.lockDatabaseForClose(close_lock_mode) catch |err| {
            first_error = err;
        };

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
        self.clearPlannerStats();
        self.planner_table_stats.deinit(self.allocator);
        self.planner_index_stats.deinit(self.allocator);
        self.deinitFunctionRegistries();

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

        // A clean connection must not checkpoint a WAL that may belong to a
        // different active writer. This connection's own unfinished
        // transaction was rolled back above.
        if (self.wal) |w| {
            self.releaseWriterLock();
            w.deinit();
        }

        // Every successful mutating statement now persists before releasing its
        // lock. The final flush remains fallible so close reports durability
        // errors without rewriting potentially stale catalog metadata.
        if (self.owns_storage) {
            self.storage_engine.pager.flush() catch |err| {
                if (first_error == null) first_error = err;
            };
            self.storage_engine.deinit();
        }

        if (self.path) |p| {
            self.allocator.free(p);
        }
        self.releaseDatabaseLock();
        if (self.database_lock_file) |file| file_io.close(file);
        self.releaseSharedStorageLock();
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

    fn deinitFunctionRegistries(self: *Self) void {
        var scalar_iter = self.scalar_functions.iterator();
        while (scalar_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.scalar_functions.deinit();

        var aggregate_iter = self.aggregate_functions.iterator();
        while (aggregate_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.aggregate_functions.deinit();

        var aggregate_name_iter = self.aggregate_function_names.iterator();
        while (aggregate_name_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.aggregate_function_names.deinit();
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
        try self.ensureWritable();
        try self.checkOperation();

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
        try self.ensureWritable();

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

    /// Open bounded incremental access to one BLOB selected by a stable key.
    /// Writes replace bytes in place and never resize the value.
    pub fn openBlob(self: *Self, table_name: []const u8, column_name: []const u8, key_column: []const u8, key: storage.Value, writable: bool) !*BlobHandle {
        if (writable) try self.ensureWritable();
        if (!isSimpleIdentifier(table_name) or !isSimpleIdentifier(column_name) or !isSimpleIdentifier(key_column)) {
            return error.InvalidBlobIdentifier;
        }

        const table = self.storage_engine.getTable(table_name) orelse return error.TableNotFound;
        const column_index = table.getColumnIndex(column_name) orelse return error.ColumnNotFound;
        _ = table.getColumnIndex(key_column) orelse return error.ColumnNotFound;
        if (table.schema.columns[column_index].data_type != .Blob) return error.TypeMismatch;

        const select_sql = try std.fmt.allocPrint(self.allocator, "SELECT {s} FROM {s} WHERE {s} = ?", .{ column_name, table_name, key_column });
        errdefer self.allocator.free(select_sql);
        const update_sql = try std.fmt.allocPrint(self.allocator, "UPDATE {s} SET {s} = ? WHERE {s} = ?", .{ table_name, column_name, key_column });
        errdefer self.allocator.free(update_sql);

        const handle = try self.allocator.create(BlobHandle);
        errdefer self.allocator.destroy(handle);
        handle.* = .{
            .allocator = self.allocator,
            .connection = self,
            .select_sql = select_sql,
            .update_sql = update_sql,
            .key = try key.clone(self.allocator),
            .writable = writable,
        };
        errdefer handle.key.deinit(self.allocator);

        const initial = try handle.load();
        defer self.allocator.free(initial);
        return handle;
    }

    fn isSimpleIdentifier(name: []const u8) bool {
        if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
        for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
        return true;
    }
};

pub const ConnectionInfo = struct {
    is_memory: bool,
    path: ?[]const u8,
    has_wal: bool,
};

/// Bounded BLOB slice handle. Each operation currently materializes the full
/// value; writes use the current transaction or an atomic autocommit statement.
pub const BlobHandle = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    select_sql: []const u8,
    update_sql: []const u8,
    key: storage.Value,
    writable: bool,

    const Self = @This();

    fn load(self: *Self) ![]u8 {
        var stmt = try self.connection.prepare(self.select_sql);
        defer stmt.deinit();
        try stmt.bindParameter(0, self.key);
        var result = try stmt.execute();
        defer result.deinit();
        if (result.rows.items.len == 0) return error.BlobRowNotFound;
        if (result.rows.items.len != 1 or result.rows.items[0].values.len != 1) return error.BlobKeyNotUnique;
        return switch (result.rows.items[0].values[0]) {
            .Blob => |bytes| try self.allocator.dupe(u8, bytes),
            else => error.TypeMismatch,
        };
    }

    pub fn size(self: *Self) !usize {
        const bytes = try self.load();
        defer self.allocator.free(bytes);
        return bytes.len;
    }

    pub fn read(self: *Self, offset: usize, destination: []u8) !usize {
        const bytes = try self.load();
        defer self.allocator.free(bytes);
        if (offset > bytes.len) return error.BlobRange;
        const count = @min(destination.len, bytes.len - offset);
        @memcpy(destination[0..count], bytes[offset..][0..count]);
        return count;
    }

    pub fn write(self: *Self, offset: usize, source: []const u8) !void {
        if (!self.writable) return error.ReadOnlyBlob;
        var bytes = try self.load();
        defer self.allocator.free(bytes);
        const end = std.math.add(usize, offset, source.len) catch return error.BlobRange;
        if (offset > bytes.len or end > bytes.len) return error.BlobRange;
        @memcpy(bytes[offset..end], source);

        var stmt = try self.connection.prepare(self.update_sql);
        defer stmt.deinit();
        try stmt.bindParameter(0, .{ .Blob = bytes });
        try stmt.bindParameter(1, self.key);
        var result = try stmt.execute();
        defer result.deinit();
        if (result.affected_rows != 1) return error.BlobKeyNotUnique;
    }

    pub fn deinit(self: *Self) void {
        self.key.deinit(self.allocator);
        self.allocator.free(self.select_sql);
        self.allocator.free(self.update_sql);
        self.allocator.destroy(self);
    }
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

pub const Cursor = struct {
    mode: union(enum) {
        materialized: ResultSet,
        simple_table_scan: SimpleTableScanCursor,
    },

    const Self = @This();

    pub fn next(self: *Self) ?Row {
        return switch (self.mode) {
            .materialized => |*result_set| result_set.next(),
            .simple_table_scan => |*scan| scan.next(),
        };
    }

    pub fn reset(self: *Self) void {
        switch (self.mode) {
            .materialized => |*result_set| result_set.reset(),
            .simple_table_scan => |*scan| scan.reset(),
        }
    }

    pub fn columnCount(self: *Self) usize {
        return switch (self.mode) {
            .materialized => |*result_set| result_set.columnCount(),
            .simple_table_scan => |*scan| scan.column_names.len,
        };
    }

    pub fn columnName(self: *Self, index: usize) ?[]const u8 {
        return switch (self.mode) {
            .materialized => |*result_set| result_set.columnName(index),
            .simple_table_scan => |*scan| if (index < scan.column_names.len) scan.column_names[index] else null,
        };
    }

    pub fn rowsSeen(self: *const Self) usize {
        return switch (self.mode) {
            .materialized => |*result_set| result_set.current_index,
            .simple_table_scan => |*scan| scan.rows_seen,
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.mode) {
            .materialized => |*result_set| result_set.deinit(),
            .simple_table_scan => |*scan| scan.deinit(),
        }
    }
};

const SimpleTableScanCursor = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    table_name: []const u8,
    column_names: [][]const u8,
    column_indices: []usize,
    predicate: ?Connection.SimpleCursorPredicate,
    next_key: u64,
    row_count_snapshot: u64,
    rows_seen: usize,

    fn next(self: *SimpleTableScanCursor) ?Row {
        const table = self.connection.storage_engine.getTable(self.table_name) orelse return null;
        while (self.next_key < self.row_count_snapshot) {
            const key = self.next_key;
            self.next_key += 1;
            const storage_row = table.getRow(@intCast(key)) catch return null;
            if (storage_row) |row| {
                defer {
                    for (row.values) |value| value.deinit(self.allocator);
                    self.allocator.free(row.values);
                }

                if (!self.rowMatchesPredicate(row.values)) continue;

                const names = self.cloneColumnNames() catch {
                    return null;
                };
                const values = self.cloneProjectedValues(row.values) catch {
                    for (names) |name| self.allocator.free(name);
                    self.allocator.free(names);
                    return null;
                };
                self.rows_seen += 1;
                return Row{
                    .allocator = self.allocator,
                    .values = values,
                    .column_names = names,
                };
            }
        }
        return null;
    }

    fn reset(self: *SimpleTableScanCursor) void {
        self.next_key = 0;
        self.rows_seen = 0;
    }

    fn cloneColumnNames(self: *SimpleTableScanCursor) ![][]const u8 {
        var names = try self.allocator.alloc([]const u8, self.column_names.len);
        var loaded: usize = 0;
        errdefer {
            for (names[0..loaded]) |name| self.allocator.free(name);
            self.allocator.free(names);
        }
        for (self.column_names, 0..) |name, i| {
            names[i] = try self.allocator.dupe(u8, name);
            loaded = i + 1;
        }
        return names;
    }

    fn cloneProjectedValues(self: *SimpleTableScanCursor, source_values: []const storage.Value) ![]storage.Value {
        var values = try self.allocator.alloc(storage.Value, self.column_indices.len);
        var loaded: usize = 0;
        errdefer {
            for (values[0..loaded]) |value| value.deinit(self.allocator);
            self.allocator.free(values);
        }
        for (self.column_indices, 0..) |column_index, i| {
            values[i] = try source_values[column_index].clone(self.allocator);
            loaded = i + 1;
        }
        return values;
    }

    fn rowMatchesPredicate(self: *SimpleTableScanCursor, values: []const storage.Value) bool {
        const predicate = self.predicate orelse return true;
        if (predicate.column_index >= values.len) return false;
        const order = compareCursorValues(values[predicate.column_index], predicate.value);
        return switch (predicate.operator) {
            .Equal => order == .eq,
            .NotEqual => order != .eq,
            .LessThan => order == .lt,
            .LessThanOrEqual => order == .lt or order == .eq,
            .GreaterThan => order == .gt,
            .GreaterThanOrEqual => order == .gt or order == .eq,
            else => false,
        };
    }

    fn deinit(self: *SimpleTableScanCursor) void {
        self.allocator.free(self.table_name);
        for (self.column_names) |name| self.allocator.free(name);
        self.allocator.free(self.column_names);
        self.allocator.free(self.column_indices);
        if (self.predicate) |*predicate| predicate.deinit(self.allocator);
    }
};

fn compareCursorValues(left: storage.Value, right: storage.Value) std.math.Order {
    return switch (left) {
        .Integer => |l| switch (right) {
            .Integer => |r| std.math.order(l, r),
            .Real => |r| std.math.order(@as(f64, @floatFromInt(l)), r),
            else => .gt,
        },
        .Real => |l| switch (right) {
            .Integer => |r| std.math.order(l, @as(f64, @floatFromInt(r))),
            .Real => |r| std.math.order(l, r),
            else => .gt,
        },
        .Text => |l| switch (right) {
            .Text => |r| std.mem.order(u8, l, r),
            else => .gt,
        },
        .Null => switch (right) {
            .Null => .eq,
            else => .lt,
        },
        else => .gt,
    };
}

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
    schema_version_at_prepare: u32,

    const Self = @This();

    /// Prepare a SQL statement
    pub fn prepare(allocator: std.mem.Allocator, connection: *Connection, sql: []const u8) !*Self {
        const shared_storage_acquired = connection.acquireSharedStorageLock();
        defer if (shared_storage_acquired and !connection.in_transaction) connection.releaseSharedStorageLock();
        connection.beginOperation();
        defer connection.endOperation();
        try connection.checkStatementSize(sql);
        try connection.checkOperation();

        var stmt = try allocator.create(Self);
        stmt.allocator = allocator;
        stmt.connection = connection;
        stmt.sql = try allocator.dupe(u8, sql);

        // Parse the SQL
        var parsed_result = try parser.parse(allocator, sql);
        stmt.parsed_statement = parsed_result.statement;
        parsed_result.parser.deinit(); // Clean up parser resources
        try connection.checkOperation();
        connection.ensureStatementAllowed(&stmt.parsed_statement) catch |err| {
            stmt.parsed_statement.deinit(allocator);
            allocator.free(stmt.sql);
            allocator.destroy(stmt);
            return err;
        };

        const acquired = try connection.beginStatementAccess(&stmt.parsed_statement);
        defer connection.abortStatementAccess(acquired);

        // Create execution plan
        var query_planner = planner.Planner.initWithContext(allocator, &connection.aggregate_function_names, connection.planner_table_stats.items, connection.planner_index_stats.items);
        stmt.execution_plan = try query_planner.plan(&stmt.parsed_statement);
        try connection.checkOperation();
        stmt.schema_version_at_prepare = connection.getSchemaVersion();

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
        const shared_storage_acquired = self.connection.acquireSharedStorageLock();
        defer if (shared_storage_acquired and !self.connection.in_transaction) self.connection.releaseSharedStorageLock();
        self.connection.beginOperation();
        defer self.connection.endOperation();
        try self.connection.checkOperation();
        try self.connection.ensureStatementAllowed(&self.parsed_statement);
        const auto_transaction = !self.connection.in_transaction and Connection.statementNeedsAutoTransaction(self.parsed_statement);
        const acquired = if (auto_transaction) blk: {
            try self.connection.beginTransaction();
            break :blk false;
        } else try self.connection.beginStatementAccess(&self.parsed_statement);
        errdefer if (auto_transaction and self.connection.in_transaction) {
            self.connection.rollbackTransaction() catch |rollback_err| {
                std.log.err("prepared autocommit rollback failed: {s}", .{@errorName(rollback_err)});
            };
        } else self.connection.abortStatementAccess(acquired);
        try self.ensureSchemaCurrent(self.connection);
        var virtual_machine = vm.VirtualMachine.init(self.connection.allocator, self.connection);
        defer virtual_machine.deinitVM();
        const result = try virtual_machine.executeWithParameters(&self.execution_plan, self.parameters);
        if (auto_transaction) {
            try self.connection.commitTransaction();
        } else {
            try self.connection.finishStatementAccess(acquired, &self.parsed_statement);
        }
        return result;
    }

    /// Execute the prepared statement with explicit connection (for backwards compatibility)
    pub fn executeWithConnection(self: *Self, connection: *Connection) !vm.ExecutionResult {
        const shared_storage_acquired = connection.acquireSharedStorageLock();
        defer if (shared_storage_acquired and !connection.in_transaction) connection.releaseSharedStorageLock();
        connection.beginOperation();
        defer connection.endOperation();
        try connection.checkOperation();
        try connection.ensureStatementAllowed(&self.parsed_statement);
        const auto_transaction = !connection.in_transaction and Connection.statementNeedsAutoTransaction(self.parsed_statement);
        const acquired = if (auto_transaction) blk: {
            try connection.beginTransaction();
            break :blk false;
        } else try connection.beginStatementAccess(&self.parsed_statement);
        errdefer if (auto_transaction and connection.in_transaction) {
            connection.rollbackTransaction() catch |rollback_err| {
                std.log.err("prepared autocommit rollback failed: {s}", .{@errorName(rollback_err)});
            };
        } else connection.abortStatementAccess(acquired);
        try self.ensureSchemaCurrent(connection);
        var virtual_machine = vm.VirtualMachine.init(connection.allocator, connection);
        defer virtual_machine.deinitVM();
        const result = try virtual_machine.executeWithParameters(&self.execution_plan, self.parameters);
        if (auto_transaction) {
            try connection.commitTransaction();
        } else {
            try connection.finishStatementAccess(acquired, &self.parsed_statement);
        }
        return result;
    }

    pub fn openCursor(self: *Self) !Cursor {
        const shared_storage_acquired = self.connection.acquireSharedStorageLock();
        defer if (shared_storage_acquired and !self.connection.in_transaction) self.connection.releaseSharedStorageLock();
        self.connection.beginOperation();
        defer self.connection.endOperation();
        try self.connection.checkOperation();
        try self.connection.ensureStatementAllowed(&self.parsed_statement);
        const auto_transaction = !self.connection.in_transaction and Connection.statementNeedsAutoTransaction(self.parsed_statement);
        const acquired = if (auto_transaction) blk: {
            try self.connection.beginTransaction();
            break :blk false;
        } else try self.connection.beginStatementAccess(&self.parsed_statement);
        errdefer if (auto_transaction and self.connection.in_transaction) {
            self.connection.rollbackTransaction() catch |rollback_err| {
                std.log.err("prepared cursor autocommit rollback failed: {s}", .{@errorName(rollback_err)});
            };
        } else self.connection.abortStatementAccess(acquired);
        try self.ensureSchemaCurrent(self.connection);

        if (self.connection.is_memory and self.connection.shared_storage_mutex == null) if (try self.connection.openSimpleTableCursor(&self.parsed_statement, self.parameters)) |cursor| {
            return cursor;
        };

        var virtual_machine = vm.VirtualMachine.init(self.connection.allocator, self.connection);
        defer virtual_machine.deinitVM();
        var result = try virtual_machine.executeWithParameters(&self.execution_plan, self.parameters);
        defer result.deinit();

        var result_set = ResultSet{
            .allocator = self.connection.allocator,
            .connection = self.connection,
            .rows = .empty,
            .current_index = 0,
            .column_names = try self.connection.extractColumnNames(&self.parsed_statement),
        };
        result_set.rows = result.rows;
        result.rows = .empty;

        if (auto_transaction) {
            try self.connection.commitTransaction();
        } else {
            try self.connection.finishStatementAccess(acquired, &self.parsed_statement);
        }

        return Cursor{ .mode = .{ .materialized = result_set } };
    }

    pub fn isExpired(self: *const Self) bool {
        return self.connection.getSchemaVersion() != self.schema_version_at_prepare;
    }

    fn ensureSchemaCurrent(self: *const Self, connection: *Connection) !void {
        if (connection.getSchemaVersion() != self.schema_version_at_prepare) {
            return error.PreparedStatementExpired;
        }
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

test "prepared DML can be rebound without reset" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE rebound (id INTEGER PRIMARY KEY, value TEXT)");
    var insert = try conn.prepare("INSERT INTO rebound VALUES (?, ?)");
    defer insert.deinit();
    for (0..8) |i| {
        try insert.bind(0, @as(i64, @intCast(i)));
        try insert.bind(1, @as([]const u8, "value"));
        var result = try insert.execute();
        result.deinit();
    }

    var delete = try conn.prepare("DELETE FROM rebound WHERE id = ?");
    defer delete.deinit();
    for (0..6) |i| {
        try delete.bind(0, @as(i64, @intCast(i)));
        var result = try delete.execute();
        defer result.deinit();
        try std.testing.expectEqual(@as(u32, 1), result.affected_rows);
    }

    var rows = try conn.query("SELECT id FROM rebound ORDER BY id");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.count());
}

test "bounded blob slice access enforces bounds and transaction semantics" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE blob_items (id INTEGER PRIMARY KEY, payload BLOB)");
    var insert = try conn.prepare("INSERT INTO blob_items VALUES (?, ?)");
    defer insert.deinit();
    try insert.bind(0, @as(i64, 7));
    try insert.bindParameter(1, .{ .Blob = "abcdefgh" });
    var inserted = try insert.execute();
    inserted.deinit();

    const blob = try conn.openBlob("blob_items", "payload", "id", .{ .Integer = 7 }, true);
    defer blob.deinit();
    try std.testing.expectEqual(@as(usize, 8), try blob.size());
    var buffer: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try blob.read(2, &buffer));
    try std.testing.expectEqualStrings("cde", &buffer);
    try std.testing.expectError(error.BlobRange, blob.write(7, "XX"));

    try conn.begin();
    try blob.write(2, "XY");
    try conn.rollback();
    var after_rollback: [8]u8 = undefined;
    _ = try blob.read(0, &after_rollback);
    try std.testing.expectEqualStrings("abcdefgh", &after_rollback);

    try blob.write(2, "XY");
    var after_commit: [8]u8 = undefined;
    _ = try blob.read(0, &after_commit);
    try std.testing.expectEqualStrings("abXYefgh", &after_commit);

    const read_only = try conn.openBlob("blob_items", "payload", "id", .{ .Integer = 7 }, false);
    defer read_only.deinit();
    try std.testing.expectError(error.ReadOnlyBlob, read_only.write(0, "z"));
}

test "prepared statement expires after schema change" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE prep_expire (id INTEGER)");
    var stmt = try conn.prepare("SELECT * FROM prep_expire");
    defer stmt.deinit();

    try std.testing.expect(!stmt.isExpired());
    try conn.execute("CREATE TABLE prep_expire_other (id INTEGER)");
    try std.testing.expect(stmt.isExpired());
    try std.testing.expectError(error.PreparedStatementExpired, stmt.execute());
}

test "cursor iterates query results" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE cursor_items (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO cursor_items VALUES (1, 'one')");
    try conn.execute("INSERT INTO cursor_items VALUES (2, 'two')");

    var cursor = try conn.openCursor("SELECT id, name FROM cursor_items ORDER BY id");
    defer cursor.deinit();

    try std.testing.expectEqual(@as(usize, 2), cursor.columnCount());
    try std.testing.expectEqualStrings("id", cursor.columnName(0).?);

    var first = cursor.next().?;
    defer first.deinit();
    try std.testing.expectEqual(@as(i64, 1), first.getInt(0).?);

    var second = cursor.next().?;
    defer second.deinit();
    try std.testing.expectEqualStrings("two", second.getText(1).?);
    try std.testing.expect(cursor.next() == null);
}

test "cursor incrementally scans projected simple columns" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE cursor_projected (id INTEGER, name TEXT, ignored TEXT)");
    try conn.execute("INSERT INTO cursor_projected VALUES (1, 'one', 'x')");
    try conn.execute("INSERT INTO cursor_projected VALUES (2, 'two', 'y')");

    var cursor = try conn.openCursor("SELECT name, id FROM cursor_projected");
    defer cursor.deinit();

    try std.testing.expectEqual(@as(usize, 2), cursor.columnCount());
    try std.testing.expectEqualStrings("name", cursor.columnName(0).?);
    try std.testing.expectEqualStrings("id", cursor.columnName(1).?);

    var first = cursor.next().?;
    defer first.deinit();
    try std.testing.expectEqualStrings("one", first.getText(0).?);
    try std.testing.expectEqual(@as(i64, 1), first.getInt(1).?);

    var second = cursor.next().?;
    defer second.deinit();
    try std.testing.expectEqualStrings("two", second.getText(0).?);
    try std.testing.expectEqual(@as(i64, 2), second.getInt(1).?);
    try std.testing.expect(cursor.next() == null);
    try std.testing.expectEqual(@as(usize, 2), cursor.rowsSeen());
}

test "cursor incrementally scans simple where predicate" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE cursor_filtered (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO cursor_filtered VALUES (1, 'one')");
    try conn.execute("INSERT INTO cursor_filtered VALUES (2, 'two')");
    try conn.execute("INSERT INTO cursor_filtered VALUES (3, 'three')");

    var cursor = try conn.openCursor("SELECT name FROM cursor_filtered WHERE id >= 2");
    defer cursor.deinit();

    var first = cursor.next().?;
    defer first.deinit();
    try std.testing.expectEqualStrings("two", first.getText(0).?);

    var second = cursor.next().?;
    defer second.deinit();
    try std.testing.expectEqualStrings("three", second.getText(0).?);
    try std.testing.expect(cursor.next() == null);
    try std.testing.expectEqual(@as(usize, 2), cursor.rowsSeen());
}

test "prepared statement opens bound cursor" {
    const allocator = std.testing.allocator;
    var conn = try Connection.openMemory(allocator);
    defer conn.deinit();

    try conn.execute("CREATE TABLE prepared_cursor_items (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO prepared_cursor_items VALUES (1, 'one')");
    try conn.execute("INSERT INTO prepared_cursor_items VALUES (2, 'two')");
    try conn.execute("INSERT INTO prepared_cursor_items VALUES (3, 'three')");

    var stmt = try conn.prepare("SELECT name, id FROM prepared_cursor_items WHERE id > ?");
    defer stmt.deinit();
    try stmt.bind(0, @as(i64, 1));

    var cursor = try stmt.openCursor();
    defer cursor.deinit();

    var first = cursor.next().?;
    defer first.deinit();
    try std.testing.expectEqualStrings("two", first.getText(0).?);
    try std.testing.expectEqual(@as(i64, 2), first.getInt(1).?);

    var second = cursor.next().?;
    defer second.deinit();
    try std.testing.expectEqualStrings("three", second.getText(0).?);
    try std.testing.expectEqual(@as(i64, 3), second.getInt(1).?);
    try std.testing.expect(cursor.next() == null);
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
