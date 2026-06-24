const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

// Superblock layout constants (must mirror src/db/storage.zig).
const SUPERBLOCK_MAGIC: u32 = 0x5A444231; // "ZDB1"
const METADATA_MAGIC: u32 = 0x5A514C54; // "ZQLT" (legacy)
const SB_OFF_VERSION: usize = 4;
const SB_OFF_ACTIVE: usize = 8;
const SB_OFF_SLOT_A: usize = 20;
const SB_OFF_SLOT_B: usize = 48;
const SB_OFF_HEADER_CHECKSUM: usize = 76;
const SB_HEADER_LEN: usize = 76;
const CATALOG_PAGE_HEADER: usize = 8;
const PAGE_SIZE: usize = 4096;

var test_dir: temp_dir.TempDir = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const io = init.io;
    test_dir = try .init(io, allocator, "zqlite-catalog");
    defer test_dir.deinit();

    try testMultiPageCatalogRoundTrip(io, allocator);
    try testManyRewritesReadLatest(io, allocator);
    try testInterruptedInactiveSlotReplacement(io, allocator);
    try testHeaderChecksumCorruption(io, allocator);
    try testUnsupportedVersion(io, allocator);
    try testPayloadChecksumCorruption(io, allocator);
    try testLegacyMigration(io, allocator);

    std.log.info("=== ALL CATALOG FORMAT TESTS PASSED ===", .{});
}

fn cleanup(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const wal = std.fmt.bufPrint(&buf, "{s}-wal", .{path}) catch return;
    std.Io.Dir.cwd().deleteFile(io, wal) catch {};
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// A catalog larger than one page must survive a reopen intact, proving the
/// chained multi-page payload is written and reassembled correctly.
fn testMultiPageCatalogRoundTrip(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Multi-page catalog round-trip", .{});
    const path = try test_dir.dbPath("multipage.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    const table_count: usize = 60;

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        var name_buf: [64]u8 = undefined;
        var sql_buf: [256]u8 = undefined;
        var i: usize = 0;
        while (i < table_count) : (i += 1) {
            const name = try std.fmt.bufPrint(&name_buf, "table_{d:0>4}", .{i});
            const create = try std.fmt.bufPrint(&sql_buf, "CREATE TABLE {s} (id INTEGER, name TEXT, value REAL)", .{name});
            try conn.execute(create);
            const insert = try std.fmt.bufPrint(&sql_buf, "INSERT INTO {s} (id, name, value) VALUES (1, 'row', 1.5)", .{name});
            try conn.execute(insert);
        }
    }

    // The serialized catalog must exceed a single page for this test to be
    // meaningful; otherwise it never exercises the chain.
    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 2 * PAGE_SIZE);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        var name_buf: [64]u8 = undefined;
        var sql_buf: [256]u8 = undefined;
        var i: usize = 0;
        while (i < table_count) : (i += 1) {
            const name = try std.fmt.bufPrint(&name_buf, "table_{d:0>4}", .{i});
            const select = try std.fmt.bufPrint(&sql_buf, "SELECT * FROM {s}", .{name});
            var result = try conn.query(select);
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
        }
    }
}

/// Many rewrites alternate the active A/B slot; a reopen must always observe the
/// most recently committed catalog, never a stale slot.
fn testManyRewritesReadLatest(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] A/B ping-pong reads latest catalog", .{});
    const path = try test_dir.dbPath("pingpong.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        // Each create + drop forces multiple metadata rewrites, flipping slots.
        var round: usize = 0;
        while (round < 10) : (round += 1) {
            try conn.execute("CREATE TABLE scratch (id INTEGER)");
            try conn.execute("DROP TABLE scratch");
        }
        try conn.execute("CREATE TABLE final_table (id INTEGER, label TEXT)");
        try conn.execute("INSERT INTO final_table (id, label) VALUES (42, 'kept')");
    }

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        // The dropped scratch table must be gone and the final table present.
        var scratch = conn.query("SELECT * FROM scratch");
        if (scratch) |*r| {
            r.deinit();
            return error.DroppedTableStillPresent;
        } else |_| {}

        var result = try conn.query("SELECT * FROM final_table");
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
    }
}

