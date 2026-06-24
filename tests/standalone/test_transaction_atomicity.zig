const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

var test_dir: temp_dir.TempDir = undefined;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    test_dir = try .init(init.io, allocator, "zqlite-transaction");
    defer test_dir.deinit();

    std.log.info("=== Transaction Atomicity Tests ===", .{});

    try testCommitPersists(allocator);
    try testRollbackDiscards(allocator);
    try testNestedOperations(allocator);
    try testNestedSavepoints(allocator);
    try testReleaseSavepoint(allocator);
    try testOuterSavepointReleasePersists(allocator);
    try testNoDirtyReadsAcrossFileBackedConnections(allocator);
    try testSavepointWithForeignKeyCascade(allocator);
    try testSavepointWithUniqueIndex(allocator);
    try testDDLRejectedInsideSavepoint(allocator);

    std.log.info("=== ALL TRANSACTION ATOMICITY TESTS PASSED ===", .{});
}

fn resultHasIntegerId(result: anytype, id: i64) bool {
    for (result.rows.items) |row| {
        if (row.values.len > 0 and row.values[0] == .Integer and row.values[0].Integer == id) return true;
    }
    return false;
}

fn testCommitPersists(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] COMMIT persists to disk", .{});
    const path = try test_dir.dbPath("commit.db");
    defer allocator.free(path);

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
    const path = try test_dir.dbPath("rollback.db");
    defer allocator.free(path);

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
    const path = try test_dir.dbPath("nested.db");
    defer allocator.free(path);

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

fn testNestedSavepoints(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Nested SAVEPOINT / ROLLBACK TO / RELEASE", .{});
    const path = try test_dir.dbPath("savepoint_nested.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS items (id INTEGER, name TEXT)");
        try conn.execute("DELETE FROM items");

        try conn.execute("BEGIN");
        try conn.execute("INSERT INTO items (id, name) VALUES (1, 'outer')");
        try conn.execute("SAVEPOINT a");
        try conn.execute("INSERT INTO items (id, name) VALUES (2, 'rolled-back-to-a')");
        try conn.execute("SAVEPOINT b");
        try conn.execute("INSERT INTO items (id, name) VALUES (3, 'rolled-back-to-b')");
        try conn.execute("ROLLBACK TO b");
        try conn.execute("RELEASE b");
        try conn.execute("ROLLBACK TO a");
        try conn.execute("INSERT INTO items (id, name) VALUES (4, 'after-rollback-to-a')");
        try conn.execute("RELEASE a");
        try conn.execute("COMMIT");
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var result = try conn.query("SELECT * FROM items");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 2);
        std.debug.assert(resultHasIntegerId(&result, 1));
        std.debug.assert(resultHasIntegerId(&result, 4));
        std.log.info("[PASS] Nested savepoints preserved expected rows", .{});
    }
}

fn testReleaseSavepoint(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] RELEASE merges savepoint into outer transaction", .{});
    const path = try test_dir.dbPath("savepoint_release.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS release_test (id INTEGER, name TEXT)");
        try conn.execute("DELETE FROM release_test");
        try conn.execute("INSERT INTO release_test (id, name) VALUES (1, 'base')");

        try conn.execute("BEGIN");
        try conn.execute("SAVEPOINT s");
        try conn.execute("INSERT INTO release_test (id, name) VALUES (2, 'released')");
        try conn.execute("RELEASE s");
        try conn.execute("ROLLBACK");
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var result = try conn.query("SELECT * FROM release_test");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 1);
        std.debug.assert(resultHasIntegerId(&result, 1));
        std.debug.assert(!resultHasIntegerId(&result, 2));
        std.log.info("[PASS] RELEASE did not protect inner work from outer rollback", .{});
    }
}

fn testOuterSavepointReleasePersists(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] RELEASE of outer SAVEPOINT commits implicit transaction", .{});
    const path = try test_dir.dbPath("savepoint_outer_release.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS outer_release (id INTEGER, name TEXT)");
        try conn.execute("DELETE FROM outer_release");
        try conn.execute("SAVEPOINT outer_sp");
        try conn.execute("INSERT INTO outer_release (id, name) VALUES (1, 'committed-by-release')");
        try conn.execute("RELEASE outer_sp");
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var result = try conn.query("SELECT * FROM outer_release");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 1);
        std.debug.assert(resultHasIntegerId(&result, 1));
        std.log.info("[PASS] Outer savepoint release persisted after reopen", .{});
    }
}

