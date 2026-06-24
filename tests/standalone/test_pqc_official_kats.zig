const std = @import("std");
const zqlite = @import("zqlite");

const suites = [_]Suite{
    .{ .name = "ml-kem-768", .kind = .kem },
    .{ .name = "ml-dsa-65", .kind = .sign },
};

const Suite = struct {
    name: []const u8,
    kind: enum { kem, sign },
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend = zqlite.pqc_backend.StdlibPQCBackend.backend;
    var total: usize = 0;
    var skipped: usize = 0;

    for (suites) |suite| {
        const count = try runSuite(init.io, allocator, backend, suite);
        if (count == 0) {
            skipped += 1;
            std.log.info("[SKIP] no official {s} KAT files imported", .{suite.name});
        }
        total += count;
    }

    if (total == 0) {
        std.log.info("=== PQC OFFICIAL KAT TESTS SKIPPED: no imported official vectors ({d} suites pending) ===", .{skipped});
    } else {
        std.log.info("=== PQC OFFICIAL KAT TESTS PASSED: {d} vector files ===", .{total});
    }
}

fn runSuite(io: std.Io, allocator: std.mem.Allocator, backend: zqlite.pqc_backend.PQCBackend, suite: Suite) !usize {
    var cwd = std.Io.Dir.cwd();
    const dir_path = try std.fmt.allocPrint(allocator, "tests/standalone/fixtures/pqc/official/{s}", .{suite.name});
    defer allocator.free(dir_path);

    var dir = cwd.openDir(io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".kat")) continue;

        const data = try dir.readFileAlloc(io, entry.name, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(data);

        switch (suite.kind) {
            .kem => {
                var fixture = try zqlite.pqc_backend.loadKemKatFixture(allocator, entry.name, data);
                defer fixture.deinit(allocator);
                try zqlite.pqc_backend.runKemKatFixture(backend, allocator, fixture.fixture);
            },
            .sign => {
                var fixture = try zqlite.pqc_backend.loadSignKatFixture(allocator, entry.name, data);
                defer fixture.deinit(allocator);
                try zqlite.pqc_backend.runSignKatFixture(backend, allocator, fixture.fixture);
            },
        }

        count += 1;
        std.log.info("[PASS] official {s} KAT {s}", .{ suite.name, entry.name });
    }
    return count;
}
