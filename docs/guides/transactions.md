# Transactions

ZQLite supports transaction boundaries with write-ahead logging and verified commit/rollback behavior on the tested paths.

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

Transactions use WAL-backed logging and rollback state:
- changes are recorded before commit completes
- commit and rollback behavior is covered by transaction atomicity tests
- checkpointing flushes durable state back to the main database

Avoid reading this as a blanket claim that every ACID/crash-recovery edge case is fully characterized across all experimental subsystems.

## Isolation Model

ZQLite's stable file-backed transaction model guarantees commit and rollback
behavior for the owning connection and prevents dirty reads across independent
file-backed connections:

- uncommitted file-backed writes are not visible to other connections
- committed changes are refreshed automatically before the next statement on an existing connection
- one writer may hold a transaction while independent readers continue to read the last committed state
- a second writer waits up to its configured busy timeout, then returns `error.OperationTimedOut`
- nested `BEGIN` transactions are rejected; use `SAVEPOINT` for nested rollback scopes
- `COMMIT` and `ROLLBACK` without an active transaction return `error.NoActiveTransaction`

Individual `INSERT`, `UPDATE`, and `DELETE` statements run as WAL-backed
autocommit transactions when no explicit transaction is active. If any row in
the statement fails, the entire statement is rolled back.

This is still a conservative one-writer/multiple-reader contract rather than a
claim of full SQLite MVCC parity. Lock contention, cross-process exclusion,
cache refresh, commit, rollback, no-dirty-read, reopen, and savepoint behavior
are covered by `test-concurrent-access` and `test-transaction`.

## Notes

- Nested transactions not supported
- `in_transaction` flag tracks state
- Undo log stores pre-modification values for rollback
