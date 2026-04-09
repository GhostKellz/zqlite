const std = @import("std");

/// ZQLite version information - automatically generated from build.zig.zon
pub const MAJOR = 1;
pub const MINOR = 6;
pub const PATCH = 0;

/// Version string in format "1.3.0"
pub const VERSION_STRING = std.fmt.comptimePrint("{}.{}.{}", .{ MAJOR, MINOR, PATCH });

/// Version string with 'v' prefix: "v1.3.0"
pub const VERSION_STRING_PREFIXED = "v" ++ VERSION_STRING;

/// Full version display name
pub const FULL_VERSION_STRING = "ZQLite v" ++ VERSION_STRING;

/// Build metadata (injected by build system)
pub const BUILD_OPTIONS = @import("build_options");
pub const BUILD_COMMIT = BUILD_OPTIONS.git_commit;
pub const BUILD_DATE = BUILD_OPTIONS.build_date;
pub const BUILD_MODE = BUILD_OPTIONS.build_mode;

/// Full version with build metadata
pub const FULL_VERSION_WITH_BUILD = FULL_VERSION_STRING ++ " (commit: " ++ BUILD_COMMIT ++ ", mode: " ++ BUILD_MODE ++ ")";

/// Version info for demos and examples
pub const DEMO_HEADER = FULL_VERSION_STRING ++ " - Zig-native embedded database and query engine";

/// Get version as a single number for comparisons: 1.3.0 = 1003000
pub fn getVersionNumber() u32 {
    return (MAJOR * 1000000) + (MINOR * 1000) + PATCH;
}

/// Check if this version is at least the given version
pub fn isAtLeast(major: u32, minor: u32, patch: u32) bool {
    const current = getVersionNumber();
    const target = (major * 1000000) + (minor * 1000) + patch;
    return current >= target;
}

test "version functions" {
    const testing = std.testing;

    try testing.expectEqualStrings("1.6.0", VERSION_STRING);
    try testing.expectEqualStrings("v1.6.0", VERSION_STRING_PREFIXED);
    try testing.expectEqualStrings("ZQLite v1.6.0", FULL_VERSION_STRING);

    try testing.expect(getVersionNumber() == 1006000);
    try testing.expect(isAtLeast(1, 2, 0));
    try testing.expect(isAtLeast(1, 6, 0));
    try testing.expect(!isAtLeast(2, 0, 0));
}
