# PQC KAT Fixtures

Drop ML-KEM / ML-DSA known-answer test vectors here as simple `key = value` files.

The checked-in `sample.kat` files are loader smoke fixtures, not official vectors. Official imported vectors belong under `official/` with provenance notes.
Generated stdlib regression vectors belong under `generated/`; regenerate them with:

```sh
zig build generate-pqc-regression-kats
```

Validate fixture structure with:

```sh
zig build validate-pqc-fixtures
```

Run generated regression fixtures with:

```sh
zig build test-pqc-generated-kats
```

The generated fixtures are release-regression evidence for the active stdlib
backend, not official NIST KATs. liboqs output can be normalized by first
building the converter with `zig build build-liboqs-kat-converter`.

Current loader fields:

- ML-KEM-768: `key_seed`, `encaps_seed`, optional `expected_public_key`, `expected_secret_key`, `expected_ciphertext`, `expected_shared_secret`
- ML-DSA-65: `seed`, `message`, optional `expected_public_key`, `expected_secret_key`, `expected_signature`

Hex fields are lowercase or uppercase hexadecimal without prefixes. `message` is plain UTF-8 text.
