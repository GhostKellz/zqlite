const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

var test_dir: temp_dir.TempDir = undefined;
var test_io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    test_io = init.io;
    test_dir = try .init(init.io, allocator, "zqlite-file-backed");
    defer test_dir.deinit();

    std.log.info("=== ZQLite File-Backed Storage Tests ===", .{});

    try testBasicCreateAndSelect(allocator);
    try testInsertAndSelect(allocator);
    try testMultipleTables(allocator);
    try testPersistenceAcrossConnections(allocator);
    try testUpdateAndDelete(allocator);
    try testLargeDataset(allocator);
    try testUniqueNullsAreDistinct(allocator);
    try testColumnUniqueConstraintPersists(allocator);
    try testTableUniqueConstraintPersists(allocator);
    try testCheckConstraintPersists(allocator);
    try testForeignKeyConstraintPersists(allocator);
    try testForeignKeyActionsPersist(allocator);
    try testCompositeAndDeferredForeignKeysPersist(allocator);
    try testInsertDefaultValues(allocator);
    try testCheckpointWalStatsAndBackup(allocator);
    try testReadOnlyAndImmutableOpenModes(allocator);
    try testBusyTimeoutAndInterrupt(allocator);
    try testSchemaVersionAndMigrationPersistence(allocator);
    try testIntegrityCheckPragma(allocator);
    try testVacuumMaintenanceCommand(allocator);

    std.log.info("=== ALL FILE-BACKED TESTS PASSED ===", .{});
}

fn testCompositeAndDeferredForeignKeysPersist(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Composite and deferred foreign keys persist", .{});
    const path = try test_dir.dbPath("composite_deferred_fk.db");
    defer allocator.free(path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE parents (tenant_id INTEGER, id INTEGER)");
        try conn.execute("CREATE TABLE children (tenant_id INTEGER, parent_id INTEGER, FOREIGN KEY (tenant_id, parent_id) REFERENCES parents (tenant_id, id))");
        var composite_info = try conn.query("PRAGMA foreign_key_list(children)");
        defer composite_info.deinit();
        try std.testing.expectEqual(@as(usize, 2), composite_info.rows.items.len);
        try conn.execute("INSERT INTO parents VALUES (1, 10)");
        try conn.execute("INSERT INTO children VALUES (1, 10)");
        try conn.execute("INSERT INTO children VALUES (NULL, 999)");
        try std.testing.expectError(error.ConstraintViolation, conn.execute("INSERT INTO children VALUES (2, 10)"));
        try std.testing.expectError(error.ConstraintViolation, conn.execute("DELETE FROM parents WHERE tenant_id = 1 AND id = 10"));

        try conn.execute("CREATE TABLE deferred_parents (id INTEGER)");
        try conn.execute("CREATE TABLE deferred_children (parent_id INTEGER, FOREIGN KEY (parent_id) REFERENCES deferred_parents (id) DEFERRABLE INITIALLY DEFERRED)");
        try conn.execute("BEGIN");
        try conn.execute("INSERT INTO deferred_children VALUES (7)");
        try conn.execute("INSERT INTO deferred_parents VALUES (7)");
        try conn.execute("COMMIT");

        try conn.execute("BEGIN");
        try conn.execute("DELETE FROM deferred_parents WHERE id = 7");
        try std.testing.expectError(error.ConstraintViolation, conn.execute("COMMIT"));
        try conn.execute("ROLLBACK");

        try conn.execute("BEGIN");
        try conn.execute("INSERT INTO deferred_children VALUES (8)");
        try std.testing.expectError(error.ConstraintViolation, conn.execute("COMMIT"));
        try std.testing.expect(conn.in_transaction);
        try conn.execute("ROLLBACK");
        try std.testing.expectError(error.ConstraintViolation, conn.execute("INSERT INTO deferred_children VALUES (9)"));
    }

    {
        const reopened = try zqlite.open(allocator, path);
        defer reopened.close();
        const composite = reopened.storage_engine.getTable("children").?.schema.foreign_keys[0];
        try std.testing.expectEqual(@as(usize, 2), composite.columns.?.len);
        const deferred = reopened.storage_engine.getTable("deferred_children").?.schema.foreign_keys[0];
        try std.testing.expect(deferred.deferred);
        try std.testing.expectError(error.ConstraintViolation, reopened.execute("INSERT INTO children VALUES (1, 11)"));
        var rows = try reopened.query("SELECT * FROM deferred_children");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.items.len);
    }
    std.log.info("[PASS] Composite matching and commit-time deferred checks survived reopen", .{});
}

