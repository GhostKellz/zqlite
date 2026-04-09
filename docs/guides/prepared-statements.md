# Prepared Statements

Parameterized queries prevent SQL injection and improve performance.

## Basic Usage

```zig
const conn = try zqlite.openMemory(allocator);
defer conn.close();

// Prepare statement with ? placeholders
var stmt = try conn.prepare("SELECT * FROM users WHERE id = ?");
defer stmt.deinit();

// Bind parameter (0-indexed)
try stmt.bind(0, @as(i64, 42));

// Execute and get results
var result = try stmt.execute();
defer result.deinit();

for (result.rows.items) |row| {
    // Process row...
}
```

## Parameter Binding

Bind by index (0-based):

```zig
// Integer
try stmt.bind(0, @as(i64, 123));

// Text
try stmt.bind(1, "hello");

// Float
try stmt.bind(2, @as(f64, 3.14));

// Null
try stmt.bindNull(3);

// Blob
try stmt.bind(4, &[_]u8{0x01, 0x02, 0x03});
```

## Reusing Statements

Reset clears bindings for reuse:

```zig
var stmt = try conn.prepare("INSERT INTO logs (msg) VALUES (?)");
defer stmt.deinit();

for (messages) |msg| {
    try stmt.bind(0, msg);
    var result = try stmt.execute();
    result.deinit();
    stmt.reset();
}
```

## Reading Results

```zig
var result = try stmt.execute();
defer result.deinit();

for (result.rows.items) |row| {
    for (row.values) |value| {
        switch (value) {
            .Integer => |i| std.debug.print("int: {}\n", .{i}),
            .Text => |t| std.debug.print("text: {s}\n", .{t}),
            .Real => |r| std.debug.print("real: {d}\n", .{r}),
            .Blob => |b| std.debug.print("blob: {} bytes\n", .{b.len}),
            .Null => std.debug.print("null\n", .{}),
        }
    }
}
```

## Value Types

| Type | Zig Type | Storage |
|------|----------|---------|
| Integer | `i64` | 64-bit signed |
| Real | `f64` | 64-bit float |
| Text | `[]const u8` | UTF-8 string |
| Blob | `[]const u8` | Binary data |
| Null | - | NULL value |

## Memory Management

- `stmt.deinit()` frees statement resources
- `result.deinit()` frees result rows and values
- Always use `defer` to ensure cleanup
- Bindings are cloned internally

## Performance

Prepared statements are compiled once and can be executed many times with different parameters. This avoids parsing overhead on repeated queries.
