# ZQLite Examples

## Reference Examples

Working examples demonstrating core ZQLite features:

| Example | Description |
|---------|-------------|
| `simple_api_test.zig` | Basic API usage: parsing, binding, transactions, migrations |
| `improved_api_demo.zig` | API demo: migrations, parameter binding, transactions |
| `insert_memory_regression_test.zig` | Memory management regression test for INSERT operations |
| `datetime_test.zig` | Date/time functions |
| `web_backend_demo.zig` | HTTP backend patterns |
| `cipher_dns.zig` | DNS record storage patterns |
| `powerdns_example.zig` | PowerDNS-style backend |

## Experimental Showcases

These demonstrate experimental/scaffolding features. They are NOT reference implementations:

| Example | Description |
|---------|-------------|
| `post_quantum_showcase.zig` | PQ crypto scaffolding demonstration |
| `hybrid_crypto_banking.zig` | Hybrid crypto concepts (experimental) |
| `nextgen_database.zig` | Async/crypto/indexing scaffolding demo |

## Domain Examples

Larger examples showing domain-specific patterns:

| Example | Description |
|---------|-------------|
| `production_database_server.zig` | Connection pooling, backup, monitoring patterns |
| `blockchain_integration.zig` | Blockchain-style patterns |
| `ghostmesh_vpn_coordination.zig` | VPN coordination patterns |
| `secure_storage_system.zig` | Encrypted storage patterns |

## Building Examples

Examples use `@import("zqlite")` and require the library as a dependency:

```bash
# Build all examples
zig build

# Examples are built but not installed by default
# To run an example, build it as an executable
```

## Notes

- Examples marked "experimental" use scaffolding features that are not stable
- Domain examples demonstrate patterns but may need adaptation for real use
- All examples are for demonstration purposes
