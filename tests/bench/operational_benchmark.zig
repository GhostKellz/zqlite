const std = @import("std");
const zqlite = @import("zqlite");

const TimedResult = struct {
    name: []const u8,
    operations: usize,
    duration_ns: i128,

    fn print(self: TimedResult) void {
        const duration_ms = @as(f64, @floatFromInt(self.duration_ns)) / 1_000_000.0;
        const duration_s = @max(duration_ms / 1000.0, 0.000_001);
        const ops_per_sec = @as(f64, @floatFromInt(self.operations)) / duration_s;
        std.debug.print("{s:<34} ops={d:<8} ms={d:>9.2} ops/sec={d:>10.0}\n", .{
            self.name,
            self.operations,
            duration_ms,
            ops_per_sec,
        });
    }
};

fn monotonicNs() i128 {
    var ts: std.posix.timespec = undefined;
    const result = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    if (std.posix.errno(result) == .SUCCESS) {
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
    return 0;
}

fn timeIt(name: []const u8, operations: usize, conn: *zqlite.Connection, comptime run: fn (*zqlite.Connection) anyerror!void) !TimedResult {
    const start = monotonicNs();
    try run(conn);
    return .{
        .name = name,
        .operations = operations,
        .duration_ns = monotonicNs() - start,
    };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    std.debug.print("\nZQLite Operational Benchmark Evidence\n", .{});
    std.debug.print("--------------------------------------------------------------------------------\n", .{});

    try conn.execute("CREATE TABLE bench_ops (id INTEGER, value TEXT)");
    const append = try timeIt("append-heavy transaction", 1_000, conn, runAppendHeavy);
    append.print();

    try conn.execute("CREATE INDEX idx_bench_ops_id ON bench_ops (id)");
    const lookup = try timeIt("indexed point lookup", 100, conn, runIndexedLookup);
    lookup.print();

    const materialized = try timeIt("materialized full scan", 50, conn, runMaterializedScan);
    materialized.print();

    const cursor = try timeIt("cursor full scan", 50, conn, runCursorScan);
    cursor.print();

    const limit_abort = try timeIt("resource-limit abort", 100, conn, runResourceLimitAbort);
    limit_abort.print();

    std.debug.print("--------------------------------------------------------------------------------\n", .{});
    std.debug.print("Operational benchmarks are informational evidence, not correctness gates.\n\n", .{});
}

fn runAppendHeavy(conn: *zqlite.Connection) !void {
    try conn.execute("BEGIN");
    errdefer conn.rollbackTransaction() catch {};

    var i: usize = 0;
    while (i < 1_000) : (i += 1) {
        var sql_buf: [96]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "INSERT INTO bench_ops VALUES ({d}, 'append')", .{i});
        try conn.execute(sql);
    }
    try conn.execute("COMMIT");
}

fn runIndexedLookup(conn: *zqlite.Connection) !void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var result = try conn.query("SELECT value FROM bench_ops WHERE id = 500");
        result.deinit();
    }
}

fn runMaterializedScan(conn: *zqlite.Connection) !void {
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var result = try conn.query("SELECT id, value FROM bench_ops");
        result.deinit();
    }
}

fn runCursorScan(conn: *zqlite.Connection) !void {
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var cursor = try conn.openCursor("SELECT id, value FROM bench_ops");
        while (cursor.next()) |row| {
            var owned = row;
            owned.deinit();
        }
        cursor.deinit();
    }
}

fn runResourceLimitAbort(conn: *zqlite.Connection) !void {
    const previous = conn.getResourceLimits();
    defer conn.setResourceLimits(previous);
    conn.setResourceLimits(.{ .max_result_rows = 1 });

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (conn.query("SELECT id, value FROM bench_ops")) |result| {
            var owned = result;
            owned.deinit();
            return error.ExpectedResourceLimitExceeded;
        } else |e| switch (e) {
            error.ResourceLimitExceeded => {},
            else => return e,
        }
    }
}
