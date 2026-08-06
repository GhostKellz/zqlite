# Performance Evidence

ZQLite keeps correctness gates and performance evidence separate. Timing varies
by runner, filesystem, CPU governor, and build mode, so release validation should
only fail on low-noise thresholds that have been proven stable.

## Targets

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
