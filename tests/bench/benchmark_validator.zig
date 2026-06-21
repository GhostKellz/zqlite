const std = @import("std");
const zqlite = @import("zqlite");

const warmup_iterations = 1;
const sample_count = 5;

const BenchmarkSpec = struct {
    name: []const u8,
    operations: usize,
    min_median_ops_per_sec: f64,
    run: *const fn (*zqlite.Connection, usize) anyerror!void,
};

const BenchResult = struct {
    name: []const u8,
    median_ops_per_sec: f64,
    p95_ops_per_sec: f64,
    target_threshold: f64,
    hard_fail_threshold: f64,
    meets_target: bool,
    passed: bool,
};

const benchmarks = [_]BenchmarkSpec{
    .{ .name = "Simple INSERT", .operations = 10, .min_median_ops_per_sec = 1000.0, .run = runSimpleInsert },
    .{ .name = "Bulk INSERT", .operations = 10, .min_median_ops_per_sec = 500.0, .run = runBulkInsert },
    .{ .name = "SELECT query", .operations = 50, .min_median_ops_per_sec = 500.0, .run = runSelectQuery },
    .{ .name = "UPDATE", .operations = 50, .min_median_ops_per_sec = 50.0, .run = runUpdate },
};

fn getNanoTime() i128 {
    var ts: std.posix.timespec = undefined;
    const result = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    if (std.posix.errno(result) == .SUCCESS) {
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
    return 0;
}

fn sortAscending(values: []f64) void {
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const key = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = key;
    }
}

fn percentile(sorted_values: []const f64, pct: f64) f64 {
    if (sorted_values.len == 0) return 0;
    const raw_index = pct * @as(f64, @floatFromInt(sorted_values.len - 1));
    const index: usize = @intFromFloat(@ceil(raw_index));
    return sorted_values[@min(index, sorted_values.len - 1)];
}

fn runBenchmark(conn: *zqlite.Connection, spec: BenchmarkSpec) !BenchResult {
    var i: usize = 0;
    while (i < warmup_iterations) : (i += 1) {
        try spec.run(conn, spec.operations);
    }

    var samples: [sample_count]f64 = undefined;
    i = 0;
    while (i < sample_count) : (i += 1) {
        const start = getNanoTime();
        try spec.run(conn, spec.operations);
        const end = getNanoTime();
        const duration_s = @max(@as(f64, @floatFromInt(end - start)) / std.time.ns_per_s, 0.000_001);
        samples[i] = @as(f64, @floatFromInt(spec.operations)) / duration_s;
    }

    sortAscending(samples[0..]);
    const median = samples[samples.len / 2];
    const p95 = percentile(samples[0..], 0.95);
    const hard_fail_threshold = spec.min_median_ops_per_sec * 0.5;

    return .{
        .name = spec.name,
        .median_ops_per_sec = median,
        .p95_ops_per_sec = p95,
        .target_threshold = spec.min_median_ops_per_sec,
        .hard_fail_threshold = hard_fail_threshold,
        .meets_target = median >= spec.min_median_ops_per_sec,
        .passed = median >= hard_fail_threshold,
    };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n🔍 ZQLite Benchmark Validation\n", .{});
    std.debug.print("================================================================================\n\n", .{});

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE bench (id INTEGER, value TEXT)");
    try conn.execute("INSERT INTO bench (id, value) VALUES (1, 'seed')");
    try conn.execute("INSERT INTO bench (id, value) VALUES (99, 'update-seed')");

    var results: std.ArrayList(BenchResult) = .empty;
    defer results.deinit(allocator);

    for (benchmarks) |spec| {
        try results.append(allocator, try runBenchmark(conn, spec));
    }

    std.debug.print("Benchmark Results ({d} warmup, {d} samples, monotonic clock):\n", .{ warmup_iterations, sample_count });
    std.debug.print("--------------------------------------------------------------------------------\n", .{});

    var all_passed = true;
    for (results.items) |result| {
        const status = if (result.meets_target) "✅ PASS" else if (result.passed) "⚠️  WARN" else "❌ FAIL";
        std.debug.print("{s} {s:<20} median={d:>8.0} ops/sec p95={d:>8.0} ops/sec (target: {d:>8.0}, hard fail: {d:>8.0})\n", .{
            status,
            result.name,
            result.median_ops_per_sec,
            result.p95_ops_per_sec,
            result.target_threshold,
            result.hard_fail_threshold,
        });
        if (!result.passed) all_passed = false;
    }

    std.debug.print("================================================================================\n", .{});

    if (all_passed) {
        std.debug.print("✅ No severe benchmark regressions detected.\n\n", .{});
        std.process.exit(0);
    } else {
        std.debug.print("❌ Severe benchmark regression detected!\n\n", .{});
        std.process.exit(1);
    }
}

fn runSimpleInsert(conn: *zqlite.Connection, num_ops: usize) !void {
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        try conn.execute("INSERT INTO bench (id, value) VALUES (1, 'test')");
    }
}

fn runBulkInsert(conn: *zqlite.Connection, num_ops: usize) !void {
    try conn.execute("BEGIN TRANSACTION");
    errdefer conn.rollbackTransaction() catch {};

    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        try conn.execute("INSERT INTO bench (id, value) VALUES (2, 'bulk')");
    }
    try conn.execute("COMMIT");
}

fn runSelectQuery(conn: *zqlite.Connection, num_ops: usize) !void {
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        var result = try conn.query("SELECT * FROM bench");
        result.deinit();
    }
}

fn runUpdate(conn: *zqlite.Connection, num_ops: usize) !void {
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        try conn.execute("UPDATE bench SET value = 'updated' WHERE id = 99");
    }
}
