const compat = @import("compat/thread.zig");

pub const Notifier = struct {
    mutex: compat.Mutex = .{},
    condition: compat.Condition = .{},
    sequence: u64 = 0,

    const Self = @This();

    pub fn snapshot(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sequence;
    }

    pub fn notify(self: *Self) void {
        self.mutex.lock();
        self.sequence += 1;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    pub fn wait(self: *Self, last_seen: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.sequence == last_seen) {
            self.condition.wait(&self.mutex);
        }
    }

    pub fn waitUntil(self: *Self, last_seen: u64, deadline: compat.Instant) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.sequence == last_seen) {
            const now = compat.Instant.now() catch return false;
            if (deadline.order(now) != .gt) {
                return false;
            }

            const remaining_ns = deadline.since(now);
            if (!self.condition.waitTimeout(&self.mutex, remaining_ns) and self.sequence == last_seen) {
                return false;
            }
        }

        return true;
    }
};
