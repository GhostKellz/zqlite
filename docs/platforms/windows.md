# Windows Support

Windows x86_64 is supported for the stable embedded engine, CLI, file-backed
storage, WAL, and C ABI.

## Implementation

Database I/O goes through Zig's cross-platform `std.Io.File` positional read,
write, sync, length, and truncation operations. The CLI and process entry point
also use cross-platform standard I/O and argument APIs; no POSIX descriptor or
Linux syscall fallback is required on Windows.

## Validation

The Windows gate consists of:

```text
zig build -Dtarget=x86_64-windows-msvc -Dprofile=advanced
zig build test
zig build test-storage
zig build test-advanced
zig build test-c-api
```

The repository's Linux self-hosted workflow cross-compiles the Windows target.
Run the remaining commands above on Windows before making a native-validation
claim. The read-only permission test is skipped on Windows because a read-only
file attribute is not equivalent to POSIX write-permission denial; ZQLite's
explicit read-only database mode remains covered.

Use Windows path syntax when opening databases. Secure ATTACH root comparisons
are case-insensitive on Windows and still use canonicalized, segment-aware path
confinement.
