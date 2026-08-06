const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

var test_dir: temp_dir.TempDir = undefined;

/// Test concurrent access to same database file
/// Uses multiple threads to simulate concurrent connections
pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    if (args.next() == null) return error.MissingExecutableArgument;
    if (args.next()) |mode| {
        const path = args.next() orelse return error.MissingDatabasePath;
        if (std.mem.eql(u8, mode, "--expect-writer-timeout")) return expectWriterTimeout(allocator, path);
        if (std.mem.eql(u8, mode, "--wait-for-writer")) {
            const ready_path = args.next() orelse return error.MissingReadyPath;
            return waitForWriter(init.io, allocator, path, ready_path);
        }
        return error.UnknownTestMode;
    }

    test_dir = try .init(init.io, allocator, "zqlite-concurrent");
    defer test_dir.deinit();

    std.log.info("=== Concurrent Access Tests ===", .{});

    try testMultipleReaders(allocator);
    try testReaderWriter(allocator);
    try testParallelReaders(allocator);
    try testWriterReservationAndTimeout(allocator);
    try testCrossProcessWriterReservation(init.io, allocator);
    try testCrossProcessWriterWait(init.io, allocator);
    try testCrossConnectionCacheAndSchemaCoherence(allocator);
    try testOnlineBackupWaitsForWriter(allocator);
    try testSequentialConnections(allocator);
    try testRepeatedRandomizedConnectionInterleaving(allocator);

    std.log.info("=== ALL CONCURRENT ACCESS TESTS PASSED ===", .{});
}

const BackupContext = struct {
    source_path: []const u8,
    destination_path: []const u8,
    started: *std.atomic.Value(bool),
    failures: *std.atomic.Value(u32),
};

fn runOnlineBackup(context: *BackupContext) void {
    const allocator = std.heap.page_allocator;
    const connection = zqlite.openWithOptions(allocator, context.source_path, zqlite.OpenOptions.READ_ONLY) catch {
        recordParallelFailure(context.failures);
        return;
    };
    defer connection.close();
    connection.setBusyTimeout(2_000);
    context.started.store(true, .release);
    connection.backupToFile(std.Io.Threaded.global_single_threaded.io(), context.destination_path) catch {
        recordParallelFailure(context.failures);
    };
}

fn testOnlineBackupWaitsForWriter(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Online backup captures one committed snapshot while a writer is active", .{});
    const path = try test_dir.dbPath("online-backup-source.db");
    defer allocator.free(path);
    const backup_path = try test_dir.dbPath("online-backup-copy.db");
    defer allocator.free(backup_path);

    const writer = try zqlite.open(allocator, path);
    defer writer.close();
    writer.setBusyTimeout(2_000);
    try writer.execute("CREATE TABLE backup_rows (id INTEGER PRIMARY KEY)");
    try writer.execute("INSERT INTO backup_rows VALUES (1)");
    try writer.begin();
    try writer.execute("INSERT INTO backup_rows VALUES (2)");

    var started = std.atomic.Value(bool).init(false);
    var failures = std.atomic.Value(u32).init(0);
    var context = BackupContext{
        .source_path = path,
        .destination_path = backup_path,
        .started = &started,
        .failures = &failures,
    };
    var thread = try std.Thread.spawn(.{}, runOnlineBackup, .{&context});
    while (!started.load(.acquire)) std.atomic.spinLoopHint();
    zqlite.compat.sleepMillis(20);
    try writer.commit();
    thread.join();
    try std.testing.expectEqual(@as(u32, 0), failures.load(.acquire));

    const backup = try zqlite.open(allocator, backup_path);
    defer backup.close();
    var rows = try backup.query("SELECT id FROM backup_rows ORDER BY id");
    defer rows.deinit();
    try std.testing.expect(rows.count() == 1 or rows.count() == 2);
    try std.testing.expectEqual(@as(i64, 1), rows.rows.items[0].values[0].Integer);
    if (rows.count() == 2) try std.testing.expectEqual(@as(i64, 2), rows.rows.items[1].values[0].Integer);
    std.log.info("[PASS] Backup opened as a complete snapshot before or after the concurrent commit", .{});
}

fn testCrossConnectionCacheAndSchemaCoherence(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Cross-connection result and schema caches refresh after commit", .{});
    const path = try test_dir.dbPath("cross-connection-cache.db");
    defer allocator.free(path);

    const writer = try zqlite.open(allocator, path);
    defer writer.close();
    try writer.execute("CREATE TABLE cache_items (id INTEGER PRIMARY KEY)");
    try writer.execute("INSERT INTO cache_items VALUES (1)");

    const reader = try zqlite.open(allocator, path);
    defer reader.close();
    const cache = try zqlite.query_cache.QueryCache.init(allocator, 8, 1024 * 1024);
    defer cache.deinit();
    reader.setResultCache(cache);

    var initial = try reader.query("SELECT * FROM cache_items");
    defer initial.deinit();
    try std.testing.expectEqual(@as(usize, 1), initial.rows.items.len);

    const prepared = try reader.prepare("SELECT * FROM cache_items");
    defer prepared.deinit();
    try writer.execute("INSERT INTO cache_items VALUES (2)");
    try writer.execute("CREATE TABLE cache_schema_change (id INTEGER)");

    var refreshed = try reader.query("SELECT * FROM cache_items");
    defer refreshed.deinit();
    try std.testing.expectEqual(@as(usize, 2), refreshed.rows.items.len);
    try std.testing.expectError(error.PreparedStatementExpired, prepared.execute());
    std.log.info("[PASS] Cross-connection caches observed committed DML and DDL", .{});
}

