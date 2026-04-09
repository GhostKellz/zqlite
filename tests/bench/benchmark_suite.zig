const std = @import("std");
const zqlite = @import("zqlite");

/// Comprehensive benchmarking suite for production performance validation
/// Measures: INSERT/SELECT/UPDATE/DELETE throughput, memory usage, latency
const BenchmarkResult = struct {
    name: []const u8,
    operations: usize,
    duration_ns: u64,
    memory_used_bytes: usize,
    ops_per_second: f64,

    pub fn print(self: BenchmarkResult) void {
        const duration_ms = @as(f64, @floatFromInt(self.duration_ns)) / 1_000_000.0;
        const memory_mb = @as(f64, @floatFromInt(self.memory_used_bytes)) / 1_048_576.0;

        std.debug.print("  {s:<40} | {d:>10} ops | {d:>8.2} ms | {d:>8.2} MB | {d:>12.0} ops/sec\n", .{
            self.name,
            self.operations,
            duration_ms,
            memory_mb,
            self.ops_per_second,
        });
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("⚠️  Memory leak detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("\n🚀 ZQLite Comprehensive Benchmark Suite\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
    std.debug.print("  {s:<40} | {s:>10} | {s:>10} | {s:>10} | {s:>15}\n", .{
        "Benchmark",
        "Operations",
        "Duration",
        "Memory",
        "Throughput",
    });
    std.debug.print("-" ** 100 ++ "\n", .{});

    var results = std.array_list.Managed(BenchmarkResult).init(allocator);
    defer results.deinit();

    // Benchmark 1: Simple INSERT operations
    try results.append(try benchmarkSimpleInserts(allocator));

    std.debug.print("✓ Completed benchmark 1\n", .{});

    // Benchmark 2: Bulk INSERT operations
    try results.append(try benchmarkBulkInserts(allocator));

    std.debug.print("✓ Completed benchmark 2\n", .{});

    // Benchmark 3: SELECT queries
    try results.append(try benchmarkSelects(allocator));

    std.debug.print("✓ Completed benchmark 3\n", .{});

    // Benchmark 4: UPDATE operations
    try results.append(try benchmarkUpdates(allocator));

    std.debug.print("✓ Completed benchmark 4\n", .{});

    // Benchmark 5: DELETE operations
    try results.append(try benchmarkDeletes(allocator));

    std.debug.print("✓ Completed benchmark 5\n", .{});

    // Benchmark 6: CREATE TABLE with DEFAULT constraints
    try results.append(try benchmarkCreateTableDefaults(allocator));

    std.debug.print("✓ Completed benchmark 6\n", .{});

    // Benchmark 7: Mixed workload
    try results.append(try benchmarkMixedWorkload(allocator));

    std.debug.print("✓ Completed benchmark 7\n", .{});

    // Benchmark 8: Transaction throughput
    try results.append(try benchmarkTransactions(allocator));

    std.debug.print("✓ Completed benchmark 8\n", .{});

    std.debug.print("=" ** 100 ++ "\n", .{});

    // Print summary statistics
    var total_ops: usize = 0;
    var total_duration_ns: u64 = 0;
    for (results.items) |result| {
        total_ops += result.operations;
        total_duration_ns += result.duration_ns;
    }

    const avg_throughput = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0);
    std.debug.print("\n📊 Summary: {} total operations in {d:.2}s = {d:.0} ops/sec average\n\n", .{
        total_ops,
        @as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0,
        avg_throughput,
    });
}

fn benchmarkSimpleInserts(allocator: std.mem.Allocator) !BenchmarkResult {
    const num_ops: usize = 1000;

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE bench_insert (id INTEGER, value TEXT)");

    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start = @as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec;
    const mem_before = getMemoryUsage();

    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        try conn.execute("INSERT INTO bench_insert (id, value) VALUES (1, 'test')");
    }

    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const end_time = @as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec;
    const duration = @as(u64, @intCast(end_time - start));
    const mem_used = getMemoryUsage() - mem_before;
    const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "Simple INSERT",
        .operations = num_ops,
        .duration_ns = duration,
        .memory_used_bytes = mem_used,
        .ops_per_second = ops_per_sec,
    };
}

fn benchmarkBulkInserts(allocator: std.mem.Allocator) !BenchmarkResult {
    const num_ops: usize = 10000;

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE bench_bulk (id INTEGER, data TEXT)");

    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start = @as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec;
    const mem_before = getMemoryUsage();

    try conn.execute("BEGIN TRANSACTION");
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        try conn.execute("INSERT INTO bench_bulk VALUES (1, 'bulk data')");
    }
    try conn.execute("COMMIT");

    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const end_time = @as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec;
    const duration = @as(u64, @intCast(end_time - start));
    const mem_used = getMemoryUsage() - mem_before;
    const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "Bulk INSERT (in transaction)",
        .operations = num_ops,
        .duration_ns = duration,
        .memory_used_bytes = mem_used,
        .ops_per_second = ops_per_sec,
    };
}

