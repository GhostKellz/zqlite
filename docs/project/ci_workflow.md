# CI Workflow

## Current Pipeline

GitHub Actions CI runs on push/PR to main:

```
lint → build-test → [memory-tests, benchmarks, extended-tests]
```

### Jobs

| Job | Commands | Timeout |
|-----|----------|---------|
| lint | `zig fmt --check src/ examples/ tests/` | 10m |
| build-test | `zig build`, `zig build test` | 20m |
| memory-tests | `zig build test-create-table-leaks` | 15m |
| benchmarks | `zig build bench-validate` | 10m |
| extended-tests | `test-security`, `test-comprehensive`, `test-storage` | 15m |

### Available Build Targets

**Core:**
- `zig build test` - unit tests
- `zig build test-quick` - quick validation

**Extended:**
- `zig build test-security` - SQL injection, WAL limits, integrity
- `zig build test-comprehensive` - full functionality suite
- `zig build test-storage` - file-backed + transaction atomicity
- `zig build test-advanced` - stress, edge cases

**Memory:**
- `zig build test-create-table-leaks` - CREATE TABLE memory fixes
- `zig build test-memory-leaks` - general leak detection
- `zig build test-comprehensive-memory` - full memory suite

**Benchmarks:**
- `zig build bench` - performance benchmark
- `zig build bench-validate` - CI regression check

**FFI:**
- `zig build test-c-api` - C API tests

## Local Validation

Full release validation:

```bash
./scripts/test-release.sh
```

## Docker Testing

For local Docker validation on this workstation:

```bash
docker compose -f docker/docker-compose.yml run --rm zqlite-critical
docker compose -f docker/docker-compose.yml run --rm zqlite-full
docker compose -f docker/docker-compose.yml run --rm zqlite-audit
```

See `docker/RESULTS.md` for latest results.
