# C API

FFI bindings for C/C++ integration. Requires build with `-Dffi=true`.

## Build

```bash
zig build -Dffi=true
```

The stable `advanced` profile enables FFI by default. The build installs both static and shared C ABI libraries (`libzqlite_c.a` and the platform shared-library equivalent) plus `include/zqlite.h`. Use `-Dffi=true` to enable FFI in another profile.

## ABI Version

The C ABI exposes an independent ABI version:

```c
#define ZQLITE_ABI_VERSION_MAJOR 1
#define ZQLITE_ABI_VERSION_MINOR 0
#define ZQLITE_ABI_VERSION_PATCH 0

int zqlite_abi_version(void);
int zqlite_abi_version_major(void);
int zqlite_abi_version_minor(void);
int zqlite_abi_version_patch(void);
```

Patch and minor ABI additions preserve existing function signatures and numeric constants. A major ABI bump is required for removing functions, changing ownership rules, changing struct handle semantics, or changing existing numeric return codes. Public C functions are declared with `ZQLITE_API`; symbols absent from `include/zqlite.h` are not part of the stable ABI.

## Error Codes

| Code | Name | Meaning |
|------|------|---------|
| 0 | ZQLITE_OK | Success |
| 1 | ZQLITE_ERROR | Generic error |
| 5 | ZQLITE_BUSY | Database locked |
| 7 | ZQLITE_NOMEM | Out of memory |
| 10 | ZQLITE_IOERR | I/O failure |
| 11 | ZQLITE_CORRUPT | Corrupt data |
| 19 | ZQLITE_CONSTRAINT | Constraint violation |
| 20 | ZQLITE_MISMATCH | Type mismatch |
| 21 | ZQLITE_MISUSE | API misuse |
| 25 | ZQLITE_RANGE | Parameter or column index out of range |
| 100 | ZQLITE_ROW | `zqlite_step()` produced a row |
| 101 | ZQLITE_DONE | `zqlite_step()` completed |

Stable error category codes:

| Category | Name | Meaning |
|----------|------|---------|
| 0 | ZQLITE_ERROR_CATEGORY_OK | No error |
| 1 | ZQLITE_ERROR_CATEGORY_SQL | SQL syntax, schema, or type error |
| 2 | ZQLITE_ERROR_CATEGORY_CONSTRAINT | Constraint violation |
| 3 | ZQLITE_ERROR_CATEGORY_IO | Storage or filesystem I/O error |
| 4 | ZQLITE_ERROR_CATEGORY_MISUSE | Invalid API use, parameter range, transaction state |
| 5 | ZQLITE_ERROR_CATEGORY_MEMORY | Allocation failure |
| 6 | ZQLITE_ERROR_CATEGORY_AUTHORIZATION | Authorization/security policy failure |
| 7 | ZQLITE_ERROR_CATEGORY_FORMAT | Corrupt or unsupported database format |
| 255 | ZQLITE_ERROR_CATEGORY_UNKNOWN | Unclassified error |

Prepared-statement column type codes:

| Code | Name |
|------|------|
| 1 | ZQLITE_TYPE_INTEGER |
| 2 | ZQLITE_TYPE_REAL |
| 3 | ZQLITE_TYPE_TEXT |
| 4 | ZQLITE_TYPE_BLOB |
| 5 | ZQLITE_TYPE_NULL |

## Functions

### Connection

```c
// Open database (use ":memory:" for in-memory)
zqlite_connection_t* zqlite_open(const char* path);

// Close connection
void zqlite_close(zqlite_connection_t* conn);

// Execute statement (no results)
int zqlite_execute(zqlite_connection_t* conn, const char* sql);

// Execute query (returns results)
zqlite_result_t* zqlite_query(zqlite_connection_t* conn, const char* sql);
```

### Results

```c
int zqlite_result_row_count(zqlite_result_t* result);
int zqlite_result_column_count(zqlite_result_t* result);
const char* zqlite_result_column_name(zqlite_result_t* result, int column);
int zqlite_result_get_type(zqlite_result_t* result, int row, int column);
const char* zqlite_result_get_text(zqlite_result_t* result, int row, int col);
void zqlite_result_free(zqlite_result_t* result);
```

### Prepared Statements

```c
zqlite_stmt_t* zqlite_prepare(zqlite_connection_t* conn, const char* sql);
int zqlite_bind_int(zqlite_stmt_t* stmt, int index, int64_t value);
int zqlite_bind_text(zqlite_stmt_t* stmt, int index, const char* value);
int zqlite_bind_real(zqlite_stmt_t* stmt, int index, double value);
int zqlite_bind_null(zqlite_stmt_t* stmt, int index);
int zqlite_bind_blob(zqlite_stmt_t* stmt, int index, const void* value, size_t len);
int zqlite_bind_int_named(zqlite_stmt_t* stmt, const char* name, int64_t value);
int zqlite_bind_text_named(zqlite_stmt_t* stmt, const char* name, const char* value);
int zqlite_bind_real_named(zqlite_stmt_t* stmt, const char* name, double value);
int zqlite_bind_null_named(zqlite_stmt_t* stmt, const char* name);
int zqlite_bind_blob_named(zqlite_stmt_t* stmt, const char* name, const void* value, size_t len);
int zqlite_step(zqlite_stmt_t* stmt);
int zqlite_column_count(zqlite_stmt_t* stmt);
const char* zqlite_column_name(zqlite_stmt_t* stmt, int column);
int zqlite_column_type(zqlite_stmt_t* stmt, int column);
int64_t zqlite_column_int64(zqlite_stmt_t* stmt, int column);
double zqlite_column_double(zqlite_stmt_t* stmt, int column);
const char* zqlite_column_text(zqlite_stmt_t* stmt, int column);
const void* zqlite_column_blob(zqlite_stmt_t* stmt, int column);
size_t zqlite_column_bytes(zqlite_stmt_t* stmt, int column);
int zqlite_reset(zqlite_stmt_t* stmt);
int zqlite_finalize(zqlite_stmt_t* stmt);
```

