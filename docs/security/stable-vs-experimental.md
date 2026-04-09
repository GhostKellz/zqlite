# Stable vs Experimental Features

ZQLite is in beta. This document clarifies feature maturity.

## Core Features (Stable API)

These features have stable APIs and are the primary focus:

| Feature | Status |
|---------|--------|
| SQL Parser | Stable |
| B+ Tree Storage | Stable |
| Write-Ahead Log | Stable |
| In-Memory Mode | Stable |
| Prepared Statements | Stable |
| Connection Pooling | Stable |
| Field Encryption | Stable |
| Full-Text Search | Partial, core MATCH support only |
| ATTACH DATABASE | Stable |
| Secure Mode | Stable |

## Experimental (Not Ready)

These are proof-of-concept or incomplete:

| Feature | Status |
|---------|--------|
| Post-Quantum QUIC | Proof of concept, no network I/O |
| ML-KEM-768 | Placeholder, requires external library |
| ML-DSA-65 | Placeholder, falls back to Ed25519 |
| Cluster Manager | Simulated, no inter-node communication |
| Hot Standby | In-memory only |
| Two-Phase Commit | Single-node simulation |
| Window Functions | Partial, PARTITION BY present but advanced framing remains limited |
| Windows Platform | WAL/pager unsupported |

## Do Not Use Experimental Features For

- Security-critical operations
- Production deployments
- Data you cannot afford to lose

The PQ crypto modules are demonstrations only - not audited, may have bugs.

See [Experimental Overview](../experimental/overview.md) for details.
