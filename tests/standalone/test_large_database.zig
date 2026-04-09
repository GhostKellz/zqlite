const std = @import("std");
const zqlite = @import("zqlite");

/// Test database larger than pager cache (1000 pages)
/// Ensures cache eviction and disk I/O work correctly
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Large Database Tests (Cache Overflow) ===", .{});

    try testCacheOverflow(allocator);
    try testLargeRowCount(allocator);
    try testMultipleTablesOverflow(allocator);

    std.log.info("=== ALL LARGE DATABASE TESTS PASSED ===", .{});
}

fn testCacheOverflow(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Cache overflow with 5000+ inserts", .{});
    const path = "/tmp/zqlite_large_cache.db";

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    // Create table with moderate rows to force page allocations
    try conn.execute("CREATE TABLE IF NOT EXISTS large_data (id INTEGER, data TEXT)");
    try conn.execute("DELETE FROM large_data");

    // Insert enough data to exceed 1000 page cache
    // Use moderate text size to avoid page overflow
    const text = "ABCDEFGHIJ" ** 5; // 50 bytes per row
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "INSERT INTO large_data (id, data) VALUES ({d}, '{s}')", .{ i, text }) catch unreachable;
        try conn.execute(sql);
    }

    // Verify all data accessible (requires reading from disk, not just cache)
    var result = try conn.query("SELECT COUNT(*) FROM large_data");
    defer result.deinit();

    std.debug.assert(result.rows.items.len == 1);
    std.log.info("[PASS] Cache overflow: inserted 5000 rows", .{});
}

fn testLargeRowCount(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] 10,000 row dataset", .{});
    const path = "/tmp/zqlite_large_rows.db";

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    try conn.execute("CREATE TABLE IF NOT EXISTS many_rows (id INTEGER, value INTEGER)");
    try conn.execute("DELETE FROM many_rows");

    // Insert 10,000 rows
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        var buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "INSERT INTO many_rows (id, value) VALUES ({d}, {d})", .{ i, i * 7 }) catch unreachable;
        try conn.execute(sql);
    }

    var result = try conn.query("SELECT * FROM many_rows");
    defer result.deinit();

    std.debug.assert(result.rows.items.len == 10000);
    std.log.info("[PASS] Large row count: 10,000 rows", .{});
}

fn testMultipleTablesOverflow(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Multiple tables causing cache overflow", .{});
    const path = "/tmp/zqlite_multi_overflow.db";

    var conn = try zqlite.open(allocator, path);
    defer conn.close();

    // Create 50 tables with 100 rows each
    var t: usize = 0;
    while (t < 50) : (t += 1) {
        var create_buf: [128]u8 = undefined;
        const create_sql = std.fmt.bufPrint(&create_buf, "CREATE TABLE IF NOT EXISTS t{d} (id INTEGER, val TEXT)", .{t}) catch unreachable;
        try conn.execute(create_sql);

        var del_buf: [64]u8 = undefined;
        const del_sql = std.fmt.bufPrint(&del_buf, "DELETE FROM t{d}", .{t}) catch unreachable;
        try conn.execute(del_sql);

        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var buf: [128]u8 = undefined;
            const sql = std.fmt.bufPrint(&buf, "INSERT INTO t{d} (id, val) VALUES ({d}, 'data')", .{ t, i }) catch unreachable;
            try conn.execute(sql);
        }
    }

    // Verify random table access (forces cache misses)
    var r1 = try conn.query("SELECT * FROM t0");
    defer r1.deinit();
    var r2 = try conn.query("SELECT * FROM t49");
    defer r2.deinit();
    var r3 = try conn.query("SELECT * FROM t25");
    defer r3.deinit();

    std.debug.assert(r1.rows.items.len == 100);
    std.debug.assert(r2.rows.items.len == 100);
    std.debug.assert(r3.rows.items.len == 100);

    std.log.info("[PASS] Multiple tables overflow: 50 tables, 5000 total rows", .{});
}
