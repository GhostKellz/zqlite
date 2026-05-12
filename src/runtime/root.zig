const std = @import("std");
const notifier_mod = @import("notifier.zig");
const executor_mod = @import("executor.zig");

pub const compat = @import("compat/thread.zig");
pub const Channel = @import("channel.zig").Channel;
pub const bounded = @import("channel.zig").bounded;
pub const boundedWithOptions = @import("channel.zig").boundedWithOptions;
pub const Backpressure = @import("channel.zig").Backpressure;
pub const CancelToken = @import("cancellation.zig").CancelToken;
pub const Semaphore = @import("semaphore.zig").Semaphore;
pub const TaskContext = executor_mod.TaskContext;

pub fn Future(comptime T: type) type {
    return @import("future.zig").Future(T);
}

var executor_init_mutex: compat.Mutex = .{};
var executor_instance: ?*executor_mod.Executor = null;

pub fn yieldNow() void {
    std.Thread.yield() catch {};
}

pub fn sleep(ms: u64) void {
    compat.sleepMillis(ms);
}

fn SpawnPayload(comptime task_fn: anytype) type {
    const return_type = @typeInfo(@TypeOf(task_fn)).@"fn".return_type orelse @compileError("Task must return a value or error union");
    return switch (@typeInfo(return_type)) {
        .error_union => |eu| eu.payload,
        else => return_type,
    };
}

fn getExecutor() !*executor_mod.Executor {
    executor_init_mutex.lock();
    defer executor_init_mutex.unlock();

    if (executor_instance == null) {
        const worker_count = std.Thread.getCpuCount() catch 4;
        const count = @max(@as(usize, 1), worker_count);
        executor_instance = try executor_mod.Executor.create(std.heap.smp_allocator, count);
    }

    return executor_instance.?;
}

pub fn spawn(allocator: std.mem.Allocator, comptime task_fn: anytype, args: anytype) !*Future(SpawnPayload(task_fn)) {
    const Payload = SpawnPayload(task_fn);
    const FutureType = Future(Payload);
    const future = try FutureType.init(allocator);
    errdefer future.deinit();

    try scheduleFuture(allocator, task_fn, args, future);
    return future;
}

fn scheduleFuture(allocator: std.mem.Allocator, comptime task_fn: anytype, args: anytype, future: *Future(SpawnPayload(task_fn))) !void {
    const return_type = @typeInfo(@TypeOf(task_fn)).@"fn".return_type.?;
    const FutureType = @TypeOf(future.*);

    future.markScheduled();

    const Wrapper = struct {
        future: *FutureType,
        allocator: std.mem.Allocator,
        args: @TypeOf(args),

        fn destroy(_: *std.mem.Allocator, payload: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(payload));
            self.allocator.destroy(self);
        }

        fn invoke(self: *@This()) void {
            switch (@typeInfo(return_type)) {
                .error_union => {
                    const result = @call(.auto, task_fn, self.args) catch |err| {
                        if (err == error.Cancelled) {
                            self.future.completeCancelled();
                            return;
                        }
                        self.future.reject(err);
                        return;
                    };
                    self.future.resolve(result);
                },
                else => {
                    self.future.resolve(@call(.auto, task_fn, self.args));
                },
            }
        }

        fn run(payload: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(payload));
            if (self.future.getCancelToken().isCancelled()) {
                self.future.completeCancelled();
                return;
            }
            self.invoke();
        }
    };

    const wrapper = try allocator.create(Wrapper);
    errdefer allocator.destroy(wrapper);
    wrapper.* = .{
        .future = future,
        .allocator = allocator,
        .args = args,
    };

    const executor = try getExecutor();
    try executor.submit(.{
        .run_fn = Wrapper.run,
        .destroy_fn = Wrapper.destroy,
        .payload = wrapper,
    });
}

pub fn spawnWithTaskContext(allocator: std.mem.Allocator, comptime task_fn: anytype, args_without_ctx: anytype) !*Future(SpawnPayload(task_fn)) {
    const Payload = SpawnPayload(task_fn);
    const FutureType = Future(Payload);
    const future = try FutureType.init(allocator);
    errdefer future.deinit();

    try scheduleFuture(allocator, task_fn, args_without_ctx ++ .{TaskContext{ .cancel_token = future.getCancelToken() }}, future);
    return future;
}

pub fn timeout(comptime T: type, future: *Future(T), timeout_ms: u64) !T {
    const start = try compat.Instant.now();
    const deadline = compat.Instant{ .timestamp = start.timestamp + @as(i128, timeout_ms) * std.time.ns_per_ms };

    const result = future.awaitUntil(deadline) catch |err| switch (err) {
        error.Timeout => {
            future.cancel();
            return error.Timeout;
        },
        else => return err,
    };

    return result;
}

pub fn timeoutAll(comptime T: type, allocator: std.mem.Allocator, futures: []*Future(T), timeout_ms: u64) ![]T {
    const start = try compat.Instant.now();
    const deadline = compat.Instant{ .timestamp = start.timestamp + @as(i128, timeout_ms) * std.time.ns_per_ms };
    return allUntil(T, allocator, futures, deadline) catch |err| switch (err) {
        error.Timeout => {
            for (futures) |future| {
                future.cancel();
            }
            return error.Timeout;
        },
        else => return err,
    };
}

