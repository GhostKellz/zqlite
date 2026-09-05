const std = @import("std");
const zqlite = @import("zqlite");

const TestCase = struct {
    name: []const u8,
    setup: []const []const u8,
    query: []const u8,
};

const cases = [_]TestCase{
    .{
        .name = "signed_insert_literals",
        .setup = &.{
            "CREATE TABLE signed_values (i INTEGER, r REAL)",
            "INSERT INTO signed_values VALUES (-42, -3.5), (+17, 2.5)",
        },
        .query = "SELECT i, r FROM signed_values ORDER BY i",
    },
    .{
        .name = "populated_add_column",
        .setup = &.{
            "CREATE TABLE migrating (id INTEGER)",
            "INSERT INTO migrating VALUES (1), (2)",
            "CREATE UNIQUE INDEX migrating_id ON migrating (id)",
            "ALTER TABLE migrating ADD COLUMN note TEXT",
            "ALTER TABLE migrating ADD COLUMN state TEXT NOT NULL DEFAULT 'new'",
        },
        .query = "SELECT id, note, state FROM migrating ORDER BY id",
    },
    .{
        .name = "indexed_duplicates_and_residual_predicate",
        .setup = &.{
            "CREATE TABLE indexed (id INTEGER, bucket INTEGER)",
            "INSERT INTO indexed VALUES (1, 7), (2, 7), (3, 8), (4, NULL)",
            "CREATE INDEX indexed_bucket ON indexed (bucket)",
        },
        .query = "SELECT id FROM indexed WHERE bucket = 7 AND id > 1 ORDER BY id",
    },
    .{
        .name = "indexed_hash_collision",
        .setup = &.{
            "CREATE TABLE indexed (id INTEGER, value TEXT)",
            "INSERT INTO indexed VALUES (1, 'Aa'), (2, 'BB'), (3, 'Aa')",
            "CREATE INDEX indexed_value ON indexed (value)",
        },
        .query = "SELECT id FROM indexed WHERE value = 'Aa' ORDER BY id",
    },
    .{
        .name = "unique_index_hash_collision",
        .setup = &.{
            "CREATE TABLE indexed (id INTEGER, value TEXT)",
            "INSERT INTO indexed VALUES (1, 'Aa'), (2, 'BB'), (3, NULL), (4, NULL)",
            "CREATE UNIQUE INDEX indexed_value ON indexed (value)",
        },
        .query = "SELECT id FROM indexed WHERE value = 'BB' ORDER BY id",
    },
    .{
        .name = "indexed_mixed_numeric_equality",
        .setup = &.{
            "CREATE TABLE indexed (id INTEGER, value BLOB)",
            "INSERT INTO indexed VALUES (1, 1), (2, 1.0), (3, '1'), (4, NULL)",
            "CREATE INDEX indexed_value ON indexed (value)",
        },
        .query = "SELECT id FROM indexed WHERE value = 1.0 ORDER BY id",
    },
    .{
        .name = "indexed_changes_and_rollback",
        .setup = &.{
            "CREATE TABLE indexed (id INTEGER, bucket INTEGER)",
            "INSERT INTO indexed VALUES (1, 7), (2, 7), (3, 8)",
            "CREATE INDEX indexed_bucket ON indexed (bucket)",
            "UPDATE indexed SET bucket = 8 WHERE id = 1",
            "BEGIN",
            "DELETE FROM indexed WHERE id = 2",
            "UPDATE indexed SET bucket = 7 WHERE id = 3",
            "ROLLBACK",
        },
        .query = "SELECT id FROM indexed WHERE bucket = 8 ORDER BY id",
    },
    .{
        .name = "composite_index_is_not_single_column_lookup",
        .setup = &.{
            "CREATE TABLE indexed (a INTEGER, b INTEGER)",
            "INSERT INTO indexed VALUES (1, 2), (1, 3)",
            "CREATE UNIQUE INDEX indexed_ab ON indexed (a, b)",
            "ANALYZE",
        },
        .query = "SELECT b FROM indexed WHERE a = 1 ORDER BY b",
    },
    .{
        .name = "basic_where_order",
        .setup = &.{
            "CREATE TABLE users (id INTEGER, name TEXT)",
            "INSERT INTO users VALUES (2, 'Bob')",
            "INSERT INTO users VALUES (1, 'Alice')",
            "INSERT INTO users VALUES (3, 'Carol')",
        },
        .query = "SELECT id, name FROM users WHERE id > 1 ORDER BY id",
    },
    .{
        .name = "null_in_logic",
        .setup = &.{
            "CREATE TABLE nullable (id INTEGER, value INTEGER)",
            "INSERT INTO nullable VALUES (1, 1)",
            "INSERT INTO nullable VALUES (2, NULL)",
            "INSERT INTO nullable VALUES (3, 3)",
        },
        .query = "SELECT id FROM nullable WHERE value IN (NULL, 1) ORDER BY id",
    },
    .{
        .name = "unique_allows_multiple_nulls",
        .setup = &.{
            "CREATE TABLE emails (id INTEGER, email TEXT)",
            "CREATE UNIQUE INDEX idx_emails_email ON emails (email)",
            "INSERT INTO emails VALUES (1, NULL)",
            "INSERT INTO emails VALUES (2, NULL)",
            "INSERT INTO emails VALUES (3, 'a@example.com')",
        },
        .query = "SELECT id, email FROM emails ORDER BY id",
    },
    .{
        .name = "check_allows_unknown",
        .setup = &.{
            "CREATE TABLE products (id INTEGER, price INTEGER CHECK(price > 0))",
            "INSERT INTO products VALUES (1, 10)",
            "INSERT INTO products VALUES (2, NULL)",
        },
        .query = "SELECT id, price FROM products ORDER BY id",
    },
    .{
        .name = "foreign_key_valid_and_null_child",
        .setup = &.{
            "CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id), title TEXT)",
            "INSERT INTO authors VALUES (1, 'Octavia')",
            "INSERT INTO books VALUES (10, 1, 'Kindred')",
            "INSERT INTO books VALUES (11, NULL, 'Draft')",
        },
        .query = "SELECT id, author_id, title FROM books ORDER BY id",
    },
    .{
        .name = "foreign_key_on_delete_cascade",
        .setup = &.{
            "CREATE TABLE parents (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id) ON DELETE CASCADE, name TEXT)",
            "INSERT INTO parents VALUES (1, 'parent')",
            "INSERT INTO children VALUES (10, 1, 'child')",
            "DELETE FROM parents WHERE id = 1",
        },
        .query = "SELECT id, parent_id, name FROM children ORDER BY id",
    },
    .{
        .name = "foreign_key_on_delete_set_null",
        .setup = &.{
            "CREATE TABLE parents (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id) ON DELETE SET NULL, name TEXT)",
            "INSERT INTO parents VALUES (1, 'parent')",
            "INSERT INTO children VALUES (10, 1, 'child')",
            "DELETE FROM parents WHERE id = 1",
        },
        .query = "SELECT id, parent_id, name FROM children ORDER BY id",
    },
    .{
        .name = "foreign_key_on_update_cascade",
        .setup = &.{
            "CREATE TABLE parents (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id) ON UPDATE CASCADE, name TEXT)",
            "INSERT INTO parents VALUES (1, 'parent')",
            "INSERT INTO children VALUES (10, 1, 'child')",
            "UPDATE parents SET id = 2 WHERE id = 1",
        },
        .query = "SELECT id, parent_id, name FROM children ORDER BY id",
    },
    .{
        .name = "insert_default_values",
        .setup = &.{
            "CREATE TABLE defaults_test (id INTEGER DEFAULT 7, name TEXT DEFAULT 'anon', note TEXT)",
            "INSERT INTO defaults_test DEFAULT VALUES",
        },
        .query = "SELECT id, name, note FROM defaults_test",
    },
    .{
        .name = "savepoint_rollback_release",
        .setup = &.{
            "CREATE TABLE savepoint_test (id INTEGER, name TEXT)",
            "BEGIN",
            "INSERT INTO savepoint_test VALUES (1, 'outer')",
            "SAVEPOINT sp",
            "INSERT INTO savepoint_test VALUES (2, 'rolled-back')",
            "ROLLBACK TO sp",
            "RELEASE sp",
            "INSERT INTO savepoint_test VALUES (3, 'kept')",
            "COMMIT",
        },
        .query = "SELECT id, name FROM savepoint_test ORDER BY id",
    },
    .{
        .name = "transaction_rollback_then_commit",
        .setup = &.{
            "CREATE TABLE tx_test (id INTEGER, name TEXT)",
            "BEGIN",
            "INSERT INTO tx_test VALUES (1, 'rolled-back')",
            "ROLLBACK",
            "BEGIN",
            "INSERT INTO tx_test VALUES (2, 'kept')",
            "COMMIT",
        },
        .query = "SELECT id, name FROM tx_test ORDER BY id",
    },
    .{
        .name = "order_by_limit_offset",
        .setup = &.{
            "CREATE TABLE page_test (id INTEGER, name TEXT)",
            "INSERT INTO page_test VALUES (1, 'a')",
            "INSERT INTO page_test VALUES (2, 'b')",
            "INSERT INTO page_test VALUES (3, 'c')",
            "INSERT INTO page_test VALUES (4, 'd')",
        },
        .query = "SELECT id, name FROM page_test ORDER BY id DESC LIMIT 2 OFFSET 1",
    },
    .{
        .name = "multi_column_order_by",
        .setup = &.{
            "CREATE TABLE ordered_pairs (a INTEGER, b INTEGER, label TEXT)",
            "INSERT INTO ordered_pairs VALUES (1, 2, 'a2')",
            "INSERT INTO ordered_pairs VALUES (1, 3, 'a3')",
            "INSERT INTO ordered_pairs VALUES (2, 1, 'b1')",
            "INSERT INTO ordered_pairs VALUES (2, 4, 'b4')",
        },
        .query = "SELECT a, b, label FROM ordered_pairs ORDER BY a ASC, b DESC",
    },
    .{
        .name = "json_date_literal_round_trip",
        .setup = &.{
            "CREATE TABLE literal_test (id INTEGER, payload TEXT, created_at TEXT)",
            "INSERT INTO literal_test VALUES (1, '{\"ok\":true}', '2026-06-24')",
        },
        .query = "SELECT payload, created_at FROM literal_test WHERE id = 1",
    },
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== SQLite Differential Tests ===", .{});
    for (cases) |case| {
        const sqlite_output = try runSqlite(init.io, allocator, case);
        defer allocator.free(sqlite_output);

        const zqlite_output = try runZqlite(allocator, case);
        defer allocator.free(zqlite_output);

        const sqlite_trimmed = std.mem.trim(u8, sqlite_output, "\r\n");
        const zqlite_trimmed = std.mem.trim(u8, zqlite_output, "\r\n");
        if (!std.mem.eql(u8, sqlite_trimmed, zqlite_trimmed)) {
            std.debug.print(
                "SQLite diff failed: {s}\n--- sqlite3 ---\n{s}\n--- zqlite ---\n{s}\n",
                .{ case.name, sqlite_trimmed, zqlite_trimmed },
            );
            return error.SQLiteDifferentialMismatch;
        }
        std.log.info("[PASS] {s}", .{case.name});
    }
    std.log.info("=== ALL SQLITE DIFFERENTIAL TESTS PASSED ===", .{});
}

