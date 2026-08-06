#ifndef ZQLITE_H
#define ZQLITE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(ZQLITE_BUILD_SHARED)
#  if defined(ZQLITE_BUILDING_LIBRARY)
#    define ZQLITE_API __declspec(dllexport)
#  else
#    define ZQLITE_API __declspec(dllimport)
#  endif
#elif defined(__GNUC__) || defined(__clang__)
#  define ZQLITE_API __attribute__((visibility("default")))
#else
#  define ZQLITE_API
#endif

/* Stable C ABI surface. Functions not declared here are not supported. */
typedef struct zqlite_connection zqlite_connection_t;
typedef struct zqlite_result zqlite_result_t;
typedef struct zqlite_stmt zqlite_stmt_t;

#define ZQLITE_ABI_VERSION_MAJOR 1
#define ZQLITE_ABI_VERSION_MINOR 0
#define ZQLITE_ABI_VERSION_PATCH 0

/* SQLite-compatible numeric values for the subset returned by ZQLite. */
#define ZQLITE_OK           0
#define ZQLITE_ERROR        1
#define ZQLITE_BUSY         5
#define ZQLITE_LOCKED       6
#define ZQLITE_NOMEM        7
#define ZQLITE_READONLY     8
#define ZQLITE_INTERRUPT    9
#define ZQLITE_IOERR       10
#define ZQLITE_CORRUPT     11
#define ZQLITE_CONSTRAINT  19
#define ZQLITE_MISMATCH    20
#define ZQLITE_MISUSE      21
#define ZQLITE_NOLFS       22
#define ZQLITE_AUTH        23
#define ZQLITE_FORMAT      24
#define ZQLITE_RANGE       25
#define ZQLITE_NOTADB      26
#define ZQLITE_ROW        100
#define ZQLITE_DONE       101

#define ZQLITE_TYPE_INTEGER 1
#define ZQLITE_TYPE_REAL    2
#define ZQLITE_TYPE_TEXT    3
#define ZQLITE_TYPE_BLOB    4
#define ZQLITE_TYPE_NULL    5

#define ZQLITE_ERROR_CATEGORY_OK             0
#define ZQLITE_ERROR_CATEGORY_SQL            1
#define ZQLITE_ERROR_CATEGORY_CONSTRAINT     2
#define ZQLITE_ERROR_CATEGORY_IO             3
#define ZQLITE_ERROR_CATEGORY_MISUSE         4
#define ZQLITE_ERROR_CATEGORY_MEMORY         5
#define ZQLITE_ERROR_CATEGORY_AUTHORIZATION  6
#define ZQLITE_ERROR_CATEGORY_FORMAT         7
#define ZQLITE_ERROR_CATEGORY_UNKNOWN      255

ZQLITE_API zqlite_connection_t *zqlite_open(const char *path);
ZQLITE_API void zqlite_close(zqlite_connection_t *conn);
ZQLITE_API int zqlite_execute(zqlite_connection_t *conn, const char *sql);

ZQLITE_API zqlite_result_t *zqlite_query(zqlite_connection_t *conn, const char *sql);
ZQLITE_API int zqlite_result_row_count(zqlite_result_t *result);
ZQLITE_API int zqlite_result_column_count(zqlite_result_t *result);
ZQLITE_API const char *zqlite_result_column_name(zqlite_result_t *result, int column);
ZQLITE_API int zqlite_result_get_type(zqlite_result_t *result, int row, int column);
/* The returned string is allocated and must be released with zqlite_free_string. */
ZQLITE_API const char *zqlite_result_get_text(zqlite_result_t *result, int row, int column);
ZQLITE_API void zqlite_result_free(zqlite_result_t *result);
ZQLITE_API void zqlite_free_string(const char *str);

ZQLITE_API zqlite_stmt_t *zqlite_prepare(zqlite_connection_t *conn, const char *sql);
ZQLITE_API int zqlite_bind_int(zqlite_stmt_t *stmt, int index, int64_t value);
ZQLITE_API int zqlite_bind_text(zqlite_stmt_t *stmt, int index, const char *value);
ZQLITE_API int zqlite_bind_real(zqlite_stmt_t *stmt, int index, double value);
ZQLITE_API int zqlite_bind_null(zqlite_stmt_t *stmt, int index);
ZQLITE_API int zqlite_bind_blob(zqlite_stmt_t *stmt, int index, const void *value, size_t len);
ZQLITE_API int zqlite_bind_int_named(zqlite_stmt_t *stmt, const char *name, int64_t value);
ZQLITE_API int zqlite_bind_text_named(zqlite_stmt_t *stmt, const char *name, const char *value);
ZQLITE_API int zqlite_bind_real_named(zqlite_stmt_t *stmt, const char *name, double value);
ZQLITE_API int zqlite_bind_null_named(zqlite_stmt_t *stmt, const char *name);
ZQLITE_API int zqlite_bind_blob_named(zqlite_stmt_t *stmt, const char *name, const void *value, size_t len);
ZQLITE_API int zqlite_step(zqlite_stmt_t *stmt);
ZQLITE_API int zqlite_column_count(zqlite_stmt_t *stmt);
ZQLITE_API const char *zqlite_column_name(zqlite_stmt_t *stmt, int column);
ZQLITE_API int zqlite_column_type(zqlite_stmt_t *stmt, int column);
ZQLITE_API int64_t zqlite_column_int64(zqlite_stmt_t *stmt, int column);
ZQLITE_API double zqlite_column_double(zqlite_stmt_t *stmt, int column);
ZQLITE_API const char *zqlite_column_text(zqlite_stmt_t *stmt, int column);
ZQLITE_API const void *zqlite_column_blob(zqlite_stmt_t *stmt, int column);
ZQLITE_API size_t zqlite_column_bytes(zqlite_stmt_t *stmt, int column);
ZQLITE_API int zqlite_reset(zqlite_stmt_t *stmt);
ZQLITE_API int zqlite_finalize(zqlite_stmt_t *stmt);

ZQLITE_API int zqlite_begin_transaction(zqlite_connection_t *conn);
ZQLITE_API int zqlite_commit_transaction(zqlite_connection_t *conn);
ZQLITE_API int zqlite_rollback_transaction(zqlite_connection_t *conn);

/* Error strings are connection-owned and valid until the next operation. */
ZQLITE_API const char *zqlite_errmsg(zqlite_connection_t *conn);
ZQLITE_API int zqlite_errcode(zqlite_connection_t *conn);
ZQLITE_API int zqlite_errcategory(zqlite_connection_t *conn);
ZQLITE_API const char *zqlite_errsql(zqlite_connection_t *conn);

ZQLITE_API const char *zqlite_version(void);
ZQLITE_API int zqlite_abi_version(void);
ZQLITE_API int zqlite_abi_version_major(void);
ZQLITE_API int zqlite_abi_version_minor(void);
ZQLITE_API int zqlite_abi_version_patch(void);
ZQLITE_API int zqlite_pq_available(void);
ZQLITE_API const char *zqlite_pq_status(void);
ZQLITE_API const char *zqlite_pq_backend(void);
ZQLITE_API const char *zqlite_pq_liboqs_status(void);
/* The returned string is allocated and must be released with zqlite_free_string. */
ZQLITE_API const char *zqlite_pq_diagnostics_json(void);
ZQLITE_API void zqlite_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