fn testNoDirtyReadsAcrossFileBackedConnections(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] File-backed readers do not see uncommitted writer rows", .{});
    const path = try test_dir.dbPath("no_dirty_reads.db");
    defer allocator.free(path);

    {
        var setup = try zqlite.open(allocator, path);
        defer setup.close();
        try setup.execute("CREATE TABLE IF NOT EXISTS isolation_test (id INTEGER, name TEXT)");
        try setup.execute("DELETE FROM isolation_test");
        try setup.flush();
    }

    var writer = try zqlite.open(allocator, path);
    defer writer.close();
    var reader = try zqlite.open(allocator, path);
    defer reader.close();

    try writer.execute("BEGIN");
    try writer.execute("INSERT INTO isolation_test VALUES (1, 'uncommitted')");

    {
        var before_commit = try reader.query("SELECT * FROM isolation_test");
        defer before_commit.deinit();
        std.debug.assert(before_commit.rows.items.len == 0);
    }

    try writer.execute("COMMIT");

    {
        var reopened = try zqlite.open(allocator, path);
        defer reopened.close();
        var after_reopen = try reopened.query("SELECT * FROM isolation_test");
        defer after_reopen.deinit();
        std.debug.assert(after_reopen.rows.items.len == 1);
        std.debug.assert(resultHasIntegerId(&after_reopen, 1));
    }

    std.log.info("[PASS] Uncommitted file-backed rows stay invisible until commit", .{});
}

fn testSavepointWithForeignKeyCascade(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] SAVEPOINT rollback restores FK cascade effects", .{});
    const path = try test_dir.dbPath("savepoint_fk_cascade.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS parents (id INTEGER PRIMARY KEY, name TEXT)");
        try conn.execute("CREATE TABLE IF NOT EXISTS children (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id) ON DELETE CASCADE, name TEXT)");
        try conn.execute("DELETE FROM children");
        try conn.execute("DELETE FROM parents");
        try conn.execute("INSERT INTO parents (id, name) VALUES (1, 'parent')");
        try conn.execute("INSERT INTO children (id, parent_id, name) VALUES (10, 1, 'child')");

        try conn.execute("BEGIN");
        try conn.execute("SAVEPOINT before_cascade");
        try conn.execute("DELETE FROM parents WHERE id = 1");
        try conn.execute("ROLLBACK TO before_cascade");
        try conn.execute("RELEASE before_cascade");
        try conn.execute("COMMIT");
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var parents = try conn.query("SELECT * FROM parents");
        defer parents.deinit();
        var children = try conn.query("SELECT * FROM children");
        defer children.deinit();

        std.debug.assert(parents.rows.items.len == 1);
        std.debug.assert(children.rows.items.len == 1);
        std.debug.assert(resultHasIntegerId(&parents, 1));
        std.debug.assert(resultHasIntegerId(&children, 10));
        std.log.info("[PASS] Savepoint rollback restored FK cascade delete", .{});
    }
}

fn testSavepointWithUniqueIndex(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] SAVEPOINT rollback refreshes unique indexes", .{});
    const path = try test_dir.dbPath("savepoint_unique.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS accounts (id INTEGER, email TEXT UNIQUE)");
        try conn.execute("DELETE FROM accounts");

        try conn.execute("BEGIN");
        try conn.execute("INSERT INTO accounts (id, email) VALUES (1, 'a@example.com')");
        try conn.execute("SAVEPOINT before_unique");
        try conn.execute("INSERT INTO accounts (id, email) VALUES (2, 'b@example.com')");
        try conn.execute("ROLLBACK TO before_unique");
        try conn.execute("INSERT INTO accounts (id, email) VALUES (3, 'b@example.com')");
        try conn.execute("COMMIT");
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try std.testing.expectError(
            error.UniqueConstraintViolation,
            conn.execute("INSERT INTO accounts (id, email) VALUES (4, 'b@example.com')"),
        );

        var result = try conn.query("SELECT * FROM accounts");
        defer result.deinit();
        std.debug.assert(result.rows.items.len == 2);
        std.debug.assert(resultHasIntegerId(&result, 1));
        std.debug.assert(resultHasIntegerId(&result, 3));
        std.log.info("[PASS] Savepoint rollback allowed reusing rolled-back unique value", .{});
    }
}

fn testDDLRejectedInsideSavepoint(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] DDL is explicitly rejected inside active savepoints", .{});
    const path = try test_dir.dbPath("savepoint_ddl_rejected.db");
    defer allocator.free(path);

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    try conn.execute("CREATE TABLE base (id INTEGER)");
    try conn.execute("SAVEPOINT ddl_guard");
    try std.testing.expectError(
        error.UnsupportedDDLInSavepoint,
        conn.execute("CREATE TABLE should_not_exist (id INTEGER)"),
    );
    try std.testing.expectError(
        error.UnsupportedDDLInSavepoint,
        conn.execute("CREATE INDEX idx_base_id ON base (id)"),
    );
    try conn.execute("ROLLBACK TO ddl_guard");
    try conn.execute("RELEASE ddl_guard");

    try std.testing.expectError(
        error.TableNotFound,
        conn.query("SELECT * FROM should_not_exist"),
    );
    std.log.info("[PASS] DDL savepoint limitation fails explicitly", .{});
}
