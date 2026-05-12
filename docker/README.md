# ZQLite Docker Testing

Containerized testing for ZQLite using host networking. Images bake in the repository and bind only the host Zig toolchain.

## Quick Start

```bash
# Run full validation
docker compose -f docker/docker-compose.yml run --rm zqlite-full

# Run critical path validation
docker compose -f docker/docker-compose.yml run --rm zqlite-critical

# Run Valgrind audit
docker compose -f docker/docker-compose.yml run --rm zqlite-valgrind

# Run combined audit
docker compose -f docker/docker-compose.yml run --rm zqlite-audit
```

## Services

| Service | Description |
|---------|-------------|
| `zqlite-test` | Unit tests |
| `zqlite-memory` | Memory leak tests |
| `zqlite-full` | Full validation suite |
| `zqlite-critical` | Critical standalone regression suite |
| `zqlite-audit` | Combined critical, full, and Valgrind audit |
| `zqlite-stress` | Stress test |
| `zqlite-chaos` | 10 iteration flake detection |
| `zqlite-perf` | Performance baseline |
| `zqlite-valgrind` | Valgrind memory analysis |
| `zqlite-file-storage` | File-backed storage tests (disk I/O, persistence) |

## Requirements

- Docker with compose
- Zig at `/opt/zig-dev` or an equivalent bind path in `docker-compose.yml`
- Host networking enabled for local test services

## Design

- `network_mode: host` for all services
- No repository bind mounts
- Repository copied into the image at build time
- Host Zig bind preserved to match the local toolchain exactly

## Building Valgrind Image

```bash
docker compose -f docker/docker-compose.yml build zqlite-valgrind
```

## Recommended Audit Order

```bash
docker compose -f docker/docker-compose.yml run --rm zqlite-critical
docker compose -f docker/docker-compose.yml run --rm zqlite-full
docker compose -f docker/docker-compose.yml run --rm zqlite-valgrind
```

Or run the combined audit service on the Debian-based Valgrind image:

```bash
docker compose -f docker/docker-compose.yml run --rm zqlite-audit
```

## Valgrind Coverage

Current Valgrind audit covers:

- `test_security`
- `test_file_backed`
- `test_transaction_atomicity`
- `test_concurrent_access`
- `test_index_persistence`

## Results

See [RESULTS.md](RESULTS.md) for latest test results and benchmarks.
