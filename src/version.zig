const std = @import("std");

/// Build metadata (injected by build system)
pub const BUILD_OPTIONS = @import("build_options");
pub const VERSION_STRING = BUILD_OPTIONS.version;
pub const VERSION_STRING_Z = VERSION_STRING ++ "\x00";
pub const VERSION_STRING_PREFIXED = "v" ++ VERSION_STRING;
pub const FULL_VERSION_STRING = "ZQLite v" ++ VERSION_STRING;

fn parseVersionPart(comptime part_index: usize) u32 {
    var iter = std.mem.splitScalar(u8, VERSION_STRING, '.');
    var index: usize = 0;
    while (iter.next()) |part| : (index += 1) {
        if (index == part_index) return std.fmt.parseInt(u32, part, 10) catch 0;
    }
    return 0;
}

pub const MAJOR = parseVersionPart(0);
pub const MINOR = parseVersionPart(1);
pub const PATCH = parseVersionPart(2);
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

    try testing.expectEqualStrings("1.6.4", VERSION_STRING);
    try testing.expectEqualStrings("v1.6.4", VERSION_STRING_PREFIXED);
    try testing.expectEqualStrings("ZQLite v1.6.4", FULL_VERSION_STRING);

    try testing.expect(getVersionNumber() == 1006004);
    try testing.expect(isAtLeast(1, 2, 0));
    try testing.expect(isAtLeast(1, 6, 0));
    try testing.expect(isAtLeast(1, 6, 4));
    try testing.expect(!isAtLeast(2, 0, 0));
}
