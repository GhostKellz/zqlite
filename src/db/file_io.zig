const std = @import("std");

pub const File = std.Io.File;
pub const Lock = File.Lock;

pub const OpenMode = enum {
    read_write_create,
    read_only,
};

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn tryLock(file: File, lock_mode: Lock) !bool {
    return file.tryLock(io(), lock_mode);
}

pub fn lock(file: File, lock_mode: Lock) !void {
    try file.lock(io(), lock_mode);
}

pub fn unlock(file: File) void {
    file.unlock(io());
}

pub fn waitForLockRetry() !void {
    try std.Io.sleep(io(), .fromMilliseconds(1), .awake);
}

pub fn open(_: std.mem.Allocator, path: []const u8, mode: OpenMode) !File {
    return switch (mode) {
        .read_write_create => std.Io.Dir.cwd().createFile(io(), path, .{
            .read = true,
            .truncate = false,
        }),
        .read_only => std.Io.Dir.cwd().openFile(io(), path, .{}),
    };
}

pub fn close(file: File) void {
    file.close(io());
}

pub fn size(file: File) !u64 {
    return file.length(io());
}

pub fn stat(file: File) !File.Stat {
    return file.stat(io());
}

pub fn statPath(path: []const u8) !File.Stat {
    const file = try std.Io.Dir.cwd().openFile(io(), path, .{});
    defer file.close(io());
    return file.stat(io());
}

pub fn readAtAll(file: File, buffer: []u8, offset: i64) !usize {
    if (offset < 0) return error.InvalidOffset;
    return file.readPositionalAll(io(), buffer, @intCast(offset));
}

pub fn writeAtAll(file: File, buffer: []const u8, offset: i64) !void {
    if (offset < 0) return error.InvalidOffset;
    try file.writePositionalAll(io(), buffer, @intCast(offset));
}

pub fn sync(file: File) !void {
    try file.sync(io());
}

pub fn truncate(file: File, len: u64) !void {
    try file.setLength(io(), len);
}

pub fn renamePreserve(old_path: []const u8, new_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try std.Io.Dir.renamePreserve(cwd, old_path, cwd, new_path, io());
}

pub fn delete(path: []const u8) !void {
    try std.Io.Dir.cwd().deleteFile(io(), path);
}
