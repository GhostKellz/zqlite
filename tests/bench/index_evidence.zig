const std = @import("std");
const builtin = @import("builtin");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir");

// Count successful allocation requests, independent of allocator caching.
pub const Counter = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,
    bytes: usize = 0,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret) orelse return null;
        self.allocations += 1;
        self.bytes += len;
        self.live_bytes += len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, len, ret)) return false;
        if (len > memory.len) self.bytes += len - memory.len;
        self.live_bytes = self.live_bytes - memory.len + len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, len, ret) orelse return null;
        if (len > memory.len) self.bytes += len - memory.len;
        self.live_bytes = self.live_bytes - memory.len + len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret);
        self.live_bytes -= memory.len;
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var counter = Counter{ .backing = gpa.allocator() };
    const allocator = counter.allocator();
    var dir = try temp_dir.TempDir.init(init.io, allocator, "index-evidence");
    defer dir.deinit();
    for ([_]usize{ 128, 1024 }) |rows| {
        const name = try std.fmt.allocPrint(allocator, "{d}.db", .{rows});
        defer allocator.free(name);
        const path = try dir.dbPath(name);
        defer allocator.free(path);
        {
            const conn = try zqlite.open(allocator, path);
            defer conn.close();
            try conn.execute("CREATE TABLE samples (id INTEGER, bucket INTEGER, payload TEXT)");
            try conn.execute("BEGIN");
            const insert = try conn.prepare("INSERT INTO samples VALUES (?, ?, 'payload')");
            defer insert.deinit();
            for (0..rows) |i| {
                try insert.bind(0, @as(i64, @intCast(i)));
                try insert.bind(1, @as(i64, @intCast(i / 4)));
                var result = try insert.execute();
                result.deinit();
            }
            try conn.execute("COMMIT");
            try conn.execute("CREATE UNIQUE INDEX sample_id ON samples (id)");
            try conn.execute("CREATE INDEX sample_bucket ON samples (bucket)");
            try measure(conn, &counter, rows, "created");
            try conn.execute("ANALYZE");
            try measure(conn, &counter, rows, "analyzed");
        }
        try reportSize(init.io, path, rows, "closed");
        {
            const conn = try zqlite.open(allocator, path);
            defer conn.close();
            try measure(conn, &counter, rows, "reopened");
        }
        try reportSize(init.io, path, rows, "reopened_closed");
    }
}

fn reportSize(io: std.Io, path: []const u8, rows: usize, state: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    std.debug.print("{{\"schema_version\":1,\"metric\":\"database_size\",\"rows\":{d},\"state\":\"{s}\",\"bytes\":{d}}}\n", .{ rows, state, try file.length(io) });
}

fn measure(conn: *zqlite.Connection, counter: *Counter, rows: usize, state: []const u8) !void {
    const queries = [_][]const u8{
        "SELECT payload FROM samples WHERE id = 7",
        "SELECT payload FROM samples WHERE id = ?",
        "SELECT payload FROM samples WHERE bucket = 7",
        "SELECT payload FROM samples WHERE bucket = ?",
    };
    for (queries, 0..) |sql, query_kind| {
        const stmt = try conn.prepare(sql);
        defer stmt.deinit();
        const allocations = counter.allocations;
        const bytes = counter.bytes;
        const live_bytes = counter.live_bytes;
        counter.peak_bytes = live_bytes;
        var scanned: u64 = 0;
        const start = try zqlite.compat.Instant.now();
        for (0..32) |i| {
            if (query_kind % 2 == 1) try stmt.bind(0, @as(i64, @intCast(i % 16)));
            var result = try stmt.execute();
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, if (query_kind < 2) 1 else 4), result.rows.items.len);
            scanned += conn.currentProgressEvent().scanned_rows;
        }
        const elapsed = (try zqlite.compat.Instant.now()).since(start);
        const allocation_count = counter.allocations - allocations;
        const requested_bytes = counter.bytes - bytes;
        const peak_extra_bytes = counter.peak_bytes - live_bytes;
        const plan = if (stmt.execution_plan.steps[0] == .IndexScan) "index" else "table";
        std.debug.print(
            "{{\"schema_version\":1,\"zig\":\"{s}\",\"os\":\"{s}\",\"arch\":\"{s}\",\"optimize\":\"{s}\",\"rows\":{d},\"state\":\"{s}\",\"query_kind\":{d},\"plan\":\"{s}\",\"iterations\":32,\"scanned_rows\":{d},\"allocations\":{d},\"requested_bytes\":{d},\"live_bytes_before\":{d},\"peak_extra_bytes\":{d},\"elapsed_ns\":{d}}}\n",
            .{ builtin.zig_version_string, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), @tagName(builtin.mode), rows, state, query_kind, plan, scanned, allocation_count, requested_bytes, live_bytes, peak_extra_bytes, elapsed },
        );
    }
}
