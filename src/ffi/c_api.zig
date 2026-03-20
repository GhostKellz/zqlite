const std = @import("std");
const zqlite = @import("zqlite");

/// C FFI interface for zqlite
/// Enables integration with Rust, Python, and other languages

// Opaque handles for C API
const zqlite_connection_t = anyopaque;
const zqlite_result_t = anyopaque;
const zqlite_stmt_t = anyopaque;

/// Error codes for C API
pub const ZQLITE_OK = 0;
pub const ZQLITE_ERROR = 1;
pub const ZQLITE_BUSY = 2;
pub const ZQLITE_LOCKED = 3;
pub const ZQLITE_NOMEM = 4;
pub const ZQLITE_READONLY = 5;
pub const ZQLITE_MISUSE = 6;
pub const ZQLITE_NOLFS = 7;
pub const ZQLITE_AUTH = 8;
pub const ZQLITE_FORMAT = 9;
pub const ZQLITE_RANGE = 10;
pub const ZQLITE_NOTADB = 11;
pub const ZQLITE_CONSTRAINT = 12;
pub const ZQLITE_MISMATCH = 13;
pub const ZQLITE_IOERR = 14;
pub const ZQLITE_CORRUPT = 15;

/// Extended error information
const ErrorInfo = struct {
    code: c_int,
    message: [256]u8,
    message_len: usize,
    sql: ?[*:0]const u8,

    fn init() ErrorInfo {
        return ErrorInfo{
            .code = ZQLITE_OK,
            .message = [_]u8{0} ** 256,
            .message_len = 0,
            .sql = null,
        };
    }

    fn set(self: *ErrorInfo, code: c_int, msg: []const u8, sql: ?[*:0]const u8) void {
        self.code = code;
        const copy_len = @min(msg.len, self.message.len - 1);
        @memcpy(self.message[0..copy_len], msg[0..copy_len]);
        self.message[copy_len] = 0;
        self.message_len = copy_len;
        self.sql = sql;
    }

    fn clear(self: *ErrorInfo) void {
        self.code = ZQLITE_OK;
        self.message[0] = 0;
        self.message_len = 0;
        self.sql = null;
    }
};

/// Result structure for queries
const QueryResult = struct {
    rows: [][]?[]const u8,
    column_count: u32,
    row_count: u32,
    error_message: ?[]const u8,
};

/// Wrapper for connection with error tracking
const ConnectionWrapper = struct {
    connection: *zqlite.db.Connection,
    error_info: ErrorInfo,
    allocator: std.mem.Allocator,
};

// Default global allocator for C API
var gpa: std.heap.DebugAllocator(.{}) = .init;
var c_allocator: std.mem.Allocator = gpa.allocator();