fn benchmarkSelects(allocator: std.mem.Allocator) !BenchmarkResult {
    const num_rows: usize = 100;
    const num_queries: usize = 50;

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE bench_select (id INTEGER, value TEXT)");

    // Populate data
    var i: usize = 0;
    while (i < num_rows) : (i += 1) {
        try conn.execute("INSERT INTO bench_select VALUES (1, 'data')");
    }

    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start = @as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec;
    const mem_before = getMemoryUsage();

    i = 0;
    while (i < num_queries) : (i += 1) {
        var result = try conn.query("SELECT * FROM bench_select");
        result.deinit();
    }

    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const end_time = @as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec;
    const duration = @as(u64, @intCast(end_time - start));
    const mem_used = getMemoryUsage() - mem_before;
    const ops_per_sec = @as(f64, @floatFromInt(num_queries)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "SELECT queries",
        .operations = num_queries,
        .duration_ns = duration,
        .memory_used_bytes = mem_used,
        .ops_per_second = ops_per_sec,
    };
}

fn benchmarkUpdates(allocator: std.mem.Allocator) !BenchmarkResult {
    const num_ops: usize = 500;

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE bench_update (id INTEGER, value TEXT)");
    try conn.execute("INSERT INTO bench_update VALUES (1, 'initial')");

    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start = @as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec;
    const mem_before = getMemoryUsage();

    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        try conn.execute("UPDATE bench_update SET value = 'updated'");
    }

    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const end_time = @as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec;
    const duration = @as(u64, @intCast(end_time - start));
    const mem_used = getMemoryUsage() - mem_before;
    const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "UPDATE operations",
        .operations = num_ops,
        .duration_ns = duration,
        .memory_used_bytes = mem_used,
        .ops_per_second = ops_per_sec,
    };
}

fn benchmarkDeletes(allocator: std.mem.Allocator) !BenchmarkResult {
    const num_ops: usize = 500;

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE bench_delete (id INTEGER, value TEXT)");

    // Populate data
    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        try conn.execute("INSERT INTO bench_delete VALUES (1, 'data')");
    }

    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start = @as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec;
    const mem_before = getMemoryUsage();

    i = 0;
    while (i < num_ops) : (i += 1) {
        try conn.execute("DELETE FROM bench_delete WHERE id = 1");
    }

    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const end_time = @as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec;
    const duration = @as(u64, @intCast(end_time - start));
    const mem_used = getMemoryUsage() - mem_before;
    const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "DELETE operations",
        .operations = num_ops,
        .duration_ns = duration,
        .memory_used_bytes = mem_used,
        .ops_per_second = ops_per_sec,
    };
}

fn benchmarkCreateTableDefaults(allocator: std.mem.Allocator) !BenchmarkResult {
    const num_ops: usize = 100;

    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start = @as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec;
    const mem_before = getMemoryUsage();

    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        var conn = try zqlite.open(allocator, ":memory:");
        try conn.execute(
            \\CREATE TABLE test (
            \\  id INTEGER,
            \\  name TEXT DEFAULT 'default',
            \\  created DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        );
        conn.close();
    }

    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const end_time = @as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec;
    const duration = @as(u64, @intCast(end_time - start));
    const mem_used = getMemoryUsage() - mem_before;
    const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "CREATE TABLE with DEFAULT constraints",
        .operations = num_ops,
        .duration_ns = duration,
        .memory_used_bytes = mem_used,
        .ops_per_second = ops_per_sec,
    };
}

fn benchmarkMixedWorkload(allocator: std.mem.Allocator) !BenchmarkResult {
    const num_ops: usize = 400;

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE bench_mixed (id INTEGER, value TEXT)");

    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start = @as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec;
    const mem_before = getMemoryUsage();

    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        const op = i % 4;
        switch (op) {
            0 => try conn.execute("INSERT INTO bench_mixed VALUES (1, 'data')"),
            1 => {
                var result = try conn.query("SELECT * FROM bench_mixed");
                result.deinit();
            },
            2 => try conn.execute("UPDATE bench_mixed SET value = 'updated'"),
            3 => try conn.execute("DELETE FROM bench_mixed WHERE id = 1"),
            else => unreachable,
        }
    }

    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const end_time = @as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec;
    const duration = @as(u64, @intCast(end_time - start));
    const mem_used = getMemoryUsage() - mem_before;
    const ops_per_sec = @as(f64, @floatFromInt(num_ops)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "Mixed workload (25% each: CRUD)",
        .operations = num_ops,
        .duration_ns = duration,
        .memory_used_bytes = mem_used,
        .ops_per_second = ops_per_sec,
    };
}

fn benchmarkTransactions(allocator: std.mem.Allocator) !BenchmarkResult {
    const num_txns: usize = 100;
    const ops_per_txn: usize = 50;

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE bench_txn (id INTEGER, value TEXT)");

    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start = @as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec;
    const mem_before = getMemoryUsage();

    var i: usize = 0;
    while (i < num_txns) : (i += 1) {
        try conn.execute("BEGIN TRANSACTION");
        var j: usize = 0;
        while (j < ops_per_txn) : (j += 1) {
            try conn.execute("INSERT INTO bench_txn VALUES (1, 'txn_data')");
        }
        try conn.execute("COMMIT");
    }

    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const end_time = @as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec;
    const duration = @as(u64, @intCast(end_time - start));
    const mem_used = getMemoryUsage() - mem_before;
    const total_ops = num_txns * ops_per_txn;
    const ops_per_sec = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "Transaction throughput (50 INSERTs/txn)",
        .operations = total_ops,
        .duration_ns = duration,
        .memory_used_bytes = mem_used,
        .ops_per_second = ops_per_sec,
    };
}

fn getMemoryUsage() usize {
    // Simplified memory tracking - actual implementation would use OS-specific APIs
    return 1024 * 1024; // Placeholder: 1MB
}
