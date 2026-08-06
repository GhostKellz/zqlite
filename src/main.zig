const std = @import("std");
const zqlite = @import("zqlite");
const cli = @import("zqlite").cli;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    const args = args_list.items;

    if (args.len <= 1) {
        // No arguments, start interactive shell
        try cli.runShell();
    } else {
        // Process command line arguments
        cli.executeCommand(allocator, args) catch |err| {
            std.debug.print("zqlite: error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }
}

test "simple test" {
    var list: std.ArrayListUnmanaged(i32) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "database integration" {
    // Test in-memory database
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.openMemory(allocator);
    defer conn.close();

    // Test basic functionality
    try std.testing.expect(conn.info().is_memory);

    // Test table creation
    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);");

    // Test insertion
    try conn.execute("INSERT INTO users VALUES (1, 'Alice');");
    try conn.execute("INSERT INTO users VALUES (2, 'Bob');");

    // Test selection (this should work without crashing)
    try conn.execute("SELECT * FROM users;");

    // Integration test passed
}

test "end-to-end workflow" {
    const allocator = std.testing.allocator;

    // Create in-memory database
    const conn = try zqlite.openMemory(allocator);
    defer conn.close();

    // Create table
    try conn.execute("CREATE TABLE products (id INTEGER, name TEXT, price REAL);");

    // Insert data
    try conn.execute("INSERT INTO products VALUES (1, 'Laptop', 999.99);");
    try conn.execute("INSERT INTO products VALUES (2, 'Mouse', 29.99);");

    // Query data
    try conn.execute("SELECT * FROM products;");

    // Test prepared statements
    var stmt = try conn.prepare("INSERT INTO products VALUES (?, ?, ?);");
    defer stmt.deinit();

    try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = 3 });
    const keyboard_text = try allocator.dupe(u8, "Keyboard");
    defer allocator.free(keyboard_text);
    try stmt.bindParameter(1, zqlite.storage.Value{ .Text = keyboard_text });
    try stmt.bindParameter(2, zqlite.storage.Value{ .Real = 79.99 });

    var result = try stmt.execute();
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 1), result.affected_rows);

    // End-to-end test passed
}

// Fuzz test moved to tests/fuzz/fuzz_example.zig to avoid test harness protocol issues
// Run with: zig build fuzz-example
