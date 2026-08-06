const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

const wal_mod = zqlite.wal;
const WriteAheadLog = wal_mod.WriteAheadLog;
const LogEntry = wal_mod.LogEntry;
const LogEntryType = wal_mod.LogEntryType;
const Pager = zqlite.pager.Pager;

var test_dir: temp_dir.TempDir = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const io = init.io;
    test_dir = try .init(io, allocator, "zqlite-wal-recovery");
    defer test_dir.deinit();

    try testInvalidEntryType(io, allocator);
    try testTruncatedHeader(io, allocator);
    try testTruncatedPayload(io, allocator);
    try testOversizedLengthField(io, allocator);
    try testCommittedTxnRecovery(io, allocator);
    try testUncommittedTxnNotApplied(io, allocator);
    try testDuplicateCommitIdempotent(io, allocator);
    try testReorderedAndInterleaved(io, allocator);
    try testPageOffsetOverflow(io, allocator);
    try testInjectedFaults(io, allocator);
    try testRetryAfterCheckpointFailure(io, allocator);

    std.log.info("=== ALL WAL RECOVERY TESTS PASSED ===", .{});
}

fn cleanup(io: std.Io, path: []const u8, wal_path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    std.Io.Dir.cwd().deleteFile(io, wal_path) catch {};
}

const TestPaths = struct {
    path: []u8,
    wal_path: []u8,

    fn init(name: []const u8) !TestPaths {
        const path = try test_dir.dbPath(name);
        errdefer test_dir.allocator.free(path);
        const wal_path = try test_dir.walPath(name);
        return .{ .path = path, .wal_path = wal_path };
    }

    fn deinit(self: *TestPaths) void {
        test_dir.allocator.free(self.path);
        test_dir.allocator.free(self.wal_path);
    }
};

/// Serialize a sequence of log entries and write them to the WAL file path.
fn writeWalFile(io: std.Io, allocator: std.mem.Allocator, wal_path: []const u8, entries: []const LogEntry) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (entries) |entry| {
        const size = 25 + entry.old_data.len + entry.new_data.len;
        const tmp = try allocator.alloc(u8, size);
        defer allocator.free(tmp);
        const serialized = try entry.serialize(tmp);
        try buf.appendSlice(allocator, serialized);
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wal_path, .data = buf.items });
}

fn beginEntry(tx: u64) LogEntry {
    return LogEntry{ .entry_type = .Begin, .transaction_id = tx, .page_id = 0, .offset = 0, .old_data = &.{}, .new_data = &.{} };
}

fn commitEntry(tx: u64) LogEntry {
    return LogEntry{ .entry_type = .Commit, .transaction_id = tx, .page_id = 0, .offset = 0, .old_data = &.{}, .new_data = &.{} };
}

fn pageWriteEntry(tx: u64, page_id: u32, offset: u32, new_data: []const u8) LogEntry {
    return LogEntry{ .entry_type = .PageWrite, .transaction_id = tx, .page_id = page_id, .offset = offset, .old_data = &.{}, .new_data = new_data };
}

/// A full record carrying an invalid entry-type byte must be rejected, not
/// silently skipped or misread as a valid record.
fn testInvalidEntryType(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("invalid.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    var header: [25]u8 = undefined;
    header[0] = 99; // invalid entry type
    std.mem.writeInt(u64, header[1..9], 1, .little);
    std.mem.writeInt(u32, header[9..13], 0, .little);
    std.mem.writeInt(u32, header[13..17], 0, .little);
    std.mem.writeInt(u32, header[17..21], 0, .little);
    std.mem.writeInt(u32, header[21..25], 0, .little);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.wal_path, .data = &header });

    try std.testing.expectError(error.InvalidWalEntryType, WriteAheadLog.init(allocator, paths.path));
}

/// A trailing record shorter than the fixed header is treated as truncation
/// (EOF), so recovery succeeds while ignoring the partial bytes.
fn testTruncatedHeader(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("trunc_hdr.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    const partial = [_]u8{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 }; // 10 bytes < 25
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.wal_path, .data = &partial });

    const log = try WriteAheadLog.init(allocator, paths.path);
    defer log.deinit();
    try std.testing.expectEqual(@as(u64, 0), log.transaction_id);
}

