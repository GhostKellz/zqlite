const std = @import("std");
const storage = @import("../db/storage.zig");
const zqlite = @import("../zqlite.zig");

/// Get current time in milliseconds using POSIX clock
fn getMilliTimestamp() i64 {
    const ts = zqlite.time_utils.getTimespec();
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Enhanced error reporting system for zqlite v1.2.5
/// Provides detailed error context, stack traces, and recovery suggestions
pub const EnhancedErrorReporting = struct {
    allocator: std.mem.Allocator,
    error_history: std.ArrayList(ErrorReport),
    max_history_size: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_history_size: usize) Self {
        return Self{
            .allocator = allocator,
            .error_history = .{},
            .max_history_size = max_history_size,
        };
    }

    /// Report an error with enhanced context
    pub fn reportError(self: *Self, error_type: ErrorType, context: ErrorContext) !ErrorReport {
        const timestamp = getMilliTimestamp();
        const stack_trace = try self.captureStackTrace();

        const report = ErrorReport{
            .id = self.generateErrorId(),
            .error_type = error_type,
            .context = context,
            .timestamp = timestamp,
            .stack_trace = stack_trace,
            .suggestions = try self.generateSuggestions(error_type, context),
            .severity = self.determineSeverity(error_type),
        };

        try self.addToHistory(report);

        return report;
    }

    /// Get formatted error message
    pub fn formatError(self: *Self, report: ErrorReport) ![]u8 {
        var message = std.ArrayList(u8){};

        // Header
        try message.writer().print("🚨 zqlite Error #{} [{}]\n", .{ report.id, @tagName(report.severity) });
        try message.writer().print("⏰ Time: {}\n", .{report.timestamp});
        try message.writer().print("📋 Type: {}\n\n", .{@tagName(report.error_type)});

        // Main error message
        switch (report.error_type) {
            .ParseError => |parse_err| {
                try message.writer().print("💥 Parse Error at position {}\n", .{parse_err.position});
                try message.writer().print("   Expected: {s}\n", .{parse_err.expected});
                try message.writer().print("   Found: {s}\n", .{parse_err.found});
                if (parse_err.sql_context) |sql| {
                    try message.appendSlice("   SQL: ");
                    try self.formatSQLWithHighlight(&message, sql, parse_err.position);
                }
            },
            .DatabaseError => |db_err| {
                try message.writer().print("🗃️ Database Error: {s}\n", .{db_err.message});
                if (db_err.table_name) |table| {
                    try message.writer().print("   Table: {s}\n", .{table});
                }
                if (db_err.column_name) |column| {
                    try message.writer().print("   Column: {s}\n", .{column});
                }
            },
            .ConnectionError => |conn_err| {
                try message.writer().print("🔗 Connection Error: {s}\n", .{conn_err.message});
                try message.writer().print("   Database Path: {s}\n", .{conn_err.database_path});
                if (conn_err.last_known_good_connection) |time| {
                    try message.writer().print("   Last Good Connection: {}\n", .{time});
                }
            },
            .PerformanceWarning => |perf_warn| {
                try message.writer().print("⚡ Performance Warning: {s}\n", .{perf_warn.message});
                try message.writer().print("   Execution Time: {d:.2}ms\n", .{perf_warn.execution_time_ms});
                if (perf_warn.expected_time_ms) |expected| {
                    try message.writer().print("   Expected Time: {d:.2}ms\n", .{expected});
                    const slowdown = perf_warn.execution_time_ms / expected;
                    try message.writer().print("   Slowdown Factor: {d:.1}x\n", .{slowdown});
                }
            },
            .IntegrityError => |integrity_err| {
                try message.writer().print("🛡️ Integrity Error: {s}\n", .{integrity_err.message});
                if (integrity_err.expected_checksum) |expected| {
                    try message.writer().print("   Expected Checksum: {s}\n", .{expected});
                }
                if (integrity_err.actual_checksum) |actual| {
                    try message.writer().print("   Actual Checksum: {s}\n", .{actual});
                }
            },
            .AsyncError => |async_err| {
                try message.writer().print("⚡ Async Operation Error: {s}\n", .{async_err.message});
                try message.writer().print("   Operation Type: {s}\n", .{@tagName(async_err.operation_type)});
                if (async_err.timeout_ms) |timeout| {
                    try message.writer().print("   Timeout: {}ms\n", .{timeout});
                }
            },
        }

        // Context information
        if (report.context.user_id) |user| {
            try message.writer().print("\n👤 User: {s}\n", .{user});
        }
        if (report.context.query_id) |query_id| {
            try message.writer().print("🔍 Query ID: {}\n", .{query_id});
        }
        if (report.context.session_id) |session| {
            try message.writer().print("📱 Session: {s}\n", .{session});
        }

        // Stack trace (abbreviated)
        if (report.stack_trace.len > 0) {
            try message.appendSlice("\n📚 Stack Trace (top 5):\n");
            const max_frames = @min(5, report.stack_trace.len);
            for (report.stack_trace[0..max_frames]) |frame| {
                try message.writer().print("   {s}:{}\n", .{ frame.function_name, frame.line_number });
            }
            if (report.stack_trace.len > 5) {
                try message.writer().print("   ... and {} more frames\n", .{report.stack_trace.len - 5});
            }
        }

        // Suggestions
        if (report.suggestions.len > 0) {
            try message.appendSlice("\n💡 Suggestions:\n");
            for (report.suggestions, 0..) |suggestion, i| {
                try message.writer().print("   {}. {s}\n", .{ i + 1, suggestion });
            }
        }

        // Related errors
        const related = try self.findRelatedErrors(report);
        if (related.len > 0) {
            try message.writer().print("\n🔗 Related Errors (last {}): ", .{related.len});
            for (related, 0..) |related_id, i| {
                if (i > 0) try message.appendSlice(", ");
                try message.writer().print("#{}", .{related_id});
            }
            try message.appendSlice("\n");
        }

        return try message.toOwnedSlice();
    }

    /// Get error statistics
    pub fn getErrorStats(self: *Self, time_window_ms: i64) ErrorStats {
        const current_time = getMilliTimestamp();
        const cutoff_time = current_time - time_window_ms;

        var stats = ErrorStats{};
        var error_type_counts = std.enums.EnumArray(ErrorType, u32).initFill(0);
        var severity_counts = std.enums.EnumArray(ErrorSeverity, u32).initFill(0);

        for (self.error_history.items) |report| {
            if (report.timestamp >= cutoff_time) {
                stats.total_errors += 1;
                error_type_counts.set(report.error_type, error_type_counts.get(report.error_type) + 1);
                severity_counts.set(report.severity, severity_counts.get(report.severity) + 1);

                // Track most frequent error
                const current_count = error_type_counts.get(report.error_type);
                if (current_count > error_type_counts.get(stats.most_frequent_error_type)) {
                    stats.most_frequent_error_type = report.error_type;
                }

                // Track latest error
                if (report.timestamp > stats.latest_error_timestamp) {
                    stats.latest_error_timestamp = report.timestamp;
                    stats.latest_error_id = report.id;
                }
            }
        }

        stats.critical_errors = severity_counts.get(.Critical);
        stats.error_rate_per_minute = @as(f64, @floatFromInt(stats.total_errors)) / (@as(f64, @floatFromInt(time_window_ms)) / 60000.0);

        return stats;
    }

    /// Clear old errors from history
    pub fn clearOldErrors(self: *Self, max_age_ms: i64) !void {
        const current_time = getMilliTimestamp();
        const cutoff_time = current_time - max_age_ms;

        var new_history = std.ArrayList(ErrorReport){};

        for (self.error_history.items) |report| {
            if (report.timestamp >= cutoff_time) {
                try new_history.append(report);
            } else {
                // Free memory from old reports
                self.freeErrorReport(report);
            }
        }

        self.error_history.deinit();
        self.error_history = new_history;
    }

    // Helper functions
    fn captureStackTrace(self: *Self) ![]StackFrame {
        // Simplified stack trace capture - in production, use debug info
        var frames = std.ArrayList(StackFrame){};

        // Capture current function information
        try frames.append(StackFrame{
            .function_name = try self.allocator.dupe(u8, "zqlite_operation"),
            .file_name = try self.allocator.dupe(u8, "unknown.zig"),
            .line_number = 0,
        });

        return try frames.toOwnedSlice();
    }

    fn generateErrorId(self: *Self) u64 {
        _ = self; // Remove unused variable warning
        const timestamp = @as(u64, @intCast(getMilliTimestamp()));
        const random = std.crypto.random.int(u32);
        return (timestamp << 32) | random;
    }

    fn generateSuggestions(self: *Self, error_type: ErrorType, context: ErrorContext) ![][]u8 {
        _ = context; // Remove unused variable warning

        var suggestions = std.ArrayList([]u8){};

        switch (error_type) {
            .ParseError => {
                try suggestions.append(try self.allocator.dupe(u8, "Check your SQL syntax for typos or missing keywords"));
                try suggestions.append(try self.allocator.dupe(u8, "Ensure all parentheses and quotes are properly balanced"));
                try suggestions.append(try self.allocator.dupe(u8, "Verify table and column names exist in the database"));
            },
            .DatabaseError => {
                try suggestions.append(try self.allocator.dupe(u8, "Check if the database file exists and is accessible"));
                try suggestions.append(try self.allocator.dupe(u8, "Verify you have the necessary permissions"));
                try suggestions.append(try self.allocator.dupe(u8, "Consider running VACUUM to repair database corruption"));
            },
            .ConnectionError => {
                try suggestions.append(try self.allocator.dupe(u8, "Verify the database path is correct"));
                try suggestions.append(try self.allocator.dupe(u8, "Check if another process has the database locked"));
                try suggestions.append(try self.allocator.dupe(u8, "Try reducing the number of concurrent connections"));
            },
            .PerformanceWarning => {
                try suggestions.append(try self.allocator.dupe(u8, "Consider adding indexes on frequently queried columns"));
                try suggestions.append(try self.allocator.dupe(u8, "Use LIMIT to reduce the number of returned rows"));
                try suggestions.append(try self.allocator.dupe(u8, "Run ANALYZE to update query optimizer statistics"));
            },
            .IntegrityError => {
                try suggestions.append(try self.allocator.dupe(u8, "Verify the integrity of your database file"));
                try suggestions.append(try self.allocator.dupe(u8, "Check for hardware or network corruption"));
                try suggestions.append(try self.allocator.dupe(u8, "Restore from a known good backup if available"));
            },
            .AsyncError => {
                try suggestions.append(try self.allocator.dupe(u8, "Increase the timeout value for long-running operations"));
                try suggestions.append(try self.allocator.dupe(u8, "Check system resources and reduce concurrent operations"));
                try suggestions.append(try self.allocator.dupe(u8, "Consider breaking large operations into smaller chunks"));
            },
        }

        return try suggestions.toOwnedSlice();
    }

    fn determineSeverity(self: *Self, error_type: ErrorType) ErrorSeverity {
        _ = self; // Remove unused variable warning

        return switch (error_type) {
            .ParseError => .Warning,
            .DatabaseError => .Error,
            .ConnectionError => .Critical,
            .PerformanceWarning => .Info,
            .IntegrityError => .Critical,
            .AsyncError => .Error,
        };
    }

    fn formatSQLWithHighlight(self: *Self, message: *std.ArrayList(u8), sql: []const u8, error_position: usize) !void {
        _ = self; // Remove unused variable warning

        const context_size = 20;
        const start_pos = if (error_position > context_size) error_position - context_size else 0;
        const end_pos = @min(error_position + context_size, sql.len);

        // Before error position
        try message.appendSlice(sql[start_pos..error_position]);

        // Highlight error position
        try message.appendSlice(" >>> ");
        if (error_position < sql.len) {
            try message.append(sql[error_position]);
        }
        try message.appendSlice(" <<< ");

        // After error position
        if (error_position + 1 < end_pos) {
            try message.appendSlice(sql[error_position + 1 .. end_pos]);
        }

        try message.appendSlice("\n");
    }

    fn addToHistory(self: *Self, report: ErrorReport) !void {
        try self.error_history.append(report);

        // Trim history if it exceeds max size
        while (self.error_history.items.len > self.max_history_size) {
            const old_report = self.error_history.orderedRemove(0);
            self.freeErrorReport(old_report);
        }
    }

    fn findRelatedErrors(self: *Self, report: ErrorReport) ![]u64 {
        var related = std.ArrayList(u64){};
        const time_window = 300000; // 5 minutes

        for (self.error_history.items) |other_report| {
            if (other_report.id != report.id and
                @abs(other_report.timestamp - report.timestamp) < time_window and
                std.meta.activeTag(other_report.error_type) == std.meta.activeTag(report.error_type))
            {
                try related.append(other_report.id);
                if (related.items.len >= 3) break; // Limit to 3 related errors
            }
        }

        return try related.toOwnedSlice();
    }

    fn freeErrorReport(self: *Self, report: ErrorReport) void {
        // Free allocated memory in error report
        for (report.stack_trace) |frame| {
            self.allocator.free(frame.function_name);
            self.allocator.free(frame.file_name);
        }
        self.allocator.free(report.stack_trace);

        for (report.suggestions) |suggestion| {
            self.allocator.free(suggestion);
        }
        self.allocator.free(report.suggestions);

        switch (report.error_type) {
            .ParseError => |parse_err| {
                self.allocator.free(parse_err.expected);
                self.allocator.free(parse_err.found);
                if (parse_err.sql_context) |sql| {
                    self.allocator.free(sql);
                }
            },
            .DatabaseError => |db_err| {
                self.allocator.free(db_err.message);
                if (db_err.table_name) |table| {
                    self.allocator.free(table);
                }
                if (db_err.column_name) |column| {
                    self.allocator.free(column);
                }
            },
            .ConnectionError => |conn_err| {
                self.allocator.free(conn_err.message);
                self.allocator.free(conn_err.database_path);
            },
            .PerformanceWarning => |perf_warn| {
                self.allocator.free(perf_warn.message);
            },
            .IntegrityError => |integrity_err| {
                self.allocator.free(integrity_err.message);
                if (integrity_err.expected_checksum) |expected| {
                    self.allocator.free(expected);
                }
                if (integrity_err.actual_checksum) |actual| {
                    self.allocator.free(actual);
                }
            },
            .AsyncError => |async_err| {
                self.allocator.free(async_err.message);
            },
        }
    }

    pub fn deinit(self: *Self) void {
        for (self.error_history.items) |report| {
            self.freeErrorReport(report);
        }
        self.error_history.deinit();
    }
};

