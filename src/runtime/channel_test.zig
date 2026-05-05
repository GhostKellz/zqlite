const std = @import("std");
const runtime = @import("root.zig");

test "runtime channel sendUntil times out on full channel" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    defer runtime.shutdownExecutor();
    const allocator = gpa.allocator();

    var channel = try runtime.bounded(u32, allocator, 1);
    defer channel.deinit();

    try channel.send(1);

    const start = try runtime.compat.Instant.now();
    const deadline = runtime.compat.Instant{ .timestamp = start.timestamp + 2 * std.time.ns_per_ms };
    try std.testing.expectError(error.Timeout, channel.sendUntil(2, deadline, null));
}

test "runtime channel recvWithToken cancels blocked receiver" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    defer runtime.shutdownExecutor();
    const allocator = gpa.allocator();

    var channel = try runtime.bounded(u32, allocator, 1);
    defer channel.deinit();

    const token = try allocator.create(runtime.CancelToken);
    defer {
        token.deinit();
        allocator.destroy(token);
    }
    token.* = runtime.CancelToken.init(allocator);

    const receiver = try runtime.spawnWithTaskContext(allocator, struct {
        fn run(ch: *runtime.Channel(u32), cancel_token: *runtime.CancelToken, ctx: runtime.TaskContext) !u32 {
            try ctx.checkpoint();
            return try ch.recvWithToken(cancel_token);
        }
    }.run, .{ &channel, token });
    defer receiver.deinit();

    runtime.sleep(5);
    token.cancel();

    try std.testing.expectError(error.FutureCancelled, receiver.await());
}
