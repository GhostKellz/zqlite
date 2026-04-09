# ZQLite Docker Testing

Containerized testing for ZQLite. Mounts host Zig - instant startup, no build time.

## Quick Start

```bash
# Run all tests
docker-compose -f docker/docker-compose.yml run --rm zqlite-full

# Quick unit tests only
docker-compose -f docker/docker-compose.yml run --rm zqlite-test
```

## Services

| Service | Description |
|---------|-------------|
| `zqlite-test` | Unit tests |
| `zqlite-memory` | Memory leak tests |
| `zqlite-full` | Full validation suite |
| `zqlite-stress` | Stress test |
| `zqlite-chaos` | 10 iteration flake detection |
| `zqlite-perf` | Performance baseline |
| `zqlite-valgrind` | Valgrind memory analysis |

## Requirements

- Docker with compose
- Zig at `/opt/zig-0.16.0-dev` (or update path in `docker-compose.yml`)

## Building Valgrind Image

```bash
cd docker
docker build --network=host -f Dockerfile.valgrind -t zqlite-valgrind .
```

## Results

See [RESULTS.md](RESULTS.md) for latest test results and benchmarks.
