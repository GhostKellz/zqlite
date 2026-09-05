const std = @import("std");
const zqlite = @import("zqlite");

test "signed INSERT values preserve integer and real values" {
    var parsed = try zqlite.parser.parse(std.testing.allocator, "INSERT INTO numbers VALUES (-42, -3.5, -0.0, +17)");
    defer parsed.deinit();
    const values = parsed.statement.Insert.values[0];
    try std.testing.expectEqual(@as(i64, -42), values[0].Integer);
    try std.testing.expectEqual(@as(f64, -3.5), values[1].Real);
    try std.testing.expect(std.math.signbit(values[2].Real));
    try std.testing.expectEqual(@as(i64, 17), values[3].Integer);
    var minimum = try zqlite.parser.parse(std.testing.allocator, "INSERT INTO numbers VALUES (-9223372036854775808)");
    defer minimum.deinit();
    try std.testing.expectEqual(std.math.minInt(i64), minimum.statement.Insert.values[0][0].Integer);
}

fn parseWithFailures(allocator: std.mem.Allocator, sql: []const u8, valid: bool) !void {
    var parsed = zqlite.parser.parse(allocator, sql) catch |err| {
        if (err == error.OutOfMemory or valid) return err;
        return;
    };
    defer parsed.deinit();
    try std.testing.expect(valid);
}

test "INSERT syntax and allocation failures release every owned fragment" {
    for ([_][]const u8{
        "INSERT INTO data (a, b) VALUES ('one', -2), ('two', 3) RETURNING a, b",
        "INSERT INTO data DEFAULT VALUES RETURNING a",
        "INSERT INTO data (a) VALUES ('one') ON CONFLICT (a) DO UPDATE SET a = 'two' RETURNING a",
    }) |sql| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, parseWithFailures, .{ sql, true });
    }
    for ([_][]const u8{
        "INSERT INTO data (a, b VALUES (1, 2)",
        "INSERT INTO data VALUES ('owned', -)",
        "INSERT INTO data VALUES ('owned'), ('unfinished'",
        "INSERT INTO data VALUES ('owned') RETURNING a,",
        "INSERT INTO data VALUES ('owned') ON CONFLICT (a,",
        "INSERT INTO data VALUES ('owned') ON CONFLICT (a) DO UPDATE SET a = 'two',",
        "INSERT INTO data VALUES ('owned') @",
        "INSERT INTO data VALUES ('owned', +9223372036854775808)",
        "INSERT INTO data VALUES ('owned', -9223372036854775809)",
    }) |sql| {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, parseWithFailures, .{ sql, false });
    }
}

test "rejected INSERT leaves the active transaction usable" {
    const conn = try zqlite.openMemory(std.testing.allocator);
    defer conn.close();
    try conn.execute("CREATE TABLE numbers (n INTEGER, r REAL)");
    try conn.execute("BEGIN");
    try std.testing.expectError(error.ExpectedValue, conn.execute("INSERT INTO numbers VALUES ('owned', -)"));
    try conn.execute("INSERT INTO numbers VALUES (-42, -3.5)");
    try conn.execute("COMMIT");
    var result = try conn.query("SELECT * FROM numbers");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rows.items.len);
    try std.testing.expectEqual(@as(i64, -42), result.rows.items[0].values[0].Integer);
}
