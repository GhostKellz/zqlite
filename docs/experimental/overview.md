# Experimental Features in ZQLite

This document describes features that are experimental, proof-of-concept, or not yet production-ready. These features are included for testing, development, and early feedback purposes.

**Important:** Do not use experimental features in production environments without understanding their limitations.

---

## Quick Reference

| Feature | Status | Usable |
|---------|--------|--------|
| Post-Quantum QUIC Transport | Experimental | No |
| ML-KEM-768 Key Encapsulation | Experimental | No |
| ML-DSA-65 Digital Signatures | Experimental | No |
| Distributed Query Engine | Experimental | No |
| Cluster Manager | Experimental | No |
| Hot Standby Replication | Experimental | No |
| Two-Phase Commit (Phase1) | Experimental | No |
| Window Functions | Partial | Limited |
| Query Cache | Partial | Limited |
| Full-Text Search (FTS5) | Stable | Yes |
| ATTACH DATABASE | Stable | Yes |

---

## Post-Quantum Cryptography

### PQ-QUIC Transport (`src/transport/pq_quic.zig`)

**Status:** Proof of Concept - NOT production-ready

A demonstration of post-quantum secure database transport combining QUIC with ML-KEM key exchange.

**Current Limitations:**
- No actual network I/O - packet send/receive are simulated
- ML-KEM-768 key exchange is simulated, not using actual PQ algorithms
- Connection management lacks proper cleanup and concurrency controls
- Zero-RTT implementation is incomplete
- Key derivation now uses RFC 9001 compliant HKDF (improved in v1.5.2)

**Requirements for Production:**
1. Integration with a real QUIC implementation (quiche, msquic, etc.)
2. Actual ML-KEM-768 or ML-KEM-1024 key encapsulation library
3. Full TLS 1.3 handshake with PQ key exchange
4. Robust connection lifecycle management
5. Proper error recovery and reconnection logic

**What Works:**
- Cryptographic primitives (AES-GCM, ChaCha20-Poly1305) via `std.crypto`
- Key derivation using HKDF-SHA256
- Packet encryption/decryption structure

---

### ML-KEM-768 / ML-DSA-65 (`src/crypto/secure_storage.zig`)

**Status:** Placeholder - Requires external library

Post-quantum key encapsulation and digital signatures based on NIST standards.

**Current Limitations:**
- PQ algorithms (ML-KEM, ML-DSA) are experimental scaffolding only
- `hybrid_mode` flag signals intent but falls back to classical crypto
- No actual ML-KEM encapsulation or ML-DSA signing
- ZKP (zero-knowledge proofs) support is stubbed

**Fallback Behavior (v1.5.2+):**
When PQ crypto is requested but unavailable, the system logs a warning and falls back to Ed25519 for signatures and X25519 for key exchange.

**Requirements for Production:**
- Integration with NIST-approved PQ implementation
- Cryptographic audit by third-party security experts
- Hardware security module (HSM) support for key storage

---

## Distributed Database Features

### Cluster Manager (`src/cluster/manager.zig`)

**Status:** Experimental - Simulated coordination

Manages multiple database nodes for horizontal scaling.

**Current Limitations:**
- No actual inter-node network communication
- `executeQueryOnNode()` returns mock results
- `mergeResults()` has basic implementation only
- Health checks evaluate node staleness locally, but there is still no active inter-node heartbeat transport
- Shard count fixed at 1024 (hardcoded)

**What Works:**
- Node registration and tracking
- Round-robin load balancing
- Basic metrics collection
- Shard assignment calculations

**Requirements for Production:**
- Real network transport layer integration
- Consensus protocol for coordination (Raft, Paxos, etc.)
- Persistent cluster state storage
- Network partition handling

---

### Distributed Query Engine (`src/distributed/query_engine.zig`)

**Status:** Experimental - Stub implementations

Executes queries across multiple cluster nodes.

**Current Limitations:**
- `extractTables()` returns empty array
- `extractPredicates()` returns empty array
- `performJoin()` has no actual join logic
- `performAggregation()` has no actual aggregation
- `executeOnNode()` simulates execution
- Query planner uses hardcoded stub plans

**What Works:**
- Query routing infrastructure
- Result aggregation structure
- Query caching with LRU eviction
- Batch execution framework

---

### Hot Standby Replication (`src/concurrent/hot_standby.zig`)

**Status:** Experimental - In-memory only

Zero-downtime failover with streaming replication.

**Current Limitations:**
- Replication log is in-memory only (not persisted)
- No actual network replication between nodes
- Failover timing is hardcoded (1000ms lag tolerance)
- Recovery and crash handling incomplete
- Async sleep operations are placeholders

**What Works:**
- Replication log structure
- Failover state machine
- Lag monitoring calculations

---

### Two-Phase Commit (`src/concurrent/phase1_engine.zig`)

**Status:** Experimental - Single-node simulation

Coordinator for distributed transaction prepare phase.

**Current Limitations:**
- Participant voting is simulated locally
- No actual network communication between participants
- `simulateParticipantVote()` always returns "Prepared"
- Lock compatibility checks are simplified
- No rollback coordination for failed transactions

**What Works:**
- Transaction state tracking
- Lock request/release structure
- Vote collection framework
- Timeout handling
- Integration with MVCC transaction manager

---

## Stable Feature Notes

### Full-Text Search (FTS5)

**Status:** Stable

