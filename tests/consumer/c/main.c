#include <stdio.h>
#include <string.h>

#include <zqlite.h>

int main(void) {
    zqlite_connection_t *conn = zqlite_open(":memory:");
    if (conn == NULL) return 1;
    if (zqlite_abi_version_major() != ZQLITE_ABI_VERSION_MAJOR) return 16;
    if (zqlite_abi_version() < 10000) return 17;
    if (zqlite_pq_available() != 0) return 34;
    if (strcmp(zqlite_pq_backend(), "none") != 0) return 35;
    if (strcmp(zqlite_pq_liboqs_status(), "not_configured") != 0) return 36;
    const char *pq_status = zqlite_pq_status();
    if (pq_status == NULL || strlen(pq_status) == 0) return 37;
    const char *pq_json = zqlite_pq_diagnostics_json();
    if (pq_json == NULL) return 38;
    if (strstr(pq_json, "\"available\":false") == NULL) return 39;
    if (strstr(pq_json, "\"backend\":\"none\"") == NULL) return 40;
    if (strstr(pq_json, "\"provider\":\"stdlib\"") == NULL) return 41;
    if (strstr(pq_json, "\"liboqs_status\":\"not_configured\"") == NULL) return 42;
    zqlite_free_string(pq_json);

    if (zqlite_execute(conn, "CREATE TABLE smoke (id INTEGER, name TEXT)") != ZQLITE_OK) return 2;
    if (zqlite_execute(conn, "INSERT INTO smoke VALUES (1, 'package-ok')") != ZQLITE_OK) return 3;

    zqlite_result_t *result = zqlite_query(conn, "SELECT name FROM smoke WHERE id = 1");
    if (result == NULL || zqlite_result_row_count(result) != 1) return 4;
    const char *result_col = zqlite_result_column_name(result, 0);
    if (result_col == NULL || strcmp(result_col, "name") != 0) return 18;
    if (zqlite_result_get_type(result, 0, 0) != ZQLITE_TYPE_TEXT) return 19;

    const char *value = zqlite_result_get_text(result, 0, 0);
    if (value == NULL || strcmp(value, "package-ok") != 0) return 5;

    zqlite_free_string(value);
    zqlite_result_free(result);

    zqlite_stmt_t *stmt = zqlite_prepare(conn, "SELECT id, name FROM smoke WHERE id = ?");
    if (stmt == NULL) return 6;
    if (zqlite_bind_int(stmt, 0, 1) != ZQLITE_OK) return 7;
    if (zqlite_step(stmt) != ZQLITE_ROW) return 8;
    if (zqlite_column_count(stmt) != 2) return 9;
    const char *stmt_col = zqlite_column_name(stmt, 1);
    if (stmt_col == NULL || strcmp(stmt_col, "name") != 0) return 20;
    if (zqlite_column_type(stmt, 0) != ZQLITE_TYPE_INTEGER) return 10;
    if (zqlite_column_int64(stmt, 0) != 1) return 11;
    const char *stmt_name = zqlite_column_text(stmt, 1);
    if (stmt_name == NULL || strcmp(stmt_name, "package-ok") != 0) return 12;
    if (zqlite_column_bytes(stmt, 1) != strlen("package-ok")) return 13;
    if (zqlite_step(stmt) != ZQLITE_DONE) return 14;
    if (zqlite_finalize(stmt) != ZQLITE_OK) return 15;

    zqlite_stmt_t *named_stmt = zqlite_prepare(conn, "SELECT id, name FROM smoke WHERE id = :id AND name = @name");
    if (named_stmt == NULL) return 21;
    if (zqlite_bind_int_named(named_stmt, ":id", 1) != ZQLITE_OK) return 22;
    if (zqlite_bind_text_named(named_stmt, "name", "package-ok") != ZQLITE_OK) return 23;
    if (zqlite_step(named_stmt) != ZQLITE_ROW) return 24;
    if (zqlite_column_int64(named_stmt, 0) != 1) return 25;
    const char *named_value = zqlite_column_text(named_stmt, 1);
    if (named_value == NULL || strcmp(named_value, "package-ok") != 0) return 26;
    if (zqlite_step(named_stmt) != ZQLITE_DONE) return 27;
    if (zqlite_finalize(named_stmt) != ZQLITE_OK) return 28;
    if (zqlite_finalize(named_stmt) != ZQLITE_MISUSE) return 43;
    if (zqlite_step(named_stmt) != ZQLITE_MISUSE) return 44;
    if (zqlite_bind_int(NULL, 0, 1) != ZQLITE_MISUSE) return 45;
    if (zqlite_bind_int(stmt, -1, 1) != ZQLITE_MISUSE) return 46;
    zqlite_result_free(result);

    if (zqlite_execute(conn, "CREATE TABLE unique_check (id INTEGER UNIQUE)") != ZQLITE_OK) return 29;
    if (zqlite_execute(conn, "INSERT INTO unique_check VALUES (1)") != ZQLITE_OK) return 30;
    if (zqlite_execute(conn, "INSERT INTO unique_check VALUES (1)") != ZQLITE_CONSTRAINT) return 31;
    if (zqlite_errcode(conn) != ZQLITE_CONSTRAINT) return 32;
    if (zqlite_errcategory(conn) != ZQLITE_ERROR_CATEGORY_CONSTRAINT) return 33;

    zqlite_stmt_t *orphan = zqlite_prepare(conn, "SELECT id FROM unique_check");
    if (orphan == NULL) return 47;
    zqlite_close(conn);
    zqlite_close(conn);
    if (zqlite_step(orphan) != ZQLITE_MISUSE) return 48;
    if (zqlite_finalize(orphan) != ZQLITE_OK) return 49;
    puts("C package consumer passed");
    return 0;
}
