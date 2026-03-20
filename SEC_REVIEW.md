# ZQLite Security Review

Date: 2026-03-20
Scope: full repository review with focus on SQL injection, unsafe input handling, file/path boundaries, FFI/memory safety, supply-chain risks, insecure defaults, logging exposure, and example code that may be copied into production.

## Security task list

- [x] Map repository structure and identify security-sensitive components
- [x] Review auth, input handling, SQL/query execution, and filesystem/network boundaries
- [x] Assess dependency and configuration security posture
- [x] Document findings, severity, exploit scenarios, and remediations

## Executive summary

The codebase has strong foundations (prepared statement support exists, secure-zeroing utilities are present, and some hardening helpers are implemented), but there are multiple high-impact security gaps. The most urgent issues are SQL injection in package-management paths, fail-open integrity verification, and supply-chain risk in installer scripts. These should be addressed immediately as part of this security update.

## Findings

### 1) Critical: SQL injection in dynamic SQL construction (Package Manager)

Affected:
- `src/zeppelin/package_manager.zig:151`
- `src/zeppelin/package_manager.zig:191`
- `src/zeppelin/package_manager.zig:212`
- `src/zeppelin/package_manager.zig:261`
- `src/zeppelin/package_manager.zig:301`

Issue:
Untrusted values are interpolated directly into SQL statements using `std.fmt.allocPrint(...)` with quoted string formatting. Any embedded `'` or crafted payload can alter query semantics.

Exploit scenario:
If package metadata, package IDs, or search pattern are attacker-controlled, payloads such as `' OR 1=1 --` can bypass filters or manipulate stored data.

Recommendation:
- Replace all formatted SQL in these paths with prepared statements and bound parameters.
- Validate and constrain package identifiers/version strings to strict allowed character sets.
- Add regression tests with malicious payloads.

---

### 2) High: Integrity verification fails open when crypto engine unavailable

Affected:
- `src/zeppelin/package_manager.zig:295`

Issue:
`verifyPackageIntegrity(...)` returns `true` when `crypto_engine == null`, effectively disabling verification silently.

Exploit scenario:
Tampered packages are accepted in deployments where crypto initialization fails or is omitted.

Recommendation:
- Fail closed (`return false` or explicit error) when cryptographic verification is unavailable.
- Require explicit opt-in insecure mode with noisy warnings.

---

### 3) High: WAL deserialization trusts attacker-controlled lengths (DoS risk)

Affected:
- `src/db/wal.zig:636`
- `src/db/wal.zig:639`
- `src/db/wal.zig:648`
- `src/db/wal.zig:655`

Issue:
`old_data_len` and `new_data_len` are read from WAL bytes and used for allocations without hard upper bounds.

Exploit scenario:
Crafted WAL entries can trigger oversized allocations and process memory exhaustion.

Recommendation:
- Enforce strict per-entry and total replay byte caps.
- Reject records exceeding configured limits before allocation.
- Add malformed WAL fuzz tests.

---

### 4) High: Supply-chain risk in installation scripts (unverified artifacts/source)

Affected:
- `install.sh:54`
- `install.sh:47`
- `GhostwireInstall.sh:101`
- `GhostwireInstall.sh:124`
- `GhostwireInstall.sh:127`

Issue:
Installers download and execute/extract remote artifacts or clone repos without checksum/signature verification or immutable pinning.

Exploit scenario:
Compromised mirror/release/repo could deliver malicious code during installation.

Recommendation:
- Pin immutable release artifacts and commit SHAs.
- Verify artifact checksums/signatures before extraction/build.
- Avoid `curl ... | tar ...` patterns without integrity checks.

---

### 5) Medium: ATTACH/.open path access lacks policy/canonicalization controls

Affected:
- `src/db/connection.zig:443`
- `src/parser/parser.zig:661`

Issue:
Arbitrary file paths can be attached/opened with no root-policy enforcement.

Exploit scenario:
In embedded/server contexts where SQL is user-influenced, this can expose unintended local files.

Recommendation:
- Canonicalize paths and enforce allowed root directories.
- Add runtime policy hooks for `ATTACH`/open operations.

---

### 6) Medium: C FFI string APIs can leak memory under repeated calls

Affected:
- `src/ffi/c_api.zig:307`
- `src/ffi/c_api.zig:320`
- `src/ffi/c_api.zig:382`

Issue:
`zqlite_result_get_text` duplicates strings on each call and returns raw pointers, but there is no dedicated free API for those returned buffers.

Exploit scenario:
High-frequency host calls can leak memory and eventually cause DoS.

