const std = @import("std");
const compat = @import("compat/thread.zig");
const notifier_mod = @import("notifier.zig");

pub const CancelToken = struct {
    cancelled: bool = false,
    mutex: compat.Mutex = .{},
    notifier: notifier_mod.Notifier = .{},
    waiters: std.ArrayListUnmanaged(*notifier_mod.Notifier) = .empty,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn cancel(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cancelled) return;
        self.cancelled = true;
        self.notifier.notify();
        for (self.waiters.items) |waiter| {
            waiter.notify();
        }
    }

    pub fn isCancelled(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancelled;
    }

    pub fn checkpoint(self: *Self) !void {
        if (self.isCancelled()) return error.Cancelled;
    }

    pub fn waitSnapshot(self: *Self) u64 {
        return self.notifier.snapshot();
    }

    pub fn wait(self: *Self, last_seen: u64) void {
        self.notifier.wait(last_seen);
    }

    pub fn waitUntil(self: *Self, last_seen: u64, deadline: compat.Instant) bool {
        return self.notifier.waitUntil(last_seen, deadline);
    }

    pub fn addWaiter(self: *Self, waiter: *notifier_mod.Notifier) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cancelled) {
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

    pub fn deinit(self: *Self) void {
        self.waiters.deinit(self.allocator);
    }
};
