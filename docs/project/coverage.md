# Coverage Reporting

ZQLite tracks coverage expectations for the stable database core separately from experimental crypto, transport, and distributed modules.

## Stable Core Scope

Coverage reports should focus on:

- `src/db/`
- `src/parser/`
- `src/executor/`
- `src/ffi/`
- `src/sqlite_compat/`
- stable examples under `examples/`

Experimental areas such as PQ transport, clustering, and future liboqs linkage should not reduce stable-core coverage gates until they are promoted to supported release promises.

## Baseline Commands

Use the stable test set as the coverage workload:

```bash
./scripts/coverage-report.sh
```

The script requires `kcov`, builds stable test executables in Debug mode, runs
each executable under the collector, and merges the results. It writes the HTML
report and Cobertura XML under `zig-out/coverage/report/kcov-merged/`. Crypto,
transport, distributed, cluster, and wallet sources are excluded from this
stable-core report.

The run also writes `zig-out/coverage/report/summary.json` with stable
`lines_valid`, `line_rate`, and `branch_rate` fields. It fails closed when the
collector reports zero valid project lines. Set `ZQLITE_MIN_LINE_COVERAGE` to enforce
a previously observed clean-run line-rate floor. Keep it unset while collecting
a new runner baseline; never guess a percentage from a machine without `kcov`.

The Arch `kcov 43` package, a locally rebuilt BFD-enabled `kcov 43`, and current
upstream `kcov` all reject the pinned Zig DWARF as zero project lines. Coverage
therefore remains informational: CI skips collection when `kcov` is absent and
does not upload an artifact when collection fails or reports zero valid lines.

## Release Expectation

Coverage reporting remains informational. Do not fail release builds on a percentage until:

- generated files and experimental modules are excluded consistently
- line and branch thresholds are recorded here
- the threshold has passed on at least one clean release validation run
