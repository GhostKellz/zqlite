const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("❌ MEMORY LEAKS DETECTED!\n", .{});
            std.process.exit(1);
        } else {
            std.debug.print("✅ NO MEMORY LEAKS DETECTED!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("🔍 Minimal Memory Leak Test\n", .{});

    // Minimal test - just one operation
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Create table with DEFAULT value
    try conn.execute(
        \\CREATE TABLE test (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT DEFAULT 'test_name'
        \\)
    );

    // Insert one row
    try conn.execute("INSERT INTO test (id) VALUES (1)");

    // SELECT one row
    var stmt = try conn.prepare("SELECT id, name FROM test WHERE id = 1");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    std.debug.print("✅ Test completed - found {} rows\n", .{result.rows.items.len});
}
