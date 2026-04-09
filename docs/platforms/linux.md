# Linux

Linux is the primary development and test platform.

## Requirements

- Zig 0.16.0 or later
- POSIX-compliant filesystem

## Build

```bash
git clone https://github.com/your-org/zqlite.git
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

All features are fully supported:

| Feature | Status |
|---------|--------|
| File-based databases | Supported |
| In-memory databases | Supported |
| Write-Ahead Logging | Supported |
| B-tree storage | Supported |
| Full-text search | Supported |
| Connection pooling | Supported |
| Field encryption | Supported |
| Secure mode | Supported |
| C FFI | Supported |

## File Locations

Default paths:
- Database files: Current directory or specified path
- WAL files: `<database>.wal`

## Permissions

Database files require read/write access. WAL requires same directory write access.

## Distribution Notes

Tested on:
- Arch Linux (primary)
- Ubuntu/Debian
- Fedora
- Other glibc-based distributions

musl libc should work but is less tested.
