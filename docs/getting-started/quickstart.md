# Quickstart

Basic database operations with ZQLite.

## Open a Database

```zig
const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // In-memory database
    const conn = try zqlite.openMemory(allocator);
    defer conn.close();
}
```

## Create Tables

```zig
try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
```

## Insert Data

```zig
try conn.execute("INSERT INTO users (name) VALUES ('Alice')");
```

## Query Data

```zig
var stmt = try conn.prepare("SELECT id, name FROM users WHERE id = ?");
defer stmt.deinit();

stmt.bind(0, @as(i64, 1)) catch unreachable;

var result = try stmt.execute();
defer result.deinit();

for (result.rows.items) |row| {
    const id = switch (row.values[0]) {
        .Integer => |i| i,
        else => 0,
    };
    const name = switch (row.values[1]) {
        .Text => |t| t,
        else => "(null)",
    };
    std.debug.print("User: {} - {s}\n", .{ id, name });
}
```

## File-Based Database

```zig
const conn = try zqlite.open(allocator, "mydata.db");
defer conn.close();
```

## Next Steps

- [Prepared Statements](../guides/prepared-statements.md)
- [Transactions](../guides/transactions.md)
- [Secure Mode](../guides/secure-mode.md)
