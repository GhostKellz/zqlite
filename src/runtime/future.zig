const std = @import("std");
const compat = @import("compat/thread.zig");
const cancellation = @import("cancellation.zig");
const notifier_mod = @import("notifier.zig");

pub fn Future(comptime T: type) type {
    return struct {
        state: std.atomic.Value(State),
        result: ?Result,
        mutex: compat.Mutex,
        condition: compat.Condition,
        notifier: notifier_mod.Notifier,
        waiters: std.ArrayListUnmanaged(*notifier_mod.Notifier),
        cancel_token: *cancellation.CancelToken,
        allocator: std.mem.Allocator,

        const Self = @This();

        const State = enum(u8) {
            pending,
            ready,
            cancelled,
        };

        const Result = union(enum) {
            ok: T,
            err: anyerror,
        };

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const token = try allocator.create(cancellation.CancelToken);
            errdefer allocator.destroy(token);
            token.* = cancellation.CancelToken.init(allocator);

            const self = try allocator.create(Self);
            self.* = .{
                .state = std.atomic.Value(State).init(.pending),
                .result = null,
                .mutex = .{},
                .condition = .{},
                .notifier = .{},
                .waiters = .empty,
                .cancel_token = token,
                .allocator = allocator,
            };
            return self;
        }

        pub fn await(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.state.load(.acquire) == .pending) {
                self.condition.wait(&self.mutex);
            }

            return self.readLocked();
        }

        pub fn awaitUntil(self: *Self, deadline: compat.Instant) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.state.load(.acquire) == .pending) {
                const now = try compat.Instant.now();
                if (deadline.order(now) != .gt) {
                    return error.Timeout;
                }

                const remaining_ns = deadline.since(now);
                if (!self.condition.waitTimeout(&self.mutex, remaining_ns) and self.state.load(.acquire) == .pending) {
                    return error.Timeout;
                }
            }

            return self.readLocked();
        }

        pub fn poll(self: *Self) PollResult {
            return switch (self.state.load(.acquire)) {
                .pending => .pending,
                .ready => .ready,
                .cancelled => .cancelled,
            };
        }

        pub fn resolve(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .pending) return;

            self.result = .{ .ok = value };
            self.state.store(.ready, .release);
            self.condition.broadcast();
            self.notifier.notify();
            self.notifyWaitersLocked();
        }

        pub fn reject(self: *Self, err: anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .pending) return;

            self.result = .{ .err = err };
            self.state.store(.ready, .release);
            self.condition.broadcast();
            self.notifier.notify();
            self.notifyWaitersLocked();
        }

        pub fn cancel(self: *Self) void {
            self.cancel_token.cancel();

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .pending) return;

            self.state.store(.cancelled, .release);
            self.condition.broadcast();
            self.notifier.notify();
            self.notifyWaitersLocked();
        }

        pub fn getCancelToken(self: *Self) *cancellation.CancelToken {
            return self.cancel_token;
        }

        pub fn waitSnapshot(self: *Self) u64 {
            return self.notifier.snapshot();
        }

        pub fn waitForChange(self: *Self, last_seen: u64) void {
            self.notifier.wait(last_seen);
        }

        pub fn waitForChangeUntil(self: *Self, last_seen: u64, deadline: compat.Instant) bool {
            return self.notifier.waitUntil(last_seen, deadline);
        }

        pub fn addWaiter(self: *Self, waiter: *notifier_mod.Notifier) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .pending) {
                waiter.notify();
                return;
            }

            for (self.waiters.items) |existing| {
                if (existing == waiter) return;
            }

            try self.waiters.append(self.allocator, waiter);
        }

        pub fn removeWaiter(self: *Self, waiter: *notifier_mod.Notifier) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.waiters.items, 0..) |existing, i| {
                if (existing == waiter) {
                    const removed = self.waiters.swapRemove(i);
                    std.debug.assert(removed == waiter);
                    return;
                }
            }
        }

        fn notifyWaitersLocked(self: *Self) void {
            for (self.waiters.items) |waiter| {
                waiter.notify();
            }
        }

        fn readLocked(self: *Self) !T {
            const current_state = self.state.load(.acquire);
            if (current_state == .cancelled) {
                return error.FutureCancelled;
            }

            if (self.result) |result| {
                return switch (result) {
                    .ok => |value| value,
                    .err => |err| err,
                };
            }

            return error.FutureNotResolved;
        }

        pub fn deinit(self: *Self) void {
            self.waiters.deinit(self.allocator);
            self.cancel_token.deinit();
            self.allocator.destroy(self.cancel_token);
            self.allocator.destroy(self);
        }

        pub const PollResult = enum {
            pending,
            ready,
            cancelled,
        };
    };
}
