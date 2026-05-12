# Maintainer Workflow

## Local Development

Local compiler baseline:

```bash
/opt/zig-dev/zig version
```

Example result:

```text
0.17.0-dev.292+fc1c83a36
```

### Quick Validation

```bash
zig build test                    # Unit tests
zig build test-security           # Security suite
zig build test-comprehensive      # Full functionality
```

### Full Validation

```bash
./scripts/test-release.sh
```

Or manually:

```bash
zig fmt --check src/ examples/ tests/
zig build test
zig build test-security
zig build test-comprehensive
zig build test-storage
zig build test-advanced
zig build test-c-api
zig build bench-validate
```

### Storage Tests

File-backed persistence tests (use temp files in `/tmp/`):

```bash
zig build test-file-backed    # Persistence across connections
zig build test-transaction    # COMMIT/ROLLBACK atomicity
zig build test-storage        # Combined (runs both with cleanup)
```

## CI Pipeline

```
lint → build-test → [memory-tests, benchmarks, extended-tests]
```

| Job | What it runs |
|-----|--------------|
| lint | `zig fmt --check` |
| build-test | `zig build`, `zig build test` |
| memory-tests | `test-create-table-leaks` |
| benchmarks | `bench-validate` |
| extended-tests | `test-security`, `test-comprehensive`, `test-storage` |

All jobs run on self-hosted runner.
Runner Zig configuration should satisfy the minimum Zig version declared in `build.zig.zon`.

## Build Profiles

Three profiles control which features are compiled:

| Profile | Features |
|---------|----------|
| `core` | Minimal SQLite-like: db, parser, executor |
| `advanced` | Core + json, performance, concurrent |
| `full` (default) | Advanced + crypto, transport, ffi |

Usage:
```bash
zig build -Dprofile=core test       # Minimal build
zig build -Dprofile=advanced test   # Mid-tier build
zig build test                       # Full build (default)
```

Individual feature flags can override profile defaults:
```bash
zig build -Dprofile=core -Djson=true test   # Core + JSON only
zig build -Dcrypto=false test               # Full minus crypto
```

When a feature is disabled, its public API becomes an empty struct or void type. Code that conditionally uses features should check `zqlite.features.*` at comptime.

## Test Targets

### Core (run always)

| Target | Purpose |
|--------|---------|
| `test` | Unit tests |
| `test-security` | SQL injection, integrity, limits |
| `test-comprehensive` | Full functionality suite |

### Storage (file-backed)

| Target | Purpose |
|--------|---------|
| `test-file-backed` | Persistence across connections |
| `test-transaction` | COMMIT/ROLLBACK atomicity |
| `test-storage` | Combined (runs both + cleanup) |

### Memory

| Target | Purpose |
|--------|---------|
| `test-memory` | Intensive leak detection |
| `test-memory-safe` | Safe subset (avoids btree edge cases) |
| `test-create-table-leaks` | DEFAULT constraint memory fixes |
| `test-leak-detection` | Comprehensive leak detection |
| `test-memory-leaks` | Dedicated leak detection |
| `test-comprehensive-memory` | Full memory suite |

### Advanced

| Target | Purpose |
|--------|---------|
| `test-advanced` | Stress, security, edge cases |
| `test-window` | Window function tests |
| `test-logging` | Structured logging |
| `test-c-api` | C API (requires `-Dffi=true`) |

### Benchmarks

| Target | Purpose |
|--------|---------|
| `bench` | Performance benchmark |
| `bench-validate` | CI regression check |
| `bench-minimal` | Debug benchmark |

### Fuzzing

| Target | Purpose |
|--------|---------|
| `fuzz-parser` | SQL parser fuzzer |
| `fuzz-example` | Fuzz example |

### CI Pipeline Targets

- Default: `test`
- Extended: `test-security`, `test-comprehensive`, `test-storage`
- Memory: `test-create-table-leaks`
- Benchmarks: `bench-validate`

## Version Management

### Source of Truth

- `build.zig.zon` - package version
- `src/version.zig` - runtime constants (must match)

### Build Metadata

`build.zig` uses static values for portability with source archives:
- `git_commit` - set to "release" for tagged releases
- `build_date` - updated manually when releasing

### Version Update Checklist

1. Update `build.zig.zon` version
2. Update `src/version.zig` PATCH constant
3. Update `src/version.zig` test assertions
4. Update `src/zqlite.zig` version test
5. Update `README.md` install URL
6. Run `zig build test` to verify

## Release Process

See [release-process.md](release-process.md).

## Experimental Features

### Status Levels

| Status | Meaning |
|--------|---------|
| Stable | Tested, suitable for use |
| Partial | Core works, edge cases incomplete |
| Experimental | Proof of concept, scaffolding only |

### Current Experimental

- Post-quantum crypto (ML-KEM, ML-DSA) - scaffolding only
- PQ-QUIC transport - simulated, no real network I/O
- Cluster/distributed features - stub implementations

See [docs/experimental/overview.md](../experimental/overview.md) for details.

### Rules for Experimental Code

1. Must be clearly documented as experimental
2. Must fail gracefully (fallback to stable behavior)
3. Must not be expanded without implementation plan
4. Examples must state they are demonstration only

## Benchmark Maintenance

### Thresholds

Defined in `tests/bench/benchmark_validator.zig`:
- simple_insert: 1000 ops/sec
- bulk_insert: 500 ops/sec
- select_query: 500 ops/sec
- update: 50 ops/sec

### Updating Thresholds

1. Run `zig build bench` to see current performance
2. Update thresholds in `benchmark_validator.zig`
3. Update `tests/bench/benchmark_baseline.json` to match
4. Document reason for change in commit message

### When to Update

- Hardware/CI environment changes
- Intentional performance trade-offs
- Algorithm improvements (raise thresholds)

## Code Style

- Run `zig fmt` before committing
- Comments explain "why", not "what"
- No version numbers in code comments
- No marketing language in docs

## Directory Structure

```
src/
  zqlite.zig      # Library entrypoint
  version.zig     # Version constants

tests/
  standalone/     # Executable tests (file-backed, security)
  bench/          # Benchmarks
  memory/         # Memory leak tests

examples/         # Working examples (use @import("zqlite"))
docs/
  project/        # Maintainer docs
  experimental/   # Experimental feature docs
```
