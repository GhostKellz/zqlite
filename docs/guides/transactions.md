# Transactions

ZQLite supports ACID transactions with write-ahead logging.

## Basic Usage

```zig
const conn = try zqlite.openMemory(allocator);
defer conn.close();

try conn.begin();
errdefer conn.rollback() catch {};

try conn.execute("INSERT INTO accounts (id, balance) VALUES (1, 100)");
try conn.execute("INSERT INTO accounts (id, balance) VALUES (2, 200)");

try conn.commit();
```

## Automatic Rollback on Error

Use `transaction()` for automatic rollback:

```zig
try conn.transaction(void, struct {
    fn exec(c: *Connection, _: void) !void {
        try c.execute("INSERT INTO logs (msg) VALUES ('started')");
        try c.execute("UPDATE accounts SET balance = balance - 50 WHERE id = 1");
        try c.execute("UPDATE accounts SET balance = balance + 50 WHERE id = 2");
    }
}.exec, {});
```

## Execute Multiple Statements

```zig
const statements = [_][]const u8{
    "INSERT INTO users (name) VALUES ('Alice')",
    "INSERT INTO users (name) VALUES ('Bob')",
    "UPDATE stats SET user_count = user_count + 2",
};
try conn.transactionExec(&statements);
```

## Methods

| Method | Description |
|--------|-------------|
| `begin()` | Start transaction |
| `commit()` | Commit changes |
| `rollback()` | Undo changes |
| `transaction(ctx, fn, data)` | Execute with auto-rollback |
| `transactionSimple(fn)` | Execute without context |
| `transactionExec(stmts)` | Execute multiple statements |

## Write-Ahead Logging

Transactions use WAL for durability:
- Changes written to log before commit
- Crash recovery replays uncommitted changes
- Checkpoint flushes log to main database

## Notes

- Nested transactions not supported
- `in_transaction` flag tracks state
- Undo log stores pre-modification values for rollback
