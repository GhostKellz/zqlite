# ZQLite Zig API Reference

## Core API

### Database Connection

```zig
const zqlite = @import("zqlite");

// File-based database
var conn = try zqlite.open(allocator, "mydata.db");
defer conn.close();

// Read-only inspection
var ro = try zqlite.openWithOptions(allocator, "mydata.db", zqlite.OpenOptions.READ_ONLY);
defer ro.close();

// Immutable snapshot-style inspection. ZQLite opens the main database file
// read-only and does not open/replay WAL.
var imm = try zqlite.openWithOptions(allocator, "mydata.db", zqlite.OpenOptions.IMMUTABLE);
defer imm.close();

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

`query()` returns an owned result set. Call `result.deinit()` exactly once.
Rows yielded by `result.next()` are borrowed from that result set and become
invalid when the result is deinitialized. Values returned from row helpers such
as `getText()` are borrowed from the row/result; copy them with your allocator
if they must outlive the result.

### Prepared Statements

```zig
var stmt = try conn.prepare("INSERT INTO users VALUES (?, ?, ?)");
defer stmt.deinit();

try stmt.bind(0, 1);
try stmt.bind(1, "Alice");
try stmt.bind(2, "alice@example.com");
_ = try stmt.execute();

// Reuse
stmt.reset();
try stmt.bind(0, 2);
// ...
```

`bind()` uses native Zig values with 0-based parameter indexes. Use `bindParameter()` if you need to pass an explicit `storage.Value`.

### Transactions

```zig
try conn.execute("BEGIN TRANSACTION");
// ... operations ...
try conn.execute("COMMIT");
// or: try conn.execute("ROLLBACK");
```

### Timeout and Interruption

ZQLite exposes cooperative operation controls on each connection:

```zig
conn.setBusyTimeout(250); // milliseconds; 0 disables timeout checks
try conn.execute("SELECT * FROM users");

conn.interrupt();         // current or next operation returns error.Interrupted
conn.clearInterrupt();    // allow later operations to run
```

`busy_timeout_ms` can also be set through `ConnectionOptions`. Timeout and
interrupt checks run before parse/plan work and between VM plan steps and row
loops. This is a cooperative operation timeout, not a PostgreSQL-style statement
timeout daemon and not a full SQLite lock-wait implementation.

### Resource Limits and Progress

Use `ResourceLimits` when embedding ZQLite in request handlers, plugins, or other untrusted query surfaces:

```zig
var conn = try zqlite.openMemoryWithOptions(allocator, .{
    .resource_limits = .{
        .max_scanned_rows = 10_000,
        .max_result_rows = 1_000,
        .max_affected_rows = 100,
        .max_vm_steps = 50_000,
        .max_statement_bytes = 16 * 1024,
        .max_page_count = 4096,
        .max_cache_pages = 128,
        .max_memory_bytes = 4 * 1024 * 1024,
        .progress_interval_ops = 500,
    },
    .plan_cache_entries = 64, // use 0 to disable the per-connection plan cache
});
```

Queries that exceed a configured row, VM-step, statement-size, page-count, cache, or materialization-memory limit return `error.ResourceLimitExceeded`.

Use `try conn.configureResourceLimits(limits)` when changing page limits after open; it fails if the database already exceeds the requested page cap. `conn.setResourceLimits(limits)` remains available for non-failing row/statement/progress updates.

Progress handlers are cooperative cancellation hooks:

```zig
fn progress(ctx: ?*anyopaque, event: zqlite.ProgressEvent) bool {
    _ = ctx;
    return event.work_units < 50_000; // false cancels with error.Interrupted
}

conn.setProgressHandler(500, progress, null);
```

### Schema Versions and Migrations

Use `user_version` for application migration state and `schema_version` for catalog-change observation:

```zig
try conn.setUserVersion(1);
const app_version = conn.getUserVersion();
const catalog_version = conn.getSchemaVersion();

var result = try conn.query("PRAGMA user_version");
defer result.deinit();
```

`zqlite.migration.MigrationManager` applies ordered migrations transactionally and advances `user_version` only after a migration succeeds.

Prepared statements capture the catalog `schema_version` at prepare time. If DDL changes the schema before execution, `execute()` or `openCursor()` returns `error.PreparedStatementExpired`; prepare the statement again after the schema change.

### Cursor Results

Use `openCursor()` when you want row-by-row iteration semantics instead of working directly with the full `ResultSet` API:

```zig
var cursor = try conn.openCursor("SELECT id, name FROM items ORDER BY id");
defer cursor.deinit();

while (cursor.next()) |row| {
    var owned = row;
    defer owned.deinit();
    std.debug.print("{}\n", .{owned.getInt(0).?});
}
```

Prepared statements also expose cursor iteration after binding:

```zig
var stmt = try conn.prepare("SELECT name FROM items WHERE id >= ?");
defer stmt.deinit();
try stmt.bindInt(0, 10);

var cursor = try stmt.openCursor();
defer cursor.deinit();
```

The v1.7.0 cursor uses an incremental table scan for simple table queries,
including projected columns and simple `WHERE` comparisons against literals or
bound parameters. It falls back to an owned materialized result for richer SQL.
Caller ownership stays the same across both paths.

### Integrity Checks

Use `integrityCheck()` or `PRAGMA integrity_check` for a lightweight storage/catalog consistency check:

```zig
var check = try conn.integrityCheck();
defer check.deinit(allocator);

