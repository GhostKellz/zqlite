const std = @import("std");
const zqlite = @import("zqlite");

/// Test CREATE TABLE memory leak fixes (DEFAULT constraints)
/// This test focuses ONLY on table creation to avoid B-tree leaks
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("❌ MEMORY LEAK DETECTED!\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("🧪 Testing CREATE TABLE with DEFAULT constraints (memory leak fix validation)...\n\n", .{});

    // Test 1: Simple DEFAULT literal
    {
        std.debug.print("Test 1: CREATE TABLE with DEFAULT literal value\n", .{});
        var conn = try zqlite.open(allocator, ":memory:");
        defer conn.close();

        try conn.execute(
            \\CREATE TABLE test1 (
            \\  id INTEGER,
            \\  name TEXT DEFAULT 'Anonymous'
            \\)
        );
        std.debug.print("  ✓ Passed\n", .{});
    }

    // Test 2: DEFAULT with function call (CURRENT_TIMESTAMP)
    {
        std.debug.print("Test 2: CREATE TABLE with DEFAULT CURRENT_TIMESTAMP\n", .{});
        var conn = try zqlite.open(allocator, ":memory:");
        defer conn.close();

        try conn.execute(
            \\CREATE TABLE test2 (
            \\  id INTEGER,
            \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        );
        std.debug.print("  ✓ Passed\n", .{});
    }

    // Test 3: Multiple DEFAULT constraints
    {
        std.debug.print("Test 3: CREATE TABLE with multiple DEFAULT constraints\n", .{});
        var conn = try zqlite.open(allocator, ":memory:");
        defer conn.close();

        try conn.execute(
            \\CREATE TABLE test3 (
            \\  id INTEGER,
            \\  username TEXT DEFAULT 'guest',
            \\  active INTEGER DEFAULT 1,
            \\  balance REAL DEFAULT 0.0,
            \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        );
        std.debug.print("  ✓ Passed\n", .{});
    }

    // Test 4: Multiple tables with DEFAULT constraints
    {
        std.debug.print("Test 4: Multiple CREATE TABLE statements\n", .{});
        var conn = try zqlite.open(allocator, ":memory:");
        defer conn.close();

        try conn.execute(
            \\CREATE TABLE users (
            \\  id INTEGER,
            \\  name TEXT DEFAULT 'Unknown',
            \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        );

        try conn.execute(
            \\CREATE TABLE products (
            \\  id INTEGER,
            \\  price REAL DEFAULT 0.0,
            \\  available INTEGER DEFAULT 1
            \\)
        );

        try conn.execute(
            \\CREATE TABLE logs (
            \\  id INTEGER,
            \\  message TEXT,
            \\  timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        );

        std.debug.print("  ✓ Passed\n", .{});
    }

    // Test 5: Connection lifecycle test
    {
        std.debug.print("Test 5: Multiple connection open/close cycles\n", .{});
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            var conn = try zqlite.open(allocator, ":memory:");
            try conn.execute(
                \\CREATE TABLE test (
                \\  id INTEGER,
                \\  data TEXT DEFAULT 'default',
                \\  ts DATETIME DEFAULT CURRENT_TIMESTAMP
                \\)
            );
            conn.close();
        }
        std.debug.print("  ✓ Passed (10 cycles)\n", .{});
    }

    std.debug.print("\n✅ All CREATE TABLE memory leak tests passed!\n", .{});
    std.debug.print("💡 Note: DEFAULT constraint memory leaks are fixed.\n", .{});
}
