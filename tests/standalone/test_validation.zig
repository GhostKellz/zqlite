const std = @import("std");
const zqlite = @import("zqlite");
const version = zqlite.version;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧪 ZQLite Quick Validation Test\n", .{});
    std.debug.print("Version: {s}\n", .{version.FULL_VERSION_WITH_BUILD});
    std.debug.print("==================================================\n", .{});

    // Test 1: Basic Connection
    std.debug.print("1. Testing basic connection... ", .{});
    const conn = zqlite.open(allocator, ":memory:") catch |err| {
        std.debug.print("FAILED ({})\n", .{err});
        return err;
    };
    defer conn.close();
    std.debug.print("✅ PASSED\n", .{});

    // Test 2: CREATE TABLE with DEFAULT CURRENT_TIMESTAMP
    std.debug.print("2. Testing CREATE TABLE with DEFAULT CURRENT_TIMESTAMP... ", .{});
    conn.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)") catch |err| {
        std.debug.print("FAILED ({})\n", .{err});
        return err;
    };
    std.debug.print("✅ PASSED\n", .{});

    // Test 3: INSERT with DEFAULT value
    std.debug.print("3. Testing INSERT with DEFAULT values... ", .{});
    conn.execute("INSERT INTO test (id) VALUES (1)") catch |err| {
        std.debug.print("FAILED ({})\n", .{err});
        return err;
    };
    std.debug.print("✅ PASSED\n", .{});

    // Test 4: SELECT to verify data
    std.debug.print("4. Testing SELECT query... ", .{});
    var stmt = conn.prepare("SELECT id, created_at FROM test WHERE id = 1") catch |err| {
        std.debug.print("FAILED ({})\n", .{err});
        return err;
    };
    defer stmt.deinit();

    var result = stmt.execute() catch |err| {
        std.debug.print("FAILED ({})\n", .{err});
        return err;
    };
    defer result.deinit();

    if (result.rows.items.len != 1) {
        std.debug.print("FAILED (expected 1 row, got {})\n", .{result.rows.items.len});
        return error.UnexpectedRowCount;
    }
    std.debug.print("✅ PASSED\n", .{});

    // Test 5: Memory Management - Multiple Operations
    std.debug.print("5. Testing memory management with multiple operations... ", .{});
    var i: u32 = 2; // Start from 2 since we already inserted id=1
    while (i < 12) : (i += 1) {
        const insert_sql = std.fmt.allocPrint(allocator, "INSERT INTO test (id) VALUES ({})", .{i}) catch |err| {
            std.debug.print("FAILED to format SQL ({})\n", .{err});
            return err;
        };
        defer allocator.free(insert_sql);

        conn.execute(insert_sql) catch |err| {
            std.debug.print("FAILED on iteration {} ({})\n", .{ i, err });
            return err;
        };
    }

    var count_stmt = conn.prepare("SELECT COUNT(*) FROM test") catch |err| {
        std.debug.print("FAILED ({})\n", .{err});
        return err;
    };
    defer count_stmt.deinit();

    var count_result = count_stmt.execute() catch |err| {
        std.debug.print("FAILED ({})\n", .{err});
        return err;
    };
    defer count_result.deinit();

    switch (count_result.rows.items[0].values[0]) {
        .Integer => |count| {
            if (count != 11) { // 1 + 10 = 11 total
                std.debug.print("FAILED (expected 11 rows, got {})\n", .{count});
                return error.UnexpectedRowCount;
            }
        },
        else => {
            std.debug.print("FAILED (unexpected value type)\n", .{});
            return error.UnexpectedValueType;
        },
    }
    std.debug.print("✅ PASSED\n", .{});

    std.debug.print("\n🎉 All validation tests passed!\n", .{});
    std.debug.print("ZQLite {s} is working correctly.\n", .{version.VERSION_STRING_PREFIXED});
}
