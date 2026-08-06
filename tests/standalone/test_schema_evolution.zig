const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

var test_dir: temp_dir.TempDir = undefined;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    test_dir = try .init(init.io, allocator, "zqlite-schema-evolution");
    defer test_dir.deinit();

    try testAlterPersistenceAndPreparedExpiry(allocator);
    try testAlterFailuresDoNotMutateSchema(allocator);
    std.log.info("=== ALL SCHEMA EVOLUTION TESTS PASSED ===", .{});
}

fn testAlterPersistenceAndPreparedExpiry(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] ALTER TABLE operations persist and expire prepared statements", .{});
    const path = try test_dir.dbPath("alter-persistence.db");
    defer allocator.free(path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE accounts (id INTEGER)");
        const prepared = try conn.prepare("SELECT id FROM accounts");
        defer prepared.deinit();

        try conn.execute("ALTER TABLE accounts ADD COLUMN label TEXT NOT NULL DEFAULT 'new'");
        try std.testing.expectError(error.PreparedStatementExpired, prepared.execute());
        try conn.execute("INSERT INTO accounts (id) VALUES (1)");

        var added = try conn.query("SELECT label FROM accounts WHERE id = 1");
        defer added.deinit();
        try std.testing.expectEqual(@as(usize, 1), added.rows.items.len);
        try std.testing.expectEqualStrings("new", added.rows.items[0].values[0].Text);

        try conn.execute("ALTER TABLE accounts RENAME COLUMN label TO display_name");
        try conn.execute("ALTER TABLE accounts RENAME TO customers");
        try std.testing.expectError(error.TableNotFound, conn.query("SELECT * FROM accounts"));
    }

    {
        const reopened = try zqlite.open(allocator, path);
        defer reopened.close();
        var rows = try reopened.query("SELECT id, display_name FROM customers");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.items.len);
        try std.testing.expectEqual(@as(i64, 1), rows.rows.items[0].values[0].Integer);
        try std.testing.expectEqualStrings("new", rows.rows.items[0].values[1].Text);
    }
    std.log.info("[PASS] ALTER TABLE catalog changes survived reopen", .{});
}

fn testAlterFailuresDoNotMutateSchema(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Unsupported and conflicting ALTER TABLE operations fail before mutation", .{});
    const path = try test_dir.dbPath("alter-failures.db");
    defer allocator.free(path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE source (id INTEGER, value TEXT)");
        try conn.execute("CREATE TABLE occupied (id INTEGER)");
        try std.testing.expectError(error.TableAlreadyExists, conn.execute("ALTER TABLE source RENAME TO occupied"));
        try std.testing.expectError(error.ColumnAlreadyExists, conn.execute("ALTER TABLE source RENAME COLUMN value TO id"));
        conn.storage_engine.pager.injectFaultOnce(.sync);
        try std.testing.expectError(error.InjectedSyncFailure, conn.execute("ALTER TABLE source RENAME TO transient"));
        var after_fault = try conn.query("SELECT id, value FROM source");
        defer after_fault.deinit();
        try std.testing.expectEqual(@as(usize, 0), after_fault.rows.items.len);
        try conn.execute("INSERT INTO source VALUES (1, 'kept')");
        try std.testing.expectError(error.AlterTableRequiresRewrite, conn.execute("ALTER TABLE source ADD COLUMN later TEXT"));

        try conn.execute("BEGIN");
        try std.testing.expectError(error.UnsupportedDDLInTransaction, conn.execute("ALTER TABLE source RENAME TO transactional"));
        try conn.execute("ROLLBACK");

        try conn.execute("CREATE INDEX idx_source_value ON source (value)");
        try std.testing.expectError(error.UnsupportedAlterTableDependency, conn.execute("ALTER TABLE source RENAME COLUMN value TO renamed"));
        try std.testing.expectError(error.UnsupportedAlterTableDependency, conn.execute("ALTER TABLE source RENAME TO renamed_source"));
    }

    {
        const reopened = try zqlite.open(allocator, path);
        defer reopened.close();
        var rows = try reopened.query("SELECT id, value FROM source");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.items.len);
        try std.testing.expectError(error.TableNotFound, reopened.query("SELECT * FROM transactional"));
        try std.testing.expectError(error.TableNotFound, reopened.query("SELECT * FROM renamed_source"));
    }
    std.log.info("[PASS] Failed ALTER TABLE operations left the durable schema unchanged", .{});
}
