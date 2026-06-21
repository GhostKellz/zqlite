const std = @import("std");
const zqlite = @import("zqlite");

/// C FFI interface for zqlite
/// Enables integration with Rust, Python, and other languages

// Opaque handles for C API
const zqlite_connection_t = anyopaque;
const zqlite_result_t = anyopaque;
const zqlite_stmt_t = anyopaque;

pub const ZQLITE_ABI_VERSION_MAJOR = 1;
pub const ZQLITE_ABI_VERSION_MINOR = 0;
pub const ZQLITE_ABI_VERSION_PATCH = 0;

/// Error codes for C API
pub const ZQLITE_OK = 0;
pub const ZQLITE_ERROR = 1;
pub const ZQLITE_BUSY = 5;
pub const ZQLITE_LOCKED = 6;
pub const ZQLITE_NOMEM = 7;
pub const ZQLITE_READONLY = 8;
pub const ZQLITE_IOERR = 10;
pub const ZQLITE_CORRUPT = 11;
pub const ZQLITE_CONSTRAINT = 19;
pub const ZQLITE_MISMATCH = 20;
pub const ZQLITE_MISUSE = 21;
pub const ZQLITE_NOLFS = 22;
pub const ZQLITE_AUTH = 23;
pub const ZQLITE_FORMAT = 24;
pub const ZQLITE_RANGE = 25;
pub const ZQLITE_NOTADB = 26;
pub const ZQLITE_ROW = 100;
pub const ZQLITE_DONE = 101;

pub const ZQLITE_TYPE_INTEGER = 1;
pub const ZQLITE_TYPE_REAL = 2;
pub const ZQLITE_TYPE_TEXT = 3;
pub const ZQLITE_TYPE_BLOB = 4;
pub const ZQLITE_TYPE_NULL = 5;

pub const ZQLITE_ERROR_CATEGORY_OK = 0;
pub const ZQLITE_ERROR_CATEGORY_SQL = 1;
pub const ZQLITE_ERROR_CATEGORY_CONSTRAINT = 2;
pub const ZQLITE_ERROR_CATEGORY_IO = 3;
pub const ZQLITE_ERROR_CATEGORY_MISUSE = 4;
pub const ZQLITE_ERROR_CATEGORY_MEMORY = 5;
pub const ZQLITE_ERROR_CATEGORY_AUTHORIZATION = 6;
pub const ZQLITE_ERROR_CATEGORY_FORMAT = 7;
pub const ZQLITE_ERROR_CATEGORY_UNKNOWN = 255;

