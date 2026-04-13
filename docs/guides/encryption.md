# Encryption

ZQLite contains internal encryption primitives and secure-storage building blocks, but transparent database-at-rest encryption is not currently exposed as a stable connection feature.

## Overview

- **Algorithm**: ChaCha20-Poly1305 (AEAD)
- **Key size**: 256-bit
- **Nonce**: 96-bit (randomly generated per encryption)
- **Authentication**: Built-in with Poly1305 MAC

## Current Reality

```zig
const zqlite = @import("zqlite");

var conn = try zqlite.open(allocator, "mydb.db");
defer conn.close();
```

At the moment, this guide should be read as implementation context, not as a promise that opening a normal ZQLite database automatically encrypts stored table data or WAL contents.

## Internal Building Blocks

- ChaCha20-Poly1305 is present in internal secure-storage code
- key management and secure-mode infrastructure exist as lower-level components
- experimental PQ scaffolding exists separately and is not production-ready

## What Is Not Yet A Stable Public Feature

- opening a normal database with an application-provided at-rest encryption key
- transparent encryption of table pages on disk
- transparent encryption of WAL contents on disk
- end-user key rotation workflow for ordinary databases

## Security Notes

- do not assume database files are encrypted at rest unless you have added and verified that behavior yourself
- experimental PQ scaffolding is not production-ready
- for production data-at-rest protection today, use filesystem or volume encryption outside ZQLite

## Experimental: Post-Quantum

ZQLite includes experimental scaffolding for post-quantum algorithms:

- ML-KEM-768 (key encapsulation)
- ML-DSA-65 (signatures)

These are **not production-ready**. See [Stable vs Experimental](../security/stable-vs-experimental.md).
