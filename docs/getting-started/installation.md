# Installation

## Requirements

- Zig 0.16.0-dev or later
- Linux (primary), macOS, or Windows (limited)

## Zig Package Manager

Add ZQLite as a dependency:

```bash
zig fetch --save https://github.com/ghostkellz/zqlite/archive/refs/heads/main.tar.gz
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
./zig-out/bin/zqlite shell
```

## Verified Installation Script

```bash
curl -sSL https://raw.githubusercontent.com/ghostkellz/zqlite/main/install.sh -o install.sh
chmod +x install.sh && ./install.sh
```