Recommendation:
- Provide a matching free API for returned text pointers or return borrow-only buffers with strict lifetime docs.
- Audit bind path ownership to avoid duplicate unmanaged allocations.

---

### 7) Medium: Insecure defaults (foreign keys off, plain encryption init paths)

Affected:
- `src/sqlite_compat/sqlite_compatibility.zig:390`
- `src/db/pager.zig:209`

Issue:
Security-sensitive settings default to weaker behavior in compatibility/runtime paths.

Exploit scenario:
Applications relying on defaults may unintentionally run with weaker integrity/confidentiality guarantees.

Recommendation:
- Prefer secure defaults in production profiles.
- Emit startup warnings when insecure defaults are active.

---

### 8) Medium: Production server example contains dangerous placeholders

Affected:
- `examples/production_database_server.zig:89`
- `examples/production_database_server.zig:232`
- `examples/production_database_server.zig:297`

Issue:
Hardcoded master key, query logging, and auth function that returns `true` for all credentials.

Exploit scenario:
Teams copying example code into production may introduce immediate auth bypass and sensitive data exposure.

Recommendation:
- Label as insecure demo, or replace with secure reference implementation.
- Remove hardcoded secrets and enforce real credential validation.
- Redact sensitive query/log fields.

---

### 9) Low: Naive JSON compatibility helpers may mis-validate input ✅ FIXED

Affected:
- `src/sqlite_compat/sqlite_compatibility.zig` (JSON helper functions)

Issue:
Simplistic JSON validation/extraction behavior can differ from strict parser semantics.

Exploit scenario:
Callers expecting strict JSON validity may accept malformed inputs.

Recommendation:
- Use `std.json` parser for validation and extraction.

**Resolution:** Replaced all naive string-based JSON parsing with `std.json` parser:
- `jsonExtract()` - Now parses JSON and navigates paths properly
- `jsonSet()` - Parses, modifies, and re-serializes using std.json
- `jsonValid()` - Uses std.json.parseFromSlice for strict validation
- Added `jsonValidateWithError()` for detailed error reporting
- Added `jsonType()` helper function

---

### 10) Low: Potential sensitive-data leakage through logging ✅ FIXED

Affected:
- `src/logging/logger.zig`
- `src/production/hardening.zig` (audit detail logging paths)

Issue:
Logging APIs can emit raw details if callers pass secrets/tokens/PII.

Recommendation:
- Add centralized redaction utilities and safe structured logging conventions.

**Resolution:** Added comprehensive redaction infrastructure:
- `SensitiveDataRedactor` struct with pattern-based detection (password, token, api_key, etc.)
- `redactString()` - Redacts values matching sensitive key patterns
- `redactEmails()` - Redacts email addresses
- `SafeLogger` wrapper that auto-redacts logged messages
- `AuditLogger` now auto-redacts by default via `enable_redaction` flag
- Added `logSafe()` method for pre-validated content

## Positive security patterns

- Prepared statement/bind flow exists and can be reused for remediation:
  - `src/db/connection.zig:787`
- Secure memory wipe helpers are present:
  - `src/production/hardening.zig:14`
  - `src/db/encryption.zig:93`
- Constant-time compare utility exists:
  - `src/production/hardening.zig:27`
- WAL page-write copy paths include bounds checks before memcpy:
  - `src/db/wal.zig:267`

## Recommended remediation plan

### Immediate (0-48h)

1. Replace dynamic SQL in `package_manager.zig` with prepared statements and bindings.
2. Change integrity verification to fail closed when crypto engine is unavailable.
3. Add WAL size limits to deserialization and reject oversized entries.
4. Patch installer scripts to require checksum/signature verification.

### Short-term (this release)

1. Add configurable path policy for `ATTACH`/open operations.
2. Fix C FFI ownership API for returned strings and run leak tests.
3. Turn on secure defaults (or explicit production profile with secure settings).
4. Replace insecure production example placeholders.

### Backlog

1. ~~Harden logging redaction and safe logging guidelines.~~ ✅ DONE - Added `SensitiveDataRedactor` and `SafeLogger` in logger.zig, updated `AuditLogger` to auto-redact
2. ~~Replace naive JSON compatibility parsing with strict parser-based implementation.~~ ✅ DONE - JSONFunctions now uses std.json parser
3. Add fuzzing for WAL and parser boundary conditions.

## Suggested verification gates for this security update

- Add tests proving SQLi payloads do not alter query behavior in package manager APIs.
- Add tests confirming verification fails when crypto engine is absent.
- Add WAL malformed/oversized replay tests.
- Add CI step for installer artifact integrity verification logic.
