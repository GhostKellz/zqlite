# Official PQC Vectors

Place official ML-KEM-768 and ML-DSA-65 KAT files here when they are imported for release validation.

Rules:

- Keep provenance notes with each imported vector set.
- Keep upstream version/source information in the commit that imports the vectors.
- Use the loader format documented in `../README.md`, or add a deterministic converter under `scripts/` before committing generated fixture files.
- Do not mark PQC as promoted beyond experimental until official vectors pass every enabled backend.

Use `scripts/import-pqc-kats.sh <source-dir> <ml-kem-768|ml-dsa-65>` to import a converted vector set with a local provenance file and manifest.

Run imported vectors with:

```bash
zig build test-pqc-official-kats --summary all
```

The target skips cleanly when no official vectors are present. Do not treat a skip as vector validation.