```zig
// Create FTS virtual table
try conn.execute("CREATE VIRTUAL TABLE docs USING fts5(title, body)");

// Insert and search
try conn.execute("INSERT INTO docs VALUES ('ZQLite Guide', 'A comprehensive guide to ZQLite')");
var result = try conn.query("SELECT * FROM docs WHERE body MATCH 'comprehensive guide'");
```

**Features:**
- CREATE VIRTUAL TABLE with FTS5/FTS4 module
- Inverted index for fast term lookups
- MATCH operator for full-text queries
- Case-insensitive tokenization
- Multi-term AND search semantics
- Phrase search using quoted terms
- Boolean `AND` / `OR` / `NOT` matching
- FTS metadata persists across reopen for file-backed databases

**Limitations:**
- Large document indexing not optimized

### ATTACH DATABASE

**Status:** Stable

```zig
// Attach external database file
try conn.execute("ATTACH DATABASE 'archive.db' AS archive");

// Query across databases
var result = try conn.query("SELECT * FROM main.users u JOIN archive.logs l ON u.id = l.user_id");

// Detach when done
try conn.execute("DETACH DATABASE archive");
```

**Features:**
- Multiple database files in single connection
- Schema-qualified table names (schema.table)
- Automatic cleanup on connection close
- Reserved schema name protection (main, temp)

**Limitations:**
- Cross-database transactions not fully tested
- No schema migration between attached databases

### Additional SQL Features

- **HAVING clause** - Filter results after GROUP BY aggregation
- **SELECT DISTINCT** - Remove duplicate rows with hash-based deduplication
- **Subqueries** - IN (SELECT ...) and scalar subqueries
- **STDDEV/VARIANCE** - Population standard deviation and variance functions

---

## Partial Implementations

### Window Functions (`src/executor/window_functions.zig`)

**Status:** Partial - Core functionality works

SQL window functions (RANK, ROW_NUMBER, etc.).

**Limitations:**
- Complex window frame specifications not supported
- Performance optimizations missing
- Some edge cases in ranking may not be handled

**What Works:**
- Basic ROW_NUMBER, RANK, DENSE_RANK
- Simple ORDER BY within windows
- PARTITION BY for supported ranking/window paths
- Aggregate functions over windows (SUM, AVG, etc.)

---

### Query Cache (`src/performance/query_cache.zig`)

**Status:** Partial - Basic functionality

Caches query results for repeated SELECT statements.

**Limitations:**
- Cache invalidation is table-scoped and does not support distributed/shared caches
- Memory estimation is approximate
- No cache warming or preloading
- No distributed cache invalidation

**What Works:**
- LRU-style caching
- Query hash-based lookup
- Configurable cache size
- Invalidation on row writes and schema mutations for affected tables

---

## Using Experimental Features

### Enabling Features

Experimental code is built through the normal project profiles and feature flags:

```bash
zig build -Dprofile=full
zig build -Dcrypto=true -Dtransport=true -Dconcurrent=true
```

Current boolean feature flags exposed by the build are:

- `-Dcrypto`
- `-Dtransport`
- `-Djson`
- `-Dperformance`
- `-Dconcurrent`
- `-Dffi`

### Checking Feature Availability

There is no global `zqlite.features.pq_crypto` or `zqlite.features.cluster` runtime surface today. Check the specific API or module you intend to use instead.

### Graceful Degradation

Some experimental areas degrade or fall back gracefully, but this is feature-specific and should not be assumed globally:

```zig
// PQ crypto falls back to classical
const keypair = try crypto_engine.generateKeyPair();
// If PQ unavailable, returns Ed25519 keypair with warning

// Cluster queries fall back to local
const result = try cluster.routeQuery(query);
// If cluster unavailable, executes locally
```

---

## Roadmap

### Added Earlier
- [x] Full-text search (FTS5) with MATCH operator
- [x] ATTACH/DETACH DATABASE support
- [x] HAVING clause for GROUP BY
- [x] SELECT DISTINCT
- [x] Subquery support (IN, scalar)
- [x] STDDEV/VARIANCE aggregate functions
- [x] Two-phase commit coordinator (Phase1Engine)

### Near-term (v1.6.x)
- [x] Complete window function PARTITION BY support
- [x] Improve query cache invalidation
- [x] Add cluster health check implementation
- [x] FTS phrase search and boolean operators

### Medium-term (v1.7.x)
- [ ] Integrate real QUIC library for PQ transport
- [ ] Implement basic Raft consensus for cluster
- [ ] Add persistent replication log for hot standby

### Long-term (v2.x)
- [ ] Full ML-KEM-768 implementation
- [ ] Production-ready distributed query execution
- [ ] Multi-region cluster support

---

## Reporting Issues

When reporting issues with experimental features:

1. Note the feature is experimental in your report
2. Include the released ZQLite version you are testing
3. Include Zig compiler version (`zig version`)
4. Describe expected vs actual behavior
5. Provide minimal reproduction steps

File issues at: https://github.com/ghostkellz/zqlite/issues

---

## Contributing

Contributions to experimental features are welcome! Priority areas:

1. **PQ-QUIC:** Network transport integration
2. **Cluster:** Consensus protocol implementation
3. **Hot Standby:** Persistent replication log
4. **Tests:** Integration tests for distributed features

See `docs/project/maintainer-workflow.md` for current workflow guidance.
