// Complete C FFI header for Rust integration
// Place this in your Rust project as zqlite.h

#ifndef ZQLITE_H
#define ZQLITE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stddef.h>

// Opaque types
typedef struct zqlite_connection zqlite_connection_t;
typedef struct zqlite_result zqlite_result_t;
typedef struct zqlite_stmt zqlite_stmt_t;

// Error codes (compatible with SQLite)
#define ZQLITE_OK           0   // Successful result
#define ZQLITE_ERROR        1   // Generic error
#define ZQLITE_INTERNAL     2   // Internal logic error
#define ZQLITE_PERM         3   // Access permission denied
#define ZQLITE_ABORT        4   // Callback routine requested abort
#define ZQLITE_BUSY         5   // Database file is locked
#define ZQLITE_LOCKED       6   // Database table is locked
#define ZQLITE_NOMEM        7   // malloc() failed
#define ZQLITE_READONLY     8   // Attempt to write readonly database
#define ZQLITE_INTERRUPT    9   // Operation terminated by interrupt
#define ZQLITE_IOERR       10   // Disk I/O error
#define ZQLITE_CORRUPT     11   // Database image is malformed
#define ZQLITE_NOTFOUND    12   // Unknown opcode in sqlite3_file_control()
#define ZQLITE_FULL        13   // Insertion failed because database is full
#define ZQLITE_CANTOPEN    14   // Unable to open database file
#define ZQLITE_PROTOCOL    15   // Database lock protocol error
#define ZQLITE_EMPTY       16   // Internal use only
#define ZQLITE_SCHEMA      17   // Database schema changed
#define ZQLITE_TOOBIG      18   // String or BLOB exceeds size limit
#define ZQLITE_CONSTRAINT  19   // Constraint violation
#define ZQLITE_MISMATCH    20   // Data type mismatch
#define ZQLITE_MISUSE      21   // Library used incorrectly
#define ZQLITE_NOLFS       22   // OS features not supported
#define ZQLITE_AUTH        23   // Authorization denied
#define ZQLITE_FORMAT      24   // Not used
#define ZQLITE_RANGE       25   //2nd parameter to sqlite3_bind out of range
#define ZQLITE_NOTADB      26   // File opened that is not a database file
#define ZQLITE_ROW         100  // sqlite3_step() has another row ready
#define ZQLITE_DONE        101  // sqlite3_step() has finished executing

// Column types
#define ZQLITE_INTEGER  1
#define ZQLITE_FLOAT    2
#define ZQLITE_TEXT     3
#define ZQLITE_BLOB     4
#define ZQLITE_NULL     5

// Core database operations
zqlite_connection_t* zqlite_open(const char* path);
zqlite_connection_t* zqlite_open_encrypted(const char* path, const char* password);
int zqlite_close(zqlite_connection_t* conn);
int zqlite_execute(zqlite_connection_t* conn, const char* sql);

// Query operations
zqlite_result_t* zqlite_query(zqlite_connection_t* conn, const char* sql);
int zqlite_result_row_count(zqlite_result_t* result);
int zqlite_result_column_count(zqlite_result_t* result);
const char* zqlite_result_column_name(zqlite_result_t* result, int column);
int zqlite_result_column_type(zqlite_result_t* result, int row, int column);
const char* zqlite_result_get_text(zqlite_result_t* result, int row, int column);
int64_t zqlite_result_get_int(zqlite_result_t* result, int row, int column);
double zqlite_result_get_real(zqlite_result_t* result, int row, int column);
const void* zqlite_result_get_blob(zqlite_result_t* result, int row, int column, int* size);
void zqlite_result_free(zqlite_result_t* result);

// Prepared statements
zqlite_stmt_t* zqlite_prepare(zqlite_connection_t* conn, const char* sql);
int zqlite_bind_int(zqlite_stmt_t* stmt, int index, int64_t value);
int zqlite_bind_real(zqlite_stmt_t* stmt, int index, double value);
int zqlite_bind_text(zqlite_stmt_t* stmt, int index, const char* value);
int zqlite_bind_blob(zqlite_stmt_t* stmt, int index, const void* data, int size);
int zqlite_bind_null(zqlite_stmt_t* stmt, int index);
int zqlite_step(zqlite_stmt_t* stmt);
int zqlite_reset(zqlite_stmt_t* stmt);
int zqlite_finalize(zqlite_stmt_t* stmt);

// Statement result access
int zqlite_column_count(zqlite_stmt_t* stmt);
const char* zqlite_column_name(zqlite_stmt_t* stmt, int column);
int zqlite_column_type(zqlite_stmt_t* stmt, int column);
const char* zqlite_column_text(zqlite_stmt_t* stmt, int column);
int64_t zqlite_column_int(zqlite_stmt_t* stmt, int column);
double zqlite_column_real(zqlite_stmt_t* stmt, int column);
const void* zqlite_column_blob(zqlite_stmt_t* stmt, int column, int* size);

// Transactions
int zqlite_begin_transaction(zqlite_connection_t* conn);
int zqlite_commit_transaction(zqlite_connection_t* conn);
int zqlite_rollback_transaction(zqlite_connection_t* conn);

// JSON support (zqlite extension)
int zqlite_json_extract(zqlite_connection_t* conn, const char* json, const char* path, char** result);
int zqlite_json_set(zqlite_connection_t* conn, const char* json, const char* path, const char* value, char** result);
int zqlite_json_type(zqlite_connection_t* conn, const char* json, const char* path, char** result);

// Error handling
const char* zqlite_errmsg(zqlite_connection_t* conn);
int zqlite_errcode(zqlite_connection_t* conn);

// Memory management
// IMPORTANT: Call zqlite_free_string() to free strings returned by zqlite_result_get_text
// and other functions that return allocated strings. Failure to do so causes memory leaks.
void zqlite_free_string(const char* str);

// Utility functions
const char* zqlite_version();
int64_t zqlite_last_insert_rowid(zqlite_connection_t* conn);
int zqlite_changes(zqlite_connection_t* conn);
void zqlite_shutdown();

// Advanced features for AI/VPN/Crypto projects
int zqlite_enable_wal_mode(zqlite_connection_t* conn);
int zqlite_vacuum(zqlite_connection_t* conn);
int zqlite_backup(zqlite_connection_t* conn, const char* dest_path);
int zqlite_create_index(zqlite_connection_t* conn, const char* table, const char* column, const char* index_type);

#ifdef __cplusplus
}
#endif

#endif // ZQLITE_H
