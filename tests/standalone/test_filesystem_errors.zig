const std = @import("std");
const zqlite = @import("zqlite");

/// Test filesystem error handling
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Filesystem Error Handling Tests ===", .{});

    try testInvalidPath(allocator);
    try testDirectoryAsDatabase(allocator);
    try testPermissionDenied(allocator);

    std.log.info("=== ALL FILESYSTEM ERROR TESTS PASSED ===", .{});
}

fn testInvalidPath(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Invalid path handling", .{});

    // Try to open database in non-existent directory
    const result = zqlite.open(allocator, "/nonexistent/path/test.db");
    if (result) |conn| {
        conn.close();
        std.log.err("Should have failed on invalid path!", .{});
        return error.ShouldHaveFailed;
    } else |_| {
        // Expected - path doesn't exist
        std.log.info("[PASS] Invalid path rejected", .{});
    }
}

fn testDirectoryAsDatabase(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Directory as database path", .{});

    // Try to open a directory as a database file
    const result = zqlite.open(allocator, "/tmp");
    if (result) |conn| {
        conn.close();
        std.log.err("Should have failed opening directory as database!", .{});
        return error.ShouldHaveFailed;
    } else |_| {
        // Expected - can't open directory as file
        std.log.info("[PASS] Directory path rejected", .{});
    }
}

fn testPermissionDenied(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Permission denied handling", .{});

    // /etc/passwd exists but we can't write to it
    // This tests read-only filesystem handling
    const result = zqlite.open(allocator, "/etc/shadow.db");
    if (result) |conn| {
        // If we somehow opened it (running as root?), try to write
        const write_result = conn.execute("CREATE TABLE test (id INTEGER)");
        conn.close();
        if (write_result) |_| {
            std.log.warn("[SKIP] Running as root, permission test not applicable", .{});
        } else |_| {
            std.log.info("[PASS] Write to protected path rejected", .{});
        }
    } else |_| {
        // Expected - permission denied
        std.log.info("[PASS] Protected path rejected", .{});
    }
}
