const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var test_dir = try temp_dir.TempDir.init(init.io, allocator, "zqlite-fts");
    defer test_dir.deinit();

    std.log.info("=== FTS Persistence Tests ===", .{});

    const path = try test_dir.dbPath("fts_persistence.db");
    defer allocator.free(path);

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE VIRTUAL TABLE docs USING fts5(title, body)");
        try conn.execute("INSERT INTO docs VALUES ('Guide', 'quantum safe storage guide')");
        try conn.execute("INSERT INTO docs VALUES ('Notes', 'classical fallback details')");

        var result = try conn.query("SELECT title FROM docs WHERE body MATCH 'quantum guide'");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 1);
        std.log.info("[PASS] Initial FTS query works", .{});
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        std.debug.assert(conn.storage_engine.isFTSTable("docs"));

        var result = try conn.query("SELECT title FROM docs WHERE body MATCH 'quantum guide'");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 1);
        std.debug.assert(std.mem.eql(u8, result.rows.items[0].values[0].Text, "Guide"));

        try conn.execute("INSERT INTO docs VALUES ('Roadmap', 'quantum storage roadmap')");

        var second = try conn.query("SELECT title FROM docs WHERE body MATCH 'quantum roadmap'");
        defer second.deinit();

        std.debug.assert(second.rows.items.len == 1);
        std.debug.assert(std.mem.eql(u8, second.rows.items[0].values[0].Text, "Roadmap"));
        std.log.info("[PASS] FTS metadata and inserts survive reopen", .{});
    }

    std.log.info("=== ALL FTS PERSISTENCE TESTS PASSED ===", .{});
}
