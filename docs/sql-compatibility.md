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
| NULL IN/LIKE three-valued logic | supported | stable | tests/standalone/test_sqlite_diff.zig | WHERE treats UNKNOWN as non-matching. |
| AND/OR NULL propagation | supported | stable | tests/test_runner.zig | Implemented through SQL truth-table evaluator. |
| SAVEPOINT/RELEASE/ROLLBACK TO | supported | stable | tests/standalone/test_transaction_atomicity.zig<br> tests/standalone/test_sqlite_diff.zig | DML savepoints; DDL inside active savepoints returns error.UnsupportedDDLInSavepoint. |
| Prepared positional parameters | supported | stable | tests/test_runner.zig<br> tests/standalone/test_security.zig | Uses zero-based binding API. |
| Prepared named parameters | supported | stable | tests/test_runner.zig<br> tests/consumer/c/main.c | Supports :name, @name, $name and repeated-name binding. |
| RETURNING | supported | stable | tests/test_runner.zig | INSERT/UPDATE/DELETE RETURNING covered. |
| UPSERT ON CONFLICT | supported | stable | tests/test_runner.zig<br> tests/standalone/test_upsert.zig | DO NOTHING, DO UPDATE, RETURNING, and excluded.* covered. |
| EXPLAIN | partial | partial | tests/unit/query_validation_test.zig | Output exists but does not yet fully reflect real planning decisions. |
| ALTER TABLE | unsupported | planned | - | Schema-altering operations are planned with migration tests. |
| DDL savepoint rollback | unsupported | planned | tests/standalone/test_transaction_atomicity.zig | Savepoints currently cover DML row changes; schema/catalog changes inside active savepoints are rejected explicitly. |
| Foreign key deferral | unsupported | planned | - | Immediate enforcement only. |
| Foreign key multi-column references | unsupported | planned | - | Single-column FK subset only. |
| Collations | unsupported | planned | - | No user-visible collation support yet. |
