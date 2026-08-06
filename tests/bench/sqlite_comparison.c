#define _POSIX_C_SOURCE 200809L
#include <sqlite3.h>
#include <zqlite.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>

static int64_t now_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (int64_t)value.tv_sec * 1000000000LL + value.tv_nsec;
}

static long long file_size(const char *path) {
    struct stat value;
    return stat(path, &value) == 0 ? (long long)value.st_size : 0;
}

static void zcheck(int code, int expected, const char *operation) {
    if (code != expected) {
        fprintf(stderr, "zqlite benchmark failed at %s: %d\n", operation, code);
        exit(2);
    }
}

static void scheck(int code, sqlite3 *db, const char *operation) {
    if (code != SQLITE_OK && code != SQLITE_DONE && code != SQLITE_ROW) {
        fprintf(stderr, "sqlite benchmark failed at %s: %s\n", operation, sqlite3_errmsg(db));
        exit(3);
    }
}

int main(int argc, char **argv) {
    if (argc != 3) return 64;
    const int rows = 1000;
    const int lookups = 200;
    int64_t z_append, s_append, z_lookup, s_lookup, start;

    zqlite_connection_t *zdb = zqlite_open(argv[1]);
    if (!zdb) return 2;
    zcheck(zqlite_execute(zdb, "CREATE TABLE bench (id INTEGER PRIMARY KEY, value TEXT)"), ZQLITE_OK, "create");
    zcheck(zqlite_begin_transaction(zdb), ZQLITE_OK, "begin");
    zqlite_stmt_t *zins = zqlite_prepare(zdb, "INSERT INTO bench VALUES (?, ?)");
    if (!zins) return 2;
    start = now_ns();
    for (int i = 0; i < rows; ++i) {
        zcheck(zqlite_bind_int(zins, 0, i), ZQLITE_OK, "bind id");
        zcheck(zqlite_bind_text(zins, 1, "payload"), ZQLITE_OK, "bind value");
        zcheck(zqlite_step(zins), ZQLITE_DONE, "insert");
    }
    zcheck(zqlite_commit_transaction(zdb), ZQLITE_OK, "commit");
    z_append = now_ns() - start;
    zcheck(zqlite_finalize(zins), ZQLITE_OK, "finalize insert");
    zcheck(zqlite_execute(zdb, "CREATE INDEX bench_id ON bench (id)"), ZQLITE_OK, "index");
    zqlite_stmt_t *zsel = zqlite_prepare(zdb, "SELECT value FROM bench WHERE id = ?");
    start = now_ns();
    for (int i = 0; i < lookups; ++i) {
        zcheck(zqlite_bind_int(zsel, 0, i % rows), ZQLITE_OK, "lookup bind");
        zcheck(zqlite_step(zsel), ZQLITE_ROW, "lookup row");
        zcheck(zqlite_step(zsel), ZQLITE_DONE, "lookup done");
    }
    z_lookup = now_ns() - start;
    zcheck(zqlite_finalize(zsel), ZQLITE_OK, "finalize lookup");
    zqlite_close(zdb);

    sqlite3 *sdb = NULL;
    scheck(sqlite3_open(argv[2], &sdb), sdb, "open");
    scheck(sqlite3_exec(sdb, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE bench (id INTEGER PRIMARY KEY, value TEXT); BEGIN IMMEDIATE", NULL, NULL, NULL), sdb, "setup");
    sqlite3_stmt *sins = NULL;
    scheck(sqlite3_prepare_v2(sdb, "INSERT INTO bench VALUES (?, ?)", -1, &sins, NULL), sdb, "prepare insert");
    start = now_ns();
    for (int i = 0; i < rows; ++i) {
        sqlite3_bind_int(sins, 1, i);
        sqlite3_bind_text(sins, 2, "payload", -1, SQLITE_STATIC);
        scheck(sqlite3_step(sins), sdb, "insert");
        sqlite3_reset(sins);
        sqlite3_clear_bindings(sins);
    }
    scheck(sqlite3_exec(sdb, "COMMIT", NULL, NULL, NULL), sdb, "commit");
    s_append = now_ns() - start;
    sqlite3_finalize(sins);
    scheck(sqlite3_exec(sdb, "CREATE INDEX bench_id ON bench (id)", NULL, NULL, NULL), sdb, "index");
    sqlite3_stmt *ssel = NULL;
    scheck(sqlite3_prepare_v2(sdb, "SELECT value FROM bench WHERE id = ?", -1, &ssel, NULL), sdb, "prepare lookup");
    start = now_ns();
    for (int i = 0; i < lookups; ++i) {
        sqlite3_bind_int(ssel, 1, i % rows);
        scheck(sqlite3_step(ssel), sdb, "lookup");
        sqlite3_reset(ssel);
        sqlite3_clear_bindings(ssel);
    }
    s_lookup = now_ns() - start;
    sqlite3_finalize(ssel);
    sqlite3_close(sdb);

    printf("{\"schema_version\":1,\"durability\":\"transactional-full-sync\",\"rows\":%d,\"lookups\":%d,", rows, lookups);
    printf("\"zqlite\":{\"append_ns\":%lld,\"lookup_ns\":%lld,\"database_bytes\":%lld,\"wal_bytes_after_close\":%lld},", (long long)z_append, (long long)z_lookup, file_size(argv[1]), file_size(".scratch/perf-zqlite.db-wal"));
    printf("\"sqlite\":{\"append_ns\":%lld,\"lookup_ns\":%lld,\"database_bytes\":%lld,\"wal_bytes_after_close\":%lld}}\n", (long long)s_append, (long long)s_lookup, file_size(argv[2]), file_size(".scratch/perf-sqlite.db-wal"));
    return 0;
}