Prepared statement indices are zero-based. Named binds accept names with or without the leading
`:`, `@`, or `$` prefix and bind every matching repeated placeholder.

`zqlite_step()` returns `ZQLITE_ROW` while a row is available, `ZQLITE_DONE`
when execution is complete, or an error code. Column accessor pointers are
borrowed from the statement and remain valid until the next `zqlite_step()`,
`zqlite_reset()`, or `zqlite_finalize()` call on that statement.

### Transactions

```c
int zqlite_begin_transaction(zqlite_connection_t* conn);
int zqlite_commit_transaction(zqlite_connection_t* conn);
int zqlite_rollback_transaction(zqlite_connection_t* conn);
```

### Error Handling

```c
const char* zqlite_errmsg(zqlite_connection_t* conn);
int zqlite_errcode(zqlite_connection_t* conn);
int zqlite_errcategory(zqlite_connection_t* conn);
const char* zqlite_errsql(zqlite_connection_t* conn);
```

Error-message and error-SQL pointers are owned by the connection and remain valid only until the next operation updates its error state.
`zqlite_errcode()` returns the SQLite-compatible numeric code for the last connection error.
`zqlite_errcategory()` returns a stable coarse category suitable for application-level branching.

### Utilities

```c
const char* zqlite_version(void);
int zqlite_pq_available(void);
const char* zqlite_pq_status(void);
const char* zqlite_pq_backend(void);
const char* zqlite_pq_liboqs_status(void);
const char* zqlite_pq_diagnostics_json(void);
void zqlite_shutdown(void);
void zqlite_free_string(const char* str);
```

### Post-Quantum Status

```c
// Returns 1 only when a real PQ backend is active.
int zqlite_pq_available(void);

// Returns a human-readable runtime status message.
const char* zqlite_pq_status(void);

// Returns the backend tag name:
// "none", "native_fallback", "simulated", "hybrid", or "pqc".
const char* zqlite_pq_backend(void);

// Returns liboqs integration status:
// "not_configured", "configured_but_unlinked", or future "linked_active".
const char* zqlite_pq_liboqs_status(void);

// Returns allocated JSON diagnostics. Release with zqlite_free_string().
// The JSON includes "requested_provider", "provider", and "liboqs_status".
const char* zqlite_pq_diagnostics_json(void);
```

These functions are status/introspection helpers. The stable default reports no active PQ backend. Simulated and fallback states are never production PQC; `zqlite_pq_available()` returns `1` only for a real active backend. `-Dliboqs=true` currently reports `configured_but_unlinked`; it does not link liboqs or make liboqs production-ready.

## Example

```c
#include <stdio.h>

int main() {
    zqlite_connection_t* conn = zqlite_open(":memory:");
    if (!conn) return 1;

    zqlite_execute(conn, "CREATE TABLE test (id INTEGER, name TEXT)");
    zqlite_execute(conn, "INSERT INTO test VALUES (1, 'Alice')");

    zqlite_result_t* result = zqlite_query(conn, "SELECT * FROM test");
    if (result) {
        int rows = zqlite_result_row_count(result);
        for (int i = 0; i < rows; i++) {
            printf("Row %d: %s\n", i, zqlite_result_get_text(result, i, 1));
        }
        zqlite_result_free(result);
    }

    zqlite_close(conn);
    return 0;
}
```

## Memory Management

- All `zqlite_result_t*` must be freed with `zqlite_result_free()`
- All `zqlite_stmt_t*` must be freed with `zqlite_finalize()`
- Strings returned by `zqlite_result_get_text()` must be freed with `zqlite_free_string()`
- Strings returned by `zqlite_result_column_name()` are borrowed from the result and must not be freed
- Strings/blobs returned by `zqlite_column_text()` and `zqlite_column_blob()` are borrowed from the statement and must not be freed
- Strings returned by `zqlite_column_name()` are borrowed from the statement and must not be freed
- Error strings returned by `zqlite_errmsg()` and `zqlite_errsql()` are borrowed and must not be freed
- Call `zqlite_shutdown()` once at program exit to clean up global state

## ABI Contract

`include/zqlite.h` is the source of truth for supported C functions.
`include/zqlite_c.symbols` is the checked export manifest. Build validation
compares the header declarations, implementation exports, manifest entries,
numeric constants, and any built `libzqlite_c.so` exports.

Use:

```bash
zig build check-c-api
./scripts/check-abi-compat.sh /path/to/prior-zqlite-source-package.tar.gz
```

The compatibility script fails if the current manifest removes a symbol present
in a prior release archive. Undeclared implementation details and functions
absent from the installed header are not part of the stable ABI.
