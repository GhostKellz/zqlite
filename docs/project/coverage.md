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

The script runs the stable core tests with normal project cache behavior and prints the files/scopes that should be fed into a runner-level coverage collector such as `kcov`, `llvm-cov`, or the Zig coverage mode selected for the release runner.

## Release Expectation

For v1.7.0, coverage reporting is informational. Do not fail release builds on a percentage until:

- the CI runner has one selected coverage collector
- generated files and experimental modules are excluded consistently
- line and branch thresholds are recorded here
- the threshold has passed on at least one clean release validation run