pub fn all(comptime T: type, allocator: std.mem.Allocator, futures: []*Future(T)) ![]T {
    return allUntil(T, allocator, futures, null);
}

pub fn allUntil(comptime T: type, allocator: std.mem.Allocator, futures: []*Future(T), maybe_deadline: ?compat.Instant) ![]T {
    if (futures.len == 0) return &[_]T{};

    var notifier: notifier_mod.Notifier = .{};
    for (futures) |future| {
        try future.addWaiter(&notifier);
    }
    defer {
        for (futures) |future| {
            future.removeWaiter(&notifier);
        }
    }

    const results = try allocator.alloc(T, futures.len);
    errdefer allocator.free(results);

    const completed = try allocator.alloc(bool, futures.len);
    defer allocator.free(completed);
    @memset(completed, false);

    var resolved_count: usize = 0;

    while (resolved_count < futures.len) {
        const snapshot = notifier.snapshot();
        var progress = false;

        for (futures, 0..) |future, i| {
            if (completed[i]) continue;

            switch (future.poll()) {
                .ready => {
                    results[i] = try future.await();
                    completed[i] = true;
                    resolved_count += 1;
                    progress = true;
                },
                .cancelled => return error.FutureCancelled,
                .pending => {},
            }
        }

        if (resolved_count == futures.len) break;
        if (progress) continue;

        if (maybe_deadline) |deadline| {
            if (!notifier.waitUntil(snapshot, deadline)) {
                return error.Timeout;
            }
        } else {
            notifier.wait(snapshot);
        }
    }

    return results;
}

pub fn race(comptime T: type, futures: []*Future(T)) !T {
    if (futures.len == 0) return error.NoFutures;

    var notifier: notifier_mod.Notifier = .{};

    for (futures) |future| {
        try future.addWaiter(&notifier);
    }
    defer {
        for (futures) |future| {
            future.removeWaiter(&notifier);
        }
    }

    while (true) {
        const snapshot = notifier.snapshot();
        var cancelled_count: usize = 0;
        for (futures) |future| {
            switch (future.poll()) {
                .ready => return future.await(),
                .cancelled => cancelled_count += 1,
                .pending => {},
            }
        }

        if (cancelled_count == futures.len) {
            return error.FutureCancelled;
        }

        for (futures) |future| {
            if (future.poll() != .pending) {
                break;
            }
        } else {
            notifier.wait(snapshot);
            continue;
        }
    }
}

pub fn executorMetrics() !executor_mod.Metrics {
    const executor = try getExecutor();
    return executor.getMetrics();
}

pub fn shutdownExecutor() void {
    executor_init_mutex.lock();
    defer executor_init_mutex.unlock();

    if (executor_instance) |executor| {
        executor.deinit();
        std.heap.smp_allocator.destroy(executor);
        executor_instance = null;
    }
}

test "runtime allUntil returns timeout and cancels remain pending" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    defer shutdownExecutor();
    const allocator = gpa.allocator();

    const future_a = try Future(u32).init(allocator);
    defer future_a.deinit();
    const future_b = try Future(u32).init(allocator);
    defer future_b.deinit();

    const start = try compat.Instant.now();
    const deadline = compat.Instant{ .timestamp = start.timestamp + 2 * std.time.ns_per_ms };

    var futures = [_]*Future(u32){ future_a, future_b };
    try testing.expectError(error.Timeout, allUntil(u32, allocator, futures[0..], deadline));

    future_a.cancel();
    future_b.cancel();
}

test "runtime race returns cancelled when all futures cancel" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    defer shutdownExecutor();
    const allocator = gpa.allocator();

    const future_a = try Future(u32).init(allocator);
    defer future_a.deinit();
    const future_b = try Future(u32).init(allocator);
    defer future_b.deinit();

    future_a.cancel();
    future_b.cancel();

    var futures = [_]*Future(u32){ future_a, future_b };
    try testing.expectError(error.FutureCancelled, race(u32, futures[0..]));
}

test "runtime timeoutAll cancels pending futures on timeout" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    defer shutdownExecutor();
    const allocator = gpa.allocator();

    const future_a = try Future(u32).init(allocator);
    defer future_a.deinit();
    const future_b = try Future(u32).init(allocator);
    defer future_b.deinit();

    var futures = [_]*Future(u32){ future_a, future_b };
    try testing.expectError(error.Timeout, timeoutAll(u32, allocator, futures[0..], 2));
    try testing.expectEqual(Future(u32).PollResult.cancelled, future_a.poll());
    try testing.expectEqual(Future(u32).PollResult.cancelled, future_b.poll());
}

test "runtime executor metrics reflect submitted work" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch unreachable;
    defer shutdownExecutor();
    const allocator = gpa.allocator();

    const worker = struct {
        fn run(value: u32) u32 {
            return value + 1;
        }
    }.run;

    const future = try spawn(allocator, worker, .{@as(u32, 41)});
    defer future.deinit();
    try testing.expectEqual(@as(u32, 42), try future.await());

    const executor = try getExecutor();
    executor.waitIdle();

    const metrics = try executorMetrics();
    try testing.expect(metrics.worker_count >= 1);
    try testing.expect(metrics.submitted_jobs >= 1);
    try testing.expect(metrics.completed_jobs >= 1);
}
