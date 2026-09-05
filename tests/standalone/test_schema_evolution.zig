const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

var test_dir: temp_dir.TempDir = undefined;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    test_dir = try .init(init.io, allocator, "zqlite-schema-evolution");
    defer test_dir.deinit();

    try testPopulatedColumns(allocator, init.io);
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
        try std.testing.expectError(error.MissingRequiredValue, conn.execute("ALTER TABLE source ADD COLUMN later TEXT NOT NULL"));

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

fn testPopulatedColumns(allocator: std.mem.Allocator, io: std.Io) !void {
    const path = try test_dir.dbPath("populated.db");
    defer allocator.free(path);
    const backup_path = try test_dir.dbPath("populated-backup.db");
    defer allocator.free(backup_path);
    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE records (id INTEGER, value TEXT)");
        try conn.execute("BEGIN");
        const insert = try conn.prepare("INSERT INTO records VALUES (?, 'original')");
        defer insert.deinit();
        for (0..160) |i| {
            try insert.bind(0, @as(i64, @intCast(i)));
            var result = try insert.execute();
            result.deinit();
        }
        try conn.execute("COMMIT");
        try conn.execute("CREATE UNIQUE INDEX record_id ON records (id)");
        try conn.execute("DELETE FROM records WHERE id = 3");
        try conn.execute("UPDATE records SET value = 'changed' WHERE id = 4");
        const prepared = try conn.prepare("SELECT * FROM records WHERE id = 4");
        defer prepared.deinit();
        try std.testing.expectError(error.MissingRequiredValue, conn.execute("ALTER TABLE records ADD COLUMN invalid TEXT NOT NULL DEFAULT NULL"));
        try std.testing.expectError(error.UnsupportedAlterTableDefault, conn.execute("ALTER TABLE records ADD COLUMN clock TEXT DEFAULT CURRENT_TIMESTAMP"));
        try conn.configureResourceLimits(.{ .max_page_count = conn.storage_engine.pager.getPageCount() });
        try std.testing.expectError(error.ResourceLimitExceeded, conn.execute("ALTER TABLE records ADD COLUMN limited TEXT"));
        try conn.configureResourceLimits(.{});
        conn.storage_engine.pager.injectFaultOnce(.sync);
        try std.testing.expectError(error.InjectedSyncFailure, conn.execute("ALTER TABLE records ADD COLUMN failed TEXT DEFAULT 'no'"));
        {
            var unchanged = try prepared.execute();
            defer unchanged.deinit();
            try std.testing.expectEqual(@as(usize, 2), unchanged.rows.items[0].values.len);
        }
        try conn.execute("ALTER TABLE records ADD COLUMN note TEXT");
        try std.testing.expectError(error.PreparedStatementExpired, prepared.execute());
        try conn.execute("ALTER TABLE records ADD COLUMN state TEXT NOT NULL DEFAULT 'new'");
        try conn.execute("ALTER TABLE records ADD COLUMN delta INTEGER DEFAULT -7");
        try conn.execute("INSERT INTO records (id, value) VALUES (200, 'later')");
        try conn.execute("BEGIN");
        try conn.execute("SAVEPOINT migration");
        try std.testing.expectError(error.UnsupportedDDLInSavepoint, conn.execute("ALTER TABLE records ADD COLUMN forbidden TEXT"));
        try conn.execute("ROLLBACK");
        try conn.backupToFile(io, backup_path);
    }
    for ([_][]const u8{ path, backup_path }) |reopen_path| {
        const conn = try zqlite.open(allocator, reopen_path);
        defer conn.close();
        var all = try conn.query("SELECT * FROM records");
        defer all.deinit();
        try std.testing.expectEqual(@as(usize, 160), all.rows.items.len);
        for (all.rows.items) |row| {
            try std.testing.expectEqual(@as(usize, 5), row.values.len);
            try std.testing.expect(row.values[2] == .Null);
            try std.testing.expectEqualStrings("new", row.values[3].Text);
            try std.testing.expectEqual(@as(i64, -7), row.values[4].Integer);
        }
        var indexed = try conn.query("SELECT value, state FROM records WHERE id = 4");
        defer indexed.deinit();
        try std.testing.expectEqual(@as(usize, 1), indexed.rows.items.len);
        try std.testing.expectEqualStrings("changed", indexed.rows.items[0].values[0].Text);
        var integrity = try conn.integrityCheck();
        defer integrity.deinit(allocator);
        try std.testing.expect(integrity.ok);
    }
}
