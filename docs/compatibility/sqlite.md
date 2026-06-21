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
| ATTACH / DETACH | Supported | With security policy controls |
| SAVEPOINT / RELEASE / ROLLBACK TO | Supported | DML savepoints; DDL/catalog changes inside savepoints return an explicit error |
| Named prepared parameters | Supported | `:name`, `@name`, `$name` |

## Intentional Deviations

- `secure_mode` adds stricter ATTACH behavior than SQLite by default when enabled.
- Experimental modules are separated from the stable core instead of being implied by default.
- FTS support is intentionally smaller than full SQLite FTS5 behavior.
- Query result caching is optional and connection-local rather than an invisible global SQLite behavior.

## Verified Compatibility Areas

- `PRAGMA table_info(...)` and `PRAGMA database_list`
- `ATTACH DATABASE` / `DETACH DATABASE` with explicit path-policy enforcement
- `CREATE VIRTUAL TABLE ... USING fts5(...)` plus basic `MATCH` queries
- prepared statement bind, execute, reset, and reuse lifecycle
- named prepared parameters and repeated-name binding
- DML `SAVEPOINT`, `RELEASE`, and `ROLLBACK TO`

## Unsupported Or Partial Areas

- Full PRAGMA coverage
- DDL/catalog rollback through savepoints; schema changes inside active savepoints return `error.UnsupportedDDLInSavepoint`
- Full FTS phrase and boolean query support
- Full SQLite edge-case compatibility across all planner/executor paths
- Foreign-key deferral and multi-column FK references

## Tested Expectations

- treat `PRAGMA` support as a curated subset, not broad SQLite parity
- validate ATTACH behavior under your chosen path policy, especially in `secure_mode`
- validate FTS behavior if you depend on persistence details or advanced query semantics
- prefer application tests for SQLite edge cases outside the documented support matrix

## Migration Notes

- Start with standard CRUD, joins, aggregates, ATTACH, and prepared statements.
- Test PRAGMA usage explicitly before migrating tooling that depends on deep SQLite introspection.
- Treat FTS and window-function edge cases as compatibility areas to validate in application tests.
