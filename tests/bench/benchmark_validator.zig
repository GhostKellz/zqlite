const std = @import("std");
const zqlite = @import("zqlite");

/// Benchmark validator for CI regression detection
/// Runs benchmarks and validates against baseline thresholds
const BenchResult = struct {
    name: []const u8,
    ops_per_sec: f64,
    min_threshold: f64,
    passed: bool,
};

/// Get current time in nanoseconds using Zig 0.16 API
fn getNanoTime() i128 {
    var ts: std.posix.timespec = undefined;
    const result = std.posix.system.clock_gettime(.REALTIME, &ts);
    if (std.posix.errno(result) == .SUCCESS) {
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
    return 0;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n🔍 ZQLite Benchmark Validation\n", .{});
    std.debug.print("=" ** 80 ++ "\n\n", .{});

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE bench (id INTEGER, value TEXT)");

    var results: std.ArrayList(BenchResult) = .empty;
    defer results.deinit(allocator);

    // Benchmark 1: Simple INSERTs
    {
        const num_ops: usize = 10;
        const start = getNanoTime();

        var i: usize = 0;
        while (i < num_ops) : (i += 1) {
            try conn.execute("INSERT INTO bench (id, value) VALUES (1, 'test')");
        }

        const end_time = getNanoTime();
        const duration_s = @as(f64, @floatFromInt(end_time - start)) / 1_000_000_000.0;
        const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / duration_s;
        const min_threshold = 1000.0; // CI-friendly threshold

        try results.append(allocator, .{
            .name = "Simple INSERT",
            .ops_per_sec = ops_per_sec,
            .min_threshold = min_threshold,
            .passed = ops_per_sec >= min_threshold,
        });
    }

    // Benchmark 2: Bulk INSERTs
    {
        const num_ops: usize = 10;
        const start = getNanoTime();

        try conn.execute("BEGIN TRANSACTION");
        var i: usize = 0;
        while (i < num_ops) : (i += 1) {
            try conn.execute("INSERT INTO bench (id, value) VALUES (2, 'bulk')");
        }
        try conn.execute("COMMIT");

        const end_time = getNanoTime();
        const duration_s = @as(f64, @floatFromInt(end_time - start)) / 1_000_000_000.0;
        const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / duration_s;
        const min_threshold = 500.0; // CI-friendly threshold

        try results.append(allocator, .{
            .name = "Bulk INSERT",
            .ops_per_sec = ops_per_sec,
            .min_threshold = min_threshold,
            .passed = ops_per_sec >= min_threshold,
        });
    }

    // Benchmark 3: SELECT queries
    {
        const num_ops: usize = 50;
        const start = getNanoTime();

        var i: usize = 0;
        while (i < num_ops) : (i += 1) {
            var result = try conn.query("SELECT * FROM bench");
            result.deinit();
        }

        const end_time = getNanoTime();
        const duration_s = @as(f64, @floatFromInt(end_time - start)) / 1_000_000_000.0;
        const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / duration_s;
        const min_threshold = 500.0; // CI-friendly threshold

        try results.append(allocator, .{
            .name = "SELECT query",
            .ops_per_sec = ops_per_sec,
            .min_threshold = min_threshold,
            .passed = ops_per_sec >= min_threshold,
        });
    }

    // Benchmark 4: UPDATEs
    {
        const num_ops: usize = 50;
        const start = getNanoTime();

        var i: usize = 0;
        while (i < num_ops) : (i += 1) {
            try conn.execute("UPDATE bench SET value = 'updated' WHERE id = 1");
        }

        const end_time = getNanoTime();
        const duration_s = @as(f64, @floatFromInt(end_time - start)) / 1_000_000_000.0;
        const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / duration_s;
        const min_threshold = 50.0; // CI-friendly threshold

        try results.append(allocator, .{
            .name = "UPDATE",
            .ops_per_sec = ops_per_sec,
            .min_threshold = min_threshold,
            .passed = ops_per_sec >= min_threshold,
        });
    }

    // Print results
    std.debug.print("Benchmark Results:\n", .{});
    std.debug.print("-" ** 80 ++ "\n", .{});

    var all_passed = true;
    for (results.items) |result| {
        const status = if (result.passed) "✅ PASS" else "❌ FAIL";
        std.debug.print("{s} {s:<20} {d:>8.0} ops/sec (min: {d:>8.0})\n", .{
            status,
            result.name,
            result.ops_per_sec,
            result.min_threshold,
        });
        if (!result.passed) all_passed = false;
    }

    std.debug.print("=" ** 80 ++ "\n", .{});

    if (all_passed) {
        std.debug.print("✅ All benchmarks passed regression thresholds!\n\n", .{});
        std.process.exit(0);
    } else {
        std.debug.print("❌ Some benchmarks failed regression thresholds!\n\n", .{});
        std.process.exit(1);
    }
}