// Data structures
pub const ErrorReport = struct {
    id: u64,
    error_type: ErrorType,
    context: ErrorContext,
    timestamp: i64,
    stack_trace: []StackFrame,
    suggestions: [][]u8,
    severity: ErrorSeverity,
};

pub const ErrorType = union(enum) {
    ParseError: ParseErrorInfo,
    DatabaseError: DatabaseErrorInfo,
    ConnectionError: ConnectionErrorInfo,
    PerformanceWarning: PerformanceWarningInfo,
    IntegrityError: IntegrityErrorInfo,
    AsyncError: AsyncErrorInfo,
};

pub const ParseErrorInfo = struct {
    position: usize,
    expected: []u8,
    found: []u8,
    sql_context: ?[]u8,
};

pub const DatabaseErrorInfo = struct {
    message: []u8,
    table_name: ?[]u8,
    column_name: ?[]u8,
    error_code: i32,
};

pub const ConnectionErrorInfo = struct {
    message: []u8,
    database_path: []u8,
    last_known_good_connection: ?i64,
};

pub const PerformanceWarningInfo = struct {
    message: []u8,
    execution_time_ms: f64,
    expected_time_ms: ?f64,
    query_complexity_score: f64,
};

pub const IntegrityErrorInfo = struct {
    message: []u8,
    expected_checksum: ?[]u8,
    actual_checksum: ?[]u8,
    corruption_type: CorruptionType,
};

