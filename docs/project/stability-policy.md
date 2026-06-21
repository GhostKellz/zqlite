# Stability and Compatibility Policy

ZQLite separates its supported embedded-database surface from partial and experimental work. Build inclusion does not by itself imply API stability or production readiness.

## Supported Product Surface

The stable product surface consists of:

- SQL parsing and execution for the documented compatibility subset
- in-memory and Linux file-backed databases
- B+ tree storage and write-ahead logging through the high-level connection API
- transactions, prepared statements, full-text search, ATTACH policy, and the CLI
- the functions declared in `include/zqlite.h`

Only documented high-level behavior is covered by compatibility commitments. Public Zig declarations exposing engine internals remain accessible for development but are not stable merely because they are declared `pub`.

## Build Profiles

| Profile | Stability | Contents |
|---|---|---|
| `core` | Stable | Embedded SQL engine and CLI without optional cache, JSON, concurrency, or C ABI features |
| `advanced` | Stable default | Core plus JSON, query cache/performance helpers, concurrency helpers, and C ABI libraries |
| `experimental` | Experimental | Advanced plus crypto and simulated transport scaffolding |
| `full` | Compatibility alias | Identical to `experimental`; retained for existing build automation |

Individual feature flags may override profile defaults. Enabling an experimental flag does not change its stability classification.

## Export Classification

| Export or area | Classification | Compatibility commitment |
|---|---|---|
| `open`, `openMemory`, `Connection` high-level operations | Stable | Source-compatible within the current major line unless a security or correctness issue requires a change |
| transactions and prepared statements | Stable | Documented behavior is supported |
| tokenizer, AST, parser | Stable parser capability; partial low-level API | SQL behavior is supported; AST representation may evolve |
| storage, B-tree, WAL, pager | Internal/unstable | Use through `Connection`; direct APIs and layouts may change |
| planner and VM | Internal/unstable | No direct compatibility commitment |
| CLI | Stable command surface | Documented flags and dot commands are supported |
| C functions in `include/zqlite.h` | Stable ABI | Numeric errors and declared signatures are compatibility-controlled |
| JSON | Stable documented subset | Unsupported JSON behavior must be treated as partial |
| query cache and performance helpers | Partial | APIs and invalidation details may evolve |
| connection pool and runtime primitives | Partial | Suitable for evaluation; concurrency semantics may evolve |
| window functions and advanced indexes | Partial | Only documented/tested subsets are supported |
| logging, hardening, compatibility, and enhanced errors | Partial | Utility APIs may evolve |
| encryption building blocks | Experimental/internal | Not a transparent database-at-rest encryption guarantee |
| crypto, PQ capability, and transport | Experimental | No production-security claim or stable API commitment |
| cluster, distributed, hot-standby, two-phase commit, wallet, and Zeppelin modules | Experimental/internal | Not exported as stable package features |

## Compatibility Rules

### Zig API

- Stable high-level APIs follow semantic-versioning intent.
- Additive APIs may be introduced without breaking existing stable callers.
- Breaking changes to a stable API require explicit migration notes and an appropriate major compatibility boundary.
- Partial, experimental, and internal APIs may change, but changes must be documented when they affect examples or known consumers.

### C ABI

- The installed `zqlite.h` file is the ABI source of truth.
- Existing function signatures and error-code values may not change within the current major compatibility line.
- New functions must be additive.
- Header declarations, implementation exports, documentation, and packaged symbols are verified together.

### Database Files

- ZQLite must not knowingly reinterpret an existing database incompatibly.
- Until the catalog has an explicit format version, compatibility is best-effort and layout changes require reopen/persistence regression tests.
- Once format versioning is implemented, unsupported newer formats must fail explicitly, and incompatible changes require a migration path or documented export/import procedure.

## Experimental Promotion Criteria

An experimental component can be promoted only after all of the following are true:

1. The implementation contains no placeholders, simulated success paths, or silent security fallback.
2. Its behavior and failure model are documented.
3. It has deterministic unit, integration, persistence, and adversarial tests appropriate to its risk.
4. It runs in the stable CI matrix on every claimed platform.
5. Resource ownership, concurrency, cancellation, and error semantics are specified.
6. Public APIs and compatibility expectations are reviewed.
7. Security-sensitive functionality has appropriate independent review before production claims are made.

Components with no maintained implementation plan should be archived rather than represented as active stable functionality.
