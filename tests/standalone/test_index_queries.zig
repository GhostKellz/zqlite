const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    try checkWriteMaintenance(allocator);
    try checkEdgeCases(allocator);
    try checkDeepDuplicateTree(allocator);
    var dir = try temp_dir.TempDir.init(init.io, allocator, "index-queries");
    defer dir.deinit();
    const path = try dir.dbPath("queries.db");
    defer allocator.free(path);
    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE items (id INTEGER, bucket INTEGER, label TEXT)");
        try conn.execute("BEGIN");
        const insert = try conn.prepare("INSERT INTO items VALUES (?, ?, ?)");
        defer insert.deinit();
        for (0..512) |i| {
            try insert.bind(0, @as(i64, @intCast(i)));
            try insert.bind(1, @as(i64, @intCast(i % 4)));
            try insert.bindParameter(2, .{ .Text = if (i % 2 == 0) "Aa" else "BB" });
            var result = try insert.execute();
            result.deinit();
        }
        try conn.execute("COMMIT");
        try conn.execute("CREATE UNIQUE INDEX item_id ON items (id)");
        try conn.execute("CREATE INDEX item_bucket ON items (bucket)");
        try conn.execute("CREATE INDEX item_label ON items (label)");
        try checkQueries(conn);
        try conn.execute("ANALYZE");
        try checkQueries(conn);
    }
    const initial_size = try fileSize(init.io, path);
    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try checkQueries(conn);
    }
    try std.testing.expectEqual(initial_size, try fileSize(init.io, path));
    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try checkQueries(conn);
        try conn.execute("BEGIN");
        try conn.execute("UPDATE items SET bucket = 9 WHERE id = 3");
        try expectCount(conn, "SELECT id FROM items WHERE bucket = 9", 1);
        try conn.execute("DELETE FROM items WHERE id = 7");
        try expectCount(conn, "SELECT id FROM items WHERE bucket = 3", 126);
        try conn.execute("ROLLBACK");
        try checkQueries(conn);
        try conn.execute("UPDATE items SET bucket = 9 WHERE id = 3");
        try conn.execute("DELETE FROM items WHERE id = 7");
    }
    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try expectCount(conn, "SELECT id FROM items WHERE bucket = 9", 1);
        try expectCount(conn, "SELECT id FROM items WHERE bucket = 3", 126);
        var integrity = try conn.integrityCheck();
        defer integrity.deinit(allocator);
        try std.testing.expect(integrity.ok);
        const reused = try conn.prepare("SELECT id FROM items WHERE bucket = ?");
        defer reused.deinit();
        try reused.bind(0, @as(i64, 3));
        {
            var result = try reused.execute();
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, 126), result.rows.items.len);
        }
        const writer = try zqlite.open(allocator, path);
        defer writer.close();
        try writer.execute("UPDATE items SET bucket = 8 WHERE id = 11");
        var refreshed = try reused.execute();
        defer refreshed.deinit();
        try std.testing.expectEqual(@as(usize, 125), refreshed.rows.items.len);
    }
    {
        const conn = try zqlite.openWithOptions(allocator, path, zqlite.OpenOptions.READ_ONLY);
        defer conn.close();
        try expectCount(conn, "SELECT id FROM items WHERE bucket = 3", 125);
        try std.testing.expect(conn.currentProgressEvent().scanned_rows <= 250);
    }
    std.log.info("Index query regression tests passed", .{});
}

fn fileSize(io: std.Io, path: []const u8) !u64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return file.length(io);
}

fn expectCount(conn: *zqlite.Connection, sql: []const u8, expected: usize) !void {
    var result = try conn.query(sql);
    defer result.deinit();
    try std.testing.expectEqual(expected, result.rows.items.len);
}

