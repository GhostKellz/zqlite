# Changelog

All notable changes to ZQLite will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.7.1] - 2026-08-06

### Added
- **Cross-process concurrency controls** - added cross-platform reader/writer coordination, interruptible busy-timeout waits, one-writer/multiple-reader visibility guarantees, and real threaded and child-process contention tests.
- **Schema evolution** - added `ALTER TABLE RENAME TABLE`, `ALTER TABLE RENAME COLUMN`, and the safe no-rewrite subset of `ALTER TABLE ADD COLUMN`, with reopen, migration, statement-expiration, and failure-atomicity coverage.
- **Composite and deferred foreign keys** - added multi-column foreign-key matching and initially deferred constraint checks at commit.
- **Bounded blob slice access** - added transaction-aware blob handles for bounded reads and same-length writes. The current implementation materializes the complete value for each operation; storage-level incremental I/O remains future work.
- **Online backup consistency** - backups now capture one complete committed snapshot while coordinating with concurrent writers.
- **Operational evidence** - added matched-durability SQLite comparison workloads and machine-readable database-growth, WAL-amplification, checkpoint-cost, and allocator-use measurements.
- **Self-hosted Linux release validation** - expanded concurrency, storage, advanced, C ABI, package-consumer, and default-build coverage on the repository's Linux x86_64 runner.

### Changed
- **WAL writer reservation** - writable databases now use a dedicated `<database>-writer` sidecar, separate from WAL I/O, so Windows readers can recover committed WAL records while another process owns the writer reservation.
- **File-backed connection behavior** - independent connections and pooled connections now coordinate writers and refresh stale result, plan, schema, and index state after committed changes.
- **VACUUM implementation** - `VACUUM` now rebuilds live rows, indexes, FTS metadata, and catalog state into a validated compact image before atomically replacing the database file.
- **CLI failure behavior** - invalid SQL, missing option arguments, and unknown arguments now produce stable errors and non-zero exit status instead of reporting success.
- **Coverage reporting** - coverage collection now fails closed when the collector reports zero valid project lines, preventing misleading empty coverage artifacts from being published.
- **Toolchain requirement** - updated the pinned minimum Zig development toolchain used by local, CI, install, and release validation paths.

### Fixed
- **Windows WAL lock violations** - separated writer reservation locking from positional WAL reads, fixing cross-process recovery failures on Windows.
- **Prepared DML reuse** - verified reusable prepared INSERT and DELETE statements correctly consume rebound values without requiring a reset between executions.
- **C ABI handle lifetime** - statement handles now retain parent-connection identity and reject use after their connection closes; expanded double-close, double-finalize, stale-handle, null-bind, and repeated-result-free coverage.
- **Transactional failure semantics** - failing autocommit statements roll back atomically, invalid transaction transitions fail explicitly, and writer waits remain cooperatively interruptible.
- **Schema and result invalidation** - existing readers and prepared statements no longer retain stale state after another connection commits DML, DDL, or an atomic database replacement.
- **Advanced index persistence** - supported partial and expression index definitions, enforcement state, and planner metadata survive close and reopen.

### Verified
- `zig build check --summary all`
- `zig build test-c-api --summary all`
- `bash scripts/test-release-package.sh`
- `./scripts/sqlite-comparison.sh`
- Full Linux x86_64 release sweep on the self-hosted runner
- C99, C++, and Zig release-package consumer smoke tests

## [1.7.0] - 2026-06-24

