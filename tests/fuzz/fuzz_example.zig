const std = @import("std");

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), smith: *std.testing.Smith) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            var buf: [64]u8 = undefined;
            const len = smith.slice(&buf);
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", buf[0..len]));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
