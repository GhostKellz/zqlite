const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize database
    const db = try zqlite.openMemory(allocator);
    defer db.close();

    std.log.info("Testing datetime function support...", .{});

    // Test 1: Create table with datetime default
    const create_table_sql =
        \\CREATE TABLE test_table (
        \\    id INTEGER PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now'))
        \\);
    ;

    std.log.info("Creating table with datetime default...", .{});
    try db.execute(create_table_sql);
    std.log.info("✓ Table created successfully", .{});

    // Test 2: Insert data without providing created_at (should use default)
    const insert_sql = "INSERT INTO test_table (name) VALUES ('test_user');";

    std.log.info("Inserting data without datetime column...", .{});
    try db.execute(insert_sql);
    std.log.info("✓ Data inserted successfully", .{});

    // Test 3: Query the data to see if default was applied
    const select_sql = "SELECT * FROM test_table;";

    std.log.info("Querying data to check default value...", .{});
    var result = try db.query(select_sql);
    defer result.deinit();

    if (result.rows.items.len > 0) {
        const row = result.rows.items[0];
        std.log.info("✓ Found row with {} columns", .{row.values.len});

        if (row.values.len >= 3) {
            const created_at = row.values[2];
            switch (created_at) {
                .Text => |datetime_str| {
                    std.log.info("✓ Default datetime value: {s}", .{datetime_str});
                },
                else => {
                    std.log.err("✗ Expected Text value for datetime, got: {}", .{created_at});
                },
            }
        } else {
            std.log.err("✗ Expected at least 3 columns, got: {}", .{row.values.len});
        }
    } else {
        std.log.err("✗ No rows returned from query", .{});
    }

    // Test 4: Test other datetime functions
    const datetime_tests = [_]struct {
        name: []const u8,
        sql: []const u8,
    }{
        .{ .name = "NOW()", .sql = "SELECT now() AS current_time;" },
        .{ .name = "DATETIME('now')", .sql = "SELECT datetime('now') AS current_datetime;" },
        .{ .name = "UNIXEPOCH()", .sql = "SELECT unixepoch() AS current_timestamp;" },
        .{ .name = "STRFTIME('%s', 'now')", .sql = "SELECT strftime('%s', 'now') AS unix_timestamp;" },
        .{ .name = "DATE('now')", .sql = "SELECT date('now') AS current_date;" },
        .{ .name = "TIME('now')", .sql = "SELECT time('now') AS current_time;" },
    };

    for (datetime_tests) |test_case| {
        std.log.info("Testing {s}...", .{test_case.name});
        var test_result = db.query(test_case.sql) catch |err| {
            std.log.err("✗ Failed to execute {s}: {}", .{ test_case.name, err });
            continue;
        };
        defer test_result.deinit();

        if (test_result.rows.items.len > 0) {
            const row = test_result.rows.items[0];
            if (row.values.len > 0) {
                const value = row.values[0];
                switch (value) {
                    .Text => |text| std.log.info("✓ {s} result: {s}", .{ test_case.name, text }),
                    .Integer => |int| std.log.info("✓ {s} result: {d}", .{ test_case.name, int }),
                    .Real => |real| std.log.info("✓ {s} result: {d}", .{ test_case.name, real }),
                    else => std.log.info("✓ {s} result: {}", .{ test_case.name, value }),
                }
            } else {
                std.log.err("✗ {s} returned no columns", .{test_case.name});
            }
        } else {
            std.log.err("✗ {s} returned no rows", .{test_case.name});
        }
    }

    std.log.info("Datetime function tests completed!", .{});
}
