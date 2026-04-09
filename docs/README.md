# ZQLite Documentation

## Getting Started

- [Installation](getting-started/installation.md) - Build from source, Zig integration
- [Quickstart](getting-started/quickstart.md) - Basic database operations

## API Reference

- [Zig API](api/zig-api.md) - Core API, types, error handling
- [C API](api/c-api.md) - FFI bindings for C/C++ integration

## Guides

- [Secure Mode](guides/secure-mode.md) - ATTACH path policies, secure connections
- [Transactions](guides/transactions.md) - BEGIN, COMMIT, ROLLBACK
- [Prepared Statements](guides/prepared-statements.md) - Parameterized queries

## Compatibility

- [SQLite Compatibility](compatibility/sqlite.md) - Support matrix, deviations, migration notes
- [PostgreSQL-Style Features](compatibility/postgresql.md) - PostgreSQL-inspired syntax and positioning

## Security

- [Stable vs Experimental](security/stable-vs-experimental.md) - Feature maturity status
- [Security Policy](../SECURITY.md) - Vulnerability reporting, supported versions

## Platform Support

- [Linux](platforms/linux.md) - Primary platform
- [Windows](platforms/windows.md) - Current limitations and roadmap

## Experimental Features

- [Overview](experimental/overview.md) - PQ crypto, distributed features, limitations
- [Post-Quantum Crypto Status](experimental/pqc.md) - Real vs fallback vs simulated PQ behavior

## Project

- [Release Process](project/release-process.md) - Release checklist and verification flow

The root documentation entrypoints are intentionally small:

- `README.md` for product overview and quick links
- `SECURITY.md` for support and vulnerability reporting
- `CHANGELOG.md` for release history

## Architecture

```
src/
├── db/           # Storage engine (B-tree, WAL, pager, FTS indexes, connection)
├── parser/       # SQL tokenizer, AST, parser
├── executor/     # Query planner, VM, prepared statements
├── crypto/       # Encryption, secure storage
├── transport/    # PQ-QUIC transport layer (experimental)
├── concurrent/   # Async operations, MVCC, 2PC
├── shell/        # CLI interface
└── ffi/          # C API bindings
```

## Build Targets

```bash
zig build                    # Library + CLI
zig build test               # Unit tests
zig build test-comprehensive # Full test suite
zig build test-security      # Security tests
zig build bench              # Performance benchmarks
```
