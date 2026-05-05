const std = @import("std");
const compat = @import("compat/thread.zig");
const cancellation = @import("cancellation.zig");
const notifier_mod = @import("notifier.zig");

pub const Backpressure = enum {
    block,
    drop_newest,
};

pub fn Channel(comptime T: type) type {
    return struct {
        buffer: []T,
        capacity: usize,
        head: usize,
        tail: usize,
        size: usize,
        mutex: compat.Mutex,
        not_empty: compat.Condition,
        not_full: compat.Condition,
        notifier: notifier_mod.Notifier,
        waiters: std.ArrayListUnmanaged(*notifier_mod.Notifier),
        closed: bool,
        backpressure: Backpressure,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return initWithOptions(allocator, capacity, .block);
        }

        pub fn initWithOptions(allocator: std.mem.Allocator, capacity: usize, backpressure: Backpressure) !Self {
            if (capacity == 0) return error.InvalidChannelCapacity;

            return .{
                .buffer = try allocator.alloc(T, capacity),
                .capacity = capacity,
                .head = 0,
                .tail = 0,
                .size = 0,
                .mutex = .{},
                .not_empty = .{},
                .not_full = .{},
                .notifier = .{},
                .waiters = .empty,
                .closed = false,
                .backpressure = backpressure,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.waiters.deinit(self.allocator);
            self.allocator.free(self.buffer);
        }

        pub fn send(self: *Self, item: T) !void {
            return self.sendWithToken(item, null);
        }

        pub fn sendUntil(self: *Self, item: T, deadline: compat.Instant, token: ?*cancellation.CancelToken) !void {
            var waiter: notifier_mod.Notifier = .{};
            if (token != null) {
                try self.addWaiter(&waiter);
                defer self.removeWaiter(&waiter);
            }
            if (token) |cancel_token| {
                try cancel_token.addWaiter(&waiter);
                defer cancel_token.removeWaiter(&waiter);
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.size >= self.capacity) {
                if (self.closed) return error.ChannelClosed;
                if (token) |cancel_token| {
                    const snapshot = waiter.snapshot();
                    if (cancel_token.isCancelled()) return error.Cancelled;
                    self.mutex.unlock();
                    const woke = waiter.waitUntil(snapshot, deadline);
                    self.mutex.lock();
                    if (cancel_token.isCancelled()) return error.Cancelled;
                    if (!woke and self.size >= self.capacity) return error.Timeout;
                } else {
                    const now = try compat.Instant.now();
                    if (deadline.order(now) != .gt) return error.Timeout;

                    const remaining_ns = deadline.since(now);
                    if (!self.not_full.waitTimeout(&self.mutex, remaining_ns) and self.size >= self.capacity) {
                        return error.Timeout;
                    }
                }
            }

            if (self.closed) return error.ChannelClosed;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.size += 1;
            self.not_empty.signal();
            self.notifier.notify();
            self.notifyWaitersLocked();
        }

        pub fn sendWithToken(self: *Self, item: T, token: ?*cancellation.CancelToken) !void {
            var waiter: notifier_mod.Notifier = .{};
            if (token != null) {
                try self.addWaiter(&waiter);
                errdefer self.removeWaiter(&waiter);
            }
            if (token) |cancel_token| {
                try cancel_token.addWaiter(&waiter);
                defer cancel_token.removeWaiter(&waiter);
            }
            if (token != null) {
                defer self.removeWaiter(&waiter);
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.size >= self.capacity) {
                if (self.closed) return error.ChannelClosed;
                if (token) |cancel_token| {
                    if (cancel_token.isCancelled()) return error.Cancelled;
                }

                switch (self.backpressure) {
                    .drop_newest => return error.ChannelFull,
                    .block => {
                        if (token) |cancel_token| {
                            const snapshot = waiter.snapshot();
                            if (cancel_token.isCancelled()) return error.Cancelled;
                            self.mutex.unlock();
                            waiter.wait(snapshot);
                            self.mutex.lock();
                            if (cancel_token.isCancelled()) return error.Cancelled;
                        } else {
                            self.not_full.wait(&self.mutex);
                        }
                    },
                }
            }

            if (self.closed) return error.ChannelClosed;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.size += 1;
            self.not_empty.signal();
            self.notifier.notify();
            self.notifyWaitersLocked();
        }

        pub fn trySend(self: *Self, item: T) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.ChannelClosed;
            if (self.size >= self.capacity) return false;

            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.size += 1;
            self.not_empty.signal();
            self.notifier.notify();
            self.notifyWaitersLocked();
            return true;
        }

        pub fn recv(self: *Self) !T {
            return self.recvWithToken(null);
        }

        pub fn recvWithToken(self: *Self, token: ?*cancellation.CancelToken) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.size == 0) {
                if (self.closed) return error.ChannelClosed;
                if (token) |cancel_token| {
                    if (cancel_token.isCancelled()) return error.Cancelled;
                    const now = try compat.Instant.now();
                    const deadline = compat.Instant{ .timestamp = now.timestamp + 2 * std.time.ns_per_ms };
                    if (!self.not_empty.waitTimeout(&self.mutex, deadline.since(now)) and self.size == 0 and cancel_token.isCancelled()) {
                        return error.Cancelled;
                    }
                } else {
                    self.not_empty.wait(&self.mutex);
                }
            }

            return self.recvLocked();
        }

        pub fn recvUntil(self: *Self, deadline: compat.Instant, token: ?*cancellation.CancelToken) !T {
            var waiter: notifier_mod.Notifier = .{};
            if (token != null) {
                try self.addWaiter(&waiter);
                errdefer self.removeWaiter(&waiter);
            }
            if (token) |cancel_token| {
                try cancel_token.addWaiter(&waiter);
                defer cancel_token.removeWaiter(&waiter);
            }
            if (token != null) {
                defer self.removeWaiter(&waiter);
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.size == 0) {
                if (self.closed) return error.ChannelClosed;
                if (token) |cancel_token| {
                    const snapshot = waiter.snapshot();
                    if (cancel_token.isCancelled()) return error.Cancelled;
                    self.mutex.unlock();
                    const woke = waiter.waitUntil(snapshot, deadline);
                    self.mutex.lock();
                    if (cancel_token.isCancelled()) return error.Cancelled;
                    if (!woke and self.size == 0) return error.Timeout;
                } else {
                    const now = try compat.Instant.now();
                    if (deadline.order(now) != .gt) return error.Timeout;

                    const remaining_ns = deadline.since(now);
                    if (!self.not_empty.waitTimeout(&self.mutex, remaining_ns) and self.size == 0) {
                        return error.Timeout;
                    }
                }
            }

            return self.recvLocked();
        }

        pub fn tryRecv(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.size == 0) return null;
            return self.recvLocked();
        }

        fn recvLocked(self: *Self) T {
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.size -= 1;
            self.not_full.signal();
            self.notifier.notify();
            self.notifyWaitersLocked();
            return item;
        }

        pub fn addWaiter(self: *Self, waiter: *notifier_mod.Notifier) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

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

        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.size;
        }

        pub fn isClosed(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.closed;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
            self.notifier.notify();
            self.notifyWaitersLocked();
        }
    };
}

pub fn bounded(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !Channel(T) {
    return Channel(T).init(allocator, capacity);
}

pub fn boundedWithOptions(comptime T: type, allocator: std.mem.Allocator, capacity: usize, backpressure: Backpressure) !Channel(T) {
    return Channel(T).initWithOptions(allocator, capacity, backpressure);
}
