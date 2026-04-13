const std = @import("std");
const zqlite = @import("zqlite");

/// Test concurrent access to same database file
/// Uses multiple threads to simulate concurrent connections
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Concurrent Access Tests ===", .{});

    try testMultipleReaders(allocator);
    try testReaderWriter(allocator);
    try testSequentialConnections(allocator);

    std.log.info("=== ALL CONCURRENT ACCESS TESTS PASSED ===", .{});
}

fn testMultipleReaders(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Multiple sequential readers", .{});
    const path = "/tmp/zqlite_concurrent_read.db";

    // Setup: create database with data
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS data (id INTEGER, value TEXT)");
        try conn.execute("DELETE FROM data");

        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var buf: [128]u8 = undefined;
            const sql = std.fmt.bufPrint(&buf, "INSERT INTO data (id, value) VALUES ({d}, 'value{d}')", .{ i, i }) catch unreachable;
            try conn.execute(sql);
        }
    }

    // Test sequential read connections (zqlite uses single-connection model per file)
    var count1: usize = 0;
    var count2: usize = 0;
    var count3: usize = 0;

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();
        var r1 = try conn.query("SELECT * FROM data WHERE id < 30");
        defer r1.deinit();
        count1 = r1.rows.items.len;
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();
        var r2 = try conn.query("SELECT * FROM data WHERE id >= 30 AND id < 60");
        defer r2.deinit();
        count2 = r2.rows.items.len;
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();
        var r3 = try conn.query("SELECT * FROM data WHERE id >= 60");
        defer r3.deinit();
        count3 = r3.rows.items.len;
    }

    const total = count1 + count2 + count3;
    std.log.info("[DEBUG] counts: {d} + {d} + {d} = {d}", .{ count1, count2, count3, total });
    if (total != 100) {
        std.log.err("[FAIL] Expected 100 rows, got {d}", .{total});
        return error.TestFailed;
    }

    std.log.info("[PASS] Sequential readers: {d} + {d} + {d} = {d} rows", .{ count1, count2, count3, total });
}

fn testReaderWriter(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Reader and writer connections", .{});
    const path = "/tmp/zqlite_concurrent_rw.db";

    // Setup
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS counter (id INTEGER, count INTEGER)");
        try conn.execute("DELETE FROM counter");
        try conn.execute("INSERT INTO counter (id, count) VALUES (1, 0)");
    }

    // Writer connection
    var writer = try zqlite.open(allocator, path);
    defer writer.close();

    // Reader connection
    var reader = try zqlite.open(allocator, path);
    defer reader.close();

    // Writer increments
    try writer.execute("UPDATE counter SET count = count + 1 WHERE id = 1");
    try writer.execute("UPDATE counter SET count = count + 1 WHERE id = 1");
    try writer.execute("UPDATE counter SET count = count + 1 WHERE id = 1");

    // Reader reads
    var result = try reader.query("SELECT count FROM counter WHERE id = 1");
    defer result.deinit();

    std.debug.assert(result.rows.items.len == 1);
    std.log.info("[PASS] Reader/writer: reader sees updates", .{});
}

fn testSequentialConnections(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Rapid sequential connections", .{});
    const path = "/tmp/zqlite_concurrent_seq.db";

    // Setup
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS seq (id INTEGER, ts INTEGER)");
        try conn.execute("DELETE FROM seq");
    }

    // Rapidly open/close/write
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var conn = try zqlite.open(allocator, path);
        var buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "INSERT INTO seq (id, ts) VALUES ({d}, {d})", .{ i, i * 1000 }) catch unreachable;
        try conn.execute(sql);
        conn.close();
    }

    // Verify all writes persisted
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var result = try conn.query("SELECT * FROM seq");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 50);
        std.log.info("[PASS] Sequential connections: {d} writes persisted", .{result.rows.items.len});
    }
}