/// A complete header that claims more payload than the file contains is treated
/// as truncation (EOF); recovery succeeds without misapplying garbage.
fn testTruncatedPayload(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("trunc_payload.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    var header: [25]u8 = undefined;
    header[0] = @backingInt(LogEntryType.PageWrite);
    std.mem.writeInt(u64, header[1..9], 1, .little);
    std.mem.writeInt(u32, header[9..13], 2, .little);
    std.mem.writeInt(u32, header[13..17], 0, .little);
    std.mem.writeInt(u32, header[17..21], 1000, .little); // old_data_len, file too short
    std.mem.writeInt(u32, header[21..25], 1000, .little); // new_data_len
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.wal_path, .data = &header });

    const log = try WriteAheadLog.init(allocator, paths.path);
    defer log.deinit();
    // No complete record recovered.
    try std.testing.expectEqual(@as(u64, 0), log.transaction_id);
}

/// A length field beyond the documented maximum must be rejected to prevent
/// memory-exhaustion via malformed WAL files.
fn testOversizedLengthField(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("oversized.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    var header: [25]u8 = undefined;
    header[0] = @backingInt(LogEntryType.PageWrite);
    std.mem.writeInt(u64, header[1..9], 1, .little);
    std.mem.writeInt(u32, header[9..13], 2, .little);
    std.mem.writeInt(u32, header[13..17], 0, .little);
    std.mem.writeInt(u32, header[17..21], 200_000, .little); // > MAX_DATA_FIELD_SIZE
    std.mem.writeInt(u32, header[21..25], 0, .little);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = paths.wal_path, .data = &header });

    try std.testing.expectError(error.WalEntryTooLarge, WriteAheadLog.init(allocator, paths.path));
}

/// A committed transaction's page writes are replayed onto the pager during
/// checkpoint after a simulated interruption (no checkpoint before reopen).
fn testCommittedTxnRecovery(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("committed.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    const entries = [_]LogEntry{
        beginEntry(1),
        pageWriteEntry(1, 2, 0, "HELLO"),
        commitEntry(1),
    };
    try writeWalFile(io, allocator, paths.wal_path, &entries);

    const pager = try Pager.init(allocator, paths.path);
    defer pager.deinit();

    const log = try WriteAheadLog.init(allocator, paths.path);
    defer log.deinit();

    try log.checkpointToPager(pager);

    const page = try pager.getPage(2);
    try std.testing.expectEqualSlices(u8, "HELLO", page.data[0..5]);
}

/// Page writes from a transaction that never committed must not be applied.
fn testUncommittedTxnNotApplied(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("uncommitted.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    const entries = [_]LogEntry{
        beginEntry(1),
        pageWriteEntry(1, 2, 0, "GHOST"),
        // no commit record
    };
    try writeWalFile(io, allocator, paths.wal_path, &entries);

    const pager = try Pager.init(allocator, paths.path);
    defer pager.deinit();

    const log = try WriteAheadLog.init(allocator, paths.path);
    defer log.deinit();

    try log.checkpointToPager(pager);

    const page = try pager.getPage(2);
    const expected = [_]u8{ 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &expected, page.data[0..5]);
}

/// Duplicate COMMIT records for the same transaction are idempotent.
fn testDuplicateCommitIdempotent(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("dup.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    const entries = [_]LogEntry{
        beginEntry(1),
        pageWriteEntry(1, 2, 0, "AAAAA"),
        commitEntry(1),
        commitEntry(1),
    };
    try writeWalFile(io, allocator, paths.wal_path, &entries);

    const pager = try Pager.init(allocator, paths.path);
    defer pager.deinit();

    const log = try WriteAheadLog.init(allocator, paths.path);
    defer log.deinit();

    try log.checkpointToPager(pager);

    const page = try pager.getPage(2);
    try std.testing.expectEqualSlices(u8, "AAAAA", page.data[0..5]);
}

