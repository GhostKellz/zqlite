const std = @import("std");
const builtin = @import("builtin");
const zqlite = @import("zqlite");
const Counter = @import("index_evidence.zig").Counter;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var counter = Counter{ .backing = gpa.allocator() };
    for ([_]usize{ 128, 1024, 4096 }) |rows| {
        const conn = try zqlite.openMemory(counter.allocator());
        defer conn.close();
        try conn.execute("CREATE TABLE samples (id INTEGER, bucket INTEGER, payload TEXT)");
        const seed = try conn.prepare("INSERT INTO samples VALUES (?, ?, 'payload')");
        defer seed.deinit();
        try conn.execute("BEGIN");
        for (0..rows) |i| {
            try seed.bind(0, @as(i64, @intCast(i)));
            try seed.bind(1, @as(i64, @intCast(i / 4)));
            var result = try seed.execute();
            result.deinit();
        }
        try conn.execute("COMMIT");
        try conn.execute("CREATE UNIQUE INDEX sample_id ON samples (id)");
        try conn.execute("CREATE INDEX sample_bucket ON samples (bucket)");
        try conn.execute("BEGIN");
        for ([_][]const u8{
            "INSERT INTO samples VALUES (?, 7, 'new')",
            "UPDATE samples SET bucket = 8 WHERE id = ?",
            "DELETE FROM samples WHERE id = ?",
        }, 0..) |sql, kind| {
            const stmt = try conn.prepare(sql);
            defer stmt.deinit();
            const allocations = counter.allocations;
            const bytes = counter.bytes;
            const live = counter.live_bytes;
            counter.peak_bytes = live;
            const start = try zqlite.compat.Instant.now();
            for (0..32) |i| {
                try stmt.bind(0, @as(i64, @intCast(rows + i)));
                var result = try stmt.execute();
                defer result.deinit();
                try std.testing.expectEqual(@as(u32, 1), result.affected_rows);
            }
            const elapsed = (try zqlite.compat.Instant.now()).since(start);
            std.debug.print(
                "{{\"zig\":\"{s}\",\"os\":\"{s}\",\"arch\":\"{s}\",\"optimize\":\"{s}\",\"rows\":{d},\"operation\":\"{s}\",\"iterations\":32,\"allocations\":{d},\"requested_bytes\":{d},\"peak_extra_bytes\":{d},\"elapsed_ns\":{d}}}\n",
                .{ builtin.zig_version_string, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), @tagName(builtin.mode), rows, ([_][]const u8{ "insert", "update", "delete" })[kind], counter.allocations - allocations, counter.bytes - bytes, counter.peak_bytes - live, elapsed },
            );
        }
        try conn.execute("COMMIT");
        var result = try conn.query("SELECT * FROM samples");
        defer result.deinit();
        try std.testing.expectEqual(rows, result.rows.items.len);
    }
}
