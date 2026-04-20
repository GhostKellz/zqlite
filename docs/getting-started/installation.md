# Installation

## Requirements

- Zig `0.17.0-dev.27+0dd99c37c` or later
- Linux (primary), macOS, or Windows (limited)

## Zig Package Manager

Add ZQLite as a dependency:

```bash
zig fetch --save https://github.com/ghostkellz/zqlite/archive/refs/tags/v1.6.2.tar.gz
```

In your `build.zig`:

```zig
const zqlite = b.dependency("zqlite", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zqlite", zqlite.module("zqlite"));
```

## Build from Source

```bash
git clone https://github.com/ghostkellz/zqlite
cd zqlite
zig build
```

### Build Targets

```bash
zig build                    # Library + CLI
zig build test               # Unit tests
zig build test-comprehensive # Full test suite
zig build test-security      # Security tests
zig build bench              # Performance benchmarks
```

### CLI

After building, the CLI is available at:

```bash
./zig-out/bin/zqlite --help
./zig-out/bin/zqlite
```

The CLI supports direct startup plus flags such as `--help`, `--version`, `--db`, and `--sql`.

Validated locally with `/opt/zig-dev/zig` (`0.17.0-dev.27+0dd99c37c`).

## Installation Script

```bash
curl -sSL https://raw.githubusercontent.com/ghostkellz/zqlite/main/install.sh -o install.sh
chmod +x install.sh && ./install.sh
```

Note: review `install.sh` before relying on it in automation. The canonical verified path is still `zig build` from source.