fn testVacuumMaintenanceCommand(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] VACUUM reclaims pages and refreshes existing readers", .{});
    const path = try test_dir.dbPath("vacuum_maintenance.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE vacuum_items (id INTEGER, name TEXT)");
        try conn.execute("CREATE UNIQUE INDEX idx_vacuum_items_id ON vacuum_items (id)");
        for (0..10) |id| {
            var sql: [96]u8 = undefined;
            try conn.execute(try std.fmt.bufPrint(&sql, "INSERT INTO vacuum_items VALUES ({d}, 'kept')", .{id}));
        }
        try conn.execute("CREATE TABLE discarded_pages (id INTEGER, payload TEXT)");
        const payload = try allocator.alloc(u8, 1500);
        defer allocator.free(payload);
        @memset(payload, 'x');
        try conn.begin();
        for (0..80) |id| {
            const sql = try std.fmt.allocPrint(allocator, "INSERT INTO discarded_pages VALUES ({d}, '{s}')", .{ id, payload });
            defer allocator.free(sql);
            try conn.execute(sql);
        }
        try conn.commit();
        try conn.execute("DROP TABLE discarded_pages");
        try conn.flush();

        const before_file = try std.Io.Dir.cwd().openFile(test_io, path, .{});
        const before_size = try before_file.length(test_io);
        before_file.close(test_io);
        const observer = try zqlite.open(allocator, path);
        defer observer.close();

        conn.storage_engine.pager.injectFaultOnce(.sync);
        try std.testing.expectError(error.InjectedSyncFailure, conn.query("VACUUM"));
        conn.interrupt();
        try std.testing.expectError(error.Interrupted, conn.query("VACUUM"));
        conn.clearInterrupt();
        var unchanged = try conn.query("SELECT * FROM vacuum_items");
        defer unchanged.deinit();
        try std.testing.expectEqual(@as(usize, 10), unchanged.rows.items.len);

        var result = try conn.query("VACUUM");
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
        try std.testing.expectEqualStrings("ok", result.rows.items[0].values[0].Text);

        var check = try conn.query("PRAGMA integrity_check");
        defer check.deinit();
        try std.testing.expectEqualStrings("ok", check.rows.items[0].values[0].Text);
        try conn.flush();

        const after_file = try std.Io.Dir.cwd().openFile(test_io, path, .{});
        const after_size = try after_file.length(test_io);
        after_file.close(test_io);
        try std.testing.expect(after_size < before_size);

        var visible = try observer.query("SELECT * FROM vacuum_items");
        defer visible.deinit();
        try std.testing.expectEqual(@as(usize, 10), visible.rows.items.len);
        std.log.info("[PASS] VACUUM reduced database from {d} to {d} bytes", .{ before_size, after_size });
    }
}

fn testIntegrityCheckPragma(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] PRAGMA integrity_check validates storage metadata", .{});
    const path = try test_dir.dbPath("integrity_check.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE integrity_items (id INTEGER, name TEXT)");
        try conn.execute("CREATE UNIQUE INDEX idx_integrity_items_id ON integrity_items (id)");
        try conn.execute("INSERT INTO integrity_items VALUES (1, 'one')");
        try conn.execute("INSERT INTO integrity_items VALUES (2, 'two')");

        var check = try conn.integrityCheck();
        defer check.deinit(allocator);
        try std.testing.expect(check.ok);
        try std.testing.expectEqual(@as(usize, 1), check.table_count);
        try std.testing.expectEqual(@as(usize, 1), check.index_count);
        try std.testing.expectEqual(@as(usize, 2), check.live_rows);

        var pragma = try conn.query("PRAGMA integrity_check");
        defer pragma.deinit();
        try std.testing.expectEqual(@as(usize, 1), pragma.rows.items.len);
        try std.testing.expectEqualStrings("ok", pragma.rows.items[0].values[0].Text);
        try conn.flush();
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var pragma = try conn.query("PRAGMA integrity_check");
        defer pragma.deinit();
        try std.testing.expectEqualStrings("ok", pragma.rows.items[0].values[0].Text);
    }

    std.log.info("[PASS] PRAGMA integrity_check reports ok across reopen", .{});
}

