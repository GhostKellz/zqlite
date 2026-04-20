# ZQLite Docker Testing Results

Date: 2026-04-13
Host: Arch Linux
Primary Docker test images: Alpine
Valgrind image: Debian bookworm-slim
Zig: `/opt/zig-dev` (`0.17.0-dev.27+0dd99c37c`)

## Current Status

- `docker compose -f docker/docker-compose.yml run --rm zqlite-critical`: PASS
- `docker compose -f docker/docker-compose.yml run --rm zqlite-full`: PASS
- `docker compose -f docker/docker-compose.yml run --rm zqlite-valgrind`: PASS
- `docker compose -f docker/docker-compose.yml run --rm zqlite-audit`: PASS

## Verified Fixes

- File-backed metadata persistence after B-tree root splits is fixed
- Aggregate-keyword identifier handling (`count`, etc.) is fixed across `CREATE TABLE`, `INSERT`, `UPDATE`, and bare `SELECT`
- Unique index persistence after reopen is fixed

## Validation Coverage

### Critical

- File-backed persistence
- Large database / cache overflow
- Transaction atomicity
- Concurrent access
- Index persistence
- Filesystem error handling

### Full

- Format check
- Core build
- Unit tests
- Quick validation
- Security tests
- Comprehensive tests
- Advanced tests
- C API tests
- Memory leak tests
- Comprehensive memory tests
- Benchmark validation
- File-backed storage tests
- Critical path tests

### Valgrind

- `test_security`
- `test_file_backed`
- `test_transaction_atomicity`
- `test_concurrent_access`
- `test_index_persistence`

## Valgrind Result

- Audit completed successfully
- No invalid reads/writes reported
- No leaks reported
- `ERROR SUMMARY: 0 errors from 0 contexts`

## Notes

- The normal Docker test stack remains Alpine-based.
- The Valgrind image uses Debian slim because the Alpine-based Valgrind path was not reliable enough for this workload.
- Valgrind log noise was reduced by using `--quiet`, log files, and summary extraction in `docker/scripts/run-valgrind.sh`.
- Additional Valgrind coverage now includes concurrency and index persistence regressions.
- The combined `run-audit.sh` flow should run on the Debian-based audit image, not the Alpine full-test image.
- Host networking remains required for both build `network: host` and runtime `network_mode: host` across the Docker services on this workstation.

## Suggested Next Improvements

- Expand Valgrind coverage to selected parser and large-dataset tests if runtime stays reasonable
- Add a lightweight machine-readable audit summary if CI ingestion becomes useful
