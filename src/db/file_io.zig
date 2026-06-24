const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const native_os = builtin.os.tag;

pub const File = posix.fd_t;

pub const OpenMode = enum {
    read_write_create,
    read_only,
};

pub fn open(allocator: std.mem.Allocator, path: []const u8, mode: OpenMode) !File {
    if (comptime native_os == .windows) return error.Unsupported;

    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    const flags: posix.O = switch (mode) {
        .read_write_create => .{
            .ACCMODE = .RDWR,
            .CREAT = true,
        },
        .read_only => .{
            .ACCMODE = .RDONLY,
        },
    };

    if (comptime native_os == .linux) {
        while (true) {
            const rc = std.os.linux.openat(posix.AT.FDCWD, path_z.ptr, flags, 0o644);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .INVAL => return error.BadPathName,
                .ACCES => return error.AccessDenied,
                .FBIG, .OVERFLOW => return error.FileTooBig,
                .ISDIR => return error.IsDir,
                .LOOP => return error.SymLinkLoop,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NAMETOOLONG => return error.NameTooLong,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NODEV, .NXIO => return error.NoDevice,
                .NOENT, .SRCH => return error.FileNotFound,
                .NOMEM => return error.SystemResources,
                .NOSPC => return error.NoSpaceLeft,
                .NOTDIR => return error.NotDir,
                .PERM => return error.PermissionDenied,
                .EXIST => return error.PathAlreadyExists,
                .BUSY => return error.DeviceBusy,
                .OPNOTSUPP => return error.FileLocksUnsupported,
                .AGAIN => return error.WouldBlock,
                .TXTBSY => return error.FileBusy,
                .ILSEQ => return error.BadPathName,
                .ROFS => return error.ReadOnlyFileSystem,
                else => return error.Unexpected,
            }
        }
    }

    return posix.openat(posix.AT.FDCWD, path_z, flags, 0o644);
}

pub fn close(file: File) void {
    std.Io.Threaded.closeFd(file);
}

pub fn size(file: File) !u64 {
    const SEEK_END = 2;
    const SEEK_SET = 0;

    if (comptime native_os == .windows) {
        return error.Unsupported;
    } else if (comptime native_os == .linux) {
        const end_rc = std.os.linux.lseek(file, 0, SEEK_END);
        if (@as(isize, @bitCast(end_rc)) < 0) return error.SeekError;
        const start_rc = std.os.linux.lseek(file, 0, SEEK_SET);
        if (@as(isize, @bitCast(start_rc)) < 0) return error.SeekError;
        return end_rc;
    } else {
        const end_rc = std.c.lseek(file, 0, SEEK_END);
        if (end_rc < 0) return error.SeekError;
        _ = std.c.lseek(file, 0, SEEK_SET);
        return @intCast(end_rc);
    }
}

pub fn readAtAll(file: File, buf: []u8, offset: i64) !usize {
    var total_read: usize = 0;
    while (total_read < buf.len) {
        const current_offset = offset + @as(i64, @intCast(total_read));
        const remaining = buf.len - total_read;

        const bytes_read: usize = blk: {
            if (comptime native_os == .windows) {
                return error.Unsupported;
            } else if (comptime native_os == .linux) {
                const rc = std.os.linux.pread(file, buf.ptr + total_read, remaining, current_offset);
                const signed_rc = @as(isize, @bitCast(rc));
                if (signed_rc < 0) {
                    const errno: usize = @bitCast(-signed_rc);
                    if (errno == 4) continue; // EINTR
                    return error.ReadError;
                }
                break :blk @bitCast(signed_rc);
            } else {
                const rc = std.c.pread(file, buf.ptr + total_read, remaining, current_offset);
                if (rc < 0) {
                    if (std.c._errno().* == 4) continue; // EINTR
                    return error.ReadError;
                }
                break :blk @intCast(rc);
            }
        };

        if (bytes_read == 0) break;
        total_read += bytes_read;
    }
    return total_read;
}

pub fn writeAtAll(file: File, buf: []const u8, offset: i64) !void {
    var total_written: usize = 0;
    while (total_written < buf.len) {
        const current_offset = offset + @as(i64, @intCast(total_written));
        const remaining = buf.len - total_written;

        const bytes_written: usize = blk: {
            if (comptime native_os == .windows) {
                return error.Unsupported;
            } else if (comptime native_os == .linux) {
                const rc = std.os.linux.pwrite(file, buf.ptr + total_written, remaining, current_offset);
                const signed_rc = @as(isize, @bitCast(rc));
                if (signed_rc < 0) {
                    const errno: usize = @bitCast(-signed_rc);
                    if (errno == 4) continue; // EINTR
                    return error.WriteError;
                }
                break :blk @bitCast(signed_rc);
            } else {
                const rc = std.c.pwrite(file, buf.ptr + total_written, remaining, current_offset);
                if (rc < 0) {
                    if (std.c._errno().* == 4) continue; // EINTR
                    return error.WriteError;
                }
                break :blk @intCast(rc);
            }
        };

        if (bytes_written == 0) return error.WriteError;
        total_written += bytes_written;
    }
}

pub fn sync(file: File) !void {
    try posix.fdatasync(file);
}

pub fn truncate(file: File, len: u64) !void {
    if (comptime native_os == .windows) {
        return error.Unsupported;
    } else if (comptime native_os == .linux) {
        const rc = std.os.linux.ftruncate(file, @intCast(len));
        if (std.os.linux.errno(rc) != .SUCCESS) return error.TruncateError;
    } else {
        if (std.c.ftruncate(file, @intCast(len)) != 0) return error.TruncateError;
    }
}