### Added
- **Release documentation and packaging discipline** - reorganized docs around supported claims, release workflows, install paths, compatibility matrices, and stable/experimental boundaries.
- **Storage and durability APIs** - added explicit checkpoint/WAL statistics, backup/snapshot support, read-only and immutable open modes, busy timeout controls, and cooperative operation interruption.
- **Resource limits and progress callbacks** - added connection-level scanned-row, result-row, affected-row, VM-step, statement-size, pager page-count, pager cache-page, and query-materialization memory limits plus cooperative progress callbacks for cancellable embedded execution.
- **Integrity checking and recovery hardening** - added `Connection.integrityCheck()`, `PRAGMA integrity_check`, table/index metadata validation, and torn-WAL commit coverage so interrupted WAL records do not replay as committed data.
- **Cursor-style query API** - added `Connection.openCursor()` / `Cursor` for row-by-row query iteration semantics, including an incremental simple-table scan path for `SELECT * FROM table` and materialized fallback for richer SQL.
- **VACUUM maintenance and compact copy-out** - added a conservative `VACUUM` implementation plus `Connection.vacuumInto(...)` for maintenance, integrity validation, and flushed compact backup copies.
- **Application schema-version and migration primitives** - added persistent `user_version`/`schema_version` metadata, `PRAGMA user_version`, `PRAGMA schema_version`, Zig getters/setters, and a `user_version`-backed migration manager with rollback coverage.
- **Prepared statement schema invalidation** - prepared statements now capture `schema_version`, expose expiration checks, and fail with `error.PreparedStatementExpired` after schema-changing DDL instead of running a stale plan.
- **SQLite-class correctness coverage** - expanded tests for WAL recovery, catalog format recovery, read-only behavior, deterministic parser fuzzing, B-tree/storage properties, randomized concurrent access, and statement-level SQL conformance.
- **PostgreSQL-style SQL subset** - added tested support for generated columns, partial indexes, expression indexes, richer JSON helpers, timestamp/date arithmetic, user-defined scalar functions, and user-defined aggregate functions.
- **Planner statistics and planning visibility** - added `ANALYZE`, connection-local planner table/index statistics, `PRAGMA planner_stats`, analyzed unique equality-index selection, and `EXPLAIN QUERY PLAN` output that shows real plan steps with index scan row/cost estimates.
- **Schema-qualified attached database SQL** - added execution coverage for `schema.table` DDL/DML against attached databases, including `CREATE TABLE`, `CREATE INDEX`, `DROP INDEX`, `INSERT`, `SELECT`, `UPDATE`, `DELETE`, and `DROP TABLE`.
- **Security and experimental-boundary cleanup** - made secure-mode behavior, ATTACH policy, experimental crypto/transport positioning, and PQC capability claims more explicit and testable.
- **PQC verification model** - added explicit unavailable, classical fallback, simulated, hybrid-active, and PQC-active states plus a focused `zig build test-pqc` target for deterministic capability and negative-path tests.
- **Machine-readable PQC diagnostics** - added JSON diagnostics through Zig, C, and CLI surfaces so release tooling can inspect requested mode, selected state/backend, provider name, fallback reason, production readiness, and algorithm availability.
- **Experimental stdlib PQC backend** - added a direct Zig stdlib-backed ML-KEM-768 / ML-DSA-65 provider with deterministic key generation, encapsulation/decapsulation, signing/verification, malformed-input checks, and `CryptoInterface` integration when `-Dcrypto=true` and PQC/hybrid mode is requested.
- **PQC backend interface and fixture harness** - added a provider-shaped `PQCBackend` interface, backend-agnostic deterministic/KAT fixture runners, and a gated liboqs placeholder provider for future optional integration without linking liboqs by default.
- **liboqs provider-selection diagnostics** - added explicit `auto`/`stdlib`/`liboqs` provider preference plumbing, fail-closed liboqs requests, `configured_but_unlinked` diagnostics for `-Dliboqs=true`, and C API visibility through `zqlite_pq_liboqs_status()`.
- **PQC verification hardening** - added fixture-file KAT loading, checked-in PQC fixture-format directories, provider lifecycle/status helpers, algorithm policy validation, and zeroization of owned secret-key/shared-secret buffers.
- **Official PQC vector import lane** - added `tests/standalone/fixtures/pqc/official/`, a manifest, provenance rules, and `scripts/import-pqc-kats.sh` so real ML-KEM/ML-DSA KAT vectors can be imported without changing backend test logic.
- **liboqs build diagnostics** - added diagnostic-only `-Dliboqs-include-path` and `-Dliboqs-library-path` options for future liboqs detection/linkage without linking liboqs in this release.
- **Generated PQC regression KAT lane** - added `zig build generate-pqc-regression-kats`, checked-in generated stdlib ML-KEM/ML-DSA regression fixtures, and `zig build test-pqc-generated-kats` so backend behavior can be locked down separately from official NIST vectors.
- **PQC fixture tooling** - added `zig build validate-pqc-fixtures` for fixture manifest/field checks and `zig build build-liboqs-kat-converter` as a compile-checked scaffold for normalizing future liboqs KAT output into ZQLite fixture files.
- **PQC release-package diagnostics** - packaged Zig and C consumers now verify PQC availability, backend, provider, liboqs status, and diagnostics JSON from the release archive.
- **Self-hosted coverage reporting** - added stable-core coverage scope documentation, `scripts/coverage-report.sh`, and a self-hosted CI artifact job for the stable database-core coverage workload.
- **Operational benchmark evidence** - added `zig build bench-operational` for append-heavy, indexed lookup, materialized scan, cursor scan, and resource-limit abort timing evidence outside correctness gates.
- **Long-running storage stress target** - added `zig build test-storage-stress` for deterministic reopen/checkpoint/rollback/integrity cursor stress coverage.
- **Release artifacts with integrity metadata** - added release artifact generation for source packages, SBOM output, checksum manifests, and optional minisign/GPG detached signatures.
- **Release artifact verification** - added `scripts/verify-release-artifacts.sh` to validate checksums, archive contents, SBOM contents, and optional detached signatures.
- **Official PQC KAT execution target** - added `zig build test-pqc-official-kats`, which runs imported official ML-KEM/ML-DSA `.kat` files and skips cleanly when no official vectors are present.
- **PQC review notes** - added explicit PQC claim mapping, validation commands, non-claims, and promotion blockers for the experimental crypto layer.
- **C/Zig consumer validation** - added or strengthened C99/C++ package consumer tests, ABI/header checks, stable profile checks, and release archive/install-script validation helpers.
- **C ABI symbol governance** - added `include/zqlite_c.symbols`, manifest/header/implementation/shared-library export checks, and a previous-release ABI compatibility harness.
- **Packaged C ABI manifest checks** - release package validation now installs and verifies the public C symbol manifest alongside `zqlite.h`, `libzqlite_c.a`, and `libzqlite_c.so`.

### Changed
- **PostgreSQL positioning** - documented ZQLite as a selective PostgreSQL-inspired embedded SQL engine, not a PostgreSQL wire-compatible server, catalog clone, or extension-compatible runtime.
- **PQC and transport messaging** - moved placeholder or simulated cryptography claims behind experimental language; the stdlib ML-KEM/ML-DSA adapter is real but remains experimental until official vectors, review notes, and release-package evidence are present.
- **Performance baseline metadata** - refreshed benchmark baseline metadata for 1.7.0 while keeping correctness gates separate from low-noise benchmark validation.
- **Planner behavior** - SELECT planning now receives connection-local `ANALYZE` stats and can choose a cheaper analyzed unique index lookup for equality predicates while preserving a filter step for SQL semantics.
- **Secure-by-default example** - the stable secure example now combines prepared statements, resource limits, secure ATTACH policy checks, schema-qualified attached database SQL, transaction helpers, and durable flush behavior.
- **Configurable plan cache** - `ConnectionOptions.plan_cache_entries` and `setPlanCacheCapacity()` now allow applications to size or disable the per-connection plan cache.
- **Transaction isolation contract** - documented the file-backed isolation contract: uncommitted writes are hidden from other connections, and committed changes are visible after opening or reopening a reader.
- **Transactional pager flushing** - file-backed pager flush behavior now treats active transactions as a hard boundary, preventing dirty page eviction/flush before commit or rollback.
- **Repo-local scratch defaults** - standalone storage tests and release/install helper scripts now default isolated scratch work to the project's normal `.zig-cache` instead of the system temp tree.