fn testSchemaVersionAndMigrationPersistence(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] schema/user version and migration persistence", .{});
    const path = try test_dir.dbPath("schema_versions.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try std.testing.expectEqual(@as(u32, 0), conn.getUserVersion());
        try conn.setUserVersion(11);
        try conn.execute("CREATE TABLE version_persist (id INTEGER)");
        const schema_version = conn.getSchemaVersion();
        try std.testing.expect(schema_version > 0);
        try conn.flush();
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try std.testing.expectEqual(@as(u32, 11), conn.getUserVersion());
        const reopened_schema_version = conn.getSchemaVersion();
        try std.testing.expect(reopened_schema_version > 0);

        var user_result = try conn.query("PRAGMA user_version");
        defer user_result.deinit();
        try std.testing.expectEqual(@as(i64, 11), user_result.rows.items[0].values[0].Integer);

        var schema_result = try conn.query("PRAGMA schema_version");
        defer schema_result.deinit();
        try std.testing.expectEqual(@as(i64, @intCast(reopened_schema_version)), schema_result.rows.items[0].values[0].Integer);

        const migrations = [_]zqlite.migration.Migration{
            zqlite.migration.createMigration(12, "add_migration_table", "CREATE TABLE persisted_migration (id INTEGER)", "DROP TABLE persisted_migration"),
        };
        var manager = zqlite.migration.MigrationManager.init(allocator, conn, &migrations);
        try manager.runMigrations();
        try std.testing.expectEqual(@as(u32, 12), conn.getUserVersion());
        try conn.flush();
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try std.testing.expectEqual(@as(u32, 12), conn.getUserVersion());
        var result = try conn.query("SELECT * FROM persisted_migration");
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.rows.items.len);
    }

    std.log.info("[PASS] schema/user version and migration metadata survived reopen", .{});
}

fn testInsertDefaultValues(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] INSERT DEFAULT VALUES and function defaults fill defaults", .{});
    const path = try test_dir.dbPath("insert_default_values.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE defaults_test (id INTEGER DEFAULT 7, name TEXT DEFAULT 'anon', note TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");
        try conn.execute("INSERT INTO defaults_test DEFAULT VALUES");
        try conn.execute("INSERT INTO defaults_test (id, name) VALUES (8, 'explicit')");

        var result = try conn.query("SELECT * FROM defaults_test");
        defer result.deinit();
        std.debug.assert(result.rows.items.len == 2);
        const row = result.rows.items[0];
        std.debug.assert(row.values[0].Integer == 7);
        std.debug.assert(std.mem.eql(u8, row.values[1].Text, "anon"));
        std.debug.assert(row.values[2] == .Null);
        std.debug.assert(row.values[3] == .Text);
        std.debug.assert(row.values[3].Text.len > 0);

        const partial_row = result.rows.items[1];
        std.debug.assert(partial_row.values[0].Integer == 8);
        std.debug.assert(std.mem.eql(u8, partial_row.values[1].Text, "explicit"));
        std.debug.assert(partial_row.values[2] == .Null);
        std.debug.assert(partial_row.values[3] == .Text);
        std.debug.assert(partial_row.values[3].Text.len > 0);
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("INSERT INTO defaults_test (id) VALUES (9)");
        var result = try conn.query("SELECT * FROM defaults_test");
        defer result.deinit();
        std.debug.assert(result.rows.items.len == 3);
        const reopened_row = result.rows.items[2];
        std.debug.assert(reopened_row.values[0].Integer == 9);
        std.debug.assert(std.mem.eql(u8, reopened_row.values[1].Text, "anon"));
        std.debug.assert(reopened_row.values[2] == .Null);
        std.debug.assert(reopened_row.values[3] == .Text);
        std.debug.assert(reopened_row.values[3].Text.len > 0);
    }

    std.log.info("[PASS] INSERT DEFAULT VALUES and function defaults produced default rows", .{});
}

