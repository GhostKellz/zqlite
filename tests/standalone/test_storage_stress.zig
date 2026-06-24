const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

var test_dir: temp_dir.TempDir = undefined;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    test_dir = try .init(init.io, allocator, "zqlite-storage-stress");
    defer test_dir.deinit();

    try stressReopenCheckpointRollbackRecovery(allocator);
    std.log.info("=== ALL STORAGE STRESS TESTS PASSED ===", .{});
}

fn stressReopenCheckpointRollbackRecovery(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] reopen/checkpoint/rollback/recovery stress", .{});
    const path = try test_dir.dbPath("stress.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE stress_items (id INTEGER PRIMARY KEY, value INTEGER, label TEXT)");
        try conn.execute("CREATE UNIQUE INDEX idx_stress_items_id ON stress_items (id)");
        try conn.flush();
    }

    var i: usize = 0;
    while (i < 160) : (i += 1) {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        if (i % 11 == 0) {
            try conn.begin();
            try execInsert(allocator, conn, @intCast(10_000 + i), @intCast(i), "rolled_back");
            try conn.rollback();
        } else if (i % 7 == 0) {
            try conn.begin();
            try execInsert(allocator, conn, @intCast(i), @intCast(i * 3), "tx");
            try conn.commit();
        } else {
            try execInsert(allocator, conn, @intCast(i), @intCast(i * 2), "plain");
        }

        if (i % 13 == 0) {
            const delete_sql = try std.fmt.allocPrint(allocator, "DELETE FROM stress_items WHERE id = {d}", .{i / 2});
            defer allocator.free(delete_sql);
            conn.execute(delete_sql) catch {};
        }

        if (i % 17 == 0) try conn.checkpoint();
        if (i % 29 == 0) {
            var check = try conn.query("PRAGMA integrity_check");
            defer check.deinit();
            try std.testing.expectEqualStrings("ok", check.rows.items[0].values[0].Text);
        }
        try conn.flush();
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();
        var check = try conn.query("PRAGMA integrity_check");
        defer check.deinit();
        try std.testing.expectEqualStrings("ok", check.rows.items[0].values[0].Text);

        var cursor = try conn.openCursor("SELECT * FROM stress_items");
        defer cursor.deinit();
        var seen: usize = 0;
        while (cursor.next()) |row| {
            var owned = row;
            defer owned.deinit();
            seen += 1;
        }
        try std.testing.expect(seen > 100);
    }

    std.log.info("[PASS] storage stress survived deterministic reopen/checkpoint loop", .{});
}

fn execInsert(allocator: std.mem.Allocator, conn: *zqlite.Connection, id: i64, value: i64, label: []const u8) !void {
    const sql = try std.fmt.allocPrint(allocator, "INSERT INTO stress_items VALUES ({d}, {d}, '{s}')", .{ id, value, label });
    defer allocator.free(sql);
    conn.execute(sql) catch |err| switch (err) {
        error.UniqueConstraintViolation => {},
        else => return err,
    };
}
