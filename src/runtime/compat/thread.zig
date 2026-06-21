//! Compatibility layer for std.Thread.Mutex, std.Thread.Condition, and std.time.Instant.
//! Owned by zqlite to avoid external runtime coupling.

const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.c) windows.BOOL;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.c) windows.BOOL;
const windows = std.os.windows;
const windows_infinite: u32 = 0xffff_ffff;

pub const Instant = struct {
    timestamp: i128,

    pub fn now() error{}!Instant {
        return .{ .timestamp = getMonotonicNanos() };
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        const diff = self.timestamp - earlier.timestamp;
        return if (diff < 0) 0 else @intCast(diff);
    }

    pub fn order(self: Instant, other: Instant) std.math.Order {
        return std.math.order(self.timestamp, other.timestamp);
    }

    fn getMonotonicNanos() i128 {
        switch (builtin.os.tag) {
            .linux => {
                var ts: std.os.linux.timespec = undefined;
                const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
                if (std.os.linux.errno(rc) != .SUCCESS) return 0;
                return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            },
            .macos, .ios, .tvos, .watchos, .visionos => {
                var ts: std.c.timespec = undefined;
                if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
                return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            },
            .windows => {
                var counter: i64 = undefined;
                var freq: i64 = undefined;
                if (QueryPerformanceCounter(&counter) == 0) return 0;
                if (QueryPerformanceFrequency(&freq) == 0 or freq == 0) return 0;
                return @divFloor(@as(i128, counter) * std.time.ns_per_s, freq);
            },
            else => {
                return 0;
            },
        }
    }
};

pub fn instantDiff(a: Instant, b: Instant) u64 {
    return a.since(b);
}

pub const CLOCK = struct {
    pub const REALTIME = std.os.linux.CLOCK.REALTIME;
    pub const MONOTONIC = std.os.linux.CLOCK.MONOTONIC;
};

pub const timespec = std.os.linux.timespec;

pub fn clock_gettime(clock_id: std.os.linux.CLOCK) error{}!timespec {
    var ts: timespec = undefined;
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.clock_gettime(clock_id, &ts);
            if (std.os.linux.errno(rc) != .SUCCESS) {
                ts = .{ .sec = 0, .nsec = 0 };
            }
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            var c_ts: std.c.timespec = undefined;
            const c_clock: std.c.CLOCK = switch (clock_id) {
                .REALTIME => .REALTIME,
                .MONOTONIC => .MONOTONIC,
                else => .REALTIME,
            };
            if (std.c.clock_gettime(c_clock, &c_ts) != 0) {
                ts = .{ .sec = 0, .nsec = 0 };
            } else {
                ts = .{ .sec = c_ts.sec, .nsec = c_ts.nsec };
            }
        },
        else => {
            ts = .{ .sec = 0, .nsec = 0 };
        },
    }
    return ts;
}

pub fn sleepNanos(ns: u64) void {
    switch (builtin.os.tag) {
        .linux => {
            var ts = std.os.linux.timespec{
                .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
                .nsec = @intCast(@rem(ns, std.time.ns_per_s)),
            };
            while (true) {
                const rc = std.os.linux.nanosleep(&ts, &ts);
                switch (std.os.linux.errno(rc)) {
                    .SUCCESS => break,
                    .INTR => continue,
                    else => break,
                }
            }
        },
        .freestanding, .wasi => {
            var i: u64 = 0;
            const spins = @max(1, @divTrunc(ns, 1_000));
            while (i < spins) : (i += 1) {
                std.atomic.spinLoopHint();
            }
        },
        else => {
            var i: u64 = 0;
            const spins = @max(1, @divTrunc(ns, 1_000));
            while (i < spins) : (i += 1) {
                std.atomic.spinLoopHint();
            }
        },
    }
}

pub fn sleepMillis(ms: u64) void {
    sleepNanos(ms * std.time.ns_per_ms);
}

pub const Mutex = struct {
    state: std.atomic.Value(State) = .init(.unlocked),

    const State = enum(u32) {
        unlocked = 0,
        locked = 1,
        contended = 2,
    };

    pub fn lock(self: *Mutex) void {
        if (self.state.cmpxchgWeak(.unlocked, .locked, .acquire, .monotonic) == null) {
            return;
        }
        self.lockSlow();
    }

    fn lockSlow(self: *Mutex) void {
        var spin: u8 = 0;
        while (spin < 100) : (spin += 1) {
            if (self.state.load(.monotonic) == .unlocked) {
                if (self.state.cmpxchgWeak(.unlocked, .locked, .acquire, .monotonic) == null) {
                    return;
                }
            }
            std.atomic.spinLoopHint();
        }

        while (self.state.swap(.contended, .acquire) != .unlocked) {
            futexWait(@ptrCast(&self.state.raw), @intFromEnum(State.contended));
        }
    }

    pub fn unlock(self: *Mutex) void {
        const prev = self.state.swap(.unlocked, .release);
        std.debug.assert(prev != .unlocked);
        if (prev == .contended) {
            futexWake(@ptrCast(&self.state.raw), 1);
        }
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgWeak(.unlocked, .locked, .acquire, .monotonic) == null;
    }
};

