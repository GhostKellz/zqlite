const std = @import("std");
const zqlite = @import("zqlite");

/// Test transaction atomicity with file storage
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Transaction Atomicity Tests ===", .{});

    try testCommitPersists(allocator);
    try testRollbackDiscards(allocator);
    try testNestedOperations(allocator);

    std.log.info("=== ALL TRANSACTION ATOMICITY TESTS PASSED ===", .{});
}

fn testCommitPersists(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] COMMIT persists to disk", .{});
    const path = "/tmp/zqlite_txn_commit.db";

    // First connection: transaction with commit
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS accounts (id INTEGER, balance INTEGER)");
        try conn.execute("DELETE FROM accounts");

        try conn.execute("BEGIN");
        try conn.execute("INSERT INTO accounts (id, balance) VALUES (1, 1000)");
        try conn.execute("INSERT INTO accounts (id, balance) VALUES (2, 2000)");
        try conn.execute("COMMIT");
    }

    // Second connection: verify committed data
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var result = try conn.query("SELECT * FROM accounts");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 2);
        std.log.info("[PASS] COMMIT persists: {d} rows after reopen", .{result.rows.items.len});
    }
}

fn testRollbackDiscards(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] ROLLBACK discards changes", .{});
    const path = "/tmp/zqlite_txn_rollback.db";

    // First connection: setup base data
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS inventory (id INTEGER, qty INTEGER)");
        try conn.execute("DELETE FROM inventory");
        try conn.execute("INSERT INTO inventory (id, qty) VALUES (1, 100)");
    }

    // Second connection: rollback a transaction
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("BEGIN");
        try conn.execute("UPDATE inventory SET qty = 50 WHERE id = 1");
        try conn.execute("INSERT INTO inventory (id, qty) VALUES (2, 200)");
        try conn.execute("ROLLBACK");
    }

    // Third connection: verify rollback worked
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var result = try conn.query("SELECT * FROM inventory");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 1);
        std.log.info("[PASS] ROLLBACK discards: {d} rows (original state)", .{result.rows.items.len});
    }
}

fn testNestedOperations(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Multiple operations in transaction", .{});
    const path = "/tmp/zqlite_txn_nested.db";

    // Complex transaction with multiple tables
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT)");
        try conn.execute("CREATE TABLE IF NOT EXISTS orders (id INTEGER, user_id INTEGER, total INTEGER)");
        try conn.execute("DELETE FROM users");
        try conn.execute("DELETE FROM orders");

        try conn.execute("BEGIN");
        try conn.execute("INSERT INTO users (id, name) VALUES (1, 'Alice')");
        try conn.execute("INSERT INTO users (id, name) VALUES (2, 'Bob')");
        try conn.execute("INSERT INTO orders (id, user_id, total) VALUES (100, 1, 500)");
        try conn.execute("INSERT INTO orders (id, user_id, total) VALUES (101, 1, 300)");
        try conn.execute("INSERT INTO orders (id, user_id, total) VALUES (102, 2, 700)");
        try conn.execute("UPDATE users SET name = 'Alice Smith' WHERE id = 1");
        try conn.execute("DELETE FROM orders WHERE total < 400");
        try conn.execute("COMMIT");
    }

    // Verify final state
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var users = try conn.query("SELECT * FROM users");
        defer users.deinit();

        var orders = try conn.query("SELECT * FROM orders");
        defer orders.deinit();

        std.debug.assert(users.rows.items.len == 2);
        std.debug.assert(orders.rows.items.len == 2); // 300 was deleted
        std.log.info("[PASS] Nested operations: {d} users, {d} orders", .{ users.rows.items.len, orders.rows.items.len });
    }
}
