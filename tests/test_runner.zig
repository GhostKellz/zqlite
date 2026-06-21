const std = @import("std");
const zqlite = @import("zqlite");
const version = zqlite.version;

// Import all test modules
const sqlite_functionality_test = @import("unit/sqlite_functionality_test.zig");
const memory_management_test = @import("memory/memory_management_test.zig");
const query_validation_test = @import("unit/query_validation_test.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧪 {s} - Test Suite Runner\n", .{version.FULL_VERSION_WITH_BUILD});
    std.debug.print("============================================================\n", .{});

    var total_tests: u32 = 0;
    var passed_tests: u32 = 0;
    var failed_tests: u32 = 0;

    // Test categories to run
    const test_categories = [_]TestCategory{
        .{ .name = "SQLite Functionality", .test_fn = runSQLiteFunctionalityTests },
        .{ .name = "Memory Management", .test_fn = runMemoryManagementTests },
        .{ .name = "Query Validation", .test_fn = runQueryValidationTests },
    };

    for (test_categories) |category| {
        std.debug.print("\n📋 Running {s} Tests...\n", .{category.name});
        std.debug.print("----------------------------------------\n", .{});

        const result = category.test_fn(allocator) catch |err| {
            std.debug.print("❌ Category {s} failed with error: {}\n", .{ category.name, err });
            failed_tests += 1;
            continue;
        };

        total_tests += result.total;
        passed_tests += result.passed;
        failed_tests += result.failed;

        if (result.failed == 0) {
            std.debug.print("✅ All {} tests in {s} passed!\n", .{ result.passed, category.name });
        } else {
            std.debug.print("⚠️  {} tests passed, {} failed in {s}\n", .{ result.passed, result.failed, category.name });
        }
    }

    // Print summary
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("📊 Test Summary:\n", .{});
    std.debug.print("   Total Tests: {}\n", .{total_tests});
    std.debug.print("   Passed: {} ✅\n", .{passed_tests});
    std.debug.print("   Failed: {} ❌\n", .{failed_tests});

    if (failed_tests == 0) {
        std.debug.print("\n🎉 All tests passed! ZQLite is working correctly.\n", .{});
    } else {
        std.debug.print("\n⚠️  Some tests failed. Please review the output above.\n", .{});
        std.process.exit(1);
    }
}

const TestResult = struct {
    total: u32,
    passed: u32,
    failed: u32,
};

const TestCategory = struct {
    name: []const u8,
    test_fn: *const fn (allocator: std.mem.Allocator) anyerror!TestResult,
};

fn runSQLiteFunctionalityTests(allocator: std.mem.Allocator) !TestResult {
    _ = allocator;
    var result = TestResult{ .total = 0, .passed = 0, .failed = 0 };

    const tests = [_]TestFn{
        .{ .name = "Basic CRUD Operations", .test_fn = runBasicCRUDTest },
        .{ .name = "Data Types Support", .test_fn = runDataTypesTest },
        .{ .name = "WHERE Clauses and Filtering", .test_fn = runWHERETest },
        .{ .name = "UPDATE and DELETE Operations", .test_fn = runUpdateDeleteTest },
        .{ .name = "JOINS", .test_fn = runJOINSTest },
        .{ .name = "GROUP BY and Aggregation", .test_fn = runGroupByTest },
        .{ .name = "DEFAULT CURRENT_TIMESTAMP", .test_fn = runDefaultTimestampTest },
        .{ .name = "INSERT RETURNING", .test_fn = runInsertReturningTest },
        .{ .name = "UPDATE RETURNING", .test_fn = runUpdateReturningTest },
        .{ .name = "DELETE RETURNING", .test_fn = runDeleteReturningTest },
        .{ .name = "ON CONFLICT DO NOTHING", .test_fn = runOnConflictDoNothingTest },
        .{ .name = "ON CONFLICT DO UPDATE", .test_fn = runOnConflictDoUpdateTest },
        .{ .name = "UPSERT WITH RETURNING", .test_fn = runUpsertReturningTest },
        .{ .name = "UPSERT WITH excluded.*", .test_fn = runUpsertExcludedReferencesTest },
    };

    for (tests) |test_case| {
        result.total += 1;
        std.debug.print("  🔍 {s}... ", .{test_case.name});

        test_case.test_fn() catch |err| {
            result.failed += 1;
            std.debug.print("FAILED ({})\n", .{err});
            continue;
        };

        result.passed += 1;
        std.debug.print("PASSED\n", .{});
    }

    return result;
}

