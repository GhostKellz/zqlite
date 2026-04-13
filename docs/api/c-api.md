# C API

FFI bindings for C/C++ integration. Requires build with `-Dffi=true`.

## Build

```bash
zig build -Dffi=true
```

This produces a shared library based on the `zqlite_c` target (`libzqlite_c.so` / `zqlite_c.dll`, depending on platform).

## Error Codes

| Code | Name | Meaning |
|------|------|---------|
| 0 | ZQLITE_OK | Success |
| 1 | ZQLITE_ERROR | Generic error |
| 2 | ZQLITE_BUSY | Database locked |
| 4 | ZQLITE_NOMEM | Out of memory |
| 6 | ZQLITE_MISUSE | API misuse |
| 12 | ZQLITE_CONSTRAINT | Constraint violation |

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
int zqlite_step(zqlite_stmt_t* stmt);
int zqlite_reset(zqlite_stmt_t* stmt);
int zqlite_finalize(zqlite_stmt_t* stmt);
```

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
const char* zqlite_errsql(zqlite_connection_t* conn);
```

### Utilities

```c
const char* zqlite_version(void);
int zqlite_pq_available(void);
const char* zqlite_pq_status(void);
const char* zqlite_pq_backend(void);
void zqlite_shutdown(void);
void zqlite_free_string(const char* str);
```

### Post-Quantum Status

```c
// Returns 1 only when a real PQ backend is active.
int zqlite_pq_available(void);

// Returns a human-readable runtime status message.
const char* zqlite_pq_status(void);

// Returns the backend tag name: "none" or "native_fallback".
const char* zqlite_pq_backend(void);
```

These functions are status/introspection helpers. They do not imply that PQ cryptography is production-ready.

### Custom Allocator

```c
typedef void* (*ZqliteAllocFn)(size_t size, void* user_data);
typedef void (*ZqliteFreeFn)(void* ptr, void* user_data);
typedef void* (*ZqliteReallocFn)(void* ptr, size_t new_size, void* user_data);

int zqlite_set_allocator(
    ZqliteAllocFn alloc_fn,
    ZqliteFreeFn free_fn,
    ZqliteReallocFn realloc_fn,
    void* user_data
);
```

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
- Call `zqlite_shutdown()` at program exit to clean up global state