fn checkQueries(conn: *zqlite.Connection) !void {
    const stmt = try conn.prepare("SELECT id FROM items WHERE id = ?");
    defer stmt.deinit();
    for ([_]i64{ 3, 400, 7 }) |id| {
        try stmt.bind(0, id);
        var result = try stmt.execute();
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
        try std.testing.expectEqual(id, result.rows.items[0].values[0].Integer);
        try std.testing.expect(conn.currentProgressEvent().scanned_rows <= 2);
    }
    // Every table leaf boundary must remain reachable by a point lookup.
    for (0..512) |i| {
        try stmt.bind(0, @as(i64, @intCast(i)));
        var result = try stmt.execute();
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
        try std.testing.expectEqual(@as(i64, @intCast(i)), result.rows.items[0].values[0].Integer);
    }
    try stmt.bindNull(0);
    var null_result = try stmt.execute();
    defer null_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), null_result.rows.items.len);
    try expectCount(conn, "SELECT id FROM items WHERE bucket = 3", 128);
    try std.testing.expect(conn.currentProgressEvent().scanned_rows <= 256);
    try expectCount(conn, "SELECT id FROM items WHERE bucket = 3 AND id < 8", 2);
    const duplicates = try conn.prepare("SELECT id FROM items WHERE bucket = :bucket ORDER BY id");
    defer duplicates.deinit();
    for ([_]i64{ 3, 0, 2 }) |bucket| {
        try duplicates.bindNamedParameter("bucket", .{ .Integer = bucket });
        var result = try duplicates.execute();
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 128), result.rows.items.len);
        for (result.rows.items, 0..) |row, i| {
            try std.testing.expectEqual(@as(i64, @intCast(i * 4)) + bucket, row.values[0].Integer);
        }
        try std.testing.expect(conn.currentProgressEvent().scanned_rows <= 256);
    }
    // These strings collide under the existing persistent index hash.
    try expectCount(conn, "SELECT id FROM items WHERE label = 'Aa'", 256);
    try expectCount(conn, "SELECT id FROM items WHERE label = 'BB'", 256);
    try expectCount(conn, "SELECT id FROM items WHERE id = 3.0", 1);
    try expectCount(conn, "SELECT items.id FROM items WHERE id = 3", 1);
    conn.setResourceLimits(.{ .max_scanned_rows = 130 });
    try std.testing.expectError(error.ResourceLimitExceeded, conn.query("SELECT id FROM items WHERE bucket = 3 AND id > 3"));
    conn.setResourceLimits(.{});
}

