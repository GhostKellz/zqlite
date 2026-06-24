const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend = zqlite.pqc_backend.StdlibPQCBackend.backend;

    var kem = try zqlite.pqc_backend.loadKemKatFixture(
        allocator,
        "generated/ml-kem-768/zqlite-stdlib-001.kat",
        @embedFile("fixtures/pqc/generated/ml-kem-768/zqlite-stdlib-001.kat"),
    );
    defer kem.deinit(allocator);
    try zqlite.pqc_backend.runKemKatFixture(backend, allocator, kem.fixture);

    var sign = try zqlite.pqc_backend.loadSignKatFixture(
        allocator,
        "generated/ml-dsa-65/zqlite-stdlib-001.kat",
        @embedFile("fixtures/pqc/generated/ml-dsa-65/zqlite-stdlib-001.kat"),
    );
    defer sign.deinit(allocator);
    try zqlite.pqc_backend.runSignKatFixture(backend, allocator, sign.fixture);

    std.log.info("=== PQC GENERATED KAT TESTS PASSED ===", .{});
}