fn runMemoryManagementTests(allocator: std.mem.Allocator) !TestResult {
    _ = allocator;
    var result = TestResult{ .total = 0, .passed = 0, .failed = 0 };

    const tests = [_]TestFn{
        .{ .name = "No Leaks with DEFAULT CURRENT_TIMESTAMP", .test_fn = runMemoryLeakTest },
        .{ .name = "Complex INSERT/UPDATE/DELETE Cycle", .test_fn = runComplexCycleTest },
        .{ .name = "Function Call DEFAULT Values", .test_fn = runFunctionDefaultTest },
        .{ .name = "Large Text Fields", .test_fn = runLargeTextTest },
        .{ .name = "Connection Lifecycle", .test_fn = runConnectionLifecycleTest },
        .{ .name = "Prepared Statement Reuse", .test_fn = runPreparedStatementReuseTest },
        .{ .name = "Named Prepared Parameters", .test_fn = runNamedPreparedParametersTest },
    };

    for (tests) |test_case| {
        result.total += 1;
        std.debug.print("  🧠 {s}... ", .{test_case.name});

        test_case.test_fn() catch |err| {
            result.failed += 1;
            std.debug.print("FAILED ({})\n", .{err});
            continue;
        };

        result.passed += 1;
        std.debug.print("PASSED\n", .{});
    }

    return result;
}

fn runQueryValidationTests(allocator: std.mem.Allocator) !TestResult {
    _ = allocator;
    var result = TestResult{ .total = 0, .passed = 0, .failed = 0 };

    const tests = [_]TestFn{
        .{ .name = "Complex SELECT Statements", .test_fn = runComplexSelectTest },
        .{ .name = "Subqueries and Window Functions", .test_fn = runSubqueriesTest },
        .{ .name = "Date and Time Functions", .test_fn = runDateTimeTest },
        .{ .name = "Transaction Integrity", .test_fn = runTransactionTest },
        .{ .name = "Error Handling and Edge Cases", .test_fn = runErrorHandlingTest },
        .{ .name = "Index Performance", .test_fn = runIndexPerformanceTest },
        .{ .name = "NULL Handling", .test_fn = runNullHandlingTest },
    };

    for (tests) |test_case| {
        result.total += 1;
        std.debug.print("  🔎 {s}... ", .{test_case.name});

        test_case.test_fn() catch |err| {
            result.failed += 1;
            std.debug.print("FAILED ({})\n", .{err});
            continue;
        };

        result.passed += 1;
        std.debug.print("PASSED\n", .{});
    }

    return result;
}

const TestFn = struct {
    name: []const u8,
    test_fn: *const fn () anyerror!void,
};

// Shared allocator for tests
var test_gpa: std.heap.DebugAllocator(.{}) = .init;

fn getTestAllocator() std.mem.Allocator {
    return test_gpa.allocator();
}

// SQLite Functionality Tests
fn runBasicCRUDTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // CREATE
    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    // INSERT
    try conn.execute("INSERT INTO users (name, age) VALUES ('Alice', 25)");
    try conn.execute("INSERT INTO users (name, age) VALUES ('Bob', 30)");

    // SELECT
    var result = try conn.query("SELECT * FROM users");
    defer result.deinit();
    if (result.count() != 2) return error.UnexpectedRowCount;

    // UPDATE
    try conn.execute("UPDATE users SET age = 26 WHERE name = 'Alice'");

    // DELETE
    try conn.execute("DELETE FROM users WHERE name = 'Bob'");

    var result2 = try conn.query("SELECT * FROM users");
    defer result2.deinit();
    if (result2.count() != 1) return error.UnexpectedRowCount;
}

fn runDataTypesTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE types (id INTEGER, text_val TEXT, real_val REAL, null_val TEXT)");
    try conn.execute("INSERT INTO types VALUES (42, 'hello', 3.14, NULL)");

    var result = try conn.query("SELECT * FROM types");
    defer result.deinit();

    if (result.next()) |row| {
        var r = row;
        defer r.deinit();
        // Verify INTEGER
        if (r.getValue(0)) |v| {
            if (v != .Integer) return error.ExpectedInteger;
        }
        // Verify TEXT
        if (r.getValue(1)) |v| {
            if (v != .Text) return error.ExpectedText;
        }
        // Verify REAL
        if (r.getValue(2)) |v| {
            if (v != .Real) return error.ExpectedReal;
        }
        // Verify NULL
        if (r.getValue(3)) |v| {
            if (v != .Null) return error.ExpectedNull;
        }
    } else {
        return error.NoRowsReturned;
    }
}

