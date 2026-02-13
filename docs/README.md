# ZQLite Documentation

- [API Reference](API.md) - Core API, types, error handling

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    zqlite Architecture                     │
├─────────────────────────────────────────────────────────────┤
│  SQL Interface & CLI  │  Examples & Demos  │  Public API   │
├─────────────────────────────────────────────────────────────┤
│           Post-Quantum QUIC Transport Layer                │
│  ┌─────────────────┐ ┌─────────────────┐ ┌──────────────┐ │
│  │   PQ-QUIC      │ │  ZKP Queries    │ │ Hybrid Sigs  │ │
│  │  ML-KEM + X25519│ │  Bulletproofs   │ │ Ed25519+MLDSA│ │
│  └─────────────────┘ └─────────────────┘ └──────────────┘ │
├─────────────────────────────────────────────────────────────┤
│              Enhanced Crypto Engine (zcrypto)              │
│  ┌─────────────────┐ ┌─────────────────┐ ┌──────────────┐ │
│  │  ML-KEM-768    │ │   ML-DSA-65     │ │  ChaCha20    │ │
│  │  Post-Quantum  │ │  PQ Signatures  │ │  Poly1305    │ │
│  │  Key Exchange  │ │   + Ed25519     │ │  AEAD        │ │
│  └─────────────────┘ └─────────────────┘ └──────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                    Core Database Engine                     │
│  ┌─────────────────┐ ┌─────────────────┐ ┌──────────────┐ │
│  │   SQL Parser   │ │    B+ Trees     │ │     WAL      │ │
│  │   & Executor   │ │  + FTS Indexes  │ │   Logging    │ │
│  └─────────────────┘ └─────────────────┘ └──────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                    Storage & Memory                         │
│           File System  │  Memory Pools  │  Page Cache     │
└─────────────────────────────────────────────────────────────┘
```

## Source Layout

```
src/
├── db/           # Storage engine (B-tree, WAL, pager, FTS indexes, connection)
├── parser/       # SQL tokenizer, AST, parser (FTS5, ATTACH, MATCH support)
├── executor/     # Query planner, VM, prepared statements, window functions
├── crypto/       # Encryption, secure storage, ZNS adapter
├── transport/    # PQ-QUIC transport layer
├── concurrent/   # Async operations, thread safety, MVCC, 2PC coordinator
├── shell/        # CLI interface
└── ffi/          # C API bindings
```

## Build Targets

```bash
zig build                    # Library + CLI
zig build test               # Unit tests
zig build test-comprehensive # Full test suite
zig build test-memory        # Memory leak detection
zig build bench              # Performance benchmarks
zig build bench-validate     # CI benchmark validation
```

## Installation

```bash
zig fetch --save https://github.com/ghostkellz/zqlite/archive/refs/heads/main.tar.gz
```

In `build.zig`:

```zig
const zqlite = b.dependency("zqlite", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zqlite", zqlite.module("zqlite"));
```
