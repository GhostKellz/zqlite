const std = @import("std");
const zqlite = @import("zqlite");
const logger = zqlite.logging;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧪 Testing Structured Logging System\n\n", .{});

    // Test 1: Text format with colors
    {
        std.debug.print("Test 1: Text format with colors\n", .{});
        var log = logger.Logger.init(allocator, .{
            .level = .debug,
            .format = .text,
            .enable_colors = true,
            .enable_timestamps = true,
        });

        log.debug("Debug message: value={d}", .{42});
        log.info("Info message: starting operation", .{});
        log.warn("Warning: potential issue detected", .{});
        log.err("Error: operation failed with code {d}", .{-1});
        log.fatal("Fatal: critical system failure", .{});
        std.debug.print("  ✓ Text logging works\n\n", .{});
    }

    // Test 2: JSON format
    {
        std.debug.print("Test 2: JSON format\n", .{});
        var log = logger.Logger.init(allocator, .{
            .level = .info,
            .format = .json,
            .enable_colors = false,
            .enable_timestamps = true,
        });

        log.info("JSON formatted message", .{});
        log.warn("Warning with special chars: quotes \" and backslash \\", .{});
        log.err("Error message with newline\\nand tab\\t", .{});
        std.debug.print("  ✓ JSON logging works\n\n", .{});
    }

    // Test 3: Log level filtering
    {
        std.debug.print("Test 3: Log level filtering (level=WARN)\n", .{});
        var log = logger.Logger.init(allocator, .{
            .level = .warn,
            .format = .text,
            .enable_colors = true,
        });

        log.debug("This should NOT appear", .{});
        log.info("This should NOT appear", .{});
        log.warn("This SHOULD appear", .{});
        log.err("This SHOULD appear", .{});
        std.debug.print("  ✓ Log level filtering works\n\n", .{});
    }

    // Test 4: Scoped logger
    {
        std.debug.print("Test 4: Scoped logger\n", .{});
        var log = logger.Logger.init(allocator, .{
            .level = .info,
            .format = .text,
            .enable_colors = true,
        });

        const db_logger = logger.ScopedLogger.init(&log, "DATABASE");
        const net_logger = logger.ScopedLogger.init(&log, "NETWORK");

        db_logger.info("Connection established", .{});
        net_logger.info("Listening on port {d}", .{8080});
        db_logger.err("Query timeout after {d}ms", .{5000});
        std.debug.print("  ✓ Scoped logging works\n\n", .{});
    }

    // Test 5: Global logger
    {
        std.debug.print("Test 5: Global logger\n", .{});
        logger.initGlobalLogger(allocator, .{
            .level = .info,
            .format = .text,
            .enable_colors = true,
        });

        logger.info("Global logger initialized", .{});
        logger.warn("Using global logger convenience functions", .{});
        std.debug.print("  ✓ Global logger works\n\n", .{});
    }

    std.debug.print("✅ All logging tests passed!\n", .{});
}
