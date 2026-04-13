# Release Process

## Pre-Release Validation

Run full test suite:

```bash
./scripts/test-release.sh
```

Or manually:

```bash
zig fmt --check src/ examples/ tests/
zig build test
zig build test-quick
zig build test-advanced
zig build test-security
zig build test-comprehensive
zig build test-storage
zig build test-c-api
zig build bench-validate
```

## Release Checklist

- [ ] All tests pass locally
- [ ] Update version in `build.zig.zon`
- [ ] Update `CHANGELOG.md` with changes
- [ ] Verify docs accuracy (especially experimental features)
- [ ] Tag release: `git tag v1.x.x`
- [ ] Push tag: `git push origin v1.x.x`

## Version Files

Version is defined in:
- `build.zig.zon` - package metadata (source of truth)
- `src/version.zig` - runtime constants (must match)

Build metadata (git commit, date) uses static values in `build.zig` for portability with source archives.

## Post-Release

- Create GitHub release with changelog excerpt
- Verify `zig fetch` works with new tag URL