/// Interleaved/reordered records: only the committed transaction's writes are
/// applied, even when a PAGE record for an uncommitted transaction precedes it.
fn testReorderedAndInterleaved(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("reorder.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    const entries = [_]LogEntry{
        beginEntry(1),
        pageWriteEntry(1, 2, 0, "XXXXX"), // tx1 never commits
        beginEntry(2),
        pageWriteEntry(2, 3, 0, "YYYYY"),
        commitEntry(2),
    };
    try writeWalFile(io, allocator, paths.wal_path, &entries);

    const pager = try Pager.init(allocator, paths.path);
    defer pager.deinit();

    const log = try WriteAheadLog.init(allocator, paths.path);
    defer log.deinit();

    try log.checkpointToPager(pager);

    const page2 = try pager.getPage(2);
    const zeros = [_]u8{ 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &zeros, page2.data[0..5]);

    const page3 = try pager.getPage(3);
    try std.testing.expectEqualSlices(u8, "YYYYY", page3.data[0..5]);
}

/// A committed page write whose offset+length exceeds the page bounds must
/// surface a precise error instead of corrupting adjacent memory.
fn testPageOffsetOverflow(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("overflow.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    const entries = [_]LogEntry{
        beginEntry(1),
        pageWriteEntry(1, 2, 4095, "0123456789"), // 4095 + 10 > 4096
        commitEntry(1),
    };
    try writeWalFile(io, allocator, paths.wal_path, &entries);

    const pager = try Pager.init(allocator, paths.path);
    defer pager.deinit();

    const log = try WriteAheadLog.init(allocator, paths.path);
    defer log.deinit();

    try std.testing.expectError(error.WalEntryOutOfBounds, log.checkpointToPager(pager));
}

/// Injected read, write, and partial-write faults surface as errors.
fn testInjectedFaults(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("faults.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    // Write fault on the very first record (BEGIN).
    {
        const log = try WriteAheadLog.init(allocator, paths.path);
        defer log.deinit();
        log.injectFaultOnce(.write);
        try std.testing.expectError(error.InjectedWriteFailure, log.beginTransaction());
    }

    // Partial write fault while logging a page modification.
    {
        const log = try WriteAheadLog.init(allocator, paths.path);
        defer log.deinit();
        try log.beginTransaction();
        log.injectFaultOnce(.partial_write);
        try std.testing.expectError(error.InjectedPartialWrite, log.logPageWrite(2, 0, "old", "new"));
    }

    cleanup(io, paths.path, paths.wal_path);

    // Read fault while checkpointing existing committed content.
    {
        const log = try WriteAheadLog.init(allocator, paths.path);
        defer log.deinit();
        try log.beginTransaction();
        try log.logPageWrite(2, 0, "old", "new");
        try log.commit();
        log.injectFaultOnce(.read);
        try std.testing.expectError(error.InjectedReadFailure, log.checkpoint());
    }
}

/// A checkpoint that fails at truncation, after a durable commit, can be safely
/// retried; the WAL content remains intact and the page write is idempotent.
fn testRetryAfterCheckpointFailure(io: std.Io, allocator: std.mem.Allocator) !void {
    var paths = try TestPaths.init("retry.db");
    defer paths.deinit();
    cleanup(io, paths.path, paths.wal_path);
    defer cleanup(io, paths.path, paths.wal_path);

    const pager = try Pager.init(allocator, paths.path);
    defer pager.deinit();

    const log = try WriteAheadLog.init(allocator, paths.path);
    defer log.deinit();

    try log.beginTransaction();
    try log.logPageWrite(2, 0, "00000", "ZZZZZ");
    try log.commit();

    // First checkpoint applies the page write but fails at truncation.
    log.injectFaultOnce(.truncate);
    try std.testing.expectError(error.InjectedTruncateFailure, log.checkpointToPager(pager));

    // Retry succeeds; data is present and idempotent.
    try log.checkpointToPager(pager);

    const page = try pager.getPage(2);
    try std.testing.expectEqualSlices(u8, "ZZZZZ", page.data[0..5]);
}