### Fixed
- **Generated column execution** - generated values are computed on INSERT/UPDATE, direct writes to generated columns are rejected, and generated columns interact with default values and projection consistently.
- **Advanced index enforcement** - partial unique indexes enforce only rows matching the predicate, and expression unique indexes enforce deterministic same-row expression keys for the supported subset.
- **JSON/date function evaluation** - row-context function calls now handle supported JSON extraction/type/length/object helpers and UTC Gregorian date/time arithmetic more accurately.
- **Grouped aggregate coverage** - added SQL conformance coverage for grouped `COUNT`/`SUM` ordering behavior.
- **C API misuse coverage** - added tests for null handles, invalid result access, invalid bind indexes, reset/finalize null handling, and blob misuse return codes.
- **C ABI handle registry** - C handles are tracked through a live-handle registry so repeated finalize/free and stale-handle access return misuse/null results instead of blindly dereferencing finalized pointers.
- **SQLite differential expansion** - expanded opt-in SQLite differential coverage for transaction rollback/commit behavior, DESC pagination ordering, multi-column `ORDER BY`, and JSON/date literal round-trips.
- **Cursor projection and predicate scans** - simple cursor scans now incrementally handle projected columns and simple `WHERE` comparisons against literals or bound prepared-statement parameters.
- **Prepared statement cursor iteration** - prepared statements now expose `openCursor()` with the same incremental simple-scan path and materialized fallback as connection-level cursors.
- **File-backed dirty-read isolation** - transactional dirty database pages are no longer flushed before commit, and catalog/index metadata rewrites are deferred to the commit boundary so other file-backed connections cannot read uncommitted rows.
- **Transactional metadata persistence** - file-backed catalog/index metadata rewrites now defer during active transactions and persist at commit, preserving rollback behavior and preventing mid-transaction catalog flushes.
- **C PQC availability predicate** - `zqlite_pq_available()` now reports the same strict production-readiness predicate as `PQCapability.isAvailable()`.
- **C API ownership and misuse hardening** - added coverage for returned string ownership, blob bind/result ownership, stale connection/result/statement handles, invalid column access, double finalize/free-style misuse, and allocation-failure paths.
- **Index scan ownership** - fixed an intermediate-row cleanup leak exposed by planner-selected index scans.
- **Resource-limit abort cleanup** - partial VM results are now cleaned up when execution stops early due to limits, timeouts, interrupts, or progress-callback cancellation.
- **Attached schema routing** - qualified table references now route storage operations to the selected attached database instead of only resolving tables on the main connection.
- **`EXPLAIN QUERY PLAN` parsing** - parser now accepts the tokenizer's dedicated `QUERY` and `PLAN` tokens instead of treating them as generic identifiers.

### Verified
- `zig build test-sql-conformance --summary all`
- `zig build test-sqlite-diff --summary all`
- `zig build test-comprehensive --summary all`
- `zig build test-storage --summary all`
- `zig build test-transaction --summary all`
- `zig build test-file-backed --summary all`
- `zig build test-storage-properties --summary all`
- `zig build test --summary all`
- `zig build examples --summary all`
- `./zig-out/bin/secure_by_default_app`
- `zig build test-c-api --summary all`
- `zig build check-c-api --summary all`
- `./scripts/check-c-api.sh`
- `zig build test-pqc --summary all`
- `zig build -Dcrypto=true test-pqc --summary all`
- `zig build -Dliboqs=true test-pqc --summary all`
- `zig build -Dcrypto=true -Dliboqs=true test-pqc --summary all`
- `zig build -Dliboqs=true -Dliboqs-include-path=/opt/oqs/include -Dliboqs-library-path=/opt/oqs/lib test-pqc --summary all`
- `zig build generate-pqc-regression-kats --summary all`
- `zig build test-pqc-generated-kats --summary all`
- `zig build validate-pqc-fixtures --summary all`
- `zig build build-liboqs-kat-converter --summary all`
- `zig build bench-operational --summary all`
- `zig build -Dliboqs=true test-c-api --summary all`
- `zig build -Dcrypto=true -Dliboqs=true test-c-api --summary all`
- `zig build test-release-package --summary all`
- `zig build bench-validate --summary all`
- `./scripts/build-release-artifacts.sh`
- `./scripts/check-abi-compat.sh zig-out/release/zqlite-source-package.tar.gz`
- `./scripts/verify-release-artifacts.sh`
- `./scripts/coverage-report.sh`
- `git diff --check`

## [1.6.9] - 2026-06-21

### Fixed
- **Prepared UPDATE parameter binding** - folded in PR #2 from TanGentleman (Tan), who identified that `UPDATE ... SET col = ?` stored an unresolved parameter placeholder instead of the bound value.
  - Added regression coverage for positional prepared parameters in UPDATE SET assignments.
  - Added regression coverage for named prepared parameters in UPDATE SET assignments using `:name`, `@name`, and `$name`.
- **SQL escaped single quotes** - folded in PR #2 tokenizer behavior from TanGentleman (Tan) so SQL-standard escaped string literals such as `'it''s Alice'` decode and compare as `it's Alice`.
  - Added tokenizer unit coverage for escaped quotes, trailing escaped quotes, and empty string literals.
  - Added execution coverage for escaped string literals in INSERT/SELECT paths.
- **Transport connection IDs** - folded in PR #3 from TanGentleman (Tan), who identified that timestamp-derived transport connection IDs could be zero or duplicate.
  - Connection IDs are now non-zero and distinct for multiple connections created in the same second.
  - Added transport regression coverage for multiple non-zero distinct connection IDs.
- **Darwin clock compatibility** - folded in PR #3 runtime compat behavior from TanGentleman (Tan), adding macOS/iOS/tvOS/watchOS/visionOS `clock_gettime` handling instead of falling back to zero timestamps.
- **v1.6.8 release validation regression** - fixed the benchmark gate that caused the v1.6.8 CI release validation to fail on the self-hosted runner when SELECT throughput measured `451 ops/sec` against a hard `500 ops/sec` floor.
  - Benchmark validation now keeps target thresholds visible, reports median/p95, warns below target, and hard-fails only on severe regressions below 50% of target.
  - This preserves benchmark signal without making the release gate fail on normal runner variance.

### Verified
- `zig fmt --check src/ tests/ build.zig`
- `zig build check --summary all`
- `zig build test-sqlite-diff --summary all`
- `zig build bench-validate --summary all`

## [1.6.8] - 2026-06-21

