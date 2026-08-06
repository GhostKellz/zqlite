const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir");

fn fileLength(io: std.Io, path: []const u8) !u64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return file.length(io);
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var directory = try temp_dir.TempDir.init(init.io, allocator, "zqlite-storage-evidence");
    defer directory.deinit();
    const path = try directory.dbPath("metrics.db");
    defer allocator.free(path);

    const connection = try zqlite.open(allocator, path);
    try connection.execute("CREATE TABLE metrics (id INTEGER PRIMARY KEY, value TEXT)");
    const initial_bytes = try fileLength(init.io, path);

    try connection.begin();
    var insert = try connection.prepare("INSERT INTO metrics VALUES (?, ?)");
    defer insert.deinit();
    for (0..500) |i| {
        try insert.bind(0, @as(i64, @intCast(i)));
        try insert.bind(1, @as([]const u8, "storage-evidence-payload"));
        var result = try insert.execute();
        result.deinit();
    }
    const wal_peak = (try connection.getWalStats()).?.size_bytes;
    const live_allocator_bytes = gpa.total_requested_bytes;
    try connection.commit();
    const database_bytes = try fileLength(init.io, path);

    const checkpoint_start = try zqlite.compat.Instant.now();
    try connection.checkpoint();
    const checkpoint_ns = (try zqlite.compat.Instant.now()).since(checkpoint_start);
    const wal_after_checkpoint = (try connection.getWalStats()).?.size_bytes;
    connection.close();

    std.debug.print(
        "{{\"schema_version\":1,\"rows\":500,\"initial_database_bytes\":{d},\"final_database_bytes\":{d},\"growth_bytes\":{d},\"wal_peak_bytes\":{d},\"wal_after_checkpoint_bytes\":{d},\"checkpoint_ns\":{d},\"live_allocator_bytes_during_workload\":{d}}}\n",
        .{ initial_bytes, database_bytes, database_bytes - initial_bytes, wal_peak, wal_after_checkpoint, checkpoint_ns, live_allocator_bytes },
    );
}
