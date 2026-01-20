const std = @import("std");

/// Get current timestamp in nanoseconds since epoch
/// Returns 0 on error (fallback for systems where clock_gettime fails)
pub fn getTimestampNanos() i128 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
        return 0;
    };
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Get current timestamp in milliseconds since epoch
pub fn getTimestampMillis() i64 {
    const nanos = getTimestampNanos();
    return @intCast(@divTrunc(nanos, std.time.ns_per_ms));
}

/// Get current timestamp in seconds since epoch
pub fn getTimestampSecs() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
        return 0;
    };
    return ts.sec;
}

/// Get timespec struct directly (for code that needs both sec and nsec)
/// Returns zero timespec on error
pub fn getTimespec() std.posix.timespec {
    return std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
        return std.posix.timespec{ .sec = 0, .nsec = 0 };
    };
}

/// Compute elapsed time in nanoseconds between two timestamps
pub fn elapsedNanos(start: i128, end: i128) i128 {
    return end - start;
}

/// Compute elapsed time in milliseconds between two timestamps
pub fn elapsedMillis(start: i128, end: i128) i64 {
    return @intCast(@divTrunc(end - start, std.time.ns_per_ms));
}

/// Convert timespec to nanoseconds
pub fn timespecToNanos(ts: std.posix.timespec) i128 {
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
