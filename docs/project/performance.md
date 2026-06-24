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

The operational benchmark is informational evidence. It should not become a
release-blocking threshold until the same scenario is stable on the selected
self-hosted runner.

## Open Work

SQLite comparison baselines remain separate. They should use equivalent schemas,
equivalent durability settings, and enough samples to avoid normal workstation
noise.
