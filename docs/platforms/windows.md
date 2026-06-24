# Windows Fallback Implementation Plan

Current status: Windows is gated with `error.Unsupported` in WAL and pager I/O paths. This document outlines the work needed to implement Windows fallback support.

## Files Requiring Changes

### src/db/wal.zig
- `getFdSize()` - uses `std.os.linux.lseek` / `std.c.lseek`
- `preadAll()` - uses `std.os.linux.pread` / `std.c.pread`
- `pwriteAll()` - uses `std.os.linux.pwrite` / `std.c.pwrite`
- `truncateFile()` - uses `std.os.linux.ftruncate` / `std.c.ftruncate`
- `init()` - uses `posix.openat` for file creation

### src/db/pager.zig
- `getFileSize()` - uses `std.os.linux.lseek`
- File open uses `posix.openat`
- Page read/write uses POSIX file descriptors

## Implementation Plan

### Option A: std.fs.File API (Recommended)
Replace raw file descriptors with `std.fs.File` which abstracts platform differences:

```zig
// Instead of posix.fd_t, store:
file: ?std.fs.File,

// Open:
const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });

// Get size:
const stat = try file.stat();
const size = stat.size;

// Read at offset:
try file.seekTo(offset);
const bytes_read = try file.read(buffer);

// Write at offset:
try file.seekTo(offset);
try file.writeAll(data);

// Truncate:
try file.setEndPos(0);
```

### Option B: Conditional Compilation
Keep current POSIX paths for Linux/macOS, add Windows-specific implementations:

```zig
if (comptime native_os == .windows) {
    // Use Windows API via std.os.windows
} else if (comptime native_os == .linux) {
    // Current Linux implementation
} else {
    // Current libc fallback
}
```

## Test Considerations

- Standalone storage tests use per-run repo-local `.zig-cache` scratch directories instead of fixed system temp paths.
- File permission modes (0o644) don't apply on Windows.
- Path separators should be handled through `std.fs` APIs.

## Migration Steps

1. Create abstraction layer for file operations in `src/db/file_io.zig`
2. Migrate WAL to use abstraction
3. Migrate pager to use abstraction
4. Update tests to use cross-platform temp paths
5. Test on Windows (CI or manual)
6. Remove `error.Unsupported` gates

## Priority

Low - Linux is the primary target. Windows support is a nice-to-have for development/testing convenience.
