# Changelog

All notable changes to ZQLite will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
