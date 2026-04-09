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
| ATTACH path policy | ALLOW_ALL | SECURE_DEFAULT |

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
- `allow_memory`: Allow `:memory:` databases
- `allow_relative`: Allow relative paths

### Path Validation

- Rejects `..` traversal attempts
- Rejects null bytes
- Segment-aware boundary checking
- Requires absolute paths when `allow_relative = false`
