const std = @import("std");

/// One temporary directory for a standalone test executable.
///
/// The database code under test takes path strings, so tests still pass absolute
/// paths to zqlite. The isolation boundary is this per-run directory, not a
/// hand-maintained list of files under /tmp.
pub const TempDir = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []u8,
    dir: std.Io.Dir,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, prefix: []const u8) !TempDir {
        var cwd = std.Io.Dir.cwd();
        var random_bytes: [12]u8 = undefined;
        var encoded: [std.base64.url_safe.Encoder.calcSize(random_bytes.len)]u8 = undefined;

        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            io.random(&random_bytes);
            _ = std.base64.url_safe.Encoder.encode(&encoded, &random_bytes);

            const path = try std.fmt.allocPrint(allocator, "/tmp/{s}-{s}", .{ prefix, encoded });
            errdefer allocator.free(path);

            cwd.createDir(io, path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(path);
                    continue;
                },
                else => return err,
            };

            const dir = try cwd.openDir(io, path, .{});
            return .{
                .io = io,
                .allocator = allocator,
                .path = path,
                .dir = dir,
            };
        }

        return error.TempDirNameCollision;
    }

    pub fn deinit(self: *TempDir) void {
        self.dir.close(self.io);
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn dbPath(self: *const TempDir, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, name });
    }

    pub fn walPath(self: *const TempDir, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}-wal", .{ self.path, name });
    }
};