### Added
- **Authoritative release validation target** - `zig build check` now runs the stable release validation gate used for local release confidence.
- **Explicit SQLite differential target** - added `zig build test-sqlite-diff`, an opt-in compatibility suite that requires `sqlite3` on `PATH` and compares ZQLite behavior against SQLite for the currently supported subset.
- **SQL compatibility matrix** - added `tests/sql_compatibility.tsv`, `scripts/generate-sql-compat-matrix.sh`, and `docs/sql-compatibility.md` to make supported/partial/unsupported SQL behavior explicit and machine-readable.
- **DML savepoint support** - implemented `SAVEPOINT`, `RELEASE [SAVEPOINT]`, and `ROLLBACK TO [SAVEPOINT]` for row-level changes.
  - Covered nested savepoints, rollback-to-inner-savepoint behavior, release semantics, outer-savepoint implicit commit, file-backed/WAL persistence, FK cascade rollback, and unique-index refresh after rollback.
  - Schema/catalog changes inside active savepoints now fail explicitly with `error.UnsupportedDDLInSavepoint` rather than pretending DDL rollback is supported.
- **Named prepared-statement parameters** - added `:name`, `@name`, and `$name` parsing/binding support.
  - Zig prepared statements now support `bindNamed(...)`, including repeated-name binding.
  - C ABI now exposes `zqlite_bind_int_named`, `zqlite_bind_text_named`, `zqlite_bind_real_named`, `zqlite_bind_null_named`, and `zqlite_bind_blob_named`.
- **Stable public error categories** - added Zig `ErrorCategory` / `categorizeError(...)` and C `zqlite_errcategory(...)` with category constants for application-level error branching.
- **C ABI metadata and row access** - added explicit ABI version exports, symbol visibility controls, prepared-statement row stepping, typed column access, column names, blob binding, and package-consumer coverage for C99/C++ modes.

### Changed
- **Standalone file-backed tests now use repo-local cache scratch** - replaced hardcoded system temp paths and brittle cleanup lists with unique per-run directories under the project-local Zig cache and single tree cleanup.
- **Benchmark validation is less noisy and more defensible** - benchmark validation now uses a monotonic clock, warmups, five samples, median/p95 reporting, isolated UPDATE measurements, and one in-source threshold table.
- **Public API ownership docs** - documented result/row/value ownership and borrowing rules for the Zig API.
- **C API docs** - documented prepared-statement stepping, borrowed/caller-freed ownership, named binding functions, ABI versioning, and error categories.
- **SQLite compatibility docs** - updated the compatibility docs for SAVEPOINT, named parameters, foreign-key actions, DEFAULT VALUES, and explicitly unsupported DDL savepoint rollback.

### Fixed
- **Durability and storage error handling** - stopped suppressing critical WAL checkpoint, metadata save, pager flush, and sync errors.
  - Added fallible flush/close semantics and tests for injected write, sync, WAL, checkpoint, and recovery failures.
  - Preserved the rule that a durable commit record remains committed even if later checkpoint/flush work fails.
- **Metadata catalog scalability and integrity** - replaced fixed single-page metadata with a versioned multi-page catalog, checksums, feature flags, explicit format-version checks, and legacy migration coverage.
- **UNIQUE semantics** - UNIQUE indexes and constraints now treat NULL values as distinct.
  - Inline column `UNIQUE` and table-level `UNIQUE(...)` constraints are planned, enforced through persisted auto-indexes, and verified across close/reopen.
- **CHECK constraints** - column/table CHECK constraints are now planned, persisted, and enforced on INSERT/UPDATE using SQL semantics where only FALSE rejects and UNKNOWN/NULL passes.
- **Foreign keys** - implemented supported single-column FK enforcement.
  - Child INSERT/UPDATE parent existence is checked.
  - Parent DELETE/UPDATE RESTRICT/NO ACTION is enforced.
  - `ON DELETE CASCADE`, `ON DELETE SET NULL`, and `ON UPDATE CASCADE` are executed and covered by file-backed and differential tests.
- **NULL three-valued logic** - fixed NULL propagation for `IN`, `LIKE`, `AND`, and `OR`; WHERE treats UNKNOWN as non-matching and CHECK allows UNKNOWN.
- **INSERT DEFAULT VALUES and function defaults** - added `INSERT ... DEFAULT VALUES` and verified literal/function defaults including `CURRENT_TIMESTAMP` on partial inserts and close/reopen.
- **C ABI behavior** - `zqlite_step` now returns row/done semantics instead of discarding result rows, and the C ABI allocator uses a thread-safe `SafeAllocator`.
- **Public OpenOptions duplication** - top-level `OpenOptions` is now the active `db.ConnectionOptions` alias.

### Verified
- `zig fmt --check src/ tests/ build.zig`
- `zig build check --summary all`
- `zig build test-sqlite-diff --summary all`
- C ABI header/export/constant consistency check
- C package consumer smoke tests in C99 and C++ modes

## [1.6.7] - 2026-06-12

### Fixed
- **`ON CONFLICT DO UPDATE SET col = excluded.col` now parses** - the `EXCLUDED` keyword was tokenized but had no expression handler, so any upsert referencing the pseudo-table failed with `error.ExpectedValue`
  - `parsePrimaryExpression` and `expectIdentifierOrKeyword` now treat `.Excluded` as an identifier, allowing `excluded.<column>` to parse as a qualified column reference
- **Upsert `excluded.*` resolved against the wrong row** - the executor evaluated `excluded.<col>` against the existing (pre-conflict) row instead of the would-be-inserted row, producing stale/`NULL` values
  - Added `evaluateUpsertAssignment` in the VM, which resolves `excluded.<col>` against the new insert values and falls back to normal expression evaluation for all other RHS forms
  - Columns omitted from the `SET` list are preserved unchanged
- **Parser error-path memory leak in `parseOnConflict`** - partially-built `target_columns` and assignment lists leaked when an upsert clause failed to parse
  - Added `errdefer` cleanup for the target column slice and assignment contents, plus explicit per-iteration `catch` handling to free the in-flight column/expression without double-freeing