fn testCheckpointWalStatsAndBackup(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] checkpoint API, WAL stats, and file backup", .{});
    const path = try test_dir.dbPath("backup_source.db");
    defer allocator.free(path);
    const backup_path = try test_dir.dbPath("backup_copy.db");
    defer allocator.free(backup_path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE backup_test (id INTEGER PRIMARY KEY, name TEXT)");
        try conn.execute("INSERT INTO backup_test (id, name) VALUES (1, 'primary')");

        const stats_before = (try conn.getWalStats()).?;
        try std.testing.expect(stats_before.path.len > 0);
        try std.testing.expect(!stats_before.active_transaction);

        try conn.checkpoint();
        const stats_after = (try conn.getWalStats()).?;
        try std.testing.expect(!stats_after.active_transaction);

        try conn.backupToFile(test_io, backup_path);
    }

    {
        var backup = try zqlite.open(allocator, backup_path);
        defer backup.close();

        var result = try backup.query("SELECT * FROM backup_test");
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
        try std.testing.expectEqual(@as(i64, 1), result.rows.items[0].values[0].Integer);
        try std.testing.expectEqualStrings("primary", result.rows.items[0].values[1].Text);
    }

    {
        var memory = try zqlite.openMemory(allocator);
        defer memory.close();
        try std.testing.expectEqual(@as(?zqlite.wal.WriteAheadLog.Stats, null), try memory.getWalStats());
        try std.testing.expectError(error.BackupRequiresFileDatabase, memory.backupToFile(test_io, backup_path));
    }

    std.log.info("[PASS] checkpoint/WAL stats/backup API produced a readable copy", .{});
}

fn testReadOnlyAndImmutableOpenModes(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] read-only and immutable open modes", .{});
    const path = try test_dir.dbPath("readonly_modes.db");
    defer allocator.free(path);
    const backup_path = try test_dir.dbPath("readonly_backup.db");
    defer allocator.free(backup_path);
    const missing_path = try test_dir.dbPath("missing_readonly.db");
    defer allocator.free(missing_path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE readonly_test (id INTEGER PRIMARY KEY, name TEXT)");
        try conn.execute("INSERT INTO readonly_test (id, name) VALUES (1, 'stable')");
        try conn.flush();
    }

    {
        var ro = try zqlite.openWithOptions(allocator, path, zqlite.OpenOptions.READ_ONLY);
        defer ro.close();
        try std.testing.expect(ro.isReadOnly());
        try std.testing.expect(!ro.isImmutable());
        try std.testing.expectEqual(@as(?zqlite.wal.WriteAheadLog.Stats, null), try ro.getWalStats());

        var result = try ro.query("SELECT * FROM readonly_test");
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
        try std.testing.expectEqualStrings("stable", result.rows.items[0].values[1].Text);

        try ro.checkpoint();
        try ro.backupToFile(test_io, backup_path);

        try std.testing.expectError(error.ReadOnlyDatabase, ro.execute("INSERT INTO readonly_test (id, name) VALUES (2, 'blocked')"));
        try std.testing.expectError(error.ReadOnlyDatabase, ro.exec("UPDATE readonly_test SET name = 'blocked' WHERE id = 1"));
        try std.testing.expectError(error.ReadOnlyDatabase, ro.query("DELETE FROM readonly_test WHERE id = 1"));
        try std.testing.expectError(error.ReadOnlyDatabase, ro.execute("BEGIN"));
        try std.testing.expectError(error.ReadOnlyDatabase, ro.attachDatabase(path, "aux"));
        try std.testing.expectError(error.ReadOnlyDatabase, ro.prepare("INSERT INTO readonly_test (id, name) VALUES (?, ?)"));
    }

    {
        var backup = try zqlite.open(allocator, backup_path);
        defer backup.close();
        var result = try backup.query("SELECT * FROM readonly_test");
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
    }

    {
        var imm = try zqlite.openWithOptions(allocator, path, zqlite.OpenOptions.IMMUTABLE);
        defer imm.close();
        try std.testing.expect(imm.isReadOnly());
        try std.testing.expect(imm.isImmutable());

        var result = try imm.query("SELECT * FROM readonly_test");
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
        try std.testing.expectError(error.ReadOnlyDatabase, imm.execute("CREATE TABLE blocked (id INTEGER)"));
    }

    try std.testing.expectError(error.FileNotFound, zqlite.openWithOptions(allocator, missing_path, zqlite.OpenOptions.READ_ONLY));
    try std.testing.expectError(error.FileNotFound, zqlite.openWithOptions(allocator, missing_path, zqlite.OpenOptions.IMMUTABLE));

    std.log.info("[PASS] read-only and immutable modes allowed reads and rejected writes", .{});
}

