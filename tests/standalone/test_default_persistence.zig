const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Options.debug_io;

    std.log.info("=== Default Persistence Tests ===", .{});

    const path = "/tmp/zqlite_default_persistence.db";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE defaults_test (id INTEGER PRIMARY KEY, name TEXT DEFAULT 'guest', created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");
        try conn.execute("INSERT INTO defaults_test (id) VALUES (1)");

        var pragma = try conn.query("PRAGMA table_info(defaults_test)");
        defer pragma.deinit();
        std.debug.assert(pragma.rows.items.len == 3);
    }

    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("INSERT INTO defaults_test (id) VALUES (2)");

        var result = try conn.query("SELECT name, created_at FROM defaults_test WHERE id = 2");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 1);
        std.debug.assert(std.mem.eql(u8, result.rows.items[0].values[0].Text, "guest"));
        std.debug.assert(result.rows.items[0].values[1] == .Integer or result.rows.items[0].values[1] == .Text);

        var pragma = try conn.query("PRAGMA table_info(defaults_test)");
        defer pragma.deinit();

        std.debug.assert(pragma.rows.items.len == 3);
        std.debug.assert(std.mem.eql(u8, pragma.rows.items[1].values[4].Text, "guest"));
        std.debug.assert(std.mem.eql(u8, pragma.rows.items[2].values[4].Text, "CURRENT_TIMESTAMP"));
        std.log.info("[PASS] Column defaults survive reopen", .{});
    }

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    std.log.info("=== ALL DEFAULT PERSISTENCE TESTS PASSED ===", .{});
}