fn waitForWriter(io: std.Io, allocator: std.mem.Allocator, path: []const u8, ready_path: []const u8) !void {
    const contender = try zqlite.open(allocator, path);
    defer contender.close();
    contender.setBusyTimeout(2_000);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ready_path, .data = "ready" });
    try contender.begin();
    try contender.execute("INSERT INTO process_writer_wait VALUES (2)");
    try contender.commit();
}

fn testCrossProcessWriterWait(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Waiting writer proceeds after reservation release", .{});
    const path = try test_dir.dbPath("process-writer-wait.db");
    defer allocator.free(path);
    const ready_path = try test_dir.dbPath("process-writer-wait.ready");
    defer allocator.free(ready_path);

    const writer = try zqlite.open(allocator, path);
    defer writer.close();
    try writer.execute("CREATE TABLE process_writer_wait (id INTEGER PRIMARY KEY)");
    try writer.begin();
    try writer.execute("INSERT INTO process_writer_wait VALUES (1)");
    defer if (writer.in_transaction) writer.rollback() catch {};

    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    var child = try std.process.spawn(io, .{
        .argv = &.{ executable, "--wait-for-writer", path, ready_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer child.kill(io);

    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        var ready_file = std.Io.Dir.cwd().openFile(io, ready_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.sleep(io, .fromMilliseconds(1), .awake);
                continue;
            },
            else => return err,
        };
        ready_file.close(io);
        break;
    }
    if (attempts == 2_000) return error.ChildWriterDidNotBecomeReady;

    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    try writer.commit();
    const term = try child.wait(io);
    if (!term.success()) return error.ChildWriterTestFailed;

    var rows = try writer.query("SELECT * FROM process_writer_wait");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.rows.items.len);
    std.log.info("[PASS] Waiting writer committed after reservation release", .{});
}

fn expectWriterTimeout(allocator: std.mem.Allocator, path: []const u8) !void {
    const contender = try zqlite.open(allocator, path);
    defer contender.close();
    contender.setBusyTimeout(30);
    contender.begin() catch |err| switch (err) {
        error.OperationTimedOut => return,
        else => return err,
    };
    try contender.rollback();
    return error.WriterReservationNotEnforced;
}

fn testCrossProcessWriterReservation(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Writer reservation is enforced across processes", .{});
    const path = try test_dir.dbPath("process-writer-reservation.db");
    defer allocator.free(path);

    const writer = try zqlite.open(allocator, path);
    defer writer.close();
    try writer.execute("CREATE TABLE process_writer_reservation (id INTEGER PRIMARY KEY)");
    try writer.begin();
    defer if (writer.in_transaction) writer.rollback() catch {};

    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const run = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "--expect-writer-timeout", path },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    if (!run.term.success()) {
        std.log.err("writer contender failed: {s}", .{run.stderr});
        return error.ChildWriterTestFailed;
    }

    try writer.rollback();
    std.log.info("[PASS] Cross-process writer reservation timeout", .{});
}

const ParallelReaderContext = struct {
    path: []const u8,
    start: *std.atomic.Value(bool),
    failures: *std.atomic.Value(u32),
};

fn recordParallelFailure(failures: *std.atomic.Value(u32)) void {
    const previous = failures.fetchAdd(1, .acq_rel);
    if (previous == std.math.maxInt(u32)) @panic("parallel reader failure counter overflow");
}

fn parallelReader(context: *ParallelReaderContext) void {
    while (!context.start.load(.acquire)) std.atomic.spinLoopHint();

    const allocator = std.heap.page_allocator;
    const conn = zqlite.openWithOptions(allocator, context.path, zqlite.OpenOptions.READ_ONLY) catch {
        recordParallelFailure(context.failures);
        return;
    };
    defer conn.close();

    var result = conn.query("SELECT * FROM parallel_readers") catch {
        recordParallelFailure(context.failures);
        return;
    };
    defer result.deinit();
    if (result.rows.items.len != 32) recordParallelFailure(context.failures);
}

