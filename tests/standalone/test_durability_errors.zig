const std = @import("std");
const builtin = @import("builtin");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

var test_dir: temp_dir.TempDir = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    test_dir = try .init(init.io, allocator, "zqlite-durability");
    defer test_dir.deinit();

    try testCloseReportsSyncFailure(init.io, allocator);
    try testPagerFaultsAreObservable(init.io, allocator);
    try testWalFaultsAreObservable(init.io, allocator);

    try testCommitWalWriteFailure(init.io, allocator);
    try testCommitWalPartialWrite(init.io, allocator);
    try testCommitWalSyncFailure(init.io, allocator);
    try testCommitCheckpointPageWriteFailure(init.io, allocator);
    try testCommitCheckpointSyncFailure(init.io, allocator);
    try testCommitWalTruncateAfterCheckpoint(init.io, allocator);
    try testMetadataWriteFailure(init.io, allocator);
    try testMetadataSyncFailure(init.io, allocator);
    try testReadOnlyOpenIsRejected(init.io, allocator);

    std.log.info("=== ALL DURABILITY ERROR TESTS PASSED ===", .{});
}

fn cleanup(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn testCloseReportsSyncFailure(io: std.Io, allocator: std.mem.Allocator) !void {
    const path = try test_dir.dbPath("close.db");
    defer allocator.free(path);
    const wal_path = try test_dir.walPath("close.db");
    defer allocator.free(wal_path);
    cleanup(io, path);
    cleanup(io, wal_path);
    defer cleanup(io, path);
    defer cleanup(io, wal_path);

    const conn = try zqlite.open(allocator, path);
    try conn.execute("CREATE TABLE durability_test (id INTEGER)");
    conn.storage_engine.pager.injectFaultOnce(.sync);

    try std.testing.expectError(error.InjectedSyncFailure, conn.closeFallible());
}

fn testPagerFaultsAreObservable(io: std.Io, allocator: std.mem.Allocator) !void {
    const path = try test_dir.dbPath("pager.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    const pager = try zqlite.pager.Pager.init(allocator, path);
    defer pager.deinit();

    _ = try pager.allocatePage();
    pager.injectFaultOnce(.partial_write);
    try std.testing.expectError(error.InjectedPartialWrite, pager.flush());

    pager.injectFaultOnce(.write);
    try std.testing.expectError(error.InjectedWriteFailure, pager.flush());

    // Allow cleanup to persist the page, then verify read faults separately.
    try pager.flush();
    pager.injectFaultOnce(.read);
    try std.testing.expectError(error.InjectedReadFailure, pager.getPage(999));
}

fn testWalFaultsAreObservable(io: std.Io, allocator: std.mem.Allocator) !void {
    const path = try test_dir.dbPath("wal.db");
    defer allocator.free(path);
    const wal_path = try test_dir.walPath("wal.db");
    defer allocator.free(wal_path);
    cleanup(io, path);
    cleanup(io, wal_path);
    defer cleanup(io, path);
    defer cleanup(io, wal_path);

    const log = try zqlite.wal.WriteAheadLog.init(allocator, path);
    defer log.deinit();

    try log.beginTransaction();
    try log.logPageWrite(1, 0, "old", "new");
    log.injectFaultOnce(.sync);
    try std.testing.expectError(error.InjectedSyncFailure, log.commit());

    // The failed durability barrier leaves the transaction active so callers
    // cannot mistake the commit for a durable success.
    try std.testing.expect(log.is_transaction_active);
    try log.rollback();

    log.injectFaultOnce(.truncate);
    try std.testing.expectError(error.InjectedTruncateFailure, log.checkpoint());
}

/// Drive a real transaction up to COMMIT, then verify each commit stage that can
/// fail propagates its error and leaves the transaction in the documented state.
const CommitFixture = struct {
    conn: *zqlite.Connection,
    path: []const u8,
    wal_path: []const u8,

    fn open(io: std.Io, allocator: std.mem.Allocator, name: []const u8) !CommitFixture {
        const path = try test_dir.dbPath(name);
        errdefer allocator.free(path);
        const wal_path = try test_dir.walPath(name);
        errdefer allocator.free(wal_path);
        cleanup(io, path);
        cleanup(io, wal_path);

        const conn = try zqlite.open(allocator, path);
        try conn.execute("CREATE TABLE t (id INTEGER, name TEXT)");
        try conn.begin();
        try conn.execute("INSERT INTO t (id, name) VALUES (1, 'one')");
        return .{ .conn = conn, .path = path, .wal_path = wal_path };
    }

    fn deinit(self: *CommitFixture, io: std.Io, allocator: std.mem.Allocator) void {
        self.conn.close();
        cleanup(io, self.path);
        cleanup(io, self.wal_path);
        allocator.free(self.path);
        allocator.free(self.wal_path);
    }
};

fn testCommitWalWriteFailure(io: std.Io, allocator: std.mem.Allocator) !void {
    var fx = try CommitFixture.open(io, allocator, "commit_wal_write.db");
    defer fx.deinit(io, allocator);

    fx.conn.wal.?.injectFaultOnce(.write);
    try std.testing.expectError(error.InjectedWriteFailure, fx.conn.commit());

    // The commit record never reached its sync barrier, so the transaction must
    // still be active and not mistaken for durable.
    try std.testing.expect(fx.conn.in_transaction);
    try std.testing.expect(fx.conn.wal.?.is_transaction_active);
}

fn testCommitWalPartialWrite(io: std.Io, allocator: std.mem.Allocator) !void {
    var fx = try CommitFixture.open(io, allocator, "commit_wal_partial.db");
    defer fx.deinit(io, allocator);

    fx.conn.wal.?.injectFaultOnce(.partial_write);
    try std.testing.expectError(error.InjectedPartialWrite, fx.conn.commit());

    try std.testing.expect(fx.conn.in_transaction);
    try std.testing.expect(fx.conn.wal.?.is_transaction_active);
}

fn testCommitWalSyncFailure(io: std.Io, allocator: std.mem.Allocator) !void {
    var fx = try CommitFixture.open(io, allocator, "commit_wal_sync.db");
    defer fx.deinit(io, allocator);

    fx.conn.wal.?.injectFaultOnce(.sync);
    try std.testing.expectError(error.InjectedSyncFailure, fx.conn.commit());

    // A failed durability barrier keeps the transaction active.
    try std.testing.expect(fx.conn.in_transaction);
    try std.testing.expect(fx.conn.wal.?.is_transaction_active);
}

fn testCommitCheckpointPageWriteFailure(io: std.Io, allocator: std.mem.Allocator) !void {
    var fx = try CommitFixture.open(io, allocator, "commit_ckpt_write.db");
    defer fx.deinit(io, allocator);

    // The first pager write happens while the checkpoint applies committed pages.
    fx.conn.storage_engine.pager.injectFaultOnce(.write);
    try std.testing.expectError(error.InjectedWriteFailure, fx.conn.commit());

    // The WAL commit record is already durable, so the transaction is logically
    // committed even though the checkpoint could not finish.
    try std.testing.expect(!fx.conn.in_transaction);
    try std.testing.expect(!fx.conn.wal.?.is_transaction_active);
}

fn testCommitCheckpointSyncFailure(io: std.Io, allocator: std.mem.Allocator) !void {
    var fx = try CommitFixture.open(io, allocator, "commit_ckpt_sync.db");
    defer fx.deinit(io, allocator);

    fx.conn.storage_engine.pager.injectFaultOnce(.sync);
    try std.testing.expectError(error.InjectedSyncFailure, fx.conn.commit());

    try std.testing.expect(!fx.conn.in_transaction);
    try std.testing.expect(!fx.conn.wal.?.is_transaction_active);
}

fn testCommitWalTruncateAfterCheckpoint(io: std.Io, allocator: std.mem.Allocator) !void {
    var fx = try CommitFixture.open(io, allocator, "commit_truncate.db");
    defer fx.deinit(io, allocator);

    // Pages are applied and synced before the WAL is truncated; a truncate failure
    // must not undo the durable commit.
    fx.conn.wal.?.injectFaultOnce(.truncate);
    try std.testing.expectError(error.InjectedTruncateFailure, fx.conn.commit());

    try std.testing.expect(!fx.conn.in_transaction);
    try std.testing.expect(!fx.conn.wal.?.is_transaction_active);
}

fn testMetadataWriteFailure(io: std.Io, allocator: std.mem.Allocator) !void {
    const path = try test_dir.dbPath("meta_write.db");
    defer allocator.free(path);
    const wal_path = try test_dir.walPath("meta_write.db");
    defer allocator.free(wal_path);
    cleanup(io, path);
    cleanup(io, wal_path);
    defer cleanup(io, path);
    defer cleanup(io, wal_path);

    const conn = try zqlite.open(allocator, path);
    defer conn.close();
    try conn.execute("CREATE TABLE meta_t (id INTEGER)");
    // Persist everything so no unrelated dirty pages remain to consume the fault.
    try conn.flush();

    conn.storage_engine.pager.injectFaultOnce(.write);
    try std.testing.expectError(error.InjectedWriteFailure, conn.storage_engine.saveAllMetadata());
}

fn testMetadataSyncFailure(io: std.Io, allocator: std.mem.Allocator) !void {
    const path = try test_dir.dbPath("meta_sync.db");
    defer allocator.free(path);
    const wal_path = try test_dir.walPath("meta_sync.db");
    defer allocator.free(wal_path);
    cleanup(io, path);
    cleanup(io, wal_path);
    defer cleanup(io, path);
    defer cleanup(io, wal_path);

    const conn = try zqlite.open(allocator, path);
    defer conn.close();
    try conn.execute("CREATE TABLE meta_t (id INTEGER)");
    try conn.flush();

    conn.storage_engine.pager.injectFaultOnce(.sync);
    try std.testing.expectError(error.InjectedSyncFailure, conn.storage_engine.saveAllMetadata());
}

/// Opening a read-only database file for writing must fail rather than silently
/// degrade. Windows read-only attributes do not provide equivalent write denial.
fn testReadOnlyOpenIsRejected(io: std.Io, allocator: std.mem.Allocator) !void {
    if (comptime builtin.os.tag == .windows) {
        std.log.info("[SKIP] read-only open rejection (Windows permission semantics)", .{});
        return;
    }

    const path = try test_dir.dbPath("readonly.db");
    defer allocator.free(path);
    const wal_path = try test_dir.walPath("readonly.db");
    defer allocator.free(wal_path);
    cleanup(io, path);
    cleanup(io, wal_path);
    defer cleanup(io, path);
    defer cleanup(io, wal_path);

    const conn = try zqlite.open(allocator, path);
    try conn.execute("CREATE TABLE ro_t (id INTEGER)");
    conn.close();

    try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o444), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o644), .{}) catch {};

    const reopened = zqlite.open(allocator, path) catch |err| {
        try std.testing.expectEqual(error.AccessDenied, err);
        return;
    };
    reopened.close();
    std.log.info("[SKIP] read-only open rejection (permissions bypassed by current user)", .{});
}
