<h1 align="center">ZQLite</h1>

<p align="center">
  <strong>Embedded SQL Database in Pure Zig</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Zig">
  <img src="https://img.shields.io/badge/SQLite_Compatible-003B57?style=for-the-badge&logo=sqlite&logoColor=white" alt="SQLite Compatible">
  <img src="https://img.shields.io/badge/PostgreSQL_Features-4169E1?style=for-the-badge&logo=postgresql&logoColor=white" alt="PostgreSQL Features">
  <img src="https://img.shields.io/badge/ChaCha20--Poly1305-8B5CF6?style=for-the-badge&logo=keycdn&logoColor=white" alt="ChaCha20-Poly1305">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zero_Dependencies-22C55E?style=for-the-badge&logo=checkmarx&logoColor=white" alt="Zero Dependencies">
  <img src="https://img.shields.io/badge/Memory_Safe-10B981?style=for-the-badge&logo=verified&logoColor=white" alt="Memory Safe">
  <img src="https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux">
</p>

---

## What is ZQLite?

An embedded SQL database written in Zig. SQLite-style simplicity with some PostgreSQL conveniences.

**Stable features:**
- SQL parser (SELECT, INSERT, UPDATE, DELETE, JOINs, aggregates, subqueries)
- B+ tree storage with write-ahead logging
- In-memory and file-based databases
- Prepared statements with parameter binding
- Field-level encryption (ChaCha20-Poly1305)
- C FFI bindings

**Experimental features** (not stable):
- Post-quantum crypto scaffolding (ML-KEM, ML-DSA)
- Transport layer hooks

See [Stable vs Experimental](docs/security/stable-vs-experimental.md) for details.

## Install

Requires Zig 0.16.0-dev.2960 or later

```bash
# Tagged release (recommended)
zig fetch --save https://github.com/ghostkellz/zqlite/archive/refs/tags/v1.6.0.tar.gz

# Or main branch
zig fetch --save https://github.com/ghostkellz/zqlite/archive/main.tar.gz
```

```zig
// build.zig
const zqlite = b.dependency("zqlite", .{});
exe.root_module.addImport("zqlite", zqlite.module("zqlite"));
```

## Usage

```zig
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.openMemory(allocator);
    defer conn.close();

    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.execute("INSERT INTO users (name) VALUES ('Alice')");

    var stmt = try conn.prepare("SELECT * FROM users WHERE name = ?");
    defer stmt.deinit();

    try stmt.bind(0, "Alice");
    var result = try stmt.execute();
    defer result.deinit();

    for (result.rows.items) |row| {
        // process row
    }
}
```

## Build from Source

```bash
git clone https://github.com/ghostkellz/zqlite.git
cd zqlite
zig build
zig build test
```

## Test

```bash
zig build test                    # Unit tests
zig build test-security           # Security tests
zig build test-memory-leaks       # Memory leak detection
zig build test-comprehensive      # Full test suite
```

Docker testing:
```bash
docker-compose -f docker/docker-compose.yml run --rm zqlite-full
```

## Documentation

- [Installation](docs/getting-started/installation.md)
- [Quickstart](docs/getting-started/quickstart.md)
- [Zig API](docs/api/zig-api.md)
- [C API](docs/api/c-api.md)
- [Transactions](docs/guides/transactions.md)
- [Encryption](docs/guides/encryption.md)
- [Secure Mode](docs/guides/secure-mode.md)
- [SQLite Compatibility](docs/compatibility/sqlite.md)
- [PostgreSQL Features](docs/compatibility/postgresql.md)

## Project Status

**v1.6.0** - Beta

Core database functionality is stable and tested. The project is under active development.

What works well:
- Basic CRUD operations
- JOINs, GROUP BY, ORDER BY, LIMIT
- RETURNING clause, ON CONFLICT (upsert)
- Prepared statements
- Encryption at rest

What's still experimental:
- Post-quantum crypto (scaffolding only)
- Some edge cases in complex queries

## License

MIT
