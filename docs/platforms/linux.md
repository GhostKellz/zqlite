# Linux

Linux is the primary development and test platform.

## Requirements

- Zig version satisfying `build.zig.zon`
- POSIX-compliant filesystem

## Build

```bash
git clone https://github.com/ghostkellz/zqlite.git
cd zqlite
zig build
```

## Test

```bash
zig build test               # Unit tests
zig build test-security      # Security tests
zig build test-quick         # Quick validation
```

## Features

Stable core features are supported on Linux:

| Feature | Status |
|---------|--------|
| File-based databases | Supported |
| In-memory databases | Supported |
| Write-Ahead Logging | Supported |
| B-tree storage | Supported |
| Full-text search | Supported |
| Connection pooling | Supported |
| Field encryption | Experimental / internal only |
| Secure mode | Supported |
| C FFI | Supported with `-Dffi=true` |

## File Locations

Default paths:
- Database files: Current directory or specified path
- WAL files: `<database>.wal`

## Permissions

Database files require read/write access. WAL requires same directory write access.

## Distribution Notes

Verified regularly on:
- Arch Linux (primary host)
- Debian-based Docker environments for validation and Valgrind

Current local Zig baseline is tracked through `build.zig.zon` and the active `/opt/zig-dev/zig` toolchain.

Other Linux distributions may work, but should be treated as less verified unless explicitly tested.
