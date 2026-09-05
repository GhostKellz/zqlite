# SQLite Compatibility

ZQLite aims to be a strong embedded SQLite-style database, not a byte-for-byte SQLite clone.

## Support Matrix

| Area | Status | Notes |
|---|---|---|
| CREATE TABLE / DROP TABLE | Supported | Core DDL works |
| INSERT / UPDATE / DELETE | Supported | Core DML works |
| RETURNING | Supported | `INSERT`, `UPDATE`, `DELETE` |
| UPSERT / ON CONFLICT | Supported | `DO NOTHING`, `DO UPDATE` |
| SELECT / JOIN / GROUP BY | Supported | Core query path |
| Subqueries | Supported | Common forms |
| Window functions | Partial | `PARTITION BY` present, advanced framing limited |
| PRAGMA | Partial | Focused subset only |
| FTS5-style virtual tables | Partial | MATCH works, persistence/features limited |
| ATTACH / DETACH | Supported | With security policy controls and `schema.table` access |
| SAVEPOINT / RELEASE / ROLLBACK TO | Supported | DML savepoints; DDL/catalog changes inside savepoints return an explicit error |
| Named prepared parameters | Supported | `:name`, `@name`, `$name` |
| Read-only / immutable open | Supported | Main database file is opened read-only; WAL is not opened or replayed |
| `ALTER TABLE RENAME TO` | Partial | Supported when the table has no index, FTS, or foreign-key dependencies |
| `ALTER TABLE RENAME COLUMN` | Partial | Supported when the column is not referenced by an index, generated/check expression, or foreign key |
| `ALTER TABLE ADD COLUMN` | Partial | Populated tables support nullable columns and constant defaults, including `NOT NULL` with a non-NULL default; key, unique, generated, check, and foreign-key additions are rejected |
| Composite foreign keys | Partial | Multi-column matching, NULL-key behavior, parent protection, and catalog persistence are supported; composite CASCADE/SET NULL rewrites are rejected |
| Deferred foreign keys | Partial | `DEFERRABLE INITIALLY DEFERRED` NO ACTION constraints validate at commit and remain transaction-active on failure |
| Partial/expression indexes | Partial | Definitions and unique enforcement persist; deterministic same-row expressions/predicates only |
| Equality index scans | Partial | Ordinary single-column unique/non-unique indexes support literals and rebound parameters without ANALYZE; all duplicate candidates are filtered against WHERE |
| Busy timeout / interrupt | Supported | Cooperative connection-level timeout and interrupt checks during parse/plan/VM execution |
| VACUUM | Partial | Rebuilds live rows, indexes, FTS metadata, and catalog state into a validated compact image; tested to reclaim deleted-row space, without claiming full SQLite VACUUM parity |

## Intentional Deviations

- `secure_mode` adds stricter ATTACH behavior than SQLite by default when enabled.
- Experimental modules are separated from the stable core instead of being implied by default.
- FTS support is intentionally smaller than full SQLite FTS5 behavior.
- Query result caching is optional and connection-local rather than an invisible global SQLite behavior.
- Read-only and immutable opens are inspection modes over the main database file; checkpoint first if you need pending WAL content visible.
- Unsupported `ALTER TABLE` rewrites fail before catalog mutation with a specific error. Schema changes inside explicit transactions are rejected because transactional DDL rollback is not part of the stable contract.
- Busy timeout is currently a cooperative operation timeout, not complete SQLite file-lock waiting semantics.

## Verified Compatibility Areas

- `PRAGMA table_info(...)` and `PRAGMA database_list`
- `PRAGMA user_version` / `PRAGMA user_version = N` and read-only `PRAGMA schema_version`
- `PRAGMA integrity_check` as a lightweight ZQLite storage/catalog consistency check returning `ok` or one diagnostic row
- `VACUUM` as a ZQLite maintenance command, not full SQLite file rewrite parity
- `ATTACH DATABASE` / `DETACH DATABASE` with explicit path-policy enforcement
- schema-qualified attached database DDL/DML for `CREATE TABLE`, `CREATE INDEX`, `DROP INDEX`, `INSERT`, `SELECT`, `UPDATE`, `DELETE`, and `DROP TABLE`
- `CREATE VIRTUAL TABLE ... USING fts5(...)` plus basic `MATCH` queries
- prepared statement bind, execute, reset, reuse lifecycle, and explicit `error.PreparedStatementExpired` after schema-changing DDL
- named prepared parameters and repeated-name binding
- DML `SAVEPOINT`, `RELEASE`, and `ROLLBACK TO`

## Unsupported Or Partial Areas

- Full PRAGMA coverage
- DDL/catalog rollback through savepoints; schema changes inside active savepoints return `error.UnsupportedDDLInSavepoint`
- Full FTS phrase and boolean query support
- Full SQLite edge-case compatibility across all planner/executor paths

## Tested Expectations

`zig build test-index-queries` verifies duplicate traversal across B-tree splits,
prepared rebinding, hash collisions, integer/real equality, rollback, concurrent
connection refresh, and indexed read-only opens. Composite, partial, and
expression indexes are not selected by this equality fast path. Joins retain
their table-scan path. Large rounded numeric comparisons and unsupported lookup
value types fall back to scanning to preserve existing comparison behavior.

Index definitions persist in the catalog; derived index trees are rebuilt in
memory on open and rollback. Ordinary INSERT, UPDATE, DELETE, upsert, and FK
cascade paths maintain affected entries incrementally, including partial and
expression indexes. Unique checks compare actual values within the matching key
bucket. Read-only opens rebuild without modifying the database. Underfull index
pages remain allocated until rebuild; derived index memory is not included in
the connection's query-result memory budget. Existing files remain readable;
use `VACUUM` to reclaim old unreachable file pages.

Populated `ADD COLUMN` copies rows into a replacement tree, then publishes the
new root and schema together through the catalog. It uses the existing row
format and preserves logical row IDs. Constant defaults are materialized in
existing rows; absent defaults fill with NULL. Previously populated tables
reject function defaults and `NOT NULL` without a non-NULL default. Explicit
transactions/savepoints still reject this DDL. Copying requires additional
memory and database pages; old pages are reclaimed by `VACUUM`.

A failed DML statement within an explicit transaction undoes its own writes and
rebuilds derived indexes, preserving earlier successful statements. Allocation
or I/O failure during rollback can still prevent restoration; errors are logged
and callers must not assume successful recovery in that case.

- treat `PRAGMA` support as a curated subset, not broad SQLite parity
- validate ATTACH behavior under your chosen path policy, especially in `secure_mode`
- validate FTS behavior if you depend on persistence details or advanced query semantics
- prefer application tests for SQLite edge cases outside the documented support matrix

## Migration Notes

- Start with standard CRUD, joins, aggregates, ATTACH, and prepared statements.
- Test PRAGMA usage explicitly before migrating tooling that depends on deep SQLite introspection.
- Treat FTS and window-function edge cases as compatibility areas to validate in application tests.