fn checkEdgeCases(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.openMemory(allocator);
    defer conn.close();
    try conn.execute("CREATE TABLE edges (id INTEGER, value TEXT)");
    try conn.execute("INSERT INTO edges VALUES (1, 'Aa'), (2, 'BB'), (3, NULL)");
    try conn.execute("CREATE UNIQUE INDEX edge_value ON edges (value)");
    try expectCount(conn, "SELECT id FROM edges WHERE value = 'Aa'", 1);
    try expectCount(conn, "SELECT id FROM edges WHERE value = 'BB'", 1);
    try std.testing.expectError(error.UniqueConstraintViolation, conn.execute("INSERT INTO edges VALUES (4, 'Aa')"));
    try expectCount(conn, "SELECT id FROM edges WHERE value = NULL", 0);
    try expectCount(conn, "SELECT id FROM edges WHERE value = 1", 0);

    try conn.execute("CREATE TABLE large_first (n INTEGER)");
    try conn.execute("INSERT INTO large_first VALUES (9007199254740993)");
    try conn.execute("CREATE INDEX large_key ON large_first (n)");
    try expectCount(conn, "SELECT * FROM large_first WHERE n = 9007199254740993", 1);

    try conn.execute("CREATE TABLE numbers (value REAL)");
    try conn.execute("INSERT INTO numbers VALUES (1), (1.0), (0), (0.0), (1.5), (NULL)");
    const insert_zero = try conn.prepare("INSERT INTO numbers VALUES (?)");
    defer insert_zero.deinit();
    try insert_zero.bindParameter(0, .{ .Real = -0.0 });
    var inserted = try insert_zero.execute();
    inserted.deinit();
    try conn.execute("CREATE INDEX number_value ON numbers (value)");
    try expectCount(conn, "SELECT value FROM numbers WHERE value = 1", 2);
    try expectCount(conn, "SELECT value FROM numbers WHERE value = 1.0", 2);
    try expectCount(conn, "SELECT value FROM numbers WHERE value = 0", 3);
    try expectCount(conn, "SELECT value FROM numbers WHERE value = 1.5", 1);
    const numeric = try conn.prepare("SELECT value FROM numbers WHERE value = ?");
    defer numeric.deinit();
    for ([_]f64{ 1.0, -0.0, 1.5 }) |value| {
        try numeric.bindParameter(0, .{ .Real = value });
        var result = try numeric.execute();
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, if (value == 1) 2 else if (value == 0) 3 else 1), result.rows.items.len);
    }
    try conn.execute("INSERT INTO numbers VALUES (9007199254740992), (9007199254740993)");
    try expectCount(conn, "SELECT value FROM numbers WHERE value = 9007199254740992.0", 2);

    try conn.execute("CREATE TABLE composite (a INTEGER, b INTEGER)");
    try conn.execute("INSERT INTO composite VALUES (1, 2), (1, 3)");
    try conn.execute("CREATE UNIQUE INDEX composite_ab ON composite (a, b)");
    try conn.execute("ANALYZE");
    try expectCount(conn, "SELECT b FROM composite WHERE a = 1", 2);
    try conn.execute("CREATE TABLE edge_source (id INTEGER, value TEXT)");
    try conn.execute("INSERT INTO edge_source VALUES (99, 'Aa')");
    try expectCount(conn, "WITH edges AS (SELECT id, value FROM edge_source) SELECT id FROM edges WHERE value = 'Aa' AND id = 99", 1);

    // Invalidation is lazy so writes cannot free their own executing cached plan.
    try conn.execute("CREATE TABLE cached (id INTEGER)");
    try conn.execute("INSERT INTO cached VALUES (1), (2), (3)");
    try expectCount(conn, "SELECT id FROM cached WHERE id = 2", 1);
    try conn.execute("CREATE INDEX cached_id ON cached (id)");
    try expectCount(conn, "SELECT id FROM cached WHERE id = 2", 1);
    try std.testing.expect(conn.currentProgressEvent().scanned_rows <= 2);
    try conn.execute("DROP INDEX cached_id");
    try expectCount(conn, "SELECT id FROM cached WHERE id = 2", 1);

    // Fail after the index traversal, partway through residual filtering.
    conn.setResourceLimits(.{ .max_scanned_rows = 4 });
    try std.testing.expectError(error.ResourceLimitExceeded, conn.query("SELECT value FROM numbers WHERE value = 0"));
    conn.setResourceLimits(.{});
    try expectCount(conn, "SELECT value FROM numbers WHERE value = 0", 3);
    conn.setResourceLimits(.{ .max_result_rows = 1 });
    try std.testing.expectError(error.ResourceLimitExceeded, conn.query("SELECT value FROM numbers WHERE value = 1"));
    conn.setResourceLimits(.{});
}

fn checkDeepDuplicateTree(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.openMemory(allocator);
    defer conn.close();
    try conn.execute("CREATE TABLE repeated (id INTEGER, bucket INTEGER)");
    const insert = try conn.prepare("INSERT INTO repeated VALUES (?, 7)");
    defer insert.deinit();
    try conn.execute("BEGIN");
    for (0..2304) |i| {
        try insert.bind(0, @as(i64, @intCast(i)));
        var result = try insert.execute();
        result.deinit();
    }
    try conn.execute("COMMIT");
    try conn.execute("CREATE INDEX repeated_bucket ON repeated (bucket)");
    try expectCount(conn, "SELECT id FROM repeated WHERE bucket = 7", 2304);
    try expectCount(conn, "SELECT id FROM repeated WHERE bucket = 8", 0);
    try std.testing.expectEqual(@as(u64, 0), conn.currentProgressEvent().scanned_rows);
    try conn.execute("DELETE FROM repeated WHERE id < 2200");
    try expectCount(conn, "SELECT id FROM repeated WHERE bucket = 7", 104);
    try conn.execute("UPDATE repeated SET bucket = 8 WHERE id = 2303");
    try expectCount(conn, "SELECT id FROM repeated WHERE bucket = 7", 103);
    try expectCount(conn, "SELECT id FROM repeated WHERE bucket = 8", 1);
    try conn.execute("INSERT INTO repeated VALUES (3000, 7)");
    try expectCount(conn, "SELECT id FROM repeated WHERE bucket = 7", 104);
}

