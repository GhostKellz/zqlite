# Release Process

## Before Release

Run:

```bash
zig build test
zig build test-quick
zig build test-security
```

## Release Checklist

- update `src/version.zig`
- update `CHANGELOG.md`
- confirm root docs are current
- confirm experimental docs do not overstate maturity
- verify new features have tests

## After Verification

- tag the release
- publish release notes
- publish verified artifacts
