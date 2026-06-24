# Durability and Persistence

ZQLite reports persistence failures through fallible transaction, flush, and close operations. Applications that require confirmation that data reached durable storage must handle these errors.

## Operation Semantics

| Operation | Guarantee on success |
|---|---|
| `execute()` outside a transaction | Updates connection state; persistence may be deferred until `flush()`, a successful transaction boundary, or `closeFallible()` |
| `commit()` | The WAL commit record passed its durability barrier, committed pages were checkpointed, metadata was saved, and the database file passed its durability barrier |
| `rollback()` | Modified pages were restored and flushed, and rollback WAL state was cleared |
| `flush()` | Pending WAL, database pages, and metadata were written and synchronized; rejected during an active transaction |
| `checkpoint()` | Alias for the public checkpoint/flush durability boundary; rejected during an active transaction |
| `backupToFile()` | Checkpoints and flushes the source database, then copies the main database file to the destination |
| `vacuumInto()` | Runs storage maintenance, validates integrity, and writes a flushed compact backup copy |
| `closeFallible()` | Performs cleanup and returns the first checkpoint, metadata, or synchronization failure after cleanup completes |
| `close()` | Convenience cleanup for `defer`; logs persistence failures but cannot return them |

## Recommended Pattern

```zig
const conn = try zqlite.open(allocator, "application.db");
errdefer conn.close();

try conn.execute("CREATE TABLE events (id INTEGER, body TEXT)");
try conn.flush();

if (try conn.getWalStats()) |stats| {
    std.debug.print("WAL size: {}\n", .{stats.size_bytes});
}

try conn.backupToFile(io, "application.backup.db");

var check = try conn.vacuumInto(io, "application.compacted.db");
defer check.deinit(allocator);

// At final ownership handoff, use the fallible close when the result matters.
try conn.closeFallible();
```

Do not call both `close()` and `closeFallible()` on the same connection. Both consume and destroy the connection.

## Commit Failure States

- A WAL synchronization failure leaves the transaction active and returns an error. The caller may retry or roll back.
- After the WAL commit record is durable, a later checkpoint or database synchronization error is returned, but the transaction remains logically committed. Recovery retries committed WAL work when possible.
- Callers must not report success to upstream systems until `commit()`, `flush()`, or `closeFallible()` returns successfully at the durability boundary they require.
- File backups should be created with `backupToFile()` instead of copying a live database file directly; it checkpoints first and refuses in-memory databases.
- Compact copy-out workflows should use `vacuumInto()` so maintenance and integrity validation happen before the backup file is written.

## Read-Only and Immutable Opens

`zqlite.openWithOptions(..., zqlite.OpenOptions.READ_ONLY)` opens the main
database file read-only, does not create missing files, does not open or replay
WAL, and rejects mutating SQL/API paths with `error.ReadOnlyDatabase`.

`zqlite.OpenOptions.IMMUTABLE` has the same write rejection behavior and is
intended for snapshot-style inspection of a database file that the application
knows will not change while open.

For both modes, checkpoint before opening if your application needs the latest
committed WAL state reflected in the main database file.

## Metadata Catalog Format

Table, index, column-default, and FTS metadata are stored in a versioned, crash-atomic catalog. Page 1 is a fixed superblock; the catalog payload lives in dynamically allocated chained pages so metadata is never silently truncated to fit a single page.

### Superblock (page 1)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Magic `0x5A444231` ("ZDB1") |
| 4 | 2 | Format version (currently `1`) |
| 6 | 2 | Reserved flags |
| 8 | 1 | Active slot (`0` or `1`) |
| 12 | 8 | Global generation counter |
| 20 | 28 | Slot A descriptor |
| 48 | 28 | Slot B descriptor |
| 76 | 4 | Header checksum (CRC32 over bytes `[0, 76)`) |

Each 28-byte slot descriptor records the chain's first page, page count, payload length, payload CRC32, and generation.

### Catalog chain pages

Each catalog page begins with an 8-byte header: a `u32` next-page id (`0` terminates the chain) and a `u32` payload length for that page. The remaining `page_size - 8` bytes carry serialized payload. The payload is serialized into a single owned buffer before any page is written, so its length and checksum are known up front and a write can never stop halfway and leave a partial catalog.

### Checksums

- **Algorithm:** CRC32 (`std.hash.Crc32`).
- **Superblock header checksum** covers superblock bytes `[0, 76)` — every field except the checksum word itself.
- **Catalog payload checksum** covers the entire serialized payload and is stored in the active slot descriptor.

On open, a mismatching superblock header checksum or payload checksum returns `error.CorruptCatalog`. A format version greater than the supported version returns `error.UnsupportedDatabaseFormat`.

### Atomic updates (A/B ping-pong)

Catalog rewrites never overwrite the live catalog in place:

1. Serialize the full catalog to one buffer.
2. Write it into the **inactive** slot's page chain.
3. Barrier 1 — `fdatasync` so the chain pages are durable before anything references them.
4. Write a new superblock that flips the active slot to the freshly written chain.
5. Barrier 2 — `fdatasync` so the pointer flip is durable.
6. Only then is the new catalog adopted in memory.

If any step fails, the previously active slot remains authoritative on disk and in memory, so a torn rewrite can never destroy the last valid catalog. Both slots keep their chain pages linked across rewrites, so pages are reused rather than leaked.

### Legacy migration

Databases written before the superblock format used a single page-1 catalog (magic `0x5A514C54`, "ZQLT"). On open, that magic is detected and the legacy page is parsed without modification. The file is transparently upgraded to the superblock + chain format on the next successful metadata write (for example, the next committed schema change), preserving existing B-tree root pages.

## Fault Validation

The storage test suite injects one-shot read, write, partial-write, sync, and truncate failures. These hooks are intended for deterministic testing of internal storage behavior, not application-level error simulation. Coverage includes WAL commit write/partial-write/sync failures, checkpoint page-write and sync failures, metadata write and sync failures, WAL truncate failure after a durable checkpoint, catalog superblock and payload corruption, unsupported format versions, legacy auto-migration, and read-only open rejection.
