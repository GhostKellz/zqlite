const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZQLite File-Backed Storage Tests ===", .{});

    try testBasicCreateAndSelect(allocator);
    try testInsertAndSelect(allocator);
    try testMultipleTables(allocator);
    try testPersistenceAcrossConnections(allocator);
    try testUpdateAndDelete(allocator);
    try testLargeDataset(allocator);

    std.log.info("=== ALL FILE-BACKED TESTS PASSED ===", .{});
}

fn testBasicCreateAndSelect(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Basic CREATE TABLE and SELECT on empty table", .{});
    const path = "/tmp/zqlite_test_basic.db";

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    try conn.execute("CREATE TABLE IF NOT EXISTS test (id INTEGER, name TEXT)");
    var result = try conn.query("SELECT * FROM test");
    defer result.deinit();

    std.log.info("[PASS] Basic CREATE and SELECT: {d} rows", .{result.rows.items.len});
}

fn testInsertAndSelect(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] INSERT and SELECT", .{});
    const path = "/tmp/zqlite_test_insert.db";

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    try conn.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT, age INTEGER)");
    try conn.execute("INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30)");
    try conn.execute("INSERT INTO users (id, name, age) VALUES (2, 'Bob', 25)");
    try conn.execute("INSERT INTO users (id, name, age) VALUES (3, 'Charlie', 35)");

    var result = try conn.query("SELECT * FROM users");
    defer result.deinit();

    std.debug.assert(result.rows.items.len >= 3);
    std.log.info("[PASS] INSERT and SELECT: {d} rows", .{result.rows.items.len});
}

fn testMultipleTables(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Multiple tables", .{});
    const path = "/tmp/zqlite_test_multi.db";

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    try conn.execute("CREATE TABLE IF NOT EXISTS users2 (id INTEGER, name TEXT)");
    try conn.execute("CREATE TABLE IF NOT EXISTS products2 (id INTEGER, title TEXT, price REAL)");
    try conn.execute("CREATE TABLE IF NOT EXISTS orders2 (id INTEGER, user_id INTEGER, product_id INTEGER)");

    try conn.execute("INSERT INTO users2 (id, name) VALUES (1, 'Alice')");
    try conn.execute("INSERT INTO products2 (id, title, price) VALUES (100, 'Widget', 9.99)");
    try conn.execute("INSERT INTO orders2 (id, user_id, product_id) VALUES (1000, 1, 100)");

    var r1 = try conn.query("SELECT * FROM users2");
    defer r1.deinit();
    var r2 = try conn.query("SELECT * FROM products2");
    defer r2.deinit();
    var r3 = try conn.query("SELECT * FROM orders2");
    defer r3.deinit();

    std.debug.assert(r1.rows.items.len >= 1);
    std.debug.assert(r2.rows.items.len >= 1);
    std.debug.assert(r3.rows.items.len >= 1);
    std.log.info("[PASS] Multiple tables: users={d}, products={d}, orders={d}", .{ r1.rows.items.len, r2.rows.items.len, r3.rows.items.len });
}

fn testPersistenceAcrossConnections(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Persistence across connections", .{});
    const path = "/tmp/zqlite_test_persist.db";

    // First connection: create and insert
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS data (id INTEGER, value TEXT)");
        try conn.execute("INSERT INTO data (id, value) VALUES (1, 'first')");
        try conn.execute("INSERT INTO data (id, value) VALUES (2, 'second')");
    }

    // Second connection: verify data persisted
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var result = try conn.query("SELECT * FROM data");
        defer result.deinit();

        std.debug.assert(result.rows.items.len >= 2);
        std.log.info("[PASS] Persistence: {d} rows after reopen", .{result.rows.items.len});
    }
}

fn testUpdateAndDelete(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] UPDATE and DELETE", .{});
    const path = "/tmp/zqlite_test_update.db";

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    try conn.execute("CREATE TABLE IF NOT EXISTS items (id INTEGER, name TEXT)");
    try conn.execute("DELETE FROM items");
    try conn.execute("INSERT INTO items (id, name) VALUES (1, 'one')");
    try conn.execute("INSERT INTO items (id, name) VALUES (2, 'two')");
    try conn.execute("INSERT INTO items (id, name) VALUES (3, 'three')");

    // Update
    try conn.execute("UPDATE items SET name = 'updated' WHERE id = 2");

    // Delete
    try conn.execute("DELETE FROM items WHERE id = 1");

    var result = try conn.query("SELECT * FROM items");
    defer result.deinit();

    std.debug.assert(result.rows.items.len == 2);
    std.log.info("[PASS] UPDATE and DELETE: {d} rows remaining", .{result.rows.items.len});
}

fn testLargeDataset(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Large dataset (100 rows)", .{});
    const path = "/tmp/zqlite_test_large.db";

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS numbers (id INTEGER, value INTEGER)");
        try conn.execute("DELETE FROM numbers");

        // Insert 100 rows
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var buf: [128]u8 = undefined;
            const sql = std.fmt.bufPrint(&buf, "INSERT INTO numbers (id, value) VALUES ({d}, {d})", .{ i, i * 10 }) catch unreachable;
            try conn.execute(sql);
        }

        var result = try conn.query("SELECT * FROM numbers");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 100);
        std.log.info("[PASS] Large dataset in active connection: {d} rows", .{result.rows.items.len});
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var result = try conn.query("SELECT * FROM numbers");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 100);
        std.log.info("[PASS] Large dataset after reopen: {d} rows", .{result.rows.items.len});
    }
}