### Added
- **`tests/standalone/test_upsert.zig`** - standalone regression suite (GPA leak-checked) mirroring the prepared-statement + bound-parameter upsert path: parameterized `excluded.*`, literal `excluded.*`, integer columns, mixed literal/`excluded` SET lists, and non-SET column preservation
- **`UPSERT WITH excluded.*`** case added to the comprehensive test runner (`tests/unit/sqlite_functionality_test.zig`)
- Wired `test_upsert` into `docker/scripts/test-critical.sh` and `docker/scripts/run-valgrind.sh`

### Changed
- **docker-compose** - `zqlite-valgrind` and `zqlite-audit` services now pass `ZIG=/opt/zig-dev/zig` so the valgrind/audit scripts locate the toolchain (previously failed with `zig: not found`)

### Verified
- `zig build`
- `zig build test`
- `zig build test-comprehensive` (27/27, incl. `UPSERT WITH excluded.*`)
- `zig build test-advanced`
- `zig build test-memory`
- docker compose: `critical`, `valgrind` (incl. `test_upsert`, audit clean), `stress` (27/27 + benchmarks), `full-validation`, `file-storage`, `chaos` (10 iterations, no flakes)

## [1.6.6] - 2026-06-01

### Fixed
- **Parser error-path memory leaks** - `parseSimpleSelect` and `parseSelect` now release partially-built AST allocations on every failure path
  - Previously `defer list.deinit()` freed only the `ArrayList` backing buffer, leaking dup'd column names/expressions, table names, and join/where/group-by/having/order-by/window contents when a parse failed partway
  - Added `errdefer` cleanup matching the existing `parseWindowDefinitions` pattern, including ownership-transfer-aware handling for compound `UNION`/`INTERSECT`/`EXCEPT` selects so `left_select` and the `left`/`right` boxes are freed exactly once
  - Surfaced by the SQL parser fuzzer: 50,000 random parses (~20% malformed) now report zero leaks
- **Zig nightly compatibility** - Restored `zig build` and all test/bench/fuzz targets on Zig `0.17.0-dev.639+284ab0ad8`
  - `build.zig` run step uses `addPassthruArgs()` (replaces removed `b.args`)
  - `src/logging/logger.zig` imports the owned `runtime/compat/thread.zig` directly instead of the fragile `@import("root").compat` fallback
  - `tests/fuzz/fuzz_example.zig` updated for the new `std.testing.fuzz` `Smith` API
  - `tests/fuzz/sql_parser_fuzzer.zig` seeds from `zqlite.time_utils` instead of the removed `std.posix.clock_gettime`
- **Logger timestamp formatting** - ISO-8601 time fields no longer render a spurious `+` sign (e.g. `T+22:+28:+23`); signed components are cast to unsigned for the new `{d:0>2}` formatting behavior
- **`--version` output** - Removed duplicated prefix that printed `ZQLite ZQLite v1.6.6`; now prints `ZQLite v1.6.6`

### Changed
- **Minimum Zig version** - Updated package metadata to require `0.17.0-dev.639+284ab0ad8`

### Verified
- `zig build`
- `zig build test`
- `zig build test-memory`
- `zig build test-comprehensive`
- `zig build test-advanced`
- `zig build test-security`
- `zig build test-storage`
- `zig build test-window`
- `zig build test-logging`
- `zig build fuzz-parser` (zero leaks across repeated runs)

## [1.6.5] - 2026-05-12

### Fixed
- **Zig latest compatibility** - Replaced removed Zig stdlib sentinel-allocation helpers in active file-backed and FFI code paths
  - `src/db/pager.zig` now uses `dupeSentinel(..., 0)`
  - `src/db/wal.zig` now uses `dupeSentinel(..., 0)`
  - `src/ffi/c_api.zig` now uses `dupeSentinel(..., 0)`
- **Current toolchain buildability** - Restored `zig build` and `zig build test` compatibility on newer Zig `0.17.0-dev` toolchains
- **Runtime cancellation lifetime** - Prevented executor-backed futures from completing cancellation before worker teardown finishes
  - Fixes the `runtime semaphore waitWithToken cancels blocked waiter` crash seen during release validation
  - Worker-owned cancellation cleanup now finishes before the future can be torn down

### Changed
- **Minimum Zig version** - Updated package metadata to require `0.17.0-dev.292+fc1c83a36`
- **GitHub Actions runtime** - Updated workflow action pins to Node 24-capable versions
  - `actions/checkout@v6`
  - `actions/upload-artifact@v7`
  - `actions/download-artifact@v8`
  - `softprops/action-gh-release@v3`
- **Nightly validation** - Added a host-runner nightly workflow aligned with the native validation model used in adjacent repos

### Verified
- `zig build`
- `zig build test`
- `zig test src/runtime/semaphore_test.zig`
- `zig build test-security`
- `zig build test-storage`
- `zig build test-comprehensive`
- `./scripts/test-release.sh`

## [1.6.4] - 2026-05-04

### Fixed
- **Zig dev parser/build compatibility** - Removed remaining repeat-expression and stale syntax hazards across active source, examples, and test targets
  - Fixes current `/opt/zig-dev/zig build` failures triggered by array/string repeat-expression parsing in touched files
- **C API version export** - `zqlite_version()` now returns a sentinel-terminated string as required by the exported C ABI

### Changed
- **Runtime ownership** - Removed the external `zsync` dependency and replaced it with an internal `zqlite` runtime layer
  - Added owned compatibility/time primitives in `src/runtime/compat/thread.zig`
  - Added owned typed futures, channels, task spawning, timeout, and yield/sleep helpers under `src/runtime/`
  - Rewired concurrency/distributed code paths to the internal runtime surface
- **Version source of truth** - Runtime version strings now come from `build.zig.zon` via `build_options`
  - Fixes the previous hardcoded `src/version.zig` drift from package metadata

### Verified
- `zig build`
- `zig build test`
- `zig build test-security`
- `zig build test-storage`
- `zig build test-comprehensive`
- `zig build test-advanced`

## [1.6.2] - 2026-04-13

### Fixed
- **Build metadata portability** - Changed from dynamic git/date shell commands to static values
  - Ensures builds work from source archives and non-git environments
  - `git_commit` set to "release", `build_date` updated at release time