fn testBusyTimeoutAndInterrupt(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] busy timeout and interrupt controls", .{});
    const path = try test_dir.dbPath("operation_controls.db");
    defer allocator.free(path);

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    try conn.execute("CREATE TABLE operation_controls (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.execute("INSERT INTO operation_controls (id, name) VALUES (1, 'ready')");

    conn.interrupt();
    try std.testing.expect(conn.isInterrupted());
    try std.testing.expectError(error.Interrupted, conn.query("SELECT * FROM operation_controls"));
    try std.testing.expectError(error.Interrupted, conn.prepare("SELECT * FROM operation_controls"));

    conn.clearInterrupt();
    try std.testing.expect(!conn.isInterrupted());

    var result = try conn.query("SELECT * FROM operation_controls");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);

    conn.setBusyTimeout(1);
    try std.testing.expectEqual(@as(?u64, 1), conn.getBusyTimeout());
    conn.beginOperation();
    defer conn.endOperation();
    try std.Io.sleep(test_io, .fromNanoseconds(2 * std.time.ns_per_ms), .awake);
    try std.testing.expectError(error.OperationTimedOut, conn.checkOperation());

    conn.setBusyTimeout(0);
    try std.testing.expectEqual(@as(?u64, null), conn.getBusyTimeout());

    std.log.info("[PASS] busy timeout and interrupt controls fail cooperatively", .{});
}

fn testForeignKeyConstraintPersists(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] FOREIGN KEY constraints are enforced and survive reopen", .{});
    const path = try test_dir.dbPath("foreign_key_constraint.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT)");
        try conn.execute("CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id), title TEXT)");
        try conn.execute("INSERT INTO authors (id, name) VALUES (1, 'Octavia')");
        try conn.execute("INSERT INTO books (id, author_id, title) VALUES (10, 1, 'Kindred')");

        try std.testing.expectError(
            error.ConstraintViolation,
            conn.execute("INSERT INTO books (id, author_id, title) VALUES (11, 99, 'missing')"),
        );
        try std.testing.expectError(
            error.ConstraintViolation,
            conn.execute("DELETE FROM authors WHERE id = 1"),
        );
        try std.testing.expectError(
            error.ConstraintViolation,
            conn.execute("UPDATE authors SET id = 2 WHERE id = 1"),
        );

        // NULL child keys are allowed by SQL FK semantics.
        try conn.execute("INSERT INTO books (id, author_id, title) VALUES (12, NULL, 'draft')");
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try std.testing.expectError(
            error.ConstraintViolation,
            conn.execute("INSERT INTO books (id, author_id, title) VALUES (13, 99, 'still-missing')"),
        );
        try std.testing.expectError(
            error.ConstraintViolation,
            conn.execute("DELETE FROM authors WHERE id = 1"),
        );

        var result = try conn.query("SELECT * FROM books");
        defer result.deinit();
        std.debug.assert(result.rows.items.len == 2);
        std.log.info("[PASS] FOREIGN KEY persists across reopen: {d} child rows", .{result.rows.items.len});
    }
}