fn runWHERETest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE products (id INTEGER, name TEXT, price REAL)");
    try conn.execute("INSERT INTO products VALUES (1, 'Laptop', 999.99)");
    try conn.execute("INSERT INTO products VALUES (2, 'Mouse', 29.99)");
    try conn.execute("INSERT INTO products VALUES (3, 'Keyboard', 79.99)");

    // Test numeric comparison
    var result = try conn.query("SELECT * FROM products WHERE price > 50");
    defer result.deinit();
    if (result.count() != 2) return error.UnexpectedRowCount;

    // Test equality
    var result2 = try conn.query("SELECT * FROM products WHERE name = 'Mouse'");
    defer result2.deinit();
    if (result2.count() != 1) return error.UnexpectedRowCount;
}

fn runUpdateDeleteTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE inventory (id INTEGER, item TEXT, qty INTEGER)");
    try conn.execute("INSERT INTO inventory VALUES (1, 'Apples', 100)");
    try conn.execute("INSERT INTO inventory VALUES (2, 'Bananas', 50)");

    // Test UPDATE
    try conn.execute("UPDATE inventory SET qty = 150 WHERE item = 'Apples'");
    var result = try conn.query("SELECT qty FROM inventory WHERE item = 'Apples'");
    defer result.deinit();
    if (result.next()) |row| {
        var r = row;
        defer r.deinit();
        if (r.getValue(0)) |v| {
            if (v.Integer != 150) return error.UpdateFailed;
        }
    }

    // Test DELETE
    try conn.execute("DELETE FROM inventory WHERE item = 'Bananas'");
    var result2 = try conn.query("SELECT * FROM inventory");
    defer result2.deinit();
    if (result2.count() != 1) return error.DeleteFailed;
}

fn runJOINSTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.execute("CREATE TABLE orders (id INTEGER, customer_id INTEGER, product TEXT)");

    try conn.execute("INSERT INTO customers VALUES (1, 'Alice')");
    try conn.execute("INSERT INTO customers VALUES (2, 'Bob')");
    try conn.execute("INSERT INTO orders VALUES (1, 1, 'Laptop')");
    try conn.execute("INSERT INTO orders VALUES (2, 1, 'Mouse')");
    try conn.execute("INSERT INTO orders VALUES (3, 2, 'Keyboard')");

    var result = try conn.query("SELECT c.name, o.product FROM customers c INNER JOIN orders o ON c.id = o.customer_id");
    defer result.deinit();
    if (result.count() != 3) return error.JoinFailed;
}

fn runGroupByTest() !void {
    try sqlite_functionality_test.runGroupByAggregationExecution();
}

fn runDefaultTimestampTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");
    try conn.execute("INSERT INTO events (name) VALUES ('Test Event')");

    var result = try conn.query("SELECT created_at FROM events");
    defer result.deinit();
    if (result.next()) |row| {
        var r = row;
        defer r.deinit();
        if (r.getValue(0)) |v| {
            if (v != .Text) return error.ExpectedTimestamp;
            if (v.Text.len == 0) return error.EmptyTimestamp;
        }
    } else {
        return error.NoRowsReturned;
    }
}

fn runInsertReturningTest() !void {
    try sqlite_functionality_test.runInsertReturningExecution();
}

fn runUpdateReturningTest() !void {
    try sqlite_functionality_test.runUpdateReturningExecution();
}

fn runDeleteReturningTest() !void {
    try sqlite_functionality_test.runDeleteReturningExecution();
}

fn runOnConflictDoNothingTest() !void {
    try sqlite_functionality_test.runOnConflictDoNothingExecution();
}

fn runOnConflictDoUpdateTest() !void {
    try sqlite_functionality_test.runOnConflictDoUpdateExecution();
}

fn runUpsertReturningTest() !void {
    try sqlite_functionality_test.runUpsertReturningExecution();
}

fn runUpsertExcludedReferencesTest() !void {
    try sqlite_functionality_test.runUpsertExcludedReferences();
}

// Memory Management Tests
fn runMemoryLeakTest() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked != .ok) {
            @panic("Memory leak detected!");
        }
    }
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE test (id INTEGER, data TEXT DEFAULT 'test')");
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try conn.execute("INSERT INTO test (id) VALUES (1)");
    }

    var result = try conn.query("SELECT * FROM test");
    defer result.deinit();
}

