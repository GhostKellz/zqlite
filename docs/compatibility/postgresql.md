# PostgreSQL-Style Features

ZQLite is an embedded SQL database with selected PostgreSQL-inspired syntax. It is not a PostgreSQL server, wire-protocol implementation, catalog-compatible engine, extension host, or operational replacement.

## Supported Contract

Supported PostgreSQL-style behavior is limited to features that have both documentation and tests:

| Feature | Status | Test coverage | Contract |
| --- | --- | --- | --- |
| `RETURNING` | Supported | `tests/test_runner.zig`, `tests/standalone/test_sql_conformance.zig` | `INSERT`, `UPDATE`, and `DELETE` can return selected columns; conformance coverage includes `RETURNING *`, default values, and multi-row update/delete results. |
| `ON CONFLICT` / UPSERT | Supported | `tests/test_runner.zig`, `tests/standalone/test_upsert.zig`, `tests/standalone/test_sql_conformance.zig` | `DO NOTHING`, `DO UPDATE`, `RETURNING`, and `excluded.column` references are covered, including conflict and no-conflict `DO NOTHING RETURNING` paths. |
| Named parameters | Supported | `tests/test_runner.zig`, `tests/consumer/c/main.c` | `:name`, `@name`, and `$name` parameters bind by name, including repeated names. |
| Common table expressions | Partial | `tests/standalone/test_sql_conformance.zig` | Top-level non-recursive `WITH` queries, chained CTE definitions, and explicit CTE column aliases execute. Nested CTEs and recursive self-references remain unsupported. |
| Window functions | Partial | `tests/window/test_window.zig`, `tests/unit/query_validation_test.zig`, `tests/standalone/test_sql_conformance.zig` | Ranking/window helper paths exist for the tested subset. `ROWS` frames are applied for `FIRST_VALUE`, `LAST_VALUE`, and `NTH_VALUE`; full PostgreSQL window-frame semantics are not promised. |
| Generated columns | Partial | `tests/standalone/test_sql_conformance.zig` | Stored generated columns using deterministic same-row expressions are computed on `INSERT` and `UPDATE`; direct writes are rejected. |
| Partial and expression indexes | Partial | `tests/standalone/test_sql_conformance.zig` | In-memory runtime maintenance and unique enforcement support partial predicates and deterministic same-row expression keys. Persistent advanced-index catalogs and full SQLite/PostgreSQL parity are not promised. |
| Richer value types and JSON helpers | Partial | `tests/standalone/test_sql_conformance.zig` plus existing unit coverage | `json_valid`, `json_extract`, `json_type`, `json_array_length`, and `json_object` work over text JSON and column values for the documented subset; PostgreSQL JSON operator parity is not promised. |
| Date/time helpers | Partial | `tests/standalone/test_sql_conformance.zig` plus existing default timestamp tests | `datetime`, `date`, `time`, `unixepoch`, `julianday`, and `strftime` support deterministic UTC conversion for Unix timestamps and ISO-8601 strings, with simple second-based modifiers. |
| User-defined functions | Partial | `tests/standalone/test_sql_conformance.zig` | Connection-scoped Zig callbacks can be registered as scalar functions or single-column aggregate functions. PostgreSQL extension/procedure/function catalog compatibility is not promised. |
| `ANALYZE` and planner statistics | Partial | `tests/standalone/test_sql_conformance.zig` | `ANALYZE` refreshes connection-local table/index statistics exposed through `PRAGMA planner_stats`; analyzed unique equality indexes can be selected with estimated rows/cost. PostgreSQL statistics catalogs and full cost-model parity are not promised. |

The generated SQLite compatibility matrix in `docs/sql-compatibility.md` is the source of truth for cross-dialect SQL behavior that is currently tested.

## Negative Compatibility Matrix

The following PostgreSQL features are intentionally not supported unless a future task adds implementation, tests, and documentation:

| PostgreSQL feature | ZQLite status | Expected behavior |
| --- | --- | --- |
| Wire protocol, server process, replication protocol | Not supported | Use the Zig or C embedded APIs, not PostgreSQL clients or drivers. |
| PostgreSQL system catalogs such as `pg_catalog` and `information_schema` parity | Not supported | Do not introspect ZQLite as if it were PostgreSQL. |
| PostgreSQL extensions, extension SQL, background workers | Not supported | Extension compatibility is not claimed. |
| Roles, privileges, GRANT/REVOKE, row-level security | Not supported | Enforce authorization in the embedding application. |
| Stored procedures, PL/pgSQL, triggers | Not supported | Keep application logic outside the database engine. |
| PostgreSQL function/procedure catalogs and extension-defined functions | Not supported | Use the documented connection-scoped Zig UDF callbacks only. |
| Full PostgreSQL type system and implicit casts | Not supported | Only documented ZQLite value types and conversion behavior are stable. |
| Full generated-column parity | Partial | Stored same-row expressions are supported; full PostgreSQL/SQLite generated-column behavior is not promised. |
| Full partial/expression index parity | Partial | In-memory runtime uniqueness semantics are supported for the tested subset; persistent advanced-index catalogs and PostgreSQL planner behavior are not promised. |
| Nested CTEs and recursive CTEs | Not supported | Non-recursive top-level/chained CTEs and explicit CTE column aliases execute; nested CTEs and recursive self-references are rejected by conformance tests today. |
| Full window-frame semantics | Partial | `ROWS` frames are implemented for the documented value-window subset; full PostgreSQL `RANGE`/`GROUPS` behavior is not promised. |
| PostgreSQL-specific JSON operator parity | Partial | Use only documented JSON helper functions; PostgreSQL `->`, `->>`, containment, indexing, and cast behavior are not promised. |
| PostgreSQL date/time arithmetic parity | Partial | Use tested UTC helper functions only; time zones, intervals, locale-aware formatting, and PostgreSQL cast/operator behavior are not promised. |
| PostgreSQL planner behavior, statistics catalog, `ANALYZE`, `EXPLAIN` parity | Partial | `ANALYZE` gathers local ZQLite stats and the planner can choose analyzed unique equality indexes; PostgreSQL statistics catalogs and planner behavior are not promised. `EXPLAIN` reports current steps and index scan estimates, but is not PostgreSQL-compatible output. |

## Positioning

Use ZQLite when an application needs an embedded Zig-native database with SQLite-style local persistence and a small set of tested PostgreSQL-inspired conveniences.

Do not position ZQLite as a drop-in backend for applications that expect PostgreSQL protocol, catalogs, extensions, operational tooling, or full SQL semantics. A PostgreSQL-style feature is available only when it is listed here or in `docs/sql-compatibility.md` with test coverage.

## Planned Work

- a plug-and-play compatibility profile for PostgreSQL-style ergonomics without PostgreSQL-server claims
- a migration guide for common PostgreSQL-to-ZQLite query patterns
- stronger CTE execution coverage beyond the implemented top-level non-recursive and chained forms
- broader `RANGE`/`GROUPS` frame behavior if it can be kept small and testable
- PostgreSQL-style compatibility tests for parameters, identifiers, literals, transactions, JSON expressions, date/time expressions, and error categories