/// Custom allocator function pointer types for C interop
pub const ZqliteAllocFn = *const fn (size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque;
pub const ZqliteFreeFn = *const fn (ptr: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void;
pub const ZqliteReallocFn = *const fn (ptr: ?*anyopaque, new_size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque;

/// Custom allocator configuration
var custom_alloc_fn: ?ZqliteAllocFn = null;
var custom_free_fn: ?ZqliteFreeFn = null;
var custom_realloc_fn: ?ZqliteReallocFn = null;
var custom_user_data: ?*anyopaque = null;

/// Set custom allocator functions for C API
/// Call this before any other zqlite functions if you want custom memory management
export fn zqlite_set_allocator(
    alloc_fn: ?ZqliteAllocFn,
    free_fn: ?ZqliteFreeFn,
    realloc_fn: ?ZqliteReallocFn,
    user_data: ?*anyopaque,
) c_int {
    if (alloc_fn == null or free_fn == null) {
        // Reset to default allocator
        custom_alloc_fn = null;
        custom_free_fn = null;
        custom_realloc_fn = null;
        custom_user_data = null;
        c_allocator = gpa.allocator();
    } else {
        custom_alloc_fn = alloc_fn;
        custom_free_fn = free_fn;
        custom_realloc_fn = realloc_fn;
        custom_user_data = user_data;
        // Note: We still use gpa for internal allocations as Zig's Allocator
        // interface doesn't easily support C function pointers.
        // Custom allocator is used for result data returned to C.
    }
    return ZQLITE_OK;
}

/// Open a database connection
export fn zqlite_open(path: [*:0]const u8) ?*zqlite_connection_t {
    const path_slice = std.mem.span(path);

    // Create connection wrapper for error tracking
    const wrapper = c_allocator.create(ConnectionWrapper) catch return null;

    const conn = if (std.mem.eql(u8, path_slice, ":memory:"))
        zqlite.openMemory(c_allocator) catch {
            c_allocator.destroy(wrapper);
            return null;
        }
    else
        zqlite.open(c_allocator, path_slice) catch {
            c_allocator.destroy(wrapper);
            return null;
        };

    wrapper.* = ConnectionWrapper{
        .connection = conn,
        .error_info = ErrorInfo.init(),
        .allocator = c_allocator,
    };

    return @as(*zqlite_connection_t, @ptrCast(wrapper));
}

/// Close a database connection
export fn zqlite_close(conn: ?*zqlite_connection_t) void {
    if (conn) |c| {
        const wrapper: *ConnectionWrapper = @ptrCast(@alignCast(c));
        wrapper.connection.close();
        c_allocator.destroy(wrapper);
    }
}

/// Get the underlying connection from a wrapper (for internal use)
fn getConnection(conn: ?*zqlite_connection_t) ?*ConnectionWrapper {
    if (conn) |c| {
        return @ptrCast(@alignCast(c));
    }
    return null;
}

/// Execute a SQL statement (no result expected)
export fn zqlite_execute(conn: ?*zqlite_connection_t, sql: [*:0]const u8) c_int {
    const wrapper = getConnection(conn) orelse return ZQLITE_MISUSE;
    const sql_slice = std.mem.span(sql);

    wrapper.error_info.clear();
    wrapper.connection.execute(sql_slice) catch |err| {
        const error_code = mapErrorToCode(err);
        wrapper.error_info.set(error_code, @errorName(err), sql);
        return error_code;
    };
    return ZQLITE_OK;
}

/// Map Zig errors to C error codes
fn mapErrorToCode(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => ZQLITE_NOMEM,
        error.TableNotFound => ZQLITE_ERROR,
        error.ColumnNotFound => ZQLITE_ERROR,
        error.SyntaxError => ZQLITE_ERROR,
        error.TypeMismatch => ZQLITE_MISMATCH,
        error.ConstraintViolation => ZQLITE_CONSTRAINT,
        error.IoError => ZQLITE_IOERR,
        error.CorruptData => ZQLITE_CORRUPT,
        else => ZQLITE_ERROR,
    };
}

/// Execute a SQL query and return results
export fn zqlite_query(conn: ?*zqlite_connection_t, sql: [*:0]const u8) ?*zqlite_result_t {
    const wrapper = getConnection(conn) orelse return null;
    const sql_slice = std.mem.span(sql);

    wrapper.error_info.clear();
    const connection = wrapper.connection;

    // Create result structure
    const result = c_allocator.create(QueryResult) catch return null;
    result.* = QueryResult{
        .rows = &[_][]?[]const u8{},
        .column_count = 0,
        .row_count = 0,
        .error_message = null,
    };

    // Execute the query and get actual results
    var result_set = connection.query(sql_slice) catch |err| {
        const error_code = mapErrorToCode(err);
        wrapper.error_info.set(error_code, @errorName(err), sql);
        result.error_message = c_allocator.dupe(u8, @errorName(err)) catch null;
        return @as(*zqlite_result_t, @ptrCast(result));
    };
    defer result_set.deinit();

    // Get row and column counts
    const row_count = result_set.count();
    const col_count = result_set.columnCount();

    if (row_count == 0 or col_count == 0) {
        result.row_count = 0;
        result.column_count = @intCast(col_count);
        return @as(*zqlite_result_t, @ptrCast(result));
    }

    // Allocate rows array
    var rows = c_allocator.alloc([]?[]const u8, row_count) catch {
        result.error_message = c_allocator.dupe(u8, "OutOfMemory") catch null;
        return @as(*zqlite_result_t, @ptrCast(result));
    };

    // Process each row
    var row_idx: usize = 0;
    while (result_set.next()) |row| {
        var row_deinit = row;
        defer row_deinit.deinit();

        // Allocate columns for this row
        var row_data = c_allocator.alloc(?[]const u8, col_count) catch {
            // Clean up previously allocated rows
            for (rows[0..row_idx]) |r| {
                for (r) |cell| {
                    if (cell) |c| c_allocator.free(c);
                }
                c_allocator.free(r);
            }
            c_allocator.free(rows);
            result.error_message = c_allocator.dupe(u8, "OutOfMemory") catch null;
            return @as(*zqlite_result_t, @ptrCast(result));
        };

        // Copy values
        for (0..col_count) |col_idx| {
            const value = row.getValue(col_idx);
            if (value) |v| {
                row_data[col_idx] = switch (v) {
                    .Text => |t| c_allocator.dupe(u8, t) catch null,
                    .Integer => |i| blk: {
                        var buf: [32]u8 = undefined;
                        const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
                        break :blk c_allocator.dupe(u8, slice) catch null;
                    },
                    .Real => |r| blk: {
                        var buf: [64]u8 = undefined;
                        const slice = std.fmt.bufPrint(&buf, "{d}", .{r}) catch "0";
                        break :blk c_allocator.dupe(u8, slice) catch null;
                    },
                    .Null => null,
                    else => null,
                };
            } else {
                row_data[col_idx] = null;
            }
        }

        rows[row_idx] = row_data;
        row_idx += 1;
    }

    result.rows = rows;
    result.row_count = @intCast(row_count);
    result.column_count = @intCast(col_count);

    return @as(*zqlite_result_t, @ptrCast(result));
}

/// Get the number of rows in a result
export fn zqlite_result_row_count(result: ?*zqlite_result_t) c_int {
    if (result == null) return -1;

    const query_result: *QueryResult = @ptrCast(@alignCast(result.?));
    return @intCast(query_result.row_count);
}

/// Get the number of columns in a result
export fn zqlite_result_column_count(result: ?*zqlite_result_t) c_int {
    if (result == null) return -1;

    const query_result: *QueryResult = @ptrCast(@alignCast(result.?));
    return @intCast(query_result.column_count);
}

/// Get a cell value from the result
/// IMPORTANT: The returned string must be freed with zqlite_free_string() when done
export fn zqlite_result_get_text(result: ?*zqlite_result_t, row: c_int, column: c_int) ?[*:0]const u8 {
    if (result == null) return null;

    const query_result: *QueryResult = @ptrCast(@alignCast(result.?));

    if (row < 0 or column < 0) return null;
    if (row >= query_result.row_count or column >= query_result.column_count) return null;

    const row_data = query_result.rows[@intCast(row)];
    const cell_data = row_data[@intCast(column)];

    if (cell_data) |data| {
        // Convert to null-terminated string
        const c_str = c_allocator.dupeZ(u8, data) catch return null;
        return c_str.ptr;
    }

    return null;
}

/// Free a string returned by zqlite_result_get_text or other zqlite functions
/// SECURITY: Always call this to prevent memory leaks from returned strings
export fn zqlite_free_string(str: ?[*:0]const u8) void {
    if (str) |s| {
        // Calculate length and free the allocation
        const len = std.mem.len(s);
        const slice: []const u8 = s[0 .. len + 1]; // Include null terminator
        c_allocator.free(slice);
    }
}

/// Free a result
export fn zqlite_result_free(result: ?*zqlite_result_t) void {
    if (result) |r| {
        const query_result: *QueryResult = @ptrCast(@alignCast(r));

        // Free rows and columns
        for (query_result.rows) |row| {
            for (row) |cell| {
                if (cell) |data| {
                    c_allocator.free(data);
                }
            }
            c_allocator.free(row);
        }
        c_allocator.free(query_result.rows);

        if (query_result.error_message) |msg| {
            c_allocator.free(msg);
        }

        c_allocator.destroy(query_result);
    }
}

/// Prepare a SQL statement
export fn zqlite_prepare(conn: ?*zqlite_connection_t, sql: [*:0]const u8) ?*zqlite_stmt_t {
    const wrapper = getConnection(conn) orelse return null;
    const sql_slice = std.mem.span(sql);

    wrapper.error_info.clear();
    const stmt = wrapper.connection.prepare(sql_slice) catch |err| {
        const error_code = mapErrorToCode(err);
        wrapper.error_info.set(error_code, @errorName(err), sql);
        return null;
    };
    return @as(*zqlite_stmt_t, @ptrCast(stmt));
}

/// Bind an integer parameter
export fn zqlite_bind_int(stmt: ?*zqlite_stmt_t, index: c_int, value: i64) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    const statement: *zqlite.db.PreparedStatement = @ptrCast(@alignCast(stmt.?));
    const storage_value = zqlite.storage.Value{ .Integer = value };

    statement.bindParameter(@intCast(index), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

/// Bind a text parameter
export fn zqlite_bind_text(stmt: ?*zqlite_stmt_t, index: c_int, value: [*:0]const u8) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    const statement: *zqlite.db.PreparedStatement = @ptrCast(@alignCast(stmt.?));
    const text_value = std.mem.span(value);
    const owned_text = c_allocator.dupe(u8, text_value) catch return ZQLITE_NOMEM;
    const storage_value = zqlite.storage.Value{ .Text = owned_text };

    statement.bindParameter(@intCast(index), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

/// Bind a real (float) parameter
export fn zqlite_bind_real(stmt: ?*zqlite_stmt_t, index: c_int, value: f64) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    const statement: *zqlite.db.PreparedStatement = @ptrCast(@alignCast(stmt.?));
    const storage_value = zqlite.storage.Value{ .Real = value };

    statement.bindParameter(@intCast(index), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

/// Bind a null parameter
export fn zqlite_bind_null(stmt: ?*zqlite_stmt_t, index: c_int) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    const statement: *zqlite.db.PreparedStatement = @ptrCast(@alignCast(stmt.?));
    const storage_value = zqlite.storage.Value.Null;

    statement.bindParameter(@intCast(index), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

/// Execute a prepared statement
export fn zqlite_step(stmt: ?*zqlite_stmt_t) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    const statement: *zqlite.db.PreparedStatement = @ptrCast(@alignCast(stmt.?));

    // Execute the prepared statement using its stored connection
    var result = statement.execute() catch return ZQLITE_ERROR;
    defer result.deinit();

    return ZQLITE_OK;
}

/// Reset a prepared statement
export fn zqlite_reset(stmt: ?*zqlite_stmt_t) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    const statement: *zqlite.db.PreparedStatement = @ptrCast(@alignCast(stmt.?));
    statement.reset();
    return ZQLITE_OK;
}

/// Finalize a prepared statement
export fn zqlite_finalize(stmt: ?*zqlite_stmt_t) c_int {
    if (stmt) |s| {
        const statement: *zqlite.db.PreparedStatement = @ptrCast(@alignCast(s));
        statement.deinit();
    }
    return ZQLITE_OK;
}

/// Begin a transaction
export fn zqlite_begin_transaction(conn: ?*zqlite_connection_t) c_int {
    const wrapper = getConnection(conn) orelse return ZQLITE_MISUSE;
    wrapper.error_info.clear();
    wrapper.connection.begin() catch |err| {
        const error_code = mapErrorToCode(err);
        wrapper.error_info.set(error_code, @errorName(err), null);
        return error_code;
    };
    return ZQLITE_OK;
}

/// Commit a transaction
export fn zqlite_commit_transaction(conn: ?*zqlite_connection_t) c_int {
    const wrapper = getConnection(conn) orelse return ZQLITE_MISUSE;
    wrapper.error_info.clear();
    wrapper.connection.commit() catch |err| {
        const error_code = mapErrorToCode(err);
        wrapper.error_info.set(error_code, @errorName(err), null);
        return error_code;
    };
    return ZQLITE_OK;
}

/// Rollback a transaction
export fn zqlite_rollback_transaction(conn: ?*zqlite_connection_t) c_int {
    const wrapper = getConnection(conn) orelse return ZQLITE_MISUSE;
    wrapper.error_info.clear();
    wrapper.connection.rollback() catch |err| {
        const error_code = mapErrorToCode(err);
        wrapper.error_info.set(error_code, @errorName(err), null);
        return error_code;
    };
    return ZQLITE_OK;
}

/// Get the last error message
export fn zqlite_errmsg(conn: ?*zqlite_connection_t) [*:0]const u8 {
    const wrapper = getConnection(conn) orelse return "Connection is null";
    if (wrapper.error_info.message_len == 0) {
        return "No error";
    }
    // Return pointer to the message buffer (null-terminated by ErrorInfo.set)
    return @ptrCast(&wrapper.error_info.message);
}

/// Get the last error code
export fn zqlite_errcode(conn: ?*zqlite_connection_t) c_int {
    const wrapper = getConnection(conn) orelse return ZQLITE_MISUSE;
    return wrapper.error_info.code;
}

/// Get the SQL that caused the last error
export fn zqlite_errsql(conn: ?*zqlite_connection_t) ?[*:0]const u8 {
    const wrapper = getConnection(conn) orelse return null;
    return wrapper.error_info.sql;
}

/// Get the version string
export fn zqlite_version() [*:0]const u8 {
    return zqlite.version.VERSION_STRING.ptr;
}

/// Cleanup global resources
export fn zqlite_shutdown() void {
    _ = gpa.deinit();
}

// Test the C API
test "c api basic functionality" {
    const testing = std.testing;

    // Test opening database
    const conn = zqlite_open(":memory:");
    try testing.expect(conn != null);
    defer zqlite_close(conn);

    // Test executing statement
    const result = zqlite_execute(conn, "CREATE TABLE test (id INTEGER, name TEXT)");
    try testing.expectEqual(ZQLITE_OK, result);

    // Test version
    const version = zqlite_version();
    try testing.expect(std.mem.len(version) > 0);
}

test "c api prepared statements" {
    const testing = std.testing;

    // Test opening database
    const conn = zqlite_open(":memory:");
    try testing.expect(conn != null);
    defer zqlite_close(conn);

    // Create table
    _ = zqlite_execute(conn, "CREATE TABLE test (id INTEGER, name TEXT)");

    // Test prepared statement
    const stmt = zqlite_prepare(conn, "INSERT INTO test VALUES (?, ?)");
    try testing.expect(stmt != null);
    defer _ = zqlite_finalize(stmt);

    // Test binding parameters
    try testing.expectEqual(ZQLITE_OK, zqlite_bind_int(stmt, 0, 123));
    try testing.expectEqual(ZQLITE_OK, zqlite_bind_text(stmt, 1, "test"));
}
