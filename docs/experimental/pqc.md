# Post-Quantum Crypto Status

ZQLite includes experimental post-quantum crypto and transport scaffolding.

## Current Reality

- PQ capability introspection exists in the Zig API.
- PQ capability introspection also exists in the C API via `zqlite_pq_available()`, `zqlite_pq_status()`, and `zqlite_pq_backend()`.
- Classical crypto primitives are available.
- Real post-quantum backend support is not active by default.
- PQ transport remains simulated/proof-of-concept.

## What Is Real Today

- runtime capability reporting
- classical cryptography fallback behavior
- experimental transport structure and diagnostics

## What Falls Back

- requests for PQ crypto currently fall back to classical-only behavior unless a real backend is integrated
- enabling hybrid/PQ mode without an actual PQ backend logs an experimental runtime warning before key generation falls back to classical Ed25519

## What Is Simulated

- PQ-QUIC transport flow
- ML-KEM / ML-DSA availability beyond the capability/reporting layer

## Not Production-Ready

- PQ transport
- simulated PQ backend paths
- any workflow that assumes real post-quantum cryptography is active without checking capability status

## Recommended Usage

- use `getPQCapability()` / `getCryptoStatus()` before relying on PQ-related behavior
- use the C API status helpers before advertising PQ behavior through FFI consumers
- treat PQ demos and transport features as experimental