fn testForeignKeyActionsPersist(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] FOREIGN KEY actions are enforced and survive reopen", .{});
    const path = try test_dir.dbPath("foreign_key_actions.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE cascade_parent (id INTEGER PRIMARY KEY, name TEXT)");
        try conn.execute("CREATE TABLE cascade_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES cascade_parent(id) ON DELETE CASCADE, name TEXT)");
        try conn.execute("INSERT INTO cascade_parent (id, name) VALUES (1, 'parent')");
        try conn.execute("INSERT INTO cascade_child (id, parent_id, name) VALUES (10, 1, 'child')");

        try conn.execute("CREATE TABLE null_parent (id INTEGER PRIMARY KEY, name TEXT)");
        try conn.execute("CREATE TABLE null_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES null_parent(id) ON DELETE SET NULL, name TEXT)");
        try conn.execute("INSERT INTO null_parent (id, name) VALUES (1, 'parent')");
        try conn.execute("INSERT INTO null_child (id, parent_id, name) VALUES (10, 1, 'child')");

        try conn.execute("CREATE TABLE update_parent (id INTEGER PRIMARY KEY, name TEXT)");
        try conn.execute("CREATE TABLE update_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES update_parent(id) ON UPDATE CASCADE, name TEXT)");
        try conn.execute("INSERT INTO update_parent (id, name) VALUES (1, 'parent')");
        try conn.execute("INSERT INTO update_child (id, parent_id, name) VALUES (10, 1, 'child')");

        try conn.execute("CREATE TABLE required_parent (id INTEGER PRIMARY KEY, name TEXT)");
        try conn.execute("CREATE TABLE required_child (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES required_parent(id) ON DELETE SET NULL, name TEXT)");
        try conn.execute("INSERT INTO required_parent (id, name) VALUES (1, 'parent')");
        try conn.execute("INSERT INTO required_child (id, parent_id, name) VALUES (10, 1, 'child')");
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("DELETE FROM cascade_parent WHERE id = 1");
        var cascade_result = try conn.query("SELECT * FROM cascade_child");
        defer cascade_result.deinit();
        std.debug.assert(cascade_result.rows.items.len == 0);

        try conn.execute("DELETE FROM null_parent WHERE id = 1");
        var null_result = try conn.query("SELECT * FROM null_child");
        defer null_result.deinit();
        std.debug.assert(null_result.rows.items.len == 1);
        std.debug.assert(null_result.rows.items[0].values[1] == .Null);

        try conn.execute("UPDATE update_parent SET id = 2 WHERE id = 1");
        var update_result = try conn.query("SELECT * FROM update_child");
        defer update_result.deinit();
        std.debug.assert(update_result.rows.items.len == 1);
        std.debug.assert(update_result.rows.items[0].values[1].Integer == 2);

        try std.testing.expectError(
            error.MissingRequiredValue,
            conn.execute("DELETE FROM required_parent WHERE id = 1"),
        );
        var required_result = try conn.query("SELECT * FROM required_child");
        defer required_result.deinit();
        std.debug.assert(required_result.rows.items.len == 1);
        std.debug.assert(required_result.rows.items[0].values[1].Integer == 1);

        std.log.info("[PASS] FOREIGN KEY actions persisted and executed", .{});
    }
}

fn testCheckConstraintPersists(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] CHECK constraints are enforced and survive reopen", .{});
    const path = try test_dir.dbPath("check_constraint.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE products (id INTEGER, price INTEGER CHECK(price > 0), stock INTEGER, CHECK(stock > 0))");
        try conn.execute("INSERT INTO products (id, price, stock) VALUES (1, 10, 5)");

        try std.testing.expectError(
            error.ConstraintViolation,
            conn.execute("INSERT INTO products (id, price, stock) VALUES (2, 0, 5)"),
        );
        try std.testing.expectError(
            error.ConstraintViolation,
            conn.execute("UPDATE products SET stock = 0 WHERE id = 1"),
        );

        // SQL CHECK semantics reject FALSE only; UNKNOWN/NULL passes.
        try conn.execute("INSERT INTO products (id, price, stock) VALUES (3, NULL, NULL)");
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try std.testing.expectError(
            error.ConstraintViolation,
            conn.execute("INSERT INTO products (id, price, stock) VALUES (4, 2, 0)"),
        );

        var result = try conn.query("SELECT * FROM products");
        defer result.deinit();
        std.debug.assert(result.rows.items.len == 2);
        std.log.info("[PASS] CHECK persists across reopen: {d} rows", .{result.rows.items.len});
    }
}

fn testColumnUniqueConstraintPersists(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Inline UNIQUE column constraint is enforced and survives reopen", .{});
    const path = try test_dir.dbPath("col_unique.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE accounts (id INTEGER, email TEXT UNIQUE)");
        try conn.execute("INSERT INTO accounts (id, email) VALUES (1, 'a@example.com')");

        // A duplicate of the inline-UNIQUE column must be rejected.
        try std.testing.expectError(
            error.UniqueConstraintViolation,
            conn.execute("INSERT INTO accounts (id, email) VALUES (2, 'a@example.com')"),
        );

        // NULLs remain distinct under the inline constraint too.
        try conn.execute("INSERT INTO accounts (id, email) VALUES (3, NULL)");
        try conn.execute("INSERT INTO accounts (id, email) VALUES (4, NULL)");
    }

    // Reopen: the auto-created unique index is loaded from the catalog, so the
    // constraint is still enforced without re-running any DDL.
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try std.testing.expectError(
            error.UniqueConstraintViolation,
            conn.execute("INSERT INTO accounts (id, email) VALUES (5, 'a@example.com')"),
        );

        // A genuinely new value still inserts.
        try conn.execute("INSERT INTO accounts (id, email) VALUES (6, 'b@example.com')");

        var result = try conn.query("SELECT * FROM accounts");
        defer result.deinit();
        std.debug.assert(result.rows.items.len == 4);
        std.log.info("[PASS] Inline UNIQUE persists across reopen: {d} rows", .{result.rows.items.len});
    }
}

