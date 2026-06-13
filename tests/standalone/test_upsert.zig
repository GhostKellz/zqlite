const std = @import("std");
const zqlite = @import("zqlite");

// Regression coverage for INSERT ... ON CONFLICT DO UPDATE SET col = excluded.col.
// This mirrors the prepared-statement + bound-parameter upsert path that real
// callers use, and asserts that:
//   1. `excluded.<col>` resolves to the would-be-inserted row's value.
//   2. Columns NOT in the SET list keep their existing-row values.
//   3. The parser accepts EXCLUDED references (both literal and parameterized).
//   4. No memory leaks occur on the success path.

var failures: u32 = 0;

fn check(cond: bool, comptime msg: []const u8) void {
    if (cond) {
        std.debug.print("  PASS: {s}\n", .{msg});
    } else {
        std.debug.print("  FAIL: {s}\n", .{msg});
        failures += 1;
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("\nMEMORY LEAKS DETECTED!\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("=== ZQLite UPSERT / excluded.* Regression Suite ===\n\n", .{});

    try testParameterizedExcludedUpsert(allocator);
    try testLiteralExcludedUpsert(allocator);
    try testIntegerExcludedUpsert(allocator);
    try testMixedLiteralAndExcluded(allocator);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("=== ALL UPSERT TESTS PASSED ===\n", .{});
    } else {
        std.debug.print("=== {d} UPSERT TEST(S) FAILED ===\n", .{failures});
        std.process.exit(1);
    }
}

// Mirrors the exact prepared-statement upsert used by callers like zaur's
// addTrustedKey: VALUES (?,?,?,?) + ON CONFLICT DO UPDATE SET col = excluded.col.
fn testParameterizedExcludedUpsert(allocator: std.mem.Allocator) !void {
    std.debug.print("[1] Parameterized excluded.* upsert (prepared + bind)\n", .{});

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE trusted_keys (fingerprint TEXT PRIMARY KEY, owner TEXT, note TEXT, added_at TEXT)");

    try upsertKey(conn, "FPR1", "owner-v1", "note-v1", "2026-06-12T00:00:00Z");
    try upsertKey(conn, "FPR1", "owner-v2", "note-v2", "2099-01-01T00:00:00Z");

    var result = try conn.query("SELECT owner, note, added_at FROM trusted_keys WHERE fingerprint = 'FPR1'");
    defer result.deinit();

    if (result.next()) |row| {
        var r = row;
        defer r.deinit();
        check(std.mem.eql(u8, r.getText(0) orelse "", "owner-v2"), "owner updated to excluded value");
        check(std.mem.eql(u8, r.getText(1) orelse "", "note-v2"), "note updated to excluded value");
        // added_at is NOT in the SET clause, so it must retain the original row value.
        check(std.mem.eql(u8, r.getText(2) orelse "", "2026-06-12T00:00:00Z"), "added_at preserved (not in SET list)");
    } else {
        check(false, "row exists after upsert");
    }

    var count = try conn.query("SELECT COUNT(*) FROM trusted_keys");
    defer count.deinit();
    if (count.next()) |row| {
        var r = row;
        defer r.deinit();
        check((r.getInt(0) orelse 0) == 1, "exactly one row after conflict (no duplicate insert)");
    }
}

fn upsertKey(conn: anytype, fpr: []const u8, owner: []const u8, note: []const u8, added_at: []const u8) !void {
    var stmt = try conn.prepare(
        \\INSERT INTO trusted_keys (fingerprint, owner, note, added_at)
        \\VALUES (?, ?, ?, ?)
        \\ON CONFLICT(fingerprint) DO UPDATE SET
        \\    owner = excluded.owner,
        \\    note = excluded.note
    );
    defer stmt.deinit();
    try stmt.bind(0, fpr);
    try stmt.bind(1, owner);
    try stmt.bind(2, note);
    try stmt.bind(3, added_at);
    var result = try stmt.execute();
    result.deinit();
}

fn testLiteralExcludedUpsert(allocator: std.mem.Allocator) !void {
    std.debug.print("[2] Literal excluded.* upsert (exec)\n", .{});

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)");
    try conn.execute("INSERT INTO kv VALUES ('a', 'old')");

    const affected = try conn.exec(
        \\INSERT INTO kv (k, v) VALUES ('a', 'new')
        \\ON CONFLICT(k) DO UPDATE SET v = excluded.v
    );
    check(affected == 1, "one row affected by conflicting upsert");

    var result = try conn.query("SELECT v FROM kv WHERE k = 'a'");
    defer result.deinit();
    if (result.next()) |row| {
        var r = row;
        defer r.deinit();
        check(std.mem.eql(u8, r.getText(0) orelse "", "new"), "value replaced with excluded value");
    } else {
        check(false, "row exists after literal upsert");
    }
}

fn testIntegerExcludedUpsert(allocator: std.mem.Allocator) !void {
    std.debug.print("[3] Integer column excluded.* upsert\n", .{});

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE counters (id INTEGER PRIMARY KEY, hits INTEGER)");
    try conn.execute("INSERT INTO counters VALUES (1, 10)");

    _ = try conn.exec(
        \\INSERT INTO counters (id, hits) VALUES (1, 42)
        \\ON CONFLICT(id) DO UPDATE SET hits = excluded.hits
    );

    var result = try conn.query("SELECT hits FROM counters WHERE id = 1");
    defer result.deinit();
    if (result.next()) |row| {
        var r = row;
        defer r.deinit();
        check((r.getInt(0) orelse 0) == 42, "integer column replaced with excluded value");
    } else {
        check(false, "row exists after integer upsert");
    }
}

fn testMixedLiteralAndExcluded(allocator: std.mem.Allocator) !void {
    std.debug.print("[4] Mixed literal + excluded.* in one SET list\n", .{});

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE pkg (name TEXT PRIMARY KEY, version TEXT, status TEXT)");
    try conn.execute("INSERT INTO pkg VALUES ('foo', '1.0', 'stale')");

    _ = try conn.exec(
        \\INSERT INTO pkg (name, version, status) VALUES ('foo', '2.0', 'ignored')
        \\ON CONFLICT(name) DO UPDATE SET version = excluded.version, status = 'fresh'
    );

    var result = try conn.query("SELECT version, status FROM pkg WHERE name = 'foo'");
    defer result.deinit();
    if (result.next()) |row| {
        var r = row;
        defer r.deinit();
        check(std.mem.eql(u8, r.getText(0) orelse "", "2.0"), "excluded column takes inserted value");
        check(std.mem.eql(u8, r.getText(1) orelse "", "fresh"), "literal column takes literal value");
    } else {
        check(false, "row exists after mixed upsert");
    }
}
