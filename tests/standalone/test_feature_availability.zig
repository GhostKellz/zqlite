const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (zqlite.features.performance) {
        const cache = try zqlite.createQueryCache(allocator, 8, 4096);
        defer cache.deinit();
    } else {
        try std.testing.expectError(error.FeatureUnavailable, zqlite.createQueryCache(allocator, 8, 4096));
        try std.testing.expectEqual(zqlite.ErrorCategory.misuse, zqlite.categorizeError(error.FeatureUnavailable));
    }

    std.log.info("=== FEATURE AVAILABILITY TESTS PASSED ===", .{});
}