fn testTableUniqueConstraintPersists(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Table-level UNIQUE constraint is enforced and survives reopen", .{});
    const path = try test_dir.dbPath("table_unique.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE memberships (org_id INTEGER, user_id INTEGER, role TEXT, UNIQUE(org_id, user_id))");
        try conn.execute("INSERT INTO memberships (org_id, user_id, role) VALUES (1, 10, 'owner')");
        try conn.execute("INSERT INTO memberships (org_id, user_id, role) VALUES (1, 11, 'member')");
        try conn.execute("INSERT INTO memberships (org_id, user_id, role) VALUES (2, 10, 'owner')");

        try std.testing.expectError(
            error.UniqueConstraintViolation,
            conn.execute("INSERT INTO memberships (org_id, user_id, role) VALUES (1, 10, 'duplicate')"),
        );

        // NULLs are distinct for table-level UNIQUE constraints too.
        try conn.execute("INSERT INTO memberships (org_id, user_id, role) VALUES (3, NULL, 'pending')");
        try conn.execute("INSERT INTO memberships (org_id, user_id, role) VALUES (3, NULL, 'pending-again')");
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try std.testing.expectError(
            error.UniqueConstraintViolation,
            conn.execute("INSERT INTO memberships (org_id, user_id, role) VALUES (1, 10, 'still-duplicate')"),
        );

        var result = try conn.query("SELECT * FROM memberships");
        defer result.deinit();
        std.debug.assert(result.rows.items.len == 5);
        std.log.info("[PASS] Table-level UNIQUE persists across reopen: {d} rows", .{result.rows.items.len});
    }
}

fn testUniqueNullsAreDistinct(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] UNIQUE index allows multiple NULLs but rejects real duplicates", .{});
    const path = try test_dir.dbPath("unique_null.db");
    defer allocator.free(path);

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    try conn.execute("CREATE TABLE u (id INTEGER, email TEXT)");
    try conn.execute("CREATE UNIQUE INDEX idx_u_email ON u (email)");

    // SQL standard: NULLs are distinct in a UNIQUE index, so multiple NULLs are allowed.
    try conn.execute("INSERT INTO u (id, email) VALUES (1, NULL)");
    try conn.execute("INSERT INTO u (id, email) VALUES (2, NULL)");

    // A real duplicate non-NULL value must still be rejected.
    try conn.execute("INSERT INTO u (id, email) VALUES (3, 'a@example.com')");
    try std.testing.expectError(
        error.UniqueConstraintViolation,
        conn.execute("INSERT INTO u (id, email) VALUES (4, 'a@example.com')"),
    );

    var result = try conn.query("SELECT * FROM u");
    defer result.deinit();
    std.debug.assert(result.rows.items.len == 3);
    std.log.info("[PASS] UNIQUE NULL distinctness: {d} rows", .{result.rows.items.len});
}

fn testBasicCreateAndSelect(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Basic CREATE TABLE and SELECT on empty table", .{});
    const path = try test_dir.dbPath("basic.db");
    defer allocator.free(path);

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    try conn.execute("CREATE TABLE IF NOT EXISTS test (id INTEGER, name TEXT)");
    var result = try conn.query("SELECT * FROM test");
    defer result.deinit();

    std.log.info("[PASS] Basic CREATE and SELECT: {d} rows", .{result.rows.items.len});
}

fn testInsertAndSelect(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] INSERT and SELECT", .{});
    const path = try test_dir.dbPath("insert.db");
    defer allocator.free(path);

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
    const path = try test_dir.dbPath("multi.db");
    defer allocator.free(path);

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
    const path = try test_dir.dbPath("persist.db");
    defer allocator.free(path);

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
    const path = try test_dir.dbPath("update.db");
    defer allocator.free(path);

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
    const path = try test_dir.dbPath("large.db");
    defer allocator.free(path);

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
