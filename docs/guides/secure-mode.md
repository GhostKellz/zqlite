# Secure Mode

`secure_mode` enforces stricter defaults for ATTACH operations.

## Usage

```zig
const zqlite = @import("zqlite");
const db = zqlite.db;

var conn = try db.Connection.openWithOptions(
    allocator,
    "mydata.db",
    db.ConnectionOptions.SECURE,
);
defer conn.close();
```

## What Changes

| Setting | Default | Secure Mode |
|---------|---------|-------------|
| ATTACH relative paths | Allowed | Rejected |
| ATTACH filesystem paths | Allowed | Denied until an allowed root is configured |
| ATTACH in-memory databases | Allowed | Allowed |
| ATTACH path policy | `ALLOW_ALL` | `SECURE_DEFAULT` |

## Custom ATTACH Policy

```zig
var conn = try db.Connection.openWithOptions(
    allocator,
    "mydata.db",
    .{
        .attach_policy = .{
            .allowed_roots = &[_][]const u8{ "/var/lib/zqlite" },
            .allow_memory = true,
            .allow_relative = false,
        },
    },
);
```

### Policy Options

- `allowed_roots`: Allowed directory prefixes for ATTACH
- `allow_any_path`: Explicitly allow every filesystem path; disabled in secure mode
- `allow_memory`: Allow `:memory:` databases
- `allow_relative`: Allow relative paths

### Path Validation

- Rejects `..` path components
- Rejects null bytes
- Canonicalizes existing targets, their parent directories, and configured roots
- Resolves symlinks before root confinement checks
- Uses segment-aware root boundaries instead of string-prefix matching
- Requires absolute paths when `allow_relative = false`

An empty `allowed_roots` list is fail-closed unless `allow_any_path` is explicitly
set. A path containing `..` inside a filename, such as `data..db`, remains valid.
