const std = @import("std");
const compat = @import("compat/thread.zig");
const cancellation = @import("cancellation.zig");
const notifier_mod = @import("notifier.zig");

pub const Semaphore = struct {
    permits: u32,
    mutex: compat.Mutex = .{},
    condition: compat.Condition = .{},
    notifier: notifier_mod.Notifier = .{},
    waiters: std.ArrayListUnmanaged(*notifier_mod.Notifier) = .empty,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, permits: u32) Self {
        return .{ .permits = permits, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.waiters.deinit(self.allocator);
    }

    pub fn post(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.permits += 1;
        self.condition.signal();
        self.notifier.notify();
        self.notifyWaitersLocked();
    }

    pub fn wait(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.permits == 0) {
            self.condition.wait(&self.mutex);
        }

        self.permits -= 1;
    }

    pub fn waitWithToken(self: *Self, token: ?*cancellation.CancelToken) !void {
        if (token == null) {
            self.wait();
            return;
        }

        var waiter: notifier_mod.Notifier = .{};
        const cancel_token = token.?;
        try self.addWaiter(&waiter);
        errdefer self.removeWaiter(&waiter);
        try cancel_token.addWaiter(&waiter);
        defer cancel_token.removeWaiter(&waiter);
        defer self.removeWaiter(&waiter);

        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.permits == 0) {
            const snapshot = waiter.snapshot();
            if (cancel_token.isCancelled()) return error.Cancelled;
            self.mutex.unlock();
            waiter.wait(snapshot);
            self.mutex.lock();
            if (cancel_token.isCancelled()) return error.Cancelled;
        }

        self.permits -= 1;
    }

    fn addWaiter(self: *Self, waiter: *notifier_mod.Notifier) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.waiters.items) |existing| {
            if (existing == waiter) return;
        }

        try self.waiters.append(self.allocator, waiter);
    }

    fn removeWaiter(self: *Self, waiter: *notifier_mod.Notifier) void {
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
};
