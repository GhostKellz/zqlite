# Performance Evidence

ZQLite keeps correctness gates and performance evidence separate. Timing varies
by runner, filesystem, CPU governor, and build mode, so release validation should
only fail on low-noise thresholds that have been proven stable.

## Targets

Measure indexed-query behavior with:

```bash
zig build bench-index-evidence -Doptimize=ReleaseSafe
```

This emits JSON records for literal and rebound prepared lookups through unique
and non-unique single-column indexes, before/after `ANALYZE` and after reopen.
It reports plans, scanned rows, successful allocation requests, requested bytes,
live and peak additional allocator bytes, latency, and database file sizes.
Scan counts include both candidate retrieval and WHERE filtering. Duplicate
lookup cost scales with matching candidates; hash collisions can add candidates.

The [recorded comparison](index-evidence.json) uses the tagged baseline and the
working-tree implementation with the same compiler on one Linux host. Its
timings are individual samples, not regression thresholds. The allocation
counter and DebugAllocator also affect absolute timing.

For 32 prepared unique lookups over 1024 rows immediately after index creation:

| Metric | Baseline | Updated |
|---|---:|---:|
| Scanned rows, including filtering | 65536 | 64 |
| Allocation requests | 134240 | 5664 |
| Peak additional allocator bytes | 286302 | 14143 |

The original C comparison's 200 lookups took approximately 81.5 ms on the
baseline and 3.1 ms after the change in these samples. Its ZQLite database size
fell from 286720 to 147456 bytes. SQLite remained faster and smaller in that
workload; this is evidence of improvement relative to ZQLite's baseline.

The size reduction removes derived index pages from the database file. Index
definitions persist, but trees are reconstructed in owned memory pagers.
Reopening no longer appends index pages; old unreferenced pages require VACUUM
to reclaim. Ordinary writes now maintain affected entries incrementally; open
and rollback still rebuild derived trees. UPDATE and DELETE still scan to locate
matching table rows. Empty/underfull index pages are retained until a rebuild,
and total derived-index memory budgeting remains future work.

Measure write scaling with `zig build bench-write-evidence -Doptimize=ReleaseSafe`.
The [write comparison](write-evidence.json) uses the working tree immediately
before this batch as its baseline, including the preceding query improvements.
It runs 32 prepared inserts, updates, and deletes over 128, 1024, and 4096 initial
rows with two indexes in an explicit in-memory transaction. Timed regions exclude
setup and commit; this measures index/VM work, not durable commit throughput.
The same DebugAllocator-backed counter is used in both builds. Timings are
individual samples, not thresholds; allocation counts are the stronger signal.

At 4096 initial rows, the recorded 32-operation samples were:

| Operation | Before | After | Allocation requests, before → after |
|---|---:|---:|---:|
| INSERT | 6180.8 ms | 1.9 ms | 37,444,061 → 18,683 |
| UPDATE | 6215.9 ms | 52.8 ms | 37,602,167 → 566,167 |
| DELETE | 6219.3 ms | 50.2 ms | 37,450,135 → 549,793 |


Use the existing regression validator for low-noise release checks:

```bash
zig build bench-validate
```

Use the operational benchmark when collecting release notes or comparing changes
locally:

```bash
zig build bench-operational
```

`bench-operational` reports:

- append-heavy transactional inserts
- indexed point lookups
- materialized full scans
- cursor full scans
- resource-limit abort overhead

Collect machine-readable storage evidence with:

```bash
zig build bench-storage-evidence
```

It emits database growth, peak and post-checkpoint WAL bytes, checkpoint time,
and live allocator bytes during a fixed file-backed workload as one JSON object.

For an equivalent-schema comparison against the system SQLite library:

```bash
./scripts/sqlite-comparison.sh
```

This uses one durable transaction for 1,000 inserts, indexed point lookups, and
SQLite `WAL` plus `synchronous=FULL`. It writes the raw nanosecond and file-size
results to `zig-out/performance/sqlite-comparison.json`. ZQLite currently
checkpoints as part of commit while SQLite WAL commit and checkpoint are
separate, so the JSON is evidence, not a claim of architectural equivalence or
superiority.

The operational benchmark is informational evidence. It should not become a
release-blocking threshold until the same scenario is stable on the selected
self-hosted runner.

Only promote a timing threshold after repeated samples on the selected runner;
file sizes and zero-after-checkpoint WAL state are the lower-noise release
regression signals.
