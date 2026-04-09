# ZQLite Docker Testing Results

Version: v1.6.1
Date: 2026-04-09
Platform: Alpine Linux (container) / Arch Linux (host)
Zig: 0.16.0-dev.3133

## Test Results Summary

| Test Suite | Tests | Status |
|------------|-------|--------|
| Unit Tests | 8/8 | PASS |
| Quick Validation | 5/5 | PASS |
| Security Tests | 10/10 | PASS |
| SQLite Functionality | 13/13 | PASS |
| Memory Management | 6/6 | PASS |
| Query Validation | 7/7 | PASS |
| Memory Leak Detection | 29/29 | PASS |
| Comprehensive Memory | 7/7 | PASS |
| Chaos Test (10 iterations) | 30/30 | PASS |
| Benchmark Validation | 4/4 | PASS |
| **File-Backed Storage** | **6/6** | **PASS** |

**Total: 125 tests, 0 failures**

## Performance Baseline

| Operation | Ops/sec | Threshold | Status |
|-----------|---------|-----------|--------|
| Simple INSERT | 14,186 | 1,000 | PASS |
| Bulk INSERT | 5,542 | 500 | PASS |
| SELECT query | 7,277 | 500 | PASS |
| UPDATE | 238 | 50 | PASS |

## How to Run Tests

```bash
cd /path/to/zqlite

# Quick unit tests
docker-compose -f docker/docker-compose.yml run --rm zqlite-test

# Memory leak tests
docker-compose -f docker/docker-compose.yml run --rm zqlite-memory

# Full validation (everything)
docker-compose -f docker/docker-compose.yml run --rm zqlite-full

# Stress test
docker-compose -f docker/docker-compose.yml run --rm zqlite-stress

# Chaos test (10 iterations, catch flakes)
docker-compose -f docker/docker-compose.yml run --rm zqlite-chaos

# Performance baseline
docker-compose -f docker/docker-compose.yml run --rm zqlite-perf

# File-backed storage tests
docker-compose -f docker/docker-compose.yml run --rm zqlite-file-storage

# Valgrind memory analysis
docker-compose -f docker/docker-compose.yml run --rm zqlite-valgrind
```

## Requirements

- Docker with compose
- Host Zig installation at `/opt/zig-0.16.0-dev`
- Host networking enabled (required for DNS resolution)

## Architecture

The Docker setup mounts the host Zig installation rather than downloading it in the container. This provides:

- Instant container startup (no build time)
- Consistent Zig version between host and container
- Minimal image size (Alpine base)

## Test Categories

### Unit Tests
Core functionality - parser, executor, storage, btree operations.

### Security Tests
- SQL injection protection (prepared statements, quote escaping, UNION, comments, null bytes)
- Parameter binding type safety
- WAL size limits and deserialization bounds
- JSON validation
- Sensitive data redaction

### Memory Tests
- Connection lifecycle (100+ open/close cycles)
- CREATE TABLE with DEFAULT constraints
- INSERT/UPDATE/DELETE operations
- Prepared statement reuse
- Large result sets
- Transaction rollback
- Multiple concurrent connections

### File-Backed Storage Tests (NEW in v1.6.1)
- CREATE TABLE and SELECT on file databases
- INSERT/SELECT with disk persistence
- Multiple tables in single database file
- **Persistence across connection close/reopen**
- UPDATE and DELETE with file storage
- Large datasets (100+ rows)

### Chaos Tests
Repeated test runs to catch flaky/intermittent failures. Default: 10 iterations.

### Benchmark Validation
Regression thresholds to catch performance degradation.

## Known Test Gaps (TODO)

### Critical - Must Add
- [ ] Multi-process concurrent file access
- [ ] Database file larger than pager cache (1000+ pages)
- [ ] Crash recovery / partial write handling
- [ ] Index persistence across connections

### Important
- [ ] Filesystem error handling (permissions, disk full, read-only)
- [ ] WAL mode file persistence
- [ ] Transaction atomicity with file storage
- [ ] Database file corruption detection

### Nice to Have
- [ ] Fuzz testing with AFL or libFuzzer
- [ ] Long-running soak tests (hours/days)
- [ ] Large dataset tests (1M+ rows)
- [ ] Cross-platform testing (Windows via WSL)
- [ ] Network partition simulation for replication
- [ ] Memory pressure tests with cgroups limits

## Known Limitations

- Valgrind may hit instruction incompatibility with Zig's native CPU target (AVX-512 etc.)
- Host networking required for DNS resolution during container builds
- Tests assume `/opt/zig-0.16.0-dev` path - adjust `docker-compose.yml` if different

## Fixes Validated in v1.6.1

- **File-backed storage page ID conflict** - Metadata page (ID 1) no longer collides with btree pages
- **Data persistence** - Btree root page and row count now saved/restored from metadata
- **Memory leak in loadTables** - Column name allocations now properly freed

## Fixes Validated in v1.6.0

- BTree deserialization for PostgreSQL types (tags 6-18)
- Query cache invalidation after write operations
- ATTACH path validation (segment-aware boundary checking)
- FFI text binding memory leak
- journal_mode ownership tracking
- Example file API signatures updated