fn checkWriteMaintenance(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.openMemory(allocator);
    defer conn.close();
    try conn.execute("CREATE TABLE writes (id INTEGER PRIMARY KEY, label TEXT, active INTEGER)");
    try conn.execute("CREATE UNIQUE INDEX write_label ON writes (label) WHERE active = 1");
    try conn.execute("CREATE INDEX write_active ON writes (active)");
    try conn.execute("INSERT INTO writes VALUES (1, 'Aa', 1), (2, 'BB', 1), (3, 'Aa', 0)");
    try std.testing.expectError(error.UniqueConstraintViolation, conn.execute("INSERT INTO writes VALUES (4, 'same', 1), (5, 'same', 1)"));
    try expectCount(conn, "SELECT * FROM writes", 3);
    try conn.execute("BEGIN");
    try conn.execute("INSERT INTO writes VALUES (4, 'prior', 1)");
    try std.testing.expectError(error.UniqueConstraintViolation, conn.execute("INSERT INTO writes VALUES (5, 'same', 1), (6, 'same', 1)"));
    try expectCount(conn, "SELECT * FROM writes", 4);
    try conn.execute("SAVEPOINT edits");
    try conn.execute("UPDATE writes SET label = 'changed' WHERE id = 1");
    try conn.execute("UPDATE writes SET active = 1 WHERE id = 3");
    try expectCount(conn, "SELECT * FROM writes WHERE active = 1", 4);
    try std.testing.expectError(error.UniqueConstraintViolation, conn.execute("UPDATE writes SET label = 'BB' WHERE id = 3"));
    try conn.execute("ROLLBACK TO edits");
    try expectCount(conn, "SELECT * FROM writes WHERE active = 1", 3);
    try conn.execute("RELEASE edits");
    try conn.execute("INSERT INTO writes VALUES (1, 'ignored', 1) ON CONFLICT (id) DO NOTHING");
    try conn.execute("INSERT INTO writes VALUES (1, 'updated', 1) ON CONFLICT (id) DO UPDATE SET label = excluded.label");
    try conn.execute("INSERT INTO writes VALUES (5, 'Aa', 1)");
    try conn.execute("DELETE FROM writes WHERE id = 2");
    try conn.execute("INSERT INTO writes VALUES (6, 'BB', 1)");
    try conn.execute("COMMIT");
    try expectCount(conn, "SELECT * FROM writes WHERE active = 1", 4);
    try conn.execute("CREATE UNIQUE INDEX write_expr ON writes ((id + 1))");
    try std.testing.expectError(error.UniqueConstraintViolation, conn.execute("UPDATE writes SET id = 5 WHERE id = 6"));
    try conn.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)");
    try conn.execute("CREATE TABLE child (id INTEGER, parent_id INTEGER REFERENCES parent(id) ON DELETE CASCADE ON UPDATE CASCADE)");
    try conn.execute("CREATE INDEX child_parent ON child (parent_id)");
    try conn.execute("INSERT INTO parent VALUES (1)");
    try conn.execute("INSERT INTO child VALUES (1, 1), (2, 1)");
    try conn.execute("UPDATE parent SET id = 9 WHERE id = 1");
    try expectCount(conn, "SELECT * FROM child WHERE parent_id = 9", 2);
    try expectCount(conn, "SELECT * FROM child WHERE parent_id = 1", 0);
    try conn.execute("DELETE FROM parent WHERE id = 9");
    try expectCount(conn, "SELECT * FROM child WHERE parent_id = 9", 0);
    try conn.configureResourceLimits(.{ .max_affected_rows = 1 });
    try std.testing.expectError(error.ResourceLimitExceeded, conn.query("UPDATE writes SET active = 0 RETURNING label"));
    try conn.configureResourceLimits(.{});
    try expectCount(conn, "SELECT * FROM writes WHERE active = 1", 4);
    try conn.execute("CREATE TABLE zeros (n REAL)");
    try conn.execute("CREATE UNIQUE INDEX zero_key ON zeros (n)");
    try conn.execute("INSERT INTO zeros VALUES (-0.0)");
    try std.testing.expectError(error.UniqueConstraintViolation, conn.execute("INSERT INTO zeros VALUES (0.0)"));
    try expectCount(conn, "SELECT * FROM zeros WHERE n = 0", 1);
    var integrity = try conn.integrityCheck();
    defer integrity.deinit(allocator);
    try std.testing.expect(integrity.ok);
}
