const std = @import("std");
const builtin = @import("builtin");

const compat = if (builtin.is_test) struct {
    pub const Mutex = struct {
        state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

        pub fn lock(self: *Mutex) void {
            while (true) {
                if (self.state.compareExchangeWeak(0, 1, .acq_rel, .acquire) == .success) return;
                std.atomic.spinLoopHint();
            }
        }

        pub fn unlock(self: *Mutex) void {
            self.state.store(0, .release);
        }
    };

    pub const timespec = std.posix.timespec;
    pub const CLOCK = enum { REALTIME };
    pub fn clock_gettime(_: CLOCK) error{}!timespec {
        var ts: timespec = undefined;
        if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return error{};
        return ts;
    }
} else @import("root").compat;

/// Production-grade structured logging system for Zig 0.16
/// Features: JSON/text formats, log levels, thread-safe, scoped loggers
pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn toColor(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warn => "\x1b[33m", // Yellow
            .err => "\x1b[31m", // Red
            .fatal => "\x1b[35m", // Magenta
        };
    }
};

pub const LogFormat = enum {
    text,
    json,
};

pub const LoggerConfig = struct {
    level: LogLevel = .info,
    format: LogFormat = .text,
    enable_colors: bool = true,
    enable_timestamps: bool = true,
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    config: LoggerConfig,
    mutex: compat.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: LoggerConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .mutex = .{},
        };
    }

    pub fn debug(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    pub fn fatal(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.log(.fatal, fmt, args);
    }

    pub fn log(self: *Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.config.level)) {
            return; // Below minimum log level
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        switch (self.config.format) {
            .text => self.logText(level, fmt, args),
            .json => self.logJson(level, fmt, args),
        }
    }

    fn logText(self: *Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const timestamp = if (self.config.enable_timestamps) getTimestamp() else "";
        const level_color = if (self.config.enable_colors) level.toColor() else "";
        const reset_color = if (self.config.enable_colors) "\x1b[0m" else "";
        const level_str = level.toString();

        if (self.config.enable_timestamps) {
            std.debug.print("[{s}] {s}[{s}]{s} " ++ fmt ++ "\n", .{ timestamp, level_color, level_str, reset_color } ++ args);
        } else {
            std.debug.print("{s}[{s}]{s} " ++ fmt ++ "\n", .{ level_color, level_str, reset_color } ++ args);
        }
    }

    fn logJson(self: *Self, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const timestamp = getTimestamp();
        const level_str = level.toString();

        // Format message
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(message);

        // Escape JSON string
        const escaped_message = escapeJson(self.allocator, message) catch return;
        defer self.allocator.free(escaped_message);

        // Print JSON log entry
        std.debug.print("{{\"timestamp\":\"{s}\",\"level\":\"{s}\",\"message\":\"{s}\"}}\n", .{
            timestamp,
            level_str,
            escaped_message,
        });
    }

    fn getTimestamp() []const u8 {
        // Get current timestamp in ISO 8601 format using compat clock
        const ts = compat.clock_gettime(compat.CLOCK.REALTIME) catch return "UNKNOWN";
        const timestamp_ms: i64 = @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
        const seconds = @divFloor(timestamp_ms, 1000);
        const milliseconds = @mod(timestamp_ms, 1000);

        // Format: YYYY-MM-DDTHH:MM:SS.sssZ
        const epoch_seconds: i64 = @intCast(seconds);
        const epoch_day = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, epoch_seconds)) };
        const year_day = epoch_day.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        // Static buffer for timestamp (thread-local safe)
        const LocalBuffer = struct {
            threadlocal var buf: [64]u8 = undefined;
        };

        const result = std.fmt.bufPrint(&LocalBuffer.buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            @mod(@divFloor(epoch_seconds, 3600), 24),
            @mod(@divFloor(epoch_seconds, 60), 60),
            @mod(epoch_seconds, 60),
            @abs(milliseconds),
        }) catch "UNKNOWN";

        return result;
    }

    fn escapeJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        // Count how much space we need
        var needed: usize = 0;
        for (input) |c| {
            needed += switch (c) {
                '"', '\\', '\n', '\r', '\t' => 2,
                else => 1,
            };
        }

        var result = try allocator.alloc(u8, needed);
        var i: usize = 0;

        for (input) |c| {
            switch (c) {
                '"' => {
                    result[i] = '\\';
                    result[i + 1] = '"';
                    i += 2;
                },
                '\\' => {
                    result[i] = '\\';
                    result[i + 1] = '\\';
                    i += 2;
                },
                '\n' => {
                    result[i] = '\\';
                    result[i + 1] = 'n';
                    i += 2;
                },
                '\r' => {
                    result[i] = '\\';
                    result[i + 1] = 'r';
                    i += 2;
                },
                '\t' => {
                    result[i] = '\\';
                    result[i + 1] = 't';
                    i += 2;
                },
                else => {
                    result[i] = c;
                    i += 1;
                },
            }
        }

        return result;
    }
};

/// Global logger instance
var global_logger: ?Logger = null;
var global_logger_mutex: compat.Mutex = .{};

pub fn initGlobalLogger(allocator: std.mem.Allocator, config: LoggerConfig) void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    global_logger = Logger.init(allocator, config);
}

pub fn getGlobalLogger() *Logger {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger == null) {
        @panic("Global logger not initialized. Call initGlobalLogger() first.");
    }

    return &global_logger.?;
}

// Convenience functions using global logger
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    getGlobalLogger().debug(fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    getGlobalLogger().info(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    getGlobalLogger().warn(fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    getGlobalLogger().err(fmt, args);
}

pub fn fatal(comptime fmt: []const u8, args: anytype) void {
    getGlobalLogger().fatal(fmt, args);
}

/// Scoped logger for adding context to all log messages
pub const ScopedLogger = struct {
    logger: *Logger,
    scope: []const u8,

    pub fn init(logger: *Logger, scope: []const u8) ScopedLogger {
        return ScopedLogger{
            .logger = logger,
            .scope = scope,
        };
    }

    pub fn debug(self: ScopedLogger, comptime fmt: []const u8, args: anytype) void {
        self.logger.debug("[{s}] " ++ fmt, .{self.scope} ++ args);
    }

    pub fn info(self: ScopedLogger, comptime fmt: []const u8, args: anytype) void {
        self.logger.info("[{s}] " ++ fmt, .{self.scope} ++ args);
    }

    pub fn warn(self: ScopedLogger, comptime fmt: []const u8, args: anytype) void {
        self.logger.warn("[{s}] " ++ fmt, .{self.scope} ++ args);
    }

    pub fn err(self: ScopedLogger, comptime fmt: []const u8, args: anytype) void {
        self.logger.err("[{s}] " ++ fmt, .{self.scope} ++ args);
    }

    pub fn fatal(self: ScopedLogger, comptime fmt: []const u8, args: anytype) void {
        self.logger.fatal("[{s}] " ++ fmt, .{self.scope} ++ args);
    }
};
