//! Compatibility layer for Zig 0.16 API removals (blocking mutex/condition and time helpers)

const std = @import("std");
const builtin = @import("builtin");

/// Compatibility shim for std.time.Instant which was removed in Zig 0.16
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
                _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
                return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            },
            .macos, .ios, .tvos, .watchos, .visionos => {
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
                return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            },
            .windows => {
                var counter: i64 = undefined;
                var freq: i64 = undefined;
                _ = std.os.windows.kernel32.QueryPerformanceCounter(&counter);
                _ = std.os.windows.kernel32.QueryPerformanceFrequency(&freq);
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

/// Compatibility shim for std.posix.CLOCK which was removed in Zig 0.16
pub const CLOCK = struct {
    pub const REALTIME = std.os.linux.CLOCK.REALTIME;
    pub const MONOTONIC = std.os.linux.CLOCK.MONOTONIC;
};

/// Compatibility shim for timespec
pub const timespec = std.os.linux.timespec;

/// Compatibility shim for std.posix.clock_gettime which was removed in Zig 0.16
pub fn clock_gettime(clock_id: std.os.linux.CLOCK) error{}!timespec {
    var ts: timespec = undefined;
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.clock_gettime(clock_id, &ts);
        },
        else => {
            ts = .{ .sec = 0, .nsec = 0 };
        },
    }
    return ts;
}

/// A blocking mutex compatible with the old std.Thread.Mutex API
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

/// A blocking condition variable compatible with the old std.Thread.Condition API
pub const Condition = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const seq = self.state.load(.monotonic);
        mutex.unlock();
        futexWait(&self.state.raw, seq);
        mutex.lock();
    }

    pub fn signal(self: *Condition) void {
        _ = self.state.fetchAdd(1, .release);
        futexWake(&self.state.raw, 1);
    }

    pub fn broadcast(self: *Condition) void {
        _ = self.state.fetchAdd(1, .release);
        futexWake(&self.state.raw, std.math.maxInt(u32));
    }
};

fn futexWait(ptr: *const u32, expected: u32) void {
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.futex_4arg(
                @ptrCast(ptr),
                .{ .cmd = .WAIT, .private = true },
                expected,
                null,
            );
        },
        .windows => {
            std.os.windows.kernel32.WaitOnAddress(
                @ptrCast(ptr),
                @ptrCast(&expected),
                @sizeOf(u32),
                std.os.windows.INFINITE,
            );
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            _ = std.c.__ulock_wait(
                std.c.UL_COMPARE_AND_WAIT | std.c.ULF_NO_ERRNO,
                @ptrCast(@constCast(ptr)),
                expected,
                0,
            );
        },
        else => {
            while (@atomicLoad(u32, ptr, .monotonic) == expected) {
                std.atomic.spinLoopHint();
            }
        },
    }
}

fn futexWake(ptr: *const u32, max_waiters: u32) void {
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.futex_3arg(
                @ptrCast(ptr),
                .{ .cmd = .WAKE, .private = true },
                max_waiters,
            );
        },
        .windows => {
            if (max_waiters == 1) {
                std.os.windows.kernel32.WakeByAddressSingle(@ptrCast(@constCast(ptr)));
            } else {
                std.os.windows.kernel32.WakeByAddressAll(@ptrCast(@constCast(ptr)));
            }
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            _ = std.c.__ulock_wake(
                std.c.UL_COMPARE_AND_WAIT | std.c.ULF_NO_ERRNO,
                @ptrCast(@constCast(ptr)),
                max_waiters,
            );
        },
        else => {},
    }
}