- **File-backed metadata persistence after B-tree root splits** - Closing non-transaction file-backed connections now saves refreshed table metadata before pager flush/deinit
  - Fixes the `100 inserted -> 31 visible after reopen` failure reproduced by `tests/standalone/test_concurrent_access.zig`
  - Large file-backed datasets now retain the correct root page and row count across close/reopen cycles
- **Normal index correctness across create/reopen/write cycles** - Persisted index definitions now rebuild and refresh index contents from live table rows
  - Fixes normal indexes loading with definitions present but stale or empty contents after reopen
  - Fixes indexed lookups missing rows inserted after create or after reopening a file-backed database
- **Unique index persistence after reopen** - Unique index definitions now round-trip through metadata and continue enforcing uniqueness after close/reopen
  - Prevents duplicate inserts from succeeding after reopening a database with persisted unique indexes
- **FTS virtual-table persistence** - FTS table identity and indexed columns now persist across close/reopen cycles
  - Reopened file-backed FTS tables retain `MATCH` behavior and continue indexing new inserts
- **Column default persistence** - Column literal and function defaults now survive file-backed close/reopen cycles
  - Reopened schemas retain default metadata for inserts and `PRAGMA table_info`
- **Identifier handling for aggregate-keyword names** - Parser now accepts names like `count` consistently in non-aggregate identifier positions
  - Fixes `CREATE TABLE counter (id INTEGER, count INTEGER)`
  - Fixes `INSERT INTO counter (id, count) VALUES (...)`
  - Fixes `UPDATE counter SET count = count + 1 ...`
  - Fixes bare column queries like `SELECT count FROM counter WHERE id = 1`
- **FTS MATCH boolean parser hang** - Phrase and boolean `MATCH` queries no longer spin indefinitely on non-matching rows
  - Fixes an infinite loop caused by short-circuit parsing logic that failed to advance the token cursor
  - Validates quoted phrases and `AND` / `OR` / `NOT` matching on FTS queries
- **Named WINDOW clause support and window execution ordering** - Named window definitions now survive parse/plan/prepared-statement paths and window ranking respects per-partition ordering
  - Fixes `WINDOW name AS (...)` clauses being dropped before execution
  - Fixes prepared statements using named windows on stable SQL paths
  - Fixes partitioned window ranking using scan order instead of window `ORDER BY`

### Changed
- **Production-readiness messaging cleanup** - Removed misleading claims from examples and source
  - `examples/production_database_server.zig` - renamed to "Database Server Example"
  - `examples/cipher_dns.zig` - removed "Ready for integration" claim
  - `examples/improved_api_demo.zig` - removed production-ready claim
  - `examples/nextgen_database.zig` - removed "SQLite killer" and production claims
  - `examples/simple_api_test.zig` - removed "Ready for integration" claim
  - `examples/insert_memory_regression_test.zig` - removed production-ready claim
  - `src/crypto/secure_storage.zig` - removed "Production-ready" from comment
  - `src/concurrent/secure_storage.zig` - removed "Production-ready" from comment
  - `src/concurrent/async_operations.zig` - removed "Production-ready" from comment
- **Documentation accuracy** - Updated docs to reflect actual project state
  - `docs/project/release-process.md` - updated for static build metadata
  - `docs/project/maintainer-workflow.md` - updated build metadata section, status levels
  - `docs/experimental/overview.md` - changed "Production Ready" column to "Usable"
- **Experimental roadmap accuracy** - `docs/experimental/overview.md` now reflects completed `v1.6.x` near-term work and current FTS/query-cache behavior
- **Query cache invalidation coverage** - Cache invalidation now includes schema mutations for the affected table, not only row writes
- **Cluster health evaluation** - Cluster health now evaluates node staleness from `last_seen` timestamps instead of only reporting static status snapshots
- **Memory test target layout** - Redundant memory-related build targets were reduced by reusing the primary leak/regression suites behind existing step names
- **Release hardening coverage** - Stable file-backed, index, FTS, default-value, prepared-statement, and window-function paths received narrow hostile verification before release

### Added
- **Build profile documentation** - Added to `docs/project/maintainer-workflow.md`
  - Documents `core`, `advanced`, `full` profiles and their feature sets
  - Shows how to use `-Dprofile=` and individual feature flags
- **Test target documentation** - Comprehensive table of all test targets
  - Categorized by purpose: core, storage, memory, advanced, benchmarks, fuzzing
- **Examples README** - Created `examples/README.md`
  - Categorizes examples as reference, experimental showcase, or domain-specific
  - Documents build requirements and usage notes
- **Standalone persistence regressions**
  - Added `tests/standalone/test_fts_persistence.zig`
  - Added `tests/standalone/test_default_persistence.zig`
  - Expanded `tests/standalone/test_index_persistence.zig` to verify actual index lookup behavior after reopen and post-reopen writes
- **Docker combined audit flow**
  - Added `docker/scripts/run-audit.sh`
  - Added dedicated `zqlite-audit` compose service on the Debian-based Valgrind image
  - Docker validation now includes a reproducible combined critical/full/Valgrind audit path

### Removed
- **Broken standalone tests**
  - `tests/standalone/test_production.zig` - broken APIs, misleading production claims
  - `tests/standalone/test_all_features.zig` - stale v0.8.0 references, broken APIs
- **Stale version strings** - Removed version litter from example files

## [1.6.1] - 2026-04-09

### Fixed
- **File-backed storage page ID conflict** - Metadata page (ID 1) was colliding with btree root pages
  - Pager now starts `next_page_id` at 2 for file-backed storage, reserving page 1 for metadata
  - Fixes `OrderMismatch` error when executing SELECT after CREATE TABLE on file-backed databases
- **Data persistence across connections** - Btree root page and row count now saved to metadata
  - Added `root_page` (4 bytes) and `row_count` (8 bytes) to table metadata format
  - `Table.load()` function to restore tables from existing btree pages
  - `BTree.loadFromRootPage()` function to attach to existing btree structures
  - Data now survives database close/reopen cycles