pub const Condition = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const seq = self.state.load(.monotonic);
        mutex.unlock();
        futexWait(&self.state.raw, seq);
        mutex.lock();
    }

    pub fn waitTimeout(self: *Condition, mutex: *Mutex, timeout_ns: u64) bool {
        if (timeout_ns == 0) return false;

        const seq = self.state.load(.monotonic);
        mutex.unlock();
        const notified = futexWaitTimeout(&self.state.raw, seq, timeout_ns);
        mutex.lock();
        return notified or self.state.load(.acquire) != seq;
    }

    pub fn signal(self: *Condition) void {
        const previous = self.state.fetchAdd(1, .release);
        std.debug.assert(previous != std.math.maxInt(u32));
        futexWake(&self.state.raw, 1);
    }

    pub fn broadcast(self: *Condition) void {
        const previous = self.state.fetchAdd(1, .release);
        std.debug.assert(previous != std.math.maxInt(u32));
        futexWake(&self.state.raw, @intCast(std.math.maxInt(i32)));
    }
};

fn futexWait(ptr: *const u32, expected: u32) void {
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.futex_4arg(
                @ptrCast(ptr),
                .{ .cmd = .WAIT, .private = true },
                expected,
                null,
            );
            switch (std.os.linux.errno(rc)) {
                .SUCCESS, .INTR, .AGAIN => {},
                else => {},
            }
        },
        .windows => {
            while (@atomicLoad(u32, ptr, .monotonic) == expected) {
                std.atomic.spinLoopHint();
            }
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            const status = std.c.__ulock_wait(
                .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true },
                @ptrCast(@constCast(ptr)),
                expected,
                0,
            );
            if (status < 0) return;
        },
        else => {
            while (@atomicLoad(u32, ptr, .monotonic) == expected) {
                std.atomic.spinLoopHint();
            }
        },
    }
}

fn futexWaitTimeout(ptr: *const u32, expected: u32, timeout_ns: u64) bool {
    switch (builtin.os.tag) {
        .linux => {
            var ts = std.os.linux.timespec{
                .sec = @intCast(@divTrunc(timeout_ns, std.time.ns_per_s)),
                .nsec = @intCast(@rem(timeout_ns, std.time.ns_per_s)),
            };
            switch (std.os.linux.errno(std.os.linux.futex_4arg(
                @ptrCast(ptr),
                .{ .cmd = .WAIT, .private = true },
                expected,
                &ts,
            ))) {
                .SUCCESS, .INTR, .AGAIN => return true,
                .TIMEDOUT => return false,
                else => return false,
            }
        },
        .windows => {
            var remaining = timeout_ns;
            const slice = 250 * std.time.ns_per_us;
            while (@atomicLoad(u32, ptr, .monotonic) == expected and remaining > 0) {
                const current = @min(remaining, slice);
                sleepNanos(current);
                remaining -= current;
            }
            return @atomicLoad(u32, ptr, .monotonic) != expected;
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            const status = std.c.__ulock_wait2(
                .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true },
                @ptrCast(@constCast(ptr)),
                expected,
                if (timeout_ns == 0) 1 else timeout_ns,
                0,
            );
            return status >= 0;
        },
        else => {
            var remaining = timeout_ns;
            const slice = 250 * std.time.ns_per_us;
            while (@atomicLoad(u32, ptr, .monotonic) == expected and remaining > 0) {
                const current = @min(remaining, slice);
                sleepNanos(current);
                remaining -= current;
            }
            return @atomicLoad(u32, ptr, .monotonic) != expected;
        },
    }
}

fn futexWake(ptr: *const u32, max_waiters: u32) void {
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.futex_3arg(
                @ptrCast(ptr),
                .{ .cmd = .WAKE, .private = true },
                max_waiters,
            );
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                else => {},
            }
        },
        .windows => {},
        .macos, .ios, .tvos, .watchos, .visionos => {
            const flags: std.c.UL = .{
                .op = .COMPARE_AND_WAIT,
                .NO_ERRNO = true,
                .WAKE_ALL = max_waiters > 1,
            };
            const status = std.c.__ulock_wake(flags, @ptrCast(@constCast(ptr)), 0);
            if (status < 0) return;
        },
        else => {},
    }
}