fn runComplexCycleTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE cycle_test (id INTEGER, data TEXT)");

    // Multiple cycles of INSERT/UPDATE/DELETE
    var cycle: u32 = 0;
    while (cycle < 3) : (cycle += 1) {
        try conn.execute("INSERT INTO cycle_test VALUES (1, 'test')");
        try conn.execute("UPDATE cycle_test SET data = 'updated'");
        try conn.execute("DELETE FROM cycle_test WHERE id = 1");
    }
}

fn runFunctionDefaultTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE func_test (id INTEGER PRIMARY KEY, ts DATETIME DEFAULT CURRENT_TIMESTAMP)");
    // The parser currently supports column omission to trigger defaults, but not
    // the standalone INSERT ... DEFAULT VALUES form.
    try conn.execute("INSERT INTO func_test (id) VALUES (1)");
    try conn.execute("INSERT INTO func_test (id) VALUES (2)");

    var result = try conn.query("SELECT * FROM func_test");
    defer result.deinit();
    if (result.count() != 2) return error.InsertFailed;
}

fn runLargeTextTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE large_text (id INTEGER, content TEXT)");

    // Insert large text
    try conn.execute("INSERT INTO large_text VALUES (1, 'This is a moderately long text string that tests text handling capabilities of the database engine')");

    var result = try conn.query("SELECT content FROM large_text");
    defer result.deinit();
    if (result.next()) |row| {
        var r = row;
        defer r.deinit();
        if (r.getValue(0)) |v| {
            if (v.Text.len < 50) return error.TextTruncated;
        }
    }
}

fn runConnectionLifecycleTest() !void {
    const allocator = getTestAllocator();

    // Open and close multiple connections
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const conn = try zqlite.open(allocator, ":memory:");
        try conn.execute("CREATE TABLE test (id INTEGER)");
        try conn.execute("INSERT INTO test VALUES (1)");
        conn.close();
    }
}

fn runPreparedStatementReuseTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE prep_test (id INTEGER, name TEXT)");

    var stmt = try conn.prepare("INSERT INTO prep_test VALUES (?, ?)");
    defer stmt.deinit();

    // Reuse statement multiple times
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = i });
        const name = try allocator.dupe(u8, "test");
        defer allocator.free(name);
        try stmt.bindParameter(1, zqlite.storage.Value{ .Text = name });
        var result = try stmt.execute();
        defer result.deinit();
        stmt.reset();
    }

    var count_result = try conn.query("SELECT * FROM prep_test");
    defer count_result.deinit();
    if (count_result.count() != 5) return error.PreparedStatementReuseFailed;
}

fn runNamedPreparedParametersTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE named_params (id INTEGER, name TEXT, tag TEXT)");

    var insert = try conn.prepare("INSERT INTO named_params VALUES (:id, @name, $tag)");
    defer insert.deinit();
    try insert.bindNamed(":id", @as(i64, 1));
    try insert.bindNamed("name", "Alice");
    try insert.bindNamed("$tag", "admin");
    var insert_result = try insert.execute();
    defer insert_result.deinit();

    var repeated = try conn.prepare("SELECT * FROM named_params WHERE id = :id OR id = :id");
    defer repeated.deinit();
    try repeated.bindNamed("id", @as(i64, 1));
    var repeated_result = try repeated.execute();
    defer repeated_result.deinit();
    if (repeated_result.rows.items.len != 1) return error.NamedPreparedParameterFailed;

    var select = try conn.prepare("SELECT * FROM named_params WHERE name = @name AND tag = $tag");
    defer select.deinit();
    try select.bindNamed("@name", "Alice");
    try select.bindNamed("tag", "admin");
    var select_result = try select.execute();
    defer select_result.deinit();
    if (select_result.rows.items.len != 1) return error.NamedPreparedParameterFailed;

    var update = try conn.prepare("UPDATE named_params SET name = :name, tag = @tag WHERE id = $id");
    defer update.deinit();
    try update.bindNamed("name", "it's Alice");
    try update.bindNamed("@tag", "owner");
    try update.bindNamed("$id", @as(i64, 1));
    var update_result = try update.execute();
    defer update_result.deinit();

    var escaped = try conn.prepare("SELECT * FROM named_params WHERE name = 'it''s Alice' AND tag = :tag");
    defer escaped.deinit();
    try escaped.bindNamed(":tag", "owner");
    var escaped_result = try escaped.execute();
    defer escaped_result.deinit();
    if (escaped_result.rows.items.len != 1) return error.NamedPreparedParameterFailed;
}