- **Memory leak in loadTables** - Column allocations now freed after schema clone
- **Memory leaks on error paths** - Added `errdefer` cleanup in Connection and StorageEngine init
  - `Connection.openWithOptions()` now properly cleans up on failure
  - `StorageEngine.init()` and `initMemory()` now properly clean up on failure
- **Transaction ROLLBACK persistence** - WAL-based page restoration for proper rollback
  - BTree now supports transaction write callbacks for WAL integration
  - `rollbackWithPager()` physically restores pages from WAL old_data entries
  - DELETE/UPDATE operations now persist correctly across connections
  - Added `deleted_keys` to metadata format for logical delete persistence

### Added
- **File-backed storage test suite** - `tests/standalone/test_file_backed.zig`
  - Tests CREATE/INSERT/SELECT on file storage
  - Tests persistence across connection close/reopen
  - Tests UPDATE/DELETE operations
  - Tests multiple tables and large datasets (100+ rows)
- **Transaction atomicity test suite** - `tests/standalone/test_transaction_atomicity.zig`
  - Tests COMMIT persistence across connections
  - Tests ROLLBACK discards uncommitted changes
  - Tests complex nested operations (INSERT/UPDATE/DELETE)

## [1.6.0] - 2026-04-09

### Added
- **RETURNING clause** - PostgreSQL-style RETURNING for data modification statements
  - `INSERT ... RETURNING id, column1, *` returns inserted row values
  - `UPDATE ... RETURNING *` returns updated row values
  - `DELETE ... RETURNING id, name` returns deleted row values before removal
- **UPSERT / ON CONFLICT** - SQLite and PostgreSQL compatible upsert syntax
  - `ON CONFLICT DO NOTHING` - ignore conflicts silently
  - `ON CONFLICT (column) DO UPDATE SET ...` - update on conflict
  - `ON CONFLICT ... WHERE ...` - conditional updates
  - Full support combined with RETURNING clause
- **PQ capability introspection API** - Runtime post-quantum crypto status
  - `getPQCapability()` - detailed PQ algorithm availability
  - `getCryptoStatus()` - full crypto module status
  - `printPQStatus()` - diagnostic output for PQ features
  - Reports compilation status, enabled algorithms, backend type
- **Query result cache integration** - Connection now supports optional result caching
  - `setResultCache()` to attach a query cache
  - Automatic cache invalidation after INSERT/UPDATE/DELETE
- **Secure mode for connections** - New `ConnectionOptions` with `secure_mode` flag
  - `openWithOptions()`, `openMemoryWithOptions()`, `openWithSharedStorageAndOptions()` functions
  - When `secure_mode=true`, uses `SECURE_DEFAULT` ATTACH policy
  - Custom `attach_policy` option for fine-grained control
- **Standard security policy document** - Added `SECURITY.md` to project root

### Fixed
- **BTree deserialization for PostgreSQL types** - Added missing deserialize handlers for type tags 6-18
  - JSON, JSONB, UUID, Array, Boolean, Timestamp, TimestampTZ, Date, Time, Interval, Numeric, SmallInt, BigInt
  - Fixes serialization round-trip for PostgreSQL-compatible data types
  - Resolves edge case failures under stress tests with extended types
- **Query cache invalidation** - Cache entries now properly invalidated after write operations
  - `invalidateTable()` called automatically for INSERT/UPDATE/DELETE
  - Prevents stale cached query results after data modification
- **ATTACH path validation** - Segment-aware boundary checking prevents `/var/db` from matching `/var/database`
- **SQLite compatibility JSON extraction** - Changed `.Float` to `.Real` to match `storage.Value` union
- **FFI text binding memory leak** - Removed unnecessary intermediate allocation in `zqlite_bind_text()`
- **journal_mode ownership tracking** - Added `journal_mode_owned` field to prevent double-free on default static string
- **Example file API signatures** - Updated PQ examples to use correct `openMemory(allocator)` API
- **Example version references** - Updated examples from v0.5.0/v0.6.0 to v1.6.0

### Changed
- **Zig 0.17.0-dev baseline** - Updated package, install, Docker, and maintainer requirements to `0.17.0-dev.27+0dd99c37c`
- **Local tooling scripts** - Added `ZIG` environment override support so local runs, CI, and `/opt/zig-dev/zig` validation can share one baseline
- **Zig 0.16 compatibility** - Migrated all test files from `GeneralPurposeAllocator` to `DebugAllocator`
- **build.zig** - Fixed `test-quick` target path reference
- **Standalone test imports** - Updated to use module imports instead of relative paths
- **Docker environment modernized** - Stripped legacy Ghostwire FFI testing, now tests ZQLite directly
  - Updated Zig version to 0.16.0-dev.3133
  - Added `zqlite-valgrind` service for extensive memory leak detection
  - Added `scripts/test-release.sh` for local release validation
  - Added `scripts/valgrind-test.sh` for containerized valgrind testing
- **PQ messaging clarified** - Post-quantum crypto consistently described as experimental scaffolding
  - Removed all references to "Shroud" backend (never integrated)
  - Updated status messages: "PQ is experimental scaffolding" instead of "requires Shroud integration"
  - Cleaned CryptoBackend enum to only include `native` and `none`
  - Cleaned PQBackend enum to only include `none` and `native_fallback`

### Removed
- **Dead crypto implementation files** - Deleted `src/crypto/secure_storage_legacy.zig` and `src/crypto/secure_storage_v2.zig`
- **Shroud backend references** - Removed all Shroud backend assumptions from code, docs, and tests
- **Unused shroud import** - Removed dead `@import("shroud")` from test_production.zig

### Security
- Secure ATTACH path policy now available via `secure_mode` connection option
- Path boundary validation prevents prefix collision attacks
- Removed `curl | bash` one-liner from README in favor of verified installation

## [1.5.3] - 2026-02-12

### Added
- **Full-text search (FTS5)** - CREATE VIRTUAL TABLE ... USING fts5
  - FTSIndex with inverted index for fast term lookups
  - MATCH operator for full-text search queries
  - Case-insensitive tokenization and term matching
  - Multi-term AND search semantics