if (!check.ok) {
    std.debug.print("integrity issue: {s}\n", .{check.first_issue orelse "unknown"});
}
```

The current check validates table row metadata, deleted-key bounds, row/schema column cardinality, index table/column references, and supported index entry counts.

### Maintenance

`VACUUM` is available as a storage maintenance command:

```zig
var result = try conn.query("VACUUM");
defer result.deinit();
```

In v1.7.0 it checkpoints/flushed pending state, rebuilds table indexes, rewrites catalog metadata, and runs integrity validation.

Embedders that need a compact copy-out workflow can use `vacuumInto()` on file-backed databases:

```zig
var check = try conn.vacuumInto(io, "compacted.db");
defer check.deinit(allocator);
```

`vacuumInto()` returns the integrity-check result after writing a flushed backup copy.

### Durability

Use `try conn.flush()` to synchronize pending non-transaction writes. Use `try conn.checkpoint()` when you want to explicitly checkpoint WAL state into the main database file. Use `try conn.closeFallible()` when final checkpoint or synchronization failures must be handled; `close()` is a convenience cleanup that can only log such failures. See the [Durability Guide](../guides/durability.md).

```zig
try conn.checkpoint();

if (try conn.getWalStats()) |stats| {
    std.debug.print("wal bytes: {}\n", .{stats.size_bytes});
}
```

### Backup

File-backed connections can produce a consistent file-level backup after a checkpoint/flush:

```zig
try conn.backupToFile(io, "backup.db");
```

`backupToFile()` returns `error.BackupRequiresFileDatabase` for in-memory databases.

Read-only and immutable file-backed connections can also use `backupToFile()`.
They copy the main database file without checkpointing because they intentionally
do not open WAL.

## Ownership and Lifetimes

- `Connection` values returned by `open()` / `openMemory()` are owned by the caller; close them with `close()` or `closeFallible()`.
- `ResultSet` values returned by `query()` own their rows and values; call `deinit()` once.
- `Row` handles obtained from a `ResultSet` are borrowed and valid only while the result set is alive.
- `Value.Text` and `Value.Blob` slices read from result rows are borrowed from the result set. Duplicate them if they must escape the result lifetime.
- `PreparedStatement` values returned by `prepare()` are owned by the caller; call `deinit()`. Bound values are cloned by the statement.
- `interrupt()` remains set until `clearInterrupt()` is called.
- Storage-level `Row` / `Value` instances you allocate directly follow normal Zig ownership: whoever allocates text/blob/array contents must deinitialize them with the matching allocator unless ownership is explicitly transferred to storage.

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
    SmallInt: i16,
    BigInt: i64,
    UUID: [16]u8,
    JSON: []const u8,
    JSONB: []const u8,
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

### Storage and Catalog Errors

Opening a database validates the on-disk metadata catalog and can return:

- `error.CorruptCatalog` - The superblock or catalog payload failed its checksum, or a catalog record was structurally invalid.
- `error.UnsupportedDatabaseFormat` - The catalog format version is newer than this build supports.

See [Durability and Persistence](../guides/durability.md) for the catalog format and the durability guarantees of `commit()`, `flush()`, and `closeFallible()`.

## SQL Support

### Supported Statements
- `CREATE TABLE` with constraints (PRIMARY KEY, NOT NULL, UNIQUE, CHECK, DEFAULT)
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

### Subqueries

```zig
// IN subquery
try conn.query("SELECT * FROM users WHERE id IN (SELECT user_id FROM active_users)");

// Scalar subquery
try conn.query("SELECT name, (SELECT COUNT(*) FROM orders WHERE orders.user_id = users.id) FROM users");
```

### Full-Text Search

```zig
// Create FTS table
try conn.execute("CREATE VIRTUAL TABLE articles USING fts5(title, content)");

// Insert documents
try conn.execute("INSERT INTO articles VALUES ('Database Design', 'Best practices for schema design')");

// Search with MATCH operator
var result = try conn.query("SELECT * FROM articles WHERE content MATCH 'schema design'");
```

### ATTACH DATABASE

```zig
// Attach external database
try conn.execute("ATTACH DATABASE 'archive.db' AS archive");

// Query across databases
var result = try conn.query("SELECT * FROM main.users JOIN archive.old_users ON main.users.id = archive.old_users.id");

// Detach when done
try conn.execute("DETACH DATABASE archive");
```

### HAVING Clause

```zig
// Filter aggregated results
var result = try conn.query(
    \\SELECT department, COUNT(*) as count
    \\FROM employees
    \\GROUP BY department
    \\HAVING COUNT(*) > 5
);
```

### SELECT DISTINCT

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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

    try stmt.bind(0, "Alice");
    try stmt.bind(1, "alice@example.com");
    _ = try stmt.execute();

    var result = try conn.query("SELECT * FROM users");
    defer result.deinit();

    while (result.next()) |row| {
        std.debug.print("{any}\n", .{row});
    }
}
```
