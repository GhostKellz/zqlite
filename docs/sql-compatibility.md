# SQL Compatibility Matrix

Generated from `tests/sql_compatibility.tsv`.

| Feature | Status | Scope | Tests | Notes |
| --- | --- | --- | --- | --- |
| UNIQUE NULL distinctness | supported | stable | tests/standalone/test_file_backed.zig<br> tests/standalone/test_sqlite_diff.zig | Multiple NULL values are distinct for unique indexes and inline/table UNIQUE constraints. |
| Column UNIQUE constraints | supported | stable | tests/standalone/test_file_backed.zig | Inline UNIQUE creates a persisted auto-index. |
| Table UNIQUE constraints | supported | stable | tests/standalone/test_file_backed.zig | Composite UNIQUE creates a persisted auto-index; NULL-containing keys are skipped. |
| CHECK constraints | supported | stable | tests/standalone/test_file_backed.zig<br> tests/standalone/test_sqlite_diff.zig | INSERT/UPDATE reject FALSE and allow TRUE/UNKNOWN. |
| Foreign key child validation | supported | stable | tests/standalone/test_file_backed.zig<br> tests/standalone/test_sqlite_diff.zig | Supported for single-column FK references. |
| Foreign key RESTRICT/NO ACTION | supported | stable | tests/standalone/test_file_backed.zig | Parent DELETE/UPDATE reject referenced keys. |
| Foreign key ON DELETE CASCADE | supported | stable | tests/standalone/test_file_backed.zig<br> tests/standalone/test_transaction_atomicity.zig<br> tests/standalone/test_sqlite_diff.zig | Includes savepoint rollback coverage. |
| Foreign key ON DELETE SET NULL | supported | stable | tests/standalone/test_file_backed.zig<br> tests/standalone/test_sqlite_diff.zig | Rejects SET NULL when child column is NOT NULL. |
| Foreign key ON UPDATE CASCADE | supported | stable | tests/standalone/test_file_backed.zig<br> tests/standalone/test_sqlite_diff.zig | Child keys update with parent key. |
| INSERT DEFAULT VALUES | supported | stable | tests/standalone/test_file_backed.zig<br> tests/standalone/test_sqlite_diff.zig | Applies literal and function defaults. |
| DEFAULT CURRENT_TIMESTAMP | supported | stable | tests/test_runner.zig<br> tests/standalone/test_file_backed.zig | Function defaults are evaluated on INSERT and survive reopen. |
| NULL IN/LIKE three-valued logic | supported | stable | tests/standalone/test_sqlite_diff.zig<br> tests/standalone/test_sql_conformance.zig | WHERE treats UNKNOWN as non-matching. |
| AND/OR NULL propagation | supported | stable | tests/test_runner.zig<br> tests/standalone/test_sql_conformance.zig | Implemented through SQL truth-table evaluator. |
| Comparison and type ordering | partial | partial | tests/standalone/test_sql_conformance.zig | Current numeric, NULL, and text ordering behavior is covered; full SQLite affinity coercion is not claimed. |
| SAVEPOINT/RELEASE/ROLLBACK TO | supported | stable | tests/standalone/test_transaction_atomicity.zig<br> tests/standalone/test_sqlite_diff.zig | DML savepoints; DDL inside active savepoints returns error.UnsupportedDDLInSavepoint. |
| Prepared positional parameters | supported | stable | tests/test_runner.zig<br> tests/standalone/test_security.zig | Uses zero-based binding API. |
| Prepared named parameters | supported | stable | tests/test_runner.zig<br> tests/consumer/c/main.c | Supports :name, @name, $name and repeated-name binding. |
| RETURNING | supported | stable | tests/test_runner.zig<br> tests/standalone/test_sql_conformance.zig | INSERT/UPDATE/DELETE RETURNING covered, including RETURNING * defaults and multi-row UPDATE/DELETE RETURNING. |
| UPSERT ON CONFLICT | supported | stable | tests/test_runner.zig<br> tests/standalone/test_upsert.zig<br> tests/standalone/test_sql_conformance.zig | DO NOTHING, DO UPDATE, RETURNING, and excluded.* covered, including DO NOTHING RETURNING conflict/no-conflict paths. |
| Common table expressions | partial | partial | tests/standalone/test_sql_conformance.zig | Top-level non-recursive WITH, chained CTE definitions, and explicit CTE column aliases execute; nested CTEs and recursive self-references are rejected. |
| Window ROWS frames | partial | partial | tests/standalone/test_sql_conformance.zig<br> tests/window/test_window.zig | ROWS frames are applied for FIRST_VALUE, LAST_VALUE, and NTH_VALUE over the supported window-function subset. |
| Generated columns | partial | partial | tests/standalone/test_sql_conformance.zig | Stored generated columns using deterministic same-row expressions are computed on INSERT and UPDATE; direct writes are rejected. |
| Partial and expression indexes | partial | partial | tests/standalone/test_sql_conformance.zig | In-memory runtime index maintenance and unique enforcement support partial predicates and deterministic same-row expression keys; persistent advanced-index catalogs and full SQLite/PostgreSQL parity are not claimed. |
| JSON helpers | partial | partial | tests/standalone/test_sql_conformance.zig | Small SQL-callable subset: json_valid, json_extract, json_type, json_array_length, and json_object over text JSON and column values. Missing paths and invalid JSON return NULL for extract/type/length paths; PostgreSQL JSON operator parity is not claimed. |
| Date/time functions | partial | partial | tests/standalone/test_sql_conformance.zig | datetime/date/time/unixepoch/julianday/strftime use deterministic UTC Gregorian conversion for Unix timestamps and ISO-8601 strings, with simple +/- days/hours/minutes/seconds and start-of-day modifiers. Time zones, locale formatting, and full SQLite/PostgreSQL date arithmetic are not claimed. |
| User-defined functions | partial | partial | tests/standalone/test_sql_conformance.zig | Connection-scoped Zig callbacks can be registered as scalar functions or single-column aggregate functions and called from SQL. Persistent SQL-defined functions, variadic aggregate state APIs, and C ABI registration are not claimed. |
| ANALYZE and planner statistics | partial | partial | tests/standalone/test_sql_conformance.zig | ANALYZE refreshes connection-local table/index statistics and PRAGMA planner_stats exposes live row counts, logical row counts, deleted rows, indexed rows, and distinct values. The planner can use analyzed unique equality indexes with estimated rows/cost; persistent sqlite_stat* catalogs and full cost-model parity are not claimed. |
| EXPLAIN | partial | partial | tests/standalone/test_sql_conformance.zig | Output reflects the current step order and includes estimated rows/cost for planned index scans, but is not full SQLite/PostgreSQL EXPLAIN parity. |
| ALTER TABLE | partial | stable-core | `test-schema-evolution` | `RENAME TABLE`, `RENAME COLUMN`, and the no-rewrite `ADD COLUMN` subset are supported; dependent-schema rewrites are rejected. |
| DDL savepoint rollback | unsupported | planned | tests/standalone/test_transaction_atomicity.zig | Savepoints currently cover DML row changes; schema/catalog changes inside active savepoints are rejected explicitly. |
| Foreign key deferral | unsupported | planned | - | Immediate enforcement only. |
| Foreign key multi-column references | unsupported | planned | - | Single-column FK subset only. |
| Collations | partial | partial | tests/standalone/test_sql_conformance.zig | COLLATE NOCASE ordering is covered; broader user-defined collation behavior is not claimed. |