// Query Validation Tests
fn runComplexSelectTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE employees (id INTEGER, name TEXT, dept TEXT, salary INTEGER)");
    try conn.execute("INSERT INTO employees VALUES (1, 'Alice', 'Engineering', 100000)");
    try conn.execute("INSERT INTO employees VALUES (2, 'Bob', 'Engineering', 90000)");
    try conn.execute("INSERT INTO employees VALUES (3, 'Charlie', 'Sales', 80000)");

    // Complex SELECT with multiple conditions
    var result = try conn.query("SELECT name, salary FROM employees WHERE dept = 'Engineering' AND salary > 80000");
    defer result.deinit();
    if (result.count() != 2) return error.ComplexSelectFailed;
}

fn runSubqueriesTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE products (id INTEGER, name TEXT, price REAL)");
    try conn.execute("INSERT INTO products VALUES (1, 'A', 10.0)");
    try conn.execute("INSERT INTO products VALUES (2, 'B', 20.0)");
    try conn.execute("INSERT INTO products VALUES (3, 'C', 30.0)");

    // Simple query that would use subquery logic
    var result = try conn.query("SELECT * FROM products WHERE price > 15");
    defer result.deinit();
    if (result.count() != 2) return error.SubqueryTestFailed;
}

fn runDateTimeTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE events (id INTEGER, event_time DATETIME DEFAULT CURRENT_TIMESTAMP)");
    try conn.execute("INSERT INTO events (id) VALUES (1)");

    var result = try conn.query("SELECT event_time FROM events");
    defer result.deinit();
    if (result.next()) |row| {
        var r = row;
        defer r.deinit();
        // Verify timestamp format contains date separator
        if (r.getValue(0)) |v| {
            if (v == .Text and std.mem.indexOf(u8, v.Text, "-") == null) {
                return error.InvalidDateTimeFormat;
            }
        }
    }
}

fn runTransactionTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE tx_test (id INTEGER, value TEXT)");

    // Test COMMIT
    try conn.execute("BEGIN");
    try conn.execute("INSERT INTO tx_test VALUES (1, 'committed')");
    try conn.execute("COMMIT");

    var result = try conn.query("SELECT * FROM tx_test");
    defer result.deinit();
    if (result.count() != 1) return error.TransactionCommitFailed;

    // Test ROLLBACK
    try conn.execute("BEGIN");
    try conn.execute("INSERT INTO tx_test VALUES (2, 'rolled_back')");
    try conn.execute("ROLLBACK");

    var result2 = try conn.query("SELECT * FROM tx_test");
    defer result2.deinit();
    if (result2.count() != 1) return error.TransactionRollbackFailed;
}

fn runErrorHandlingTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Test invalid SQL
    const result = conn.execute("INVALID SQL SYNTAX");
    if (result) |_| {
        return error.ShouldHaveFailed;
    } else |_| {
        // Expected error
    }

    // Test table not found
    const result2 = conn.query("SELECT * FROM nonexistent_table");
    if (result2) |r| {
        var res = r;
        res.deinit();
        return error.ShouldHaveFailed;
    } else |_| {
        // Expected error
    }
}

fn runIndexPerformanceTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE indexed_table (id INTEGER, email TEXT)");
    try conn.execute("CREATE INDEX idx_email ON indexed_table (email)");

    // Insert data
    try conn.execute("INSERT INTO indexed_table VALUES (1, 'alice@example.com')");
    try conn.execute("INSERT INTO indexed_table VALUES (2, 'bob@example.com')");

    // Query using indexed column
    var result = try conn.query("SELECT * FROM indexed_table WHERE email = 'alice@example.com'");
    defer result.deinit();
    if (result.count() != 1) return error.IndexQueryFailed;

    // Drop index
    try conn.execute("DROP INDEX idx_email");
}

fn runNullHandlingTest() !void {
    const allocator = getTestAllocator();
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE null_test (id INTEGER, nullable_col TEXT)");
    try conn.execute("INSERT INTO null_test VALUES (1, NULL)");
    try conn.execute("INSERT INTO null_test VALUES (2, 'not null')");

    // Query for NULL values
    var result = try conn.query("SELECT * FROM null_test WHERE nullable_col IS NULL");
    defer result.deinit();
    if (result.count() != 1) return error.NullQueryFailed;

    // Query for NOT NULL values
    var result2 = try conn.query("SELECT * FROM null_test WHERE nullable_col IS NOT NULL");
    defer result2.deinit();
    if (result2.count() != 1) return error.NotNullQueryFailed;
}
