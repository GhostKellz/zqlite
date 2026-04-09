# CI Workflow

## Current State

GitHub Actions CI runs on push/PR:

```yaml
- zig fmt --check src/ examples/ tests/
- zig build
- zig build test
- zig build test-create-table-leaks
- zig build bench-validate
```

This covers core functionality but not the full test surface.

## Local Docker Testing

For v1.6.0, we expanded testing locally using Docker:

```bash
# Available services
docker-compose -f docker/docker-compose.yml run --rm zqlite-test      # Unit tests
docker-compose -f docker/docker-compose.yml run --rm zqlite-memory    # Memory leak tests
docker-compose -f docker/docker-compose.yml run --rm zqlite-full      # Full validation
docker-compose -f docker/docker-compose.yml run --rm zqlite-stress    # Stress test
docker-compose -f docker/docker-compose.yml run --rm zqlite-chaos     # Flake detection (10 iterations)
docker-compose -f docker/docker-compose.yml run --rm zqlite-perf      # Performance baseline
docker-compose -f docker/docker-compose.yml run --rm zqlite-valgrind  # Valgrind memory analysis
```

Setup mounts host Zig (`/opt/zig-0.16.0-dev`) for instant startup - no build time.

See [docker/RESULTS.md](../../docker/RESULTS.md) for latest test results.

## Test Coverage Gap

CI currently runs:
- `zig build test`
- `zig build test-create-table-leaks`
- `zig build bench-validate`

Local Docker runs (not in CI yet):
- `zig build test-security`
- `zig build test-comprehensive`
- `zig build test-advanced`
- `zig build test-c-api`
- `zig build test-memory-leaks`
- `zig build test-comprehensive-memory`

## Planned CI Enhancements

### Phase 1: Expand Test Coverage

Add to CI workflow:

```yaml
- zig build test-security
- zig build test-comprehensive
- zig build test-memory-leaks
```

### Phase 2: Matrix Testing

Test across Zig versions:

```yaml
strategy:
  matrix:
    zig: ['0.16.0-dev.2960', '0.16.0-dev.3133']
```

### Phase 3: Platform Coverage

Add Linux ARM64 and potentially macOS:

```yaml
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest]
    arch: [x64, arm64]
```

### Phase 4: Performance Regression

Track benchmark results over time:

```yaml
- zig build bench-validate
- Upload results to artifact storage
- Compare against baseline
- Fail if regression > 20%
```

### Phase 5: Release Automation

On tag push:
- Run full test suite
- Build release artifacts
- Generate changelog
- Create GitHub release

## Scripts

Local validation scripts in `docker/scripts/`:

| Script | Purpose |
|--------|---------|
| `full-validation.sh` | Complete test suite |
| `stress-test.sh` | Heavy load testing |
| `chaos-test.sh` | Flake detection |
| `perf-baseline.sh` | Performance metrics |

## Notes

- Host networking required for Docker DNS resolution during builds
- Valgrind may hit instruction incompatibility with AVX-512
- Zig's built-in leak detection (DebugAllocator) is reliable for memory testing
