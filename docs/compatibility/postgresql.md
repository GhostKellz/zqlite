# PostgreSQL-Style Features

ZQLite includes a growing set of PostgreSQL-style features, but it is not a PostgreSQL server replacement.

## Present Features

- `RETURNING` on data modification statements
- `ON CONFLICT` / UPSERT forms
- window functions
- CTE-related AST/planner support where implemented
- richer value types than a minimal SQLite-style engine
- capability/status introspection for experimental crypto surfaces

## Positioning

Use ZQLite as:
- an embedded SQL database,
- with SQLite-style workflows,
- plus selected PostgreSQL-inspired syntax and ergonomics.

Do not position it as:
- a PostgreSQL wire-compatible server,
- a full PostgreSQL operational replacement,
- or a drop-in backend for applications expecting full PostgreSQL semantics.

## Near-Term Priorities After v1.6.0

- broader `RETURNING` coverage and edge cases
- richer date/time behavior
- improved JSON helpers
- stronger CTE coverage
- more planner/executor compatibility tests

## Candidate Next Features

- stronger CTE execution coverage, especially multi-step and nested cases
- more PostgreSQL-style JSON helpers that stay small and testable
- richer timestamp/date arithmetic and formatting behavior
- broader `RETURNING` and `ON CONFLICT` edge-case coverage
- additional window-function framing support where implementation stays contained

## Scope Boundary

- no PostgreSQL wire protocol claim
- no promise of PostgreSQL catalog, extension, or operational compatibility
- no assumption that PostgreSQL-specific behavior is present unless documented and tested
