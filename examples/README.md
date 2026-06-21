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

These source-only design sketches demonstrate experimental/scaffolding features. They are not wired into `zig build examples`, are not required to compile against current APIs, and are NOT reference implementations:

| Example | Description |
|---------|-------------|
| `post_quantum_showcase.zig` | PQ crypto scaffolding demonstration |
| `hybrid_crypto_banking.zig` | Hybrid crypto concepts (experimental) |
| `nextgen_database.zig` | Async/crypto/indexing scaffolding demo |

## Domain Concept Demos

Larger source-only demonstrations containing placeholders and simulated integrations. They are not wired into the examples build and are design sketches, not deployable systems:

| Example | Description |
|---------|-------------|
| `production_database_server.zig` | Deployment-pattern sketch; despite the historical filename, not a production server |
| `blockchain_integration.zig` | Blockchain-style patterns |
| `ghostmesh_vpn_coordination.zig` | VPN coordination patterns |
| `secure_storage_system.zig` | Encrypted storage patterns |

## Building Examples

Examples use `@import("zqlite")` and require the library as a dependency:

```bash
# Build and install examples supported by the selected profile
zig build examples

# The experimental profile changes library features but does not certify
# source-only experimental/domain sketches as buildable examples.
zig build examples -Dprofile=experimental
```

## Notes

- Examples marked "experimental" use scaffolding features that are not stable
- Domain concept demos contain TODOs and simulated behavior and must not be presented as production implementations
- All examples are for demonstration purposes
