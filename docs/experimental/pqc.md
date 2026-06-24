# Post-Quantum Crypto Status

ZQLite includes an experimental post-quantum crypto capability layer and a direct Zig stdlib-backed ML-KEM/ML-DSA adapter.

For the future optional liboqs backend plan, see [Future liboqs Backend](liboqs-backend.md).
For claim evidence and promotion blockers, see [PQC Review Notes](pqc-review-notes.md).

## Current Reality

- PQ capability introspection exists in the Zig API.
- PQ capability introspection also exists in the C API via `zqlite_pq_available()`, `zqlite_pq_status()`, `zqlite_pq_backend()`, `zqlite_pq_liboqs_status()`, and `zqlite_pq_diagnostics_json()`.
- The Zig capability model distinguishes `unavailable`, `classical_fallback`, `simulated`, `hybrid_active`, and `pqc_active`.
- A direct stdlib-backed adapter exists for ML-KEM-768 key encapsulation and ML-DSA-65 signatures.
- Classical crypto primitives are available.
- Real post-quantum backend support is not active by default; it requires the crypto build feature and a runtime PQC/hybrid request.
- PQ transport remains simulated/proof-of-concept.

## What Is Real Today

- runtime capability reporting
- direct stdlib-backed ML-KEM-768 deterministic key generation, encapsulation, and decapsulation
- direct stdlib-backed ML-DSA-65 deterministic key generation, signing, and verification
- backend-agnostic `PQCBackend` interface shape for providers and deterministic/KAT fixtures
- fixture-file loader for backend-agnostic ML-KEM/ML-DSA KAT smoke files under `tests/standalone/fixtures/pqc/`
- generated stdlib regression fixtures under `tests/standalone/fixtures/pqc/generated/`
- official-vector import structure under `tests/standalone/fixtures/pqc/official/` with `scripts/import-pqc-kats.sh`
- liboqs KAT output converter scaffold through `zig build build-liboqs-kat-converter`
- PQC fixture manifest validation through `zig build validate-pqc-fixtures`
- provider lifecycle, algorithm policy, and secret zeroization helpers for owned PQC key/shared-secret buffers
- `CryptoInterface.signPQ(...)` and `CryptoInterface.verifyPQ(...)` use ML-DSA-65 when a real PQC/hybrid backend is active
- explicit classical cryptography fallback behavior
- experimental transport structure and diagnostics
- deterministic capability and adapter tests through `zig build test-pqc`
- generated stdlib regression KAT tests through `zig build test-pqc-generated-kats`
- machine-readable diagnostics through `pqDiagnosticsJson(...)`, `zqlite_pq_diagnostics_json()`, and `zqlite --pq-status=json`
- provider-selection diagnostics through `CryptoConfig.pq_provider`, `requested_provider`, `provider`, and `liboqs_status`

## Capability States

| State | Meaning | `isAvailable()` |
| --- | --- | --- |
| `unavailable` | PQC is disabled, not compiled, or requested without a backend and without fallback. | false |
| `classical_fallback` | Classical crypto is active because fallback was explicitly selected or allowed. | false |
| `simulated` | Test/demo diagnostics are active; this is never production PQC. | false |
| `hybrid_active` | The real ML-KEM/ML-DSA backend is active for a hybrid-mode request. | true |
| `pqc_active` | The real ML-KEM/ML-DSA backend is active for a PQC-only request. | true |

## What Falls Back

- PQC/hybrid requests fail closed when the crypto feature or backend is unavailable and fallback is not explicitly allowed
- classical-only fallback is observable as `classical_fallback` and is never reported as production-ready PQC

## What Is Simulated

- PQ-QUIC transport flow
- any transport-level use of ML-KEM / ML-DSA
- any liboqs-backed provider; liboqs remains a likely long-term optional backend, not the current dependency

## Not Production-Ready

- PQ transport
- simulated PQ backend paths
- any workflow that assumes real post-quantum cryptography is active without checking capability status
- the stdlib-backed PQC adapter as a stable/production cryptography promise; it is experimental until official vectors, review notes, and release-package evidence are added
- fixture smoke files are not official NIST KAT vectors; they validate the loader/harness shape until official vectors are imported with provenance
- generated stdlib regression fixtures are deterministic release-regression fixtures, not official vectors
- official vector provenance is required before promotion beyond experimental

## Recommended Usage

- use `getPQCapability()` / `getCryptoStatus()` before relying on PQ-related behavior
- treat `zqlite_pq_available() == 1` or `PQCapability.isAvailable()` as the only positive production-readiness signal
- use the C API status helpers before advertising PQ behavior through FFI consumers
- use the JSON diagnostics in release tooling when checking requested mode, requested provider, selected state, backend, provider, liboqs status, fallback reason, and algorithm availability
- treat PQ demos and transport features as experimental

## Claim Mapping

| Claim | Source | Test |
| --- | --- | --- |
| Capability states and diagnostics | `src/crypto/interface.zig` | `zig build test-pqc` |
| Backend provider interface | `src/crypto/pqc_backend.zig` | `zig build test-pqc` |
| ML-KEM-768 adapter | `src/crypto/pqc_backend.zig` | `zig build test-pqc` |
| ML-DSA-65 adapter | `src/crypto/pqc_backend.zig` | `zig build test-pqc` |
| Backend-agnostic deterministic/KAT fixture harness and fixture loader | `src/crypto/pqc_backend.zig`, `tests/standalone/fixtures/pqc/` | `zig build test-pqc` |
| Generated stdlib regression KATs | `scripts/generate-pqc-regression-kats.zig`, `tests/standalone/fixtures/pqc/generated/` | `zig build test-pqc-generated-kats` |
| PQC fixture validation | `scripts/validate-pqc-fixtures.sh`, `tests/standalone/fixtures/pqc/` | `zig build validate-pqc-fixtures` |
| liboqs KAT conversion scaffold | `scripts/convert-liboqs-kat-output.zig` | `zig build build-liboqs-kat-converter` |
| Official KAT import lane | `scripts/import-pqc-kats.sh`, `tests/standalone/fixtures/pqc/official/` | `zig build test-pqc` after import |
| Official KAT execution target | `tests/standalone/test_pqc_official_kats.zig` | `zig build test-pqc-official-kats` |
| Provider lifecycle, algorithm policy, and secret zeroization helpers | `src/crypto/pqc_backend.zig` | `zig build test-pqc` |
| `CryptoInterface` ML-DSA path when crypto is compiled and PQC is requested | `src/crypto/interface.zig` | `zig build -Dcrypto=true test-pqc` |
| C API default-state and liboqs status diagnostic parity | `src/ffi/c_api.zig` | `zig build test-pqc`, `zig build -Dcrypto=true -Dliboqs=true test-pqc` |
