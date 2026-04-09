# Encryption

ZQLite supports field-level encryption using ChaCha20-Poly1305.

## Overview

- **Algorithm**: ChaCha20-Poly1305 (AEAD)
- **Key size**: 256-bit
- **Nonce**: 96-bit (randomly generated per encryption)
- **Authentication**: Built-in with Poly1305 MAC

## Usage

```zig
const zqlite = @import("zqlite");

// Open with encryption key
var conn = try zqlite.openWithOptions(allocator, "mydb.db", .{
    .encryption_key = "my-32-byte-encryption-key-here!",
});
defer conn.close();

// Data is encrypted at rest
try conn.execute("CREATE TABLE secrets (id INTEGER PRIMARY KEY, data TEXT)");
try conn.execute("INSERT INTO secrets (data) VALUES ('sensitive info')");
```

## Key Management

- Keys must be exactly 32 bytes
- ZQLite does not store keys - you manage key storage
- Changing keys requires re-encrypting the database

## What Gets Encrypted

- Field values in storage
- WAL entries

## What's NOT Encrypted

- Schema metadata (table names, column names)
- Indexes (by design, for query performance)

## Security Notes

- Encryption protects data at rest
- Does not protect against memory inspection while database is open
- For production use, combine with OS-level protections

## Experimental: Post-Quantum

ZQLite includes experimental scaffolding for post-quantum algorithms:

- ML-KEM-768 (key encapsulation)
- ML-DSA-65 (signatures)

These are **not production-ready**. See [Stable vs Experimental](../security/stable-vs-experimental.md).
