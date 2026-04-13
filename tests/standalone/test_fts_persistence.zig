const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Options.debug_io;

    std.log.info("=== FTS Persistence Tests ===", .{});

    const path = "/tmp/zqlite_fts_persistence.db";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

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

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    std.log.info("=== ALL FTS PERSISTENCE TESTS PASSED ===", .{});
}
