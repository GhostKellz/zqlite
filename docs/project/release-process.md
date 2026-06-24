# Release Process

## Pre-Release Validation

Run full test suite:

```bash
./scripts/test-release.sh
```

Full release validation builds packages, runs consumers, and exercises multiple
profiles. Run it on an otherwise idle workstation or CI runner. Package/install
scratch work defaults to the project's normal repo-local `.zig-cache`:

```bash
./scripts/test-release.sh
```

Build reproducible local release artifacts:

```bash
./scripts/build-release-artifacts.sh
```

The artifact script writes:

- `zqlite-source-package.tar.gz`
- `zqlite-source-package.tar.gz.sha256`
- `SHA256SUMS`
- `SBOM.txt`

If `ZQLITE_MINISIGN_KEY` is set and `minisign` is installed, the archive is
signed with minisign. If `ZQLITE_GPG_SIGN=1` and `gpg` is installed, the archive
also gets an armored detached GPG signature.

Verify generated artifacts:

```bash
./scripts/verify-release-artifacts.sh
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
zig build check-c-api
zig build test-release-package
zig build test-install
zig build test-stable-profiles
zig build bench-validate
zig build bench-operational
```

When a prior release archive is available, check that the current C ABI manifest
does not remove exported symbols:

```bash
./scripts/check-abi-compat.sh /path/to/prior-zqlite-source-package.tar.gz
```

## Release Checklist

- [ ] All tests pass locally
- [ ] Update version in `build.zig.zon`
- [ ] Update `CHANGELOG.md` with changes
- [ ] Verify docs accuracy (especially experimental features)
- [ ] Verify all profiles build and the experimental profile remains opt-in
- [ ] Verify the packaged Zig and C consumer smoke tests
- [ ] Verify `include/zqlite_c.symbols` matches the C header, implementation, and packaged shared library
- [ ] Compare the C ABI manifest against the previous release archive when one exists
- [ ] Verify `zig fetch` consumption from the generated release archive
- [ ] Generate and verify release checksums
- [ ] Generate and review the release SBOM
- [ ] Verify release archive contents with `./scripts/verify-release-artifacts.sh`
- [ ] Generate optional detached signatures when release keys are available
- [ ] Archive the self-hosted stable-core coverage workload report
- [ ] Capture optional `zig build bench-operational` output for release notes when the runner is idle
- [ ] Tag release: `git tag v1.x.x`
- [ ] Push tag: `git push origin v1.x.x`

## Version Files

Version is defined in:
- `build.zig.zon` - package metadata (source of truth)
- `src/version.zig` - runtime constants derived from generated build options

Build metadata (git commit, date) uses static values in `build.zig` for portability with source archives.

## Post-Release

- Create GitHub release with changelog excerpt
- Verify `zig fetch` works with the published tag/archive URL