fn testParallelReaders(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Parallel readers acquire compatible shared locks", .{});
    const path = try test_dir.dbPath("parallel-readers.db");
    defer allocator.free(path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE parallel_readers (id INTEGER PRIMARY KEY)");
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            var sql: [96]u8 = undefined;
            try conn.execute(try std.fmt.bufPrint(&sql, "INSERT INTO parallel_readers VALUES ({d})", .{i}));
        }
    }

    var start = std.atomic.Value(bool).init(false);
    var failures = std.atomic.Value(u32).init(0);
    var contexts: [4]ParallelReaderContext = undefined;
    var threads: [4]std.Thread = undefined;
    for (&threads, &contexts) |*thread, *context| {
        context.* = .{ .path = path, .start = &start, .failures = &failures };
        thread.* = try std.Thread.spawn(.{}, parallelReader, .{context});
    }
    start.store(true, .release);
    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), failures.load(.acquire));
    std.log.info("[PASS] Parallel readers completed under shared locks", .{});
}

fn testWriterReservationAndTimeout(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Writer reservation blocks a second writer but not readers", .{});
    const path = try test_dir.dbPath("writer-reservation.db");
    defer allocator.free(path);

    const writer = try zqlite.open(allocator, path);
    defer writer.close();
    try writer.execute("CREATE TABLE writer_reservation (id INTEGER PRIMARY KEY)");

    const contender = try zqlite.open(allocator, path);
    defer contender.close();
    contender.setBusyTimeout(25);

    try writer.begin();
    try writer.execute("INSERT INTO writer_reservation VALUES (1)");
    try std.testing.expectError(error.OperationTimedOut, contender.begin());

    var snapshot = try contender.query("SELECT * FROM writer_reservation");
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), snapshot.rows.items.len);

    try writer.commit();
    try contender.begin();
    try contender.rollback();

    var committed = try contender.query("SELECT * FROM writer_reservation");
    defer committed.deinit();
    try std.testing.expectEqual(@as(usize, 1), committed.rows.items.len);
    std.log.info("[PASS] Writer reservation timeout and committed visibility", .{});
}

fn testMultipleReaders(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Multiple sequential readers", .{});
    const path = try test_dir.dbPath("read.db");
    defer allocator.free(path);

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
    const path = try test_dir.dbPath("rw.db");
    defer allocator.free(path);

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

    // Writer increments
    try writer.execute("UPDATE counter SET count = count + 1 WHERE id = 1");
    try writer.execute("UPDATE counter SET count = count + 1 WHERE id = 1");
    try writer.execute("UPDATE counter SET count = count + 1 WHERE id = 1");

    // A fresh reader observes the writer's persisted changes.
    var reader = try zqlite.open(allocator, path);
    defer reader.close();
    var result = try reader.query("SELECT count FROM counter WHERE id = 1");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
    try std.testing.expectEqual(@as(i64, 3), result.rows.items[0].values[0].Integer);
    std.log.info("[PASS] Reader/writer: reader sees updates", .{});
}

fn testSequentialConnections(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Rapid sequential connections", .{});
    const path = try test_dir.dbPath("seq.db");
    defer allocator.free(path);

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

fn testRepeatedRandomizedConnectionInterleaving(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Repeated randomized connection interleaving", .{});
    const path = try test_dir.dbPath("randomized.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE IF NOT EXISTS randomized (id INTEGER PRIMARY KEY, value INTEGER)");
        try conn.execute("DELETE FROM randomized");
    }

    var rng = std.Random.DefaultPrng.init(0x5A51_17E_C0FFEE);
    var expected_rows: usize = 0;
    var next_id: usize = 1;

    var i: usize = 0;
    while (i < 160) : (i += 1) {
        const action = rng.random().intRangeAtMost(u8, 0, 3);
        switch (action) {
            0, 1 => {
                var conn = try zqlite.open(allocator, path);
                defer conn.close();
                var sql_buf: [128]u8 = undefined;
                const sql = try std.fmt.bufPrint(&sql_buf, "INSERT INTO randomized (id, value) VALUES ({d}, {d})", .{ next_id, next_id * 10 });
                try conn.execute(sql);
                expected_rows += 1;
                next_id += 1;
            },
            2 => {
                var conn = try zqlite.open(allocator, path);
                defer conn.close();
                var result = try conn.query("SELECT * FROM randomized");
                defer result.deinit();
                try std.testing.expectEqual(expected_rows, result.rows.items.len);
            },
            3 => {
                var writer = try zqlite.open(allocator, path);
                defer writer.close();
                var reader = try zqlite.open(allocator, path);
                defer reader.close();

                var sql_buf: [128]u8 = undefined;
                const sql = try std.fmt.bufPrint(&sql_buf, "INSERT INTO randomized (id, value) VALUES ({d}, {d})", .{ next_id, next_id * 10 });
                try writer.execute(sql);
                expected_rows += 1;
                next_id += 1;

                var result = try reader.query("SELECT * FROM randomized");
                defer result.deinit();
                try std.testing.expect(result.rows.items.len <= expected_rows);
            },
            else => unreachable,
        }
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();
        var result = try conn.query("SELECT * FROM randomized");
        defer result.deinit();
        try std.testing.expectEqual(expected_rows, result.rows.items.len);
    }

    std.log.info("[PASS] Randomized interleaving: {d} writes persisted", .{expected_rows});
}