pub const AsyncErrorInfo = struct {
    message: []u8,
    operation_type: AsyncOperationType,
    timeout_ms: ?u64,
};

pub const ErrorContext = struct {
    user_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    query_id: ?u64 = null,
    database_version: ?[]const u8 = null,
    system_info: ?SystemInfo = null,
};

pub const StackFrame = struct {
    function_name: []u8,
    file_name: []u8,
    line_number: u32,
};

pub const ErrorSeverity = enum {
    Info,
    Warning,
    Error,
    Critical,
};

pub const CorruptionType = enum {
    PageCorruption,
    IndexCorruption,
    FreelistCorruption,
    HeaderCorruption,
    ChecksumMismatch,
};

pub const AsyncOperationType = enum {
    Query,
    Transaction,
    BulkInsert,
    BackgroundMaintenance,
};

pub const SystemInfo = struct {
    os: []const u8,
    arch: []const u8,
    available_memory_kb: u64,
    cpu_count: u32,
};

pub const ErrorStats = struct {
    total_errors: u32 = 0,
    critical_errors: u32 = 0,
    error_rate_per_minute: f64 = 0.0,
    most_frequent_error_type: ErrorType = .ParseError,
    latest_error_timestamp: i64 = 0,
    latest_error_id: u64 = 0,
};