fn runSqlite(io: std.Io, allocator: std.mem.Allocator, case: TestCase) ![]u8 {
    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(allocator);

    try script.appendSlice(allocator, "PRAGMA foreign_keys=ON;\n");
    for (case.setup) |stmt| {
        try script.appendSlice(allocator, stmt);
        try script.appendSlice(allocator, ";\n");
    }
    try script.appendSlice(allocator, case.query);
    try script.appendSlice(allocator, ";\n");

    const argv = [_][]const u8{
        "sqlite3",
        "-batch",
        "-noheader",
        "-separator",
        "|",
        "-cmd",
        ".nullvalue NULL",
        ":memory:",
        script.items,
    };

    var result = std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.Sqlite3NotFound,
        else => return err,
    };
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    if (!result.term.success()) {
        std.debug.print("sqlite3 failed for {s}: {s}\n", .{ case.name, result.stderr });
        return error.Sqlite3Failed;
    }
    return result.stdout;
}

fn runZqlite(allocator: std.mem.Allocator, case: TestCase) ![]u8 {
    var conn = try zqlite.openMemory(allocator);
    defer conn.close();

    for (case.setup) |stmt| {
        try conn.execute(stmt);
    }

    var result = try conn.query(case.query);
    defer result.deinit();

    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    while (result.next()) |row| {
        var owned_row = row;
        defer owned_row.deinit();

        for (0..owned_row.columnCount()) |i| {
            if (i > 0) try output.append(allocator, '|');
            const value = owned_row.getValue(i) orelse zqlite.storage.Value.Null;
            try appendValue(allocator, &output, value);
        }
        try output.append(allocator, '\n');
    }

    return output.toOwnedSlice(allocator);
}

fn appendValue(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), value: zqlite.storage.Value) !void {
    switch (value) {
        .Null => try output.appendSlice(allocator, "NULL"),
        .Integer => |v| try appendFmt(allocator, output, "{d}", .{v}),
        .Real => |v| try appendFmt(allocator, output, "{d}", .{v}),
        .Text => |v| try output.appendSlice(allocator, v),
        .Blob => |v| try appendFmt(allocator, output, "{x}", .{v}),
        .Boolean => |v| try appendFmt(allocator, output, "{d}", .{if (v) @as(u8, 1) else 0}),
        .SmallInt => |v| try appendFmt(allocator, output, "{d}", .{v}),
        .BigInt => |v| try appendFmt(allocator, output, "{d}", .{v}),
        else => try output.appendSlice(allocator, "NULL"),
    }
}

fn appendFmt(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try output.appendSlice(allocator, formatted);
}
