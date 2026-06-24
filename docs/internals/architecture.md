# Architecture

This document describes ZQLite's package structure, query path, persistence
model, build profiles, and security/PQC boundaries.

## High-Level Overview

```mermaid
flowchart TD
    zig["Zig application"] --> root["zqlite module"]
    c["C/C++ application"] --> capi["C ABI<br/>include/zqlite.h"]
    shell["zqlite CLI"] --> root

    capi --> root

    root --> conn["Connection API"]
    conn --> stmt["Prepared statements"]
    conn --> exec["Direct execute/query"]

    stmt --> parser["Parser"]
    exec --> parser
    parser --> planner["Planner"]
    planner --> vm["Execution VM"]

    vm --> storage["Storage engine"]
    storage --> memory["In-memory database"]
    storage --> file["File-backed database"]

    file --> pager["Pager"]
    file --> wal["Write-ahead log"]
    file --> catalog["Versioned catalog"]
    file --> btree["B+ tree pages"]

    conn --> secure["Secure mode<br/>ATTACH policy"]
    root --> compat["SQLite + PostgreSQL-style compatibility"]
    root --> experimental["Experimental opt-ins"]
```

## Source Layout

```text
src/
├── db/              # Connection, storage, B-tree, WAL, pager, encryption helpers
├── parser/          # Tokenizer, AST, SQL parser
├── executor/        # Planner, VM, functions, prepared statements, window functions
├── ffi/             # Stable C ABI wrapper
├── shell/           # CLI
├── sqlite_compat/   # SQLite-style compatibility helpers
├── crypto/          # Experimental/internal crypto surfaces
├── transport/       # Experimental PQ transport scaffolding
├── concurrent/      # Experimental concurrency, MVCC, hot standby, 2PC work
├── runtime/         # Runtime primitives
└── performance/     # Query cache and cache management
```

## Query Flow

```mermaid
sequenceDiagram
    participant App as Application
    participant Conn as Connection
    participant Parser as Parser
    participant Planner as Planner
    participant VM as Execution VM
    participant Store as Storage Engine
    participant WAL as WAL / Pager

    App->>Conn: execute/query/prepare SQL
    Conn->>Parser: tokenize and parse
    Parser-->>Conn: AST or syntax error
    Conn->>Planner: build execution plan
    Planner-->>Conn: plan or unsupported feature error
    Conn->>VM: execute plan
    VM->>Store: read/write rows and catalog
    Store->>WAL: append, flush, checkpoint as required
    WAL-->>Store: durability result
    Store-->>VM: rows or storage error
    VM-->>Conn: result set / changes / error
    Conn-->>App: caller-owned or borrowed result per API docs
```

## Persistence Flow

```mermaid
flowchart TD
    write["INSERT / UPDATE / DELETE / DDL"] --> txn{"Transaction active?"}
    txn -->|"no"| implicit["Implicit transaction"]
    txn -->|"yes"| active["Active transaction/savepoint"]

    implicit --> wal_append["Append WAL records"]
    active --> wal_append

    wal_append --> sync{"Durability boundary"}
    sync --> commit["COMMIT / checkpoint / flush / close"]
    commit --> fsync["Flush and sync errors propagate"]
    fsync --> catalog{"Catalog change?"}

    catalog -->|"yes"| catalog_pages["Versioned multi-page catalog<br/>checksum + active slot"]
    catalog -->|"no"| data_pages["Data pages"]

    catalog_pages --> recover["Reopen recovery"]
    data_pages --> recover
    recover --> outcome["Committed data preserved<br/>uncommitted data rolled back"]
```

## Build Profiles

```mermaid
flowchart LR
    build["build.zig"] --> profile{"-Dprofile"}

    profile --> core["core<br/>minimal stable engine"]
    profile --> advanced["advanced<br/>default stable optional features + C ABI"]
    profile --> experimental["experimental<br/>explicit research surfaces"]
    profile --> full["full<br/>compatibility alias"]

    core --> stable["Stable database core"]
    advanced --> stable
    advanced --> c_api["C ABI"]
    experimental --> exp_modules["crypto / transport / distributed scaffolding"]
    full --> experimental

    exp_modules --> warning["No production claim without tests, diagnostics, and review"]
```

## Compatibility Boundary

```mermaid
flowchart TD
    app_need{"Application need"}

    app_need --> sqlite["SQLite-style embedded persistence"]
    app_need --> pg["PostgreSQL-style SQL ergonomics"]
    app_need --> pqc["PQC or secure transport"]
    app_need --> server["PostgreSQL server replacement"]

    sqlite --> supported["Supported subset documented in compatibility/sqlite.md"]
    pg --> selected["Selected features documented in compatibility/postgresql.md"]
    pqc --> experimental["Opt-in stdlib adapter; transport/support claims require verification"]
    server --> no["Not a PostgreSQL wire-compatible server"]

    supported --> tests["Differential and compatibility tests"]
    selected --> pg_tests["Feature-specific compatibility tests required"]
    experimental --> pqc_tests["PQC verification tests required before claims expand"]
```

## Security and PQC Boundary

```mermaid
flowchart TD
    request["Consumer requests security-sensitive feature"] --> stable{"Stable feature?"}

    stable -->|"yes"| documented["Use documented API and tests"]
    stable -->|"no"| experimental{"Experimental opt-in enabled?"}

    experimental -->|"no"| unavailable["Feature unavailable or explicit error"]
    experimental -->|"yes"| capability["Capability status reported"]

    capability --> real{"Real backend active?"}
    real -->|"yes"| verified["Must pass vectors, negative tests, diagnostics, and review gate"]
    real -->|"no"| fallback["Fallback/simulated status must be explicit and observable"]

    fallback --> no_claim["No production PQC claim"]
```

## Downstream Contract

- Stable Zig APIs document allocator ownership and result lifetimes.
- Stable C ABI functions document borrowed versus caller-owned strings and blobs.
- On-disk format changes require versioning, compatibility policy, and migration or export/import guidance.
- Experimental modules are not part of the stable compatibility promise.
- Security and PQC claims must map to tests, diagnostics, and release artifacts.
