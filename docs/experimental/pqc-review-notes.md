# PQC Review Notes

ZQLite's PQC layer is experimental. These notes map current claims to code,
tests, and promotion blockers so release notes do not overstate cryptographic
readiness.

## Current Claims

| Claim | Evidence | Status |
| --- | --- | --- |
| Backend abstraction exists | `src/crypto/pqc_backend.zig` defines `PQCBackend` with KEM and signature operations | Implemented |
| stdlib-backed ML-KEM-768 adapter exists | `StdlibPQCBackend.MlKem768` keypair/encaps/decaps paths | Experimental |
| stdlib-backed ML-DSA-65 adapter exists | `StdlibPQCBackend.MlDsa65` keypair/sign/verify paths | Experimental |
| liboqs provider can be requested diagnostically | `LibOQSPQCBackend` reports `configured_but_unlinked` | Placeholder |
| backend-agnostic KAT loader exists | `loadKemKatFixture`, `loadSignKatFixture`, and fixture runners | Implemented |
| official KAT import lane exists | `scripts/import-pqc-kats.sh`, `test-pqc-official-kats`, and `tests/standalone/fixtures/pqc/official/` | Implemented |
| C/CLI diagnostics expose provider state | C API PQC status helpers and CLI PQ status output | Implemented |

## Required Validation

Run the deterministic adapter and diagnostic suite:

```bash
zig build test-pqc --summary all
zig build -Dcrypto=true test-pqc --summary all
zig build -Dcrypto=true -Dliboqs=true test-pqc --summary all
```

Run official vectors after importing converted upstream KAT files:

```bash
scripts/import-pqc-kats.sh /path/to/ml-kem-768 ml-kem-768
scripts/import-pqc-kats.sh /path/to/ml-dsa-65 ml-dsa-65
zig build test-pqc-official-kats --summary all
```

`test-pqc-official-kats` skips cleanly when no official vectors have been
imported. A release must not claim official vector coverage unless this target
runs at least one ML-KEM-768 file and one ML-DSA-65 file.

## Promotion Blockers

- Official ML-KEM-768 and ML-DSA-65 vectors must be imported with provenance.
- Official vectors must pass every enabled real backend.
- liboqs linkage must remain optional and build-gated.
- PQC diagnostics must keep distinguishing `stdlib`, `liboqs`, `none`, and
  `configured_but_unlinked`.
- Simulated or transport-level PQ paths must remain documented as non-production.
- Release packages must include the fixture import tooling and PQC review docs.

## Non-Claims

- ZQLite does not currently ship linked liboqs.
- PQ transport is not production-ready.
- The stdlib-backed PQC adapter is not promoted to stable cryptography.
- Checked-in sample `.kat` files outside `official/` are loader smoke fixtures,
  not official NIST KAT vectors.
