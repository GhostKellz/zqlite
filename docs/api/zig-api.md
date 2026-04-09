# ZQLite Zig API Reference

## Core API

### Database Connection

```zig
const zqlite = @import("zqlite");

// File-based database
var conn = try zqlite.open(allocator, "mydata.db");
defer conn.close();

// In-memory database
var mem_conn = try zqlite.openMemory(allocator);
defer mem_conn.close();
```

### Basic Operations

```zig
// Execute statements (CREATE, INSERT, UPDATE, DELETE)
try conn.execute("CREATE TABLE users (id INTEGER, name TEXT, email TEXT)");
try conn.execute("INSERT INTO users VALUES (1, 'Alice', 'alice@example.com')");

// Query with results
var result = try conn.query("SELECT * FROM users");
defer result.deinit();

while (result.next()) |row| {
    std.debug.print("Row: {any}\n", .{row});
}
```

### Prepared Statements

```zig
var stmt = try conn.prepare("INSERT INTO users VALUES (?, ?, ?)");
defer stmt.deinit();

try stmt.bind(1, .{ .Integer = 1 });
try stmt.bind(2, .{ .Text = "Alice" });
try stmt.bind(3, .{ .Text = "alice@example.com" });
try stmt.execute();

// Reuse
try stmt.reset();
try stmt.bind(1, .{ .Integer = 2 });
// ...
```

### Transactions

```zig
try conn.execute("BEGIN TRANSACTION");
// ... operations ...
try conn.execute("COMMIT");
// or: try conn.execute("ROLLBACK");
```

### Connection Pooling

```zig
var pool = try zqlite.createConnectionPool(allocator, "mydata.db", 4, 16);
defer pool.deinit();

var conn = try pool.acquire();
defer pool.release(conn);
```

## Value Types

```zig
pub const Value = union(enum) {
    Integer: i64,
    Real: f64,
    Text: []const u8,
    Blob: []const u8,
    Null,
    Boolean: bool,
    UUID: [16]u8,
    Json: []const u8,
    Array: []Value,
};
```

## Error Handling

```zig
conn.execute("...") catch |err| switch (err) {
    error.ParseError => // Invalid SQL
    error.TableNotFound => // Table doesn't exist
    error.ConstraintViolation => // Constraint violated
    error.OutOfMemory => // Allocation failed
    else => return err,
};
```

## SQL Support

### Supported Statements
- `CREATE TABLE` with constraints (PRIMARY KEY, NOT NULL, UNIQUE, DEFAULT)
- `CREATE VIRTUAL TABLE ... USING fts5` - Full-text search tables
- `INSERT`, `UPDATE`, `DELETE`
- `SELECT` with WHERE, ORDER BY, LIMIT, DISTINCT, GROUP BY, HAVING
- `BEGIN`, `COMMIT`, `ROLLBACK`
- `CREATE INDEX`, `DROP TABLE`
- `ATTACH DATABASE`, `DETACH DATABASE` - Multi-database support
- `EXPLAIN`, `EXPLAIN QUERY PLAN`

### Data Types
- `INTEGER` - 64-bit signed integer
- `REAL` - 64-bit floating point
- `TEXT` - UTF-8 string
- `BLOB` - Binary data
- `BOOLEAN` - True/false (stored as INTEGER)

### Aggregate Functions
- `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`
- `STDDEV` / `STDDEV_POP` / `STDEV` - Population standard deviation
- `VARIANCE` / `VAR_POP` - Population variance
- `GROUP_CONCAT` - Concatenate values with separator

### Subqueries (v1.5.3+)

```zig
// IN subquery
try conn.query("SELECT * FROM users WHERE id IN (SELECT user_id FROM active_users)");

// Scalar subquery
try conn.query("SELECT name, (SELECT COUNT(*) FROM orders WHERE orders.user_id = users.id) FROM users");
```

### Full-Text Search (v1.5.3+)

```zig
// Create FTS table
try conn.execute("CREATE VIRTUAL TABLE articles USING fts5(title, content)");

// Insert documents
try conn.execute("INSERT INTO articles VALUES (1, 'Database Design', 'Best practices for schema design')");

// Search with MATCH operator
var result = try conn.query("SELECT * FROM articles WHERE content MATCH 'schema design'");
```

### ATTACH DATABASE (v1.5.3+)

```zig
// Attach external database
try conn.execute("ATTACH DATABASE 'archive.db' AS archive");

// Query across databases
var result = try conn.query("SELECT * FROM main.users JOIN archive.old_users ON main.users.id = archive.old_users.id");

// Detach when done
try conn.execute("DETACH DATABASE archive");
```

### HAVING Clause (v1.5.3+)

```zig
// Filter aggregated results
var result = try conn.query(
    \\SELECT department, COUNT(*) as count
    \\FROM employees
    \\GROUP BY department
    \\HAVING COUNT(*) > 5
);
```

### SELECT DISTINCT (v1.5.3+)

```zig
// Remove duplicate rows
var result = try conn.query("SELECT DISTINCT category FROM products");
```

## Performance Tips

1. **Use transactions for bulk operations**
2. **Reuse prepared statements**
3. **Create indexes on frequently queried columns**
4. **Use connection pooling for concurrent access**
5. **Use `defer` to ensure resource cleanup**

## Full Example

```zig
const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conn = try zqlite.open(allocator, "app.db");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  email TEXT UNIQUE
        \\)
    );

    var stmt = try conn.prepare("INSERT INTO users (name, email) VALUES (?, ?)");
    defer stmt.deinit();

    try stmt.bind(1, .{ .Text = "Alice" });
    try stmt.bind(2, .{ .Text = "alice@example.com" });
    try stmt.execute();

    var result = try conn.query("SELECT * FROM users");
    defer result.deinit();

    while (result.next()) |row| {
        std.debug.print("{any}\n", .{row});
    }
}
```
