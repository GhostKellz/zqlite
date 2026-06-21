const std = @import("std");
const zqlite = @import("zqlite");

test "release package Zig consumer" {
    const conn = try zqlite.openMemory(std.testing.allocator);
    defer conn.close();

    try conn.execute("CREATE TABLE smoke (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO smoke VALUES (1, 'package-ok')");

    var result = try conn.query("SELECT name FROM smoke WHERE id = 1");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.count());
}
