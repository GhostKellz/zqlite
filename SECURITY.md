# Security Policy

## Supported Versions

| Version | Support Status |
|---------|----------------|
| 1.6.x   | Active development, security fixes |
| 1.5.x   | Security fixes only |
| < 1.5   | Unsupported |

## Reporting a Vulnerability

If you discover a security vulnerability in ZQLite, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

### Reporting Process

1. **Email**: Send details to the maintainers via GitHub private vulnerability reporting
2. **Include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Affected versions
   - Potential impact assessment
   - Any suggested fixes (optional)

### Response Timeline

- **Initial acknowledgment**: Within 48 hours
- **Assessment and triage**: Within 7 days
- **Fix development**: Depends on severity
- **Coordinated disclosure**: After fix is released

## Security Boundaries

### Core Database Engine (Stable)

The following components are intended for use:

- SQL parsing and execution
- B+ tree storage engine
- Write-ahead logging (WAL)
- In-memory and file-based databases
- Prepared statements
- Connection pooling
- Field-level encryption (ChaCha20-Poly1305)
- Secure mode with ATTACH path restrictions
- Documented SQLite-style compatibility surface in the `docs/` tree

The precise stable, partial, experimental, and internal boundaries are defined in [Stability and Compatibility Policy](docs/project/stability-policy.md).

### Experimental Components (Not Production-Ready)

The following components are experimental scaffolding or proof-of-concept implementations:

- **Post-quantum cryptography scaffolding**: capability/status reporting for ML-KEM-768 and ML-DSA-65 related paths, with classical fallback behavior when PQ is requested
- **Zero-knowledge proofs**: Bulletproofs-related scaffolding
- **QUIC transport layer**: PQ-QUIC proof-of-concept transport structure

These experimental features:
- Have not undergone formal security audit
- May contain implementation bugs
- Are subject to breaking API changes
- Should only be used for research and testing

## Secure Mode

ZQLite provides `secure_mode` for stricter security defaults:

```zig
const conn = try db.Connection.openWithOptions(
    allocator,
    "mydata.db",
    db.ConnectionOptions.SECURE,
);
```

Secure mode enforces:
- **ATTACH path restrictions**: Only absolute paths under allowed roots
- **Segment-aware boundary checking**: Prevents `/var/db` matching `/var/database`
- **Rejects path traversal**: Blocks `..` and null bytes

See [Secure Mode Guide](docs/guides/secure-mode.md) for details.

## Security Best Practices

### ATTACH DATABASE Policy

Configure explicit allowed roots for attached databases:

```zig
var conn = try db.Connection.openWithOptions(
    allocator,
    "mydata.db",
    .{
        .attach_policy = .{
            .allowed_roots = &[_][]const u8{ "/var/lib/zqlite" },
            .allow_memory = true,
            .allow_relative = false,
        },
    },
);
```

### Prepared Statements

Always use prepared statements for queries with user-supplied input:

```zig
// Good: parameterized query
var stmt = try conn.prepare("SELECT * FROM users WHERE id = ?");
try stmt.bind(0, user_id);

// Bad: string interpolation
const query = std.fmt.allocPrint(allocator, "SELECT * FROM users WHERE id = {d}", .{user_id});
```

### Encryption

Field-level encryption uses ChaCha20-Poly1305 AEAD:

- Use strong, unique keys derived via Argon2
- Store encryption keys separately from the database
- Rotate keys periodically

## Platform Notes

- **Linux**: Primary supported platform
- **Windows**: WAL/pager not currently supported

## Changelog

Security-relevant changes are documented in [CHANGELOG.md](CHANGELOG.md).
