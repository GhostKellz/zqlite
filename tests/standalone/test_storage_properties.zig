const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

const BTree = zqlite.btree.BTree;
const Pager = zqlite.pager.Pager;
const Row = zqlite.storage.Row;
const Value = zqlite.storage.Value;
const WriteAheadLog = zqlite.wal.WriteAheadLog;

var test_dir: temp_dir.TempDir = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    test_dir = try .init(init.io, allocator, "zqlite-storage-properties");
    defer test_dir.deinit();

    try testBtreeOrderingSplitsAndPersistence(init.io, allocator);
    try testWalReplayIdempotence(init.io, allocator);
    try testWalTornCommitDoesNotReplay(init.io, allocator);
    try testTransactionRollbackAndCommitInvariants(allocator);

    std.log.info("=== ALL STORAGE PROPERTY TESTS PASSED ===", .{});
}

fn testWalTornCommitDoesNotReplay(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] WAL torn commit records do not replay", .{});
    const path = try test_dir.dbPath("wal-torn-commit.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    {
        const log = try WriteAheadLog.init(allocator, path);
        defer log.deinit();

        try log.beginTransaction();
        try log.logPageWrite(2, 0, "00000", "delta");
        log.injectFaultOnce(.partial_write);
        try std.testing.expectError(error.InjectedPartialWrite, log.commit());
    }

    {
        const pager = try Pager.init(allocator, path);
        defer pager.deinit();
        const log = try WriteAheadLog.init(allocator, path);
        defer log.deinit();

        try log.checkpointToPager(pager);
        const page = try pager.getPage(2);
        try std.testing.expect(!std.mem.eql(u8, "delta", page.data[0..5]));
    }
}

fn cleanup(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const wal = std.fmt.bufPrint(&buf, "{s}-wal", .{path}) catch return;
    std.Io.Dir.cwd().deleteFile(io, wal) catch {};
}

fn makeRow(allocator: std.mem.Allocator, key: u64) !Row {
    const values = try allocator.alloc(Value, 1);
    values[0] = Value{ .Integer = @intCast(key) };
    return Row{ .values = values };
}

fn freeRow(allocator: std.mem.Allocator, row: Row) void {
    for (row.values) |value| value.deinit(allocator);
    allocator.free(row.values);
}

fn testBtreeOrderingSplitsAndPersistence(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] B-tree ordering, splits, and persistence properties", .{});
    const path = try test_dir.dbPath("btree-properties.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    var root_page: u32 = 0;
    const row_count: usize = 180;

    {
        const pager = try Pager.init(allocator, path);
        defer pager.deinit();
        const tree = try BTree.init(allocator, pager);
        defer tree.deinit();

        var inserted: usize = 0;
        var key: u64 = 97;
        while (inserted < row_count) : (inserted += 1) {
            try tree.insert(key, try makeRow(allocator, key));
            key = (key + 37) % row_count;
        }

        const rows = try tree.selectAllWithKeys(allocator);
        defer {
            for (rows) |item| freeRow(allocator, item.row);
            allocator.free(rows);
        }
        try std.testing.expectEqual(row_count, rows.len);
        for (rows, 0..) |item, i| {
            try std.testing.expectEqual(@as(u64, @intCast(i)), item.key);
            try std.testing.expectEqual(@as(i64, @intCast(i)), item.row.values[0].Integer);
        }

        for ([_]u64{ 0, 1, 63, 64, 127, 179 }) |search_key| {
            const found = (try tree.search(search_key)).?;
            defer freeRow(allocator, found);
            try std.testing.expectEqual(@as(i64, @intCast(search_key)), found.values[0].Integer);
        }

        root_page = tree.root_page;
        try pager.flush();
    }

    {
        const pager = try Pager.init(allocator, path);
        defer pager.deinit();
        const tree = try BTree.loadFromRootPage(allocator, pager, root_page);
        defer tree.deinit();

        const rows = try tree.selectAllWithKeys(allocator);
        defer {
            for (rows) |item| freeRow(allocator, item.row);
            allocator.free(rows);
        }
        try std.testing.expectEqual(row_count, rows.len);
        for (rows, 0..) |item, i| {
            try std.testing.expectEqual(@as(u64, @intCast(i)), item.key);
            try std.testing.expectEqual(@as(i64, @intCast(i)), item.row.values[0].Integer);
        }
    }
}

fn testWalReplayIdempotence(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] WAL replay idempotence property", .{});
    const path = try test_dir.dbPath("wal-properties.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    const pager = try Pager.init(allocator, path);
    defer pager.deinit();

    const log = try WriteAheadLog.init(allocator, path);
    defer log.deinit();

    try log.beginTransaction();
    try log.logPageWrite(2, 0, "00000", "alpha");
    try log.logPageWrite(3, 8, "00000", "bravo");
    try log.commit();

    try log.checkpointToPager(pager);

    const page2_first = try pager.getPage(2);
    const page3_first = try pager.getPage(3);
    try std.testing.expectEqualSlices(u8, "alpha", page2_first.data[0..5]);
    try std.testing.expectEqualSlices(u8, "bravo", page3_first.data[8..13]);

    // Replaying an already-truncated WAL is a no-op.
    try log.checkpointToPager(pager);

    const page2_second = try pager.getPage(2);
    const page3_second = try pager.getPage(3);
    try std.testing.expectEqualSlices(u8, "alpha", page2_second.data[0..5]);
    try std.testing.expectEqualSlices(u8, "bravo", page3_second.data[8..13]);
}

fn testTransactionRollbackAndCommitInvariants(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Transaction rollback and commit invariants", .{});
    const path = try test_dir.dbPath("transaction-properties.db");
    defer allocator.free(path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE tx_prop (id INTEGER PRIMARY KEY, name TEXT)");
        try conn.execute("INSERT INTO tx_prop (id, name) VALUES (1, 'base')");

        try conn.begin();
        try conn.execute("INSERT INTO tx_prop (id, name) VALUES (2, 'rolled-back')");
        try conn.execute("UPDATE tx_prop SET name = 'mutated' WHERE id = 1");
        try conn.rollback();

        var after_rollback = try conn.query("SELECT * FROM tx_prop");
        defer after_rollback.deinit();
        try std.testing.expectEqual(@as(usize, 1), after_rollback.rows.items.len);
        try std.testing.expectEqual(@as(i64, 1), after_rollback.rows.items[0].values[0].Integer);
        try std.testing.expectEqualStrings("base", after_rollback.rows.items[0].values[1].Text);

        try conn.begin();
        try conn.execute("INSERT INTO tx_prop (id, name) VALUES (2, 'committed')");
        try conn.commit();
    }

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        var after_reopen = try conn.query("SELECT * FROM tx_prop");
        defer after_reopen.deinit();
        try std.testing.expectEqual(@as(usize, 2), after_reopen.rows.items.len);
    }
}