fn activeSlotOffset(bytes: []const u8) usize {
    return if (bytes[SB_OFF_ACTIVE] == 0) SB_OFF_SLOT_A else SB_OFF_SLOT_B;
}

fn inactiveSlotOffset(bytes: []const u8) usize {
    return if (bytes[SB_OFF_ACTIVE] == 0) SB_OFF_SLOT_B else SB_OFF_SLOT_A;
}

/// A crash while rewriting the inactive catalog slot must not affect recovery:
/// reopen still follows the active slot recorded in the durable superblock.
fn testInterruptedInactiveSlotReplacement(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Interrupted inactive catalog slot replacement", .{});
    const path = try test_dir.dbPath("inactive-slot.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE first_table (id INTEGER)");
        try conn.execute("CREATE TABLE second_table (id INTEGER)");
        try conn.execute("CREATE TABLE final_table (id INTEGER, label TEXT)");
        try conn.execute("INSERT INTO final_table (id, label) VALUES (7, 'active')");
    }

    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    try std.testing.expectEqual(SUPERBLOCK_MAGIC, std.mem.readInt(u32, bytes[0..4], .little));

    const inactive_off = inactiveSlotOffset(bytes);
    const inactive_first_page = std.mem.readInt(u32, bytes[inactive_off..][0..4], .little);
    try std.testing.expect(inactive_first_page >= 2);

    const payload_byte = (inactive_first_page - 1) * PAGE_SIZE + CATALOG_PAGE_HEADER;
    try std.testing.expect(payload_byte < bytes.len);
    bytes[payload_byte] ^= 0xFF;
    try writeFile(io, path, bytes);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        var result = try conn.query("SELECT * FROM final_table");
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
        try std.testing.expectEqual(@as(i64, 7), result.rows.items[0].values[0].Integer);
    }
}

/// A superblock whose header bytes no longer match its checksum must be rejected
/// rather than silently interpreted.
fn testHeaderChecksumCorruption(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Superblock header checksum corruption", .{});
    const path = try test_dir.dbPath("hdrcrc.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE t (id INTEGER)");
    }

    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    try std.testing.expectEqual(SUPERBLOCK_MAGIC, std.mem.readInt(u32, bytes[0..4], .little));

    // Flip a covered header byte without updating the checksum.
    bytes[6] ^= 0xFF;
    try writeFile(io, path, bytes);

    try std.testing.expectError(error.CorruptCatalog, zqlite.open(allocator, path));
}

/// A superblock declaring a newer format version (with a valid checksum) must be
/// reported as unsupported instead of misparsed.
fn testUnsupportedVersion(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Unsupported newer format version", .{});
    const path = try test_dir.dbPath("version.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE t (id INTEGER)");
    }

    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);

    // Bump the version and recompute the header checksum so it passes integrity
    // but fails the version gate.
    std.mem.writeInt(u16, bytes[SB_OFF_VERSION..][0..2], 99, .little);
    const checksum = std.hash.Crc32.hash(bytes[0..SB_HEADER_LEN]);
    std.mem.writeInt(u32, bytes[SB_OFF_HEADER_CHECKSUM..][0..4], checksum, .little);
    try writeFile(io, path, bytes);

    try std.testing.expectError(error.UnsupportedDatabaseFormat, zqlite.open(allocator, path));
}

/// Corrupting a catalog payload byte must be caught by the chain checksum, even
/// though the superblock header itself is still valid.
fn testPayloadChecksumCorruption(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Catalog payload checksum corruption", .{});
    const path = try test_dir.dbPath("payloadcrc.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE payload_test (id INTEGER, name TEXT)");
    }

    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);

    // Locate the active slot's first catalog page and flip a payload byte.
    const slot_off = activeSlotOffset(bytes);
    const first_page = std.mem.readInt(u32, bytes[slot_off..][0..4], .little);
    try std.testing.expect(first_page >= 2);
    const payload_byte = (first_page - 1) * PAGE_SIZE + CATALOG_PAGE_HEADER;
    try std.testing.expect(payload_byte < bytes.len);
    bytes[payload_byte] ^= 0xFF;
    try writeFile(io, path, bytes);

    try std.testing.expectError(error.CorruptCatalog, zqlite.open(allocator, path));
}

