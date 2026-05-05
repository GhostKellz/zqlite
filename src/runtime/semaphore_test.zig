const std = @import("std");
const runtime = @import("root.zig");

test "runtime semaphore waitWithToken cancels blocked waiter" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    defer runtime.shutdownExecutor();
    const allocator = gpa.allocator();

    var semaphore = runtime.Semaphore.init(allocator, 0);
    defer semaphore.deinit();

    const waiter = try runtime.spawnWithTaskContext(allocator, struct {
        fn run(sem: *runtime.Semaphore, ctx: runtime.TaskContext) !void {
            try ctx.checkpoint();
            try sem.waitWithToken(ctx.cancel_token);
        }
    }.run, .{&semaphore});
    defer waiter.deinit();

    runtime.sleep(5);
    waiter.cancel();

    try std.testing.expectError(error.FutureCancelled, waiter.await());
}