/// Extended error information
const ErrorInfo = struct {
    code: c_int,
    message: [256]u8,
    message_len: usize,
    sql: ?[*:0]const u8,

    fn init() ErrorInfo {
        return ErrorInfo{
            .code = ZQLITE_OK,
            .message = std.mem.zeroes([256]u8),
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
    cell_types: [][]c_int,
    column_names: [][:0]u8,
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

const StatementWrapper = struct {
    statement: *zqlite.db.PreparedStatement,
    result: ?zqlite.vm.ExecutionResult = null,
    row_index: usize = 0,
    text_buffer: ?[:0]u8 = null,

    fn clearText(self: *StatementWrapper, allocator: std.mem.Allocator) void {
        if (self.text_buffer) |buffer| {
            allocator.free(buffer);
            self.text_buffer = null;
        }
    }

    fn clearResult(self: *StatementWrapper) void {
        if (self.result) |*result| {
            result.deinit();
            self.result = null;
        }
        self.row_index = 0;
    }

    fn currentRow(self: *StatementWrapper) ?*zqlite.storage.Row {
        if (self.result) |*result| {
            if (self.row_index < result.rows.items.len) {
                return &result.rows.items[self.row_index];
            }
        }
        return null;
    }
};

// Default global allocator for C API. SafeAllocator is thread-safe when backed
// by page_allocator, so independent C callers do not race allocator metadata.
var c_safe_allocator = std.heap.SafeAllocator.init(std.heap.page_allocator, .{});
var c_allocator: std.mem.Allocator = c_safe_allocator.allocator();

fn storageValueType(value: zqlite.storage.Value) c_int {
    return switch (value) {
        .Integer, .SmallInt, .BigInt, .Boolean, .Timestamp, .Date, .Time, .Interval => ZQLITE_TYPE_INTEGER,
        .Real => ZQLITE_TYPE_REAL,
        .Text, .JSON => ZQLITE_TYPE_TEXT,
        .Blob, .JSONB, .Array, .UUID, .TimestampTZ, .Numeric => ZQLITE_TYPE_BLOB,
        .Null => ZQLITE_TYPE_NULL,
        .Parameter, .FunctionCall => ZQLITE_TYPE_NULL,
    };
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
        error.ConstraintViolation, error.UniqueConstraintViolation, error.MissingRequiredValue => ZQLITE_CONSTRAINT,
        error.InvalidParameterIndex, error.ParameterIndexOutOfBounds, error.NamedParameterNotFound => ZQLITE_RANGE,
        error.SavepointNotFound, error.TransactionAlreadyActive, error.TransactionActive, error.UnsupportedDDLInSavepoint => ZQLITE_MISUSE,
        error.IoError => ZQLITE_IOERR,
        error.CorruptData => ZQLITE_CORRUPT,
        else => ZQLITE_ERROR,
    };
}

fn mapCodeToCategory(code: c_int) c_int {
    return switch (code) {
        ZQLITE_OK => ZQLITE_ERROR_CATEGORY_OK,
        ZQLITE_CONSTRAINT => ZQLITE_ERROR_CATEGORY_CONSTRAINT,
        ZQLITE_IOERR, ZQLITE_READONLY, ZQLITE_NOLFS => ZQLITE_ERROR_CATEGORY_IO,
        ZQLITE_MISUSE, ZQLITE_RANGE, ZQLITE_BUSY, ZQLITE_LOCKED => ZQLITE_ERROR_CATEGORY_MISUSE,
        ZQLITE_NOMEM => ZQLITE_ERROR_CATEGORY_MEMORY,
        ZQLITE_AUTH => ZQLITE_ERROR_CATEGORY_AUTHORIZATION,
        ZQLITE_CORRUPT, ZQLITE_FORMAT, ZQLITE_NOTADB => ZQLITE_ERROR_CATEGORY_FORMAT,
        ZQLITE_ERROR, ZQLITE_MISMATCH => ZQLITE_ERROR_CATEGORY_SQL,
        else => ZQLITE_ERROR_CATEGORY_UNKNOWN,
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
        .cell_types = &[_][]c_int{},
        .column_names = &[_][:0]u8{},
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
    var column_names = c_allocator.alloc([:0]u8, col_count) catch {
        result.error_message = c_allocator.dupe(u8, "OutOfMemory") catch null;
        return @as(*zqlite_result_t, @ptrCast(result));
    };
    var column_names_loaded: usize = 0;
    errdefer {
        for (column_names[0..column_names_loaded]) |name| c_allocator.free(name);
        c_allocator.free(column_names);
    }
    for (0..col_count) |col_idx| {
        const name = result_set.columnName(col_idx) orelse "";
        column_names[col_idx] = c_allocator.dupeSentinel(u8, name, 0) catch {
            result.error_message = c_allocator.dupe(u8, "OutOfMemory") catch null;
            return @as(*zqlite_result_t, @ptrCast(result));
        };
        column_names_loaded = col_idx + 1;
    }
    result.column_names = column_names;

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
    var cell_types = c_allocator.alloc([]c_int, row_count) catch {
        c_allocator.free(rows);
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
        var row_types = c_allocator.alloc(c_int, col_count) catch {
            c_allocator.free(row_data);
            for (rows[0..row_idx]) |r| {
                for (r) |cell| {
                    if (cell) |c| c_allocator.free(c);
                }
                c_allocator.free(r);
            }
            for (cell_types[0..row_idx]) |types| c_allocator.free(types);
            c_allocator.free(cell_types);
            c_allocator.free(rows);
            result.error_message = c_allocator.dupe(u8, "OutOfMemory") catch null;
            return @as(*zqlite_result_t, @ptrCast(result));
        };

        // Copy values
        for (0..col_count) |col_idx| {
            const value = row.getValue(col_idx);
            if (value) |v| {
                row_types[col_idx] = storageValueType(v);
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
                row_types[col_idx] = ZQLITE_TYPE_NULL;
                row_data[col_idx] = null;
            }
        }

        rows[row_idx] = row_data;
        cell_types[row_idx] = row_types;
        row_idx += 1;
    }

    result.rows = rows;
    result.cell_types = cell_types;
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

/// Get a result column name. Borrowed from the result object.
export fn zqlite_result_column_name(result: ?*zqlite_result_t, column: c_int) ?[*:0]const u8 {
    if (result == null or column < 0) return null;

    const query_result: *QueryResult = @ptrCast(@alignCast(result.?));
    if (column >= query_result.column_count) return null;
    const name = query_result.column_names[@intCast(column)];
    return name.ptr;
}

/// Get a result cell storage class.
export fn zqlite_result_get_type(result: ?*zqlite_result_t, row: c_int, column: c_int) c_int {
    if (result == null) return ZQLITE_TYPE_NULL;

    const query_result: *QueryResult = @ptrCast(@alignCast(result.?));

    if (row < 0 or column < 0) return ZQLITE_TYPE_NULL;
    if (row >= query_result.row_count or column >= query_result.column_count) return ZQLITE_TYPE_NULL;

    return query_result.cell_types[@intCast(row)][@intCast(column)];
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
        const c_str = c_allocator.dupeSentinel(u8, data, 0) catch return null;
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
        for (query_result.rows, 0..) |row, row_idx| {
            for (row) |cell| {
                if (cell) |data| {
                    c_allocator.free(data);
                }
            }
            c_allocator.free(row);
            c_allocator.free(query_result.cell_types[row_idx]);
        }
        c_allocator.free(query_result.rows);
        c_allocator.free(query_result.cell_types);

        for (query_result.column_names) |name| {
            c_allocator.free(name);
        }
        c_allocator.free(query_result.column_names);

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
    errdefer stmt.deinit();

    const stmt_wrapper = c_allocator.create(StatementWrapper) catch {
        stmt.deinit();
        wrapper.error_info.set(ZQLITE_NOMEM, "OutOfMemory", sql);
        return null;
    };
    stmt_wrapper.* = .{ .statement = stmt };
    return @as(*zqlite_stmt_t, @ptrCast(stmt_wrapper));
}

/// Bind an integer parameter
export fn zqlite_bind_int(stmt: ?*zqlite_stmt_t, index: c_int, value: i64) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    if (index < 0) return ZQLITE_RANGE;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const storage_value = zqlite.storage.Value{ .Integer = value };

    wrapper.clearResult();
    wrapper.statement.bindParameter(@intCast(index), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

/// Bind a text parameter
export fn zqlite_bind_text(stmt: ?*zqlite_stmt_t, index: c_int, value: [*:0]const u8) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    if (index < 0) return ZQLITE_RANGE;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const text_value = std.mem.span(value);
    // Pass borrowed value - bindParameter will clone internally
    const storage_value = zqlite.storage.Value{ .Text = text_value };

    wrapper.clearResult();
    wrapper.statement.bindParameter(@intCast(index), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

/// Bind a real (float) parameter
export fn zqlite_bind_real(stmt: ?*zqlite_stmt_t, index: c_int, value: f64) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    if (index < 0) return ZQLITE_RANGE;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const storage_value = zqlite.storage.Value{ .Real = value };

    wrapper.clearResult();
    wrapper.statement.bindParameter(@intCast(index), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

/// Bind a null parameter
export fn zqlite_bind_null(stmt: ?*zqlite_stmt_t, index: c_int) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    if (index < 0) return ZQLITE_RANGE;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const storage_value = zqlite.storage.Value.Null;

    wrapper.clearResult();
    wrapper.statement.bindParameter(@intCast(index), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

/// Bind a blob parameter
export fn zqlite_bind_blob(stmt: ?*zqlite_stmt_t, index: c_int, value: ?*const anyopaque, len: usize) c_int {
    if (stmt == null) return ZQLITE_MISUSE;
    if (index < 0) return ZQLITE_RANGE;
    if (value == null and len != 0) return ZQLITE_MISUSE;

    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const bytes: []const u8 = if (len == 0) &.{} else @as([*]const u8, @ptrCast(value.?))[0..len];
    const storage_value = zqlite.storage.Value{ .Blob = bytes };

    wrapper.clearResult();
    wrapper.statement.bindParameter(@intCast(index), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

export fn zqlite_bind_int_named(stmt: ?*zqlite_stmt_t, name: [*:0]const u8, value: i64) c_int {
    if (stmt == null) return ZQLITE_MISUSE;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const storage_value = zqlite.storage.Value{ .Integer = value };

    wrapper.clearResult();
    wrapper.statement.bindNamedParameter(std.mem.span(name), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

export fn zqlite_bind_text_named(stmt: ?*zqlite_stmt_t, name: [*:0]const u8, value: [*:0]const u8) c_int {
    if (stmt == null) return ZQLITE_MISUSE;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const storage_value = zqlite.storage.Value{ .Text = std.mem.span(value) };

    wrapper.clearResult();
    wrapper.statement.bindNamedParameter(std.mem.span(name), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

export fn zqlite_bind_real_named(stmt: ?*zqlite_stmt_t, name: [*:0]const u8, value: f64) c_int {
    if (stmt == null) return ZQLITE_MISUSE;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const storage_value = zqlite.storage.Value{ .Real = value };

    wrapper.clearResult();
    wrapper.statement.bindNamedParameter(std.mem.span(name), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

export fn zqlite_bind_null_named(stmt: ?*zqlite_stmt_t, name: [*:0]const u8) c_int {
    if (stmt == null) return ZQLITE_MISUSE;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));

    wrapper.clearResult();
    wrapper.statement.bindNamedParameter(std.mem.span(name), zqlite.storage.Value.Null) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

export fn zqlite_bind_blob_named(stmt: ?*zqlite_stmt_t, name: [*:0]const u8, value: ?*const anyopaque, len: usize) c_int {
    if (stmt == null) return ZQLITE_MISUSE;
    if (value == null and len != 0) return ZQLITE_MISUSE;

    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const bytes: []const u8 = if (len == 0) &.{} else @as([*]const u8, @ptrCast(value.?))[0..len];
    const storage_value = zqlite.storage.Value{ .Blob = bytes };

    wrapper.clearResult();
    wrapper.statement.bindNamedParameter(std.mem.span(name), storage_value) catch return ZQLITE_ERROR;
    return ZQLITE_OK;
}

/// Execute a prepared statement
export fn zqlite_step(stmt: ?*zqlite_stmt_t) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    wrapper.clearText(c_allocator);

    if (wrapper.result) |*result| {
        if (wrapper.row_index + 1 < result.rows.items.len) {
            wrapper.row_index += 1;
            return ZQLITE_ROW;
        }
        wrapper.clearResult();
        return ZQLITE_DONE;
    }

    var result = wrapper.statement.execute() catch return ZQLITE_ERROR;
    if (result.rows.items.len == 0) {
        result.deinit();
        return ZQLITE_DONE;
    }

    wrapper.result = result;
    wrapper.row_index = 0;
    return ZQLITE_ROW;
}

fn getCurrentValue(stmt: ?*zqlite_stmt_t, column: c_int) ?*const zqlite.storage.Value {
    if (stmt == null or column < 0) return null;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    const row = wrapper.currentRow() orelse return null;
    if (column >= row.values.len) return null;
    return &row.values[@intCast(column)];
}

/// Number of columns in the current prepared-statement row/result.
export fn zqlite_column_count(stmt: ?*zqlite_stmt_t) c_int {
    if (stmt == null) return -1;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    if (wrapper.result) |*result| {
        if (result.rows.items.len == 0) return 0;
        return @intCast(result.rows.items[0].values.len);
    }
    return 0;
}

/// Name of a prepared-statement result column. Borrowed until the next
/// statement step/reset/finalize or column-name call.
export fn zqlite_column_name(stmt: ?*zqlite_stmt_t, column: c_int) ?[*:0]const u8 {
    if (stmt == null or column < 0) return null;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    wrapper.clearText(c_allocator);

    const name: []const u8 = switch (wrapper.statement.parsed_statement) {
        .Select => |select| blk: {
            const col_idx: usize = @intCast(column);
            if (select.columns.len == 1 and std.mem.eql(u8, select.columns[0].name, "*")) {
                const table_name = select.table orelse return null;
                const table = wrapper.statement.connection.storage_engine.getTable(table_name) orelse return null;
                if (col_idx >= table.schema.columns.len) return null;
                break :blk table.schema.columns[col_idx].name;
            }
            if (col_idx >= select.columns.len) return null;
            break :blk select.columns[col_idx].alias orelse select.columns[col_idx].name;
        },
        else => return null,
    };

    wrapper.text_buffer = c_allocator.dupeSentinel(u8, name, 0) catch return null;
    return wrapper.text_buffer.?.ptr;
}

/// SQLite-compatible storage class for the current row/column.
export fn zqlite_column_type(stmt: ?*zqlite_stmt_t, column: c_int) c_int {
    const value = getCurrentValue(stmt, column) orelse return ZQLITE_TYPE_NULL;
    return storageValueType(value.*);
}

export fn zqlite_column_int64(stmt: ?*zqlite_stmt_t, column: c_int) i64 {
    const value = getCurrentValue(stmt, column) orelse return 0;
    return switch (value.*) {
        .Integer => |v| v,
        .SmallInt => |v| v,
        .BigInt => |v| v,
        .Boolean => |v| if (v) 1 else 0,
        .Timestamp => |v| v,
        .Date => |v| v,
        .Time => |v| v,
        .Interval => |v| v,
        else => 0,
    };
}

export fn zqlite_column_double(stmt: ?*zqlite_stmt_t, column: c_int) f64 {
    const value = getCurrentValue(stmt, column) orelse return 0;
    return switch (value.*) {
        .Real => |v| v,
        .Integer => |v| @floatFromInt(v),
        .SmallInt => |v| @floatFromInt(v),
        .BigInt => |v| @floatFromInt(v),
        else => 0,
    };
}

export fn zqlite_column_text(stmt: ?*zqlite_stmt_t, column: c_int) ?[*:0]const u8 {
    if (stmt == null or column < 0) return null;
    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    wrapper.clearText(c_allocator);

    const value = getCurrentValue(stmt, column) orelse return null;
    const text = switch (value.*) {
        .Text => |v| v,
        .JSON => |v| v,
        else => return null,
    };

    wrapper.text_buffer = c_allocator.dupeSentinel(u8, text, 0) catch return null;
    return wrapper.text_buffer.?.ptr;
}

export fn zqlite_column_blob(stmt: ?*zqlite_stmt_t, column: c_int) ?*const anyopaque {
    const value = getCurrentValue(stmt, column) orelse return null;
    return switch (value.*) {
        .Blob => |v| if (v.len == 0) null else @ptrCast(v.ptr),
        else => null,
    };
}

export fn zqlite_column_bytes(stmt: ?*zqlite_stmt_t, column: c_int) usize {
    const value = getCurrentValue(stmt, column) orelse return 0;
    return switch (value.*) {
        .Text => |v| v.len,
        .Blob => |v| v.len,
        .JSON => |v| v.len,
        else => 0,
    };
}

/// Reset a prepared statement
export fn zqlite_reset(stmt: ?*zqlite_stmt_t) c_int {
    if (stmt == null) return ZQLITE_MISUSE;

    const wrapper: *StatementWrapper = @ptrCast(@alignCast(stmt.?));
    wrapper.clearText(c_allocator);
    wrapper.clearResult();
    wrapper.statement.reset();
    return ZQLITE_OK;
}

/// Finalize a prepared statement
export fn zqlite_finalize(stmt: ?*zqlite_stmt_t) c_int {
    if (stmt) |s| {
        const wrapper: *StatementWrapper = @ptrCast(@alignCast(s));
        wrapper.clearText(c_allocator);
        wrapper.clearResult();
        wrapper.statement.deinit();
        c_allocator.destroy(wrapper);
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

/// Get the stable category for the last error code
export fn zqlite_errcategory(conn: ?*zqlite_connection_t) c_int {
    const wrapper = getConnection(conn) orelse return ZQLITE_ERROR_CATEGORY_MISUSE;
    return mapCodeToCategory(wrapper.error_info.code);
}

/// Get the SQL that caused the last error
export fn zqlite_errsql(conn: ?*zqlite_connection_t) ?[*:0]const u8 {
    const wrapper = getConnection(conn) orelse return null;
    return wrapper.error_info.sql;
}

/// Get the version string
export fn zqlite_version() [*:0]const u8 {
    return zqlite.version.VERSION_STRING_Z.ptr;
}

/// Get packed C ABI version: major.minor.patch as MMmmpp.
export fn zqlite_abi_version() c_int {
    return ZQLITE_ABI_VERSION_MAJOR * 10000 + ZQLITE_ABI_VERSION_MINOR * 100 + ZQLITE_ABI_VERSION_PATCH;
}

export fn zqlite_abi_version_major() c_int {
    return ZQLITE_ABI_VERSION_MAJOR;
}

export fn zqlite_abi_version_minor() c_int {
    return ZQLITE_ABI_VERSION_MINOR;
}

export fn zqlite_abi_version_patch() c_int {
    return ZQLITE_ABI_VERSION_PATCH;
}

/// Returns 1 when real post-quantum crypto is enabled, 0 otherwise.
export fn zqlite_pq_available() c_int {
    const pq = zqlite.getPQCapability();
    return if (pq.enabled) 1 else 0;
}

/// Returns the current post-quantum status message.
export fn zqlite_pq_status() [*:0]const u8 {
    const pq = zqlite.getPQCapability();
    return switch (pq.backend) {
        .none => "Post-quantum crypto not compiled (use -Dcrypto=true)",
        .native_fallback => "Classical crypto only (Ed25519). PQ is experimental scaffolding.",
    };
}

/// Returns the current post-quantum backend name.
export fn zqlite_pq_backend() [*:0]const u8 {
    return switch (zqlite.getPQCapability().backend) {
        .none => "none",
        .native_fallback => "native_fallback",
    };
}

/// Cleanup global resources
export fn zqlite_shutdown() void {
    _ = c_safe_allocator.deinit();
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

test "c api pq capability exports" {
    const testing = std.testing;

    const pq_status = zqlite_pq_status();
    const pq_backend = zqlite_pq_backend();

    try testing.expect(std.mem.len(pq_status) > 0);
    try testing.expect(std.mem.len(pq_backend) > 0);

    const pq_available = zqlite_pq_available();
    try testing.expect(pq_available == 0 or pq_available == 1);
}