/// A legacy single-page (page-1) catalog must still open, and the next metadata
/// rewrite must transparently migrate it to the superblock format.
fn testLegacyMigration(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Legacy catalog auto-migration", .{});
    const path = try test_dir.dbPath("legacy.db");
    defer allocator.free(path);
    cleanup(io, path);
    defer cleanup(io, path);

    var root_page: u32 = 0;
    var row_count: u64 = 0;

    // 1. Build a real database, then capture its btree root for the table.
    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try conn.execute("CREATE TABLE users (id INTEGER, name TEXT)");
        try conn.execute("INSERT INTO users (id, name) VALUES (1, 'Alice')");
        try conn.execute("INSERT INTO users (id, name) VALUES (2, 'Bob')");
        const table = conn.storage_engine.getTable("users").?;
        root_page = table.btree.root_page;
        row_count = table.row_count;
    }

    // 2. Overwrite page 1 with a hand-crafted legacy catalog that points at the
    //    same btree root, leaving the data pages untouched.
    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len >= PAGE_SIZE);

    var page1: [PAGE_SIZE]u8 = undefined;
    @memset(&page1, 0);
    std.mem.writeInt(u32, page1[0..4], METADATA_MAGIC, .little);
    std.mem.writeInt(u32, page1[4..8], 1, .little); // table_count = 1
    var off: usize = 8;
    // table name
    const tname = "users";
    std.mem.writeInt(u16, page1[off..][0..2], @intCast(tname.len), .little);
    off += 2;
    @memcpy(page1[off..][0..tname.len], tname);
    off += tname.len;
    // root_page, row_count, deleted_count
    std.mem.writeInt(u32, page1[off..][0..4], root_page, .little);
    off += 4;
    std.mem.writeInt(u64, page1[off..][0..8], row_count, .little);
    off += 8;
    std.mem.writeInt(u32, page1[off..][0..4], 0, .little); // deleted keys
    off += 4;
    // column_count = 2
    std.mem.writeInt(u16, page1[off..][0..2], 2, .little);
    off += 2;
    off = writeLegacyColumn(&page1, off, "id", 0, 0x01); // INTEGER, primary key
    off = writeLegacyColumn(&page1, off, "name", 1, 0x02); // TEXT, nullable
    // index_count = 0
    std.mem.writeInt(u32, page1[off..][0..4], 0, .little);
    off += 4;
    // No extension magic: the rest of the page stays zeroed.

    @memcpy(bytes[0..PAGE_SIZE], &page1);
    try writeFile(io, path, bytes);

    // 3. Reopen: the legacy catalog must load and report legacy format.
    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try std.testing.expect(conn.storage_engine.legacy_format);
        var result = try conn.query("SELECT * FROM users");
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 2), result.rows.items.len);

        // Force a metadata rewrite to trigger migration to the new format.
        try conn.execute("CREATE TABLE extra (id INTEGER)");
    }

    // 4. Page 1 must now be a superblock, and data is still intact.
    const migrated = try readFile(io, allocator, path);
    defer allocator.free(migrated);
    try std.testing.expectEqual(SUPERBLOCK_MAGIC, std.mem.readInt(u32, migrated[0..4], .little));

    {
        const conn = try zqlite.open(allocator, path);
        defer conn.close();
        try std.testing.expect(!conn.storage_engine.legacy_format);
        var users = try conn.query("SELECT * FROM users");
        defer users.deinit();
        try std.testing.expectEqual(@as(usize, 2), users.rows.items.len);
        var extra = try conn.query("SELECT * FROM extra");
        defer extra.deinit();
        try std.testing.expectEqual(@as(usize, 0), extra.rows.items.len);
    }
}

fn writeLegacyColumn(page: []u8, offset: usize, name: []const u8, data_type: u8, flags: u8) usize {
    var off = offset;
    std.mem.writeInt(u16, page[off..][0..2], @intCast(name.len), .little);
    off += 2;
    @memcpy(page[off..][0..name.len], name);
    off += name.len;
    page[off] = data_type;
    off += 1;
    page[off] = flags;
    off += 1;
    return off;
}