- **ATTACH DATABASE** - Multi-database support
  - ATTACH DATABASE 'file.db' AS schema_name
  - DETACH DATABASE schema_name
  - Schema-qualified table access across attached databases
  - Automatic cleanup of attached databases on connection close
- **Subquery support** - WHERE col IN (SELECT ...) and scalar subqueries in expressions
  - IN clause now supports both value lists and subqueries
  - Scalar subqueries for dynamic value comparisons
- **HAVING clause** - Filter aggregated results after GROUP BY
- **SELECT DISTINCT** - Remove duplicate rows from query results
- **Aggregate functions** - STDDEV, VARIANCE (population standard deviation and variance)
  - STDDEV_POP/STDEV aliases for standard deviation
  - VAR_POP alias for variance
  - GROUP_CONCAT now properly recognized as token
- **Query optimizer** - IndexScan execution step infrastructure
  - Index-based row lookup instead of full table scans
  - Fallback to table scan when index unavailable
  - Value-to-key conversion for index queries

### Changed
- Parser extended to handle DISTINCT keyword after SELECT
- Planner adds Distinct execution step for deduplication
- Query plan cache integration with Connection for improved performance
- Connection struct now manages attached databases HashMap

### Fixed
- **Memory leak fixes** - Added comprehensive errdefer cleanup throughout:
  - FTSIndex.create: proper cleanup on partial initialization failure
  - executeCreateVirtualTable: cleanup column allocations on error
  - attachDatabase: cleanup connection and key on HashMap insertion failure
  - parseCreateVirtualTable: cleanup table_name and module_name on parse errors
  - parseAttach: cleanup file_path on parse errors
  - executeIndexScan: cleanup cloned values on partial clone failure
  - executeTableScanFallback: cleanup cloned values on partial clone failure

### Technical
- Added Expression variants: Subquery, InList for flexible IN clause parsing
- Added HavingStep execution in VM after GROUP BY aggregation
- Hash-based row deduplication in executeDistinct with support for all Value types
- FTSIndex struct with inverted index using StringHashMap
- CreateVirtualTableStatement and CreateVirtualTableStep for FTS table creation

## [1.5.2] - 2026-02-12

### Fixed
- **ORDER BY column lookup bug** - Now properly resolves column names instead of always sorting by first column
- **Prepared statement parameter storage** - Parameters are now correctly stored and available for execution
- **Query callback implementation** - Thread-safe query with callback now iterates through result rows

### Added
- **Phase1 Engine** - Two-phase commit coordinator for distributed transactions
  - Lock acquisition and validation
  - Vote collection from participants
  - Timeout handling and recovery
  - Integration with MVCC transaction manager

### Changed
- **PQ-QUIC key derivation** - Now uses RFC 9001 compliant HKDF with connection_id instead of placeholder zeros
- **Post-quantum crypto fallback** - Gracefully falls back to Ed25519 with warning when PQ crypto unavailable
- **MVCC AsyncTransactionPool** - Documented resource ownership in deinit
- **Transport error handling** - Replaced `catch unreachable` with proper error propagation in pq_quic.zig

### Added Documentation
- **EXPERIMENTAL.md** - Comprehensive documentation of experimental feature limitations and roadmap

### Tests
- **Cluster manager integration tests** - Added 7 new tests covering node lifecycle, load balancing, health monitoring, query routing, memory cleanup, and shard management

### Compatibility
- Updated for Zig 0.16.0-dev.2535

## [1.3.5] - 2025-12-01

### Changed
- Pinned CI to Zig `0.16.0-dev.1484+d0ba6642b` for reproducible builds
- Reorganized project structure: moved test files to `tests/standalone/`
- Cleaned up root directory (removed build artifacts, temp files)
- Updated `.gitignore` to prevent future cruft accumulation

### Fixed
- Version mismatch between `build.zig.zon` and `src/version.zig`

## [1.3.4] - 2025-10-03

### Fixed
- **Critical B-tree OrderMismatch bug** - Now supports large datasets
  - Fixed missing `writeNode()` after `splitChild()`
  - Fixed array bounds checking in child index calculation
  - Validated with 5,000 row insertions (2,064 ops/sec)

## [1.3.3] - 2025-10-03

### Fixed
- Memory leaks in `planner.zig` (DEFAULT constraint handling)
- Double-free errors in `vm.zig` (`cloneStorageDefaultValue`)

### Added
- Memory leak detection in CI using `GeneralPurposeAllocator`
- Fuzzing infrastructure for SQL parser
- Fuzzing infrastructure for VM execution
- Structured logging system
- Comprehensive benchmarking suite
- Benchmark regression detection in CI

## [1.0.0] - 2025-09-01

### Added
- **Core SQL Engine**
  - Full CRUD operations: CREATE, INSERT, SELECT, UPDATE, DELETE
  - B-tree storage engine with Write-Ahead Logging (WAL)
  - SQL parser with AST generation
  - Query planner and VM executor
  - Prepared statements support

- **Advanced Indexing**
  - B-tree indexes for range queries
  - Hash indexes for O(1) lookups
  - Unique constraint indexes
  - Multi-column composite indexes

- **Post-Quantum Cryptography** (optional)
  - ML-KEM-768 key encapsulation
  - ML-DSA-65 digital signatures
  - Hybrid classical + post-quantum modes
  - Field-level encryption (ChaCha20-Poly1305)

- **Concurrency**
  - MVCC transaction isolation
  - Connection pooling
  - Thread-safe operations
  - Async database operations

- **Additional Features**
  - JSON data type support
  - C API / FFI for language bindings
  - In-memory and file-based databases
  - CLI shell interface

## [0.3.0] - 2025-06-23

### Added
- Advanced indexing system (B-tree, hash, composite)
- Cryptographic engine with AES-256-GCM, ChaCha20-Poly1305
- Async operations with connection pooling
- JSON support
- C API for FFI

### Changed
- Updated to Zig 0.15.0-dev compatibility

## [0.2.0] - 2025-05-01

### Added
- Basic SQL operations
- B-tree storage engine
- WAL support
- DNS/PowerDNS integration examples
- CLI interface

## [0.1.0] - 2025-03-01

### Added
- Initial release
- Basic embedded SQL database
- Core storage engine
- Simple query parser
