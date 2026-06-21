const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zqlite = b.dependency("zqlite", .{ .target = target, .optimize = optimize });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("zqlite", zqlite.module("zqlite"));

    const run = b.addRunArtifact(tests);
    b.getInstallStep().dependOn(&run.step);
}
