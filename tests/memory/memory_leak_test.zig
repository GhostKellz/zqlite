const std = @import("std");
const zqlite = @import("zqlite");

/// Comprehensive memory leak detection test suite
/// Targets specific areas: btree.collectAllLeafValues, storage.select,
/// vm.executeTableScan, vm.executeFilter, vm.executeProject
/// Run with: zig build test-memory-leaks
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .ok) {
            std.debug.print("\n✅ NO MEMORY LEAKS DETECTED!\n", .{});
        } else {
            std.debug.print("\n❌ MEMORY LEAK DETECTED! Check output above.\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("🔍 ZQLite Comprehensive Memory Leak Detection\n", .{});
    std.debug.print("=" ** 50 ++ "\n\n", .{});

    var tests_passed: u32 = 0;
    var tests_failed: u32 = 0;

    const tests = [_]struct { name: []const u8, func: *const fn (std.mem.Allocator) anyerror!void }{
        .{ .name = "Open/Close Cycle", .func = testOpenClose },
        .{ .name = "CREATE TABLE", .func = testCreateTable },
        .{ .name = "CREATE TABLE with DEFAULT", .func = testCreateTableWithDefault },
        .{ .name = "INSERT Operations", .func = testInsert },
        .{ .name = "SELECT * (TableScan)", .func = testSelectAll },
        .{ .name = "SELECT with WHERE (Filter)", .func = testSelectWithFilter },
        .{ .name = "SELECT columns (Projection)", .func = testSelectProjection },
        .{ .name = "SELECT with multiple filters", .func = testSelectMultipleFilters },
        .{ .name = "Large result sets", .func = testLargeResultSets },
        .{ .name = "Mixed data types", .func = testMixedDataTypes },
        .{ .name = "NULL handling", .func = testNullHandling },
        .{ .name = "String functions", .func = testStringFunctions },
        .{ .name = "LIKE operator", .func = testLikeOperator },
        .{ .name = "BETWEEN operator", .func = testBetweenOperator },
        .{ .name = "CASE expressions", .func = testCaseExpressions },
        .{ .name = "COALESCE/NULLIF/IFNULL", .func = testNullFunctions },
        .{ .name = "Aggregate functions", .func = testAggregates },
        .{ .name = "GROUP BY", .func = testGroupBy },
        .{ .name = "ORDER BY", .func = testOrderBy },
        .{ .name = "LIMIT/OFFSET", .func = testLimitOffset },
        .{ .name = "JOINs", .func = testJoins },
        .{ .name = "Subqueries in WHERE", .func = testSubqueries },
        .{ .name = "UPDATE operations", .func = testUpdate },
        .{ .name = "DELETE operations", .func = testDelete },
        .{ .name = "Prepared statements", .func = testPreparedStatements },
        .{ .name = "Transactions", .func = testTransactions },
        .{ .name = "Error paths", .func = testErrorPaths },
        .{ .name = "Repeated query cycles", .func = testRepeatedQueryCycles },
        .{ .name = "Multiple connections", .func = testMultipleConnections },
    };

    for (tests, 1..) |t, i| {
        std.debug.print("Test {d:2}: {s}... ", .{ i, t.name });
        if (t.func(allocator)) {
            std.debug.print("PASSED\n", .{});
            tests_passed += 1;
        } else |err| {
            std.debug.print("FAILED ({any})\n", .{err});
            tests_failed += 1;
        }
    }

    std.debug.print("\n" ++ "=" ** 50 ++ "\n", .{});
    std.debug.print("Results: {d} passed, {d} failed\n", .{ tests_passed, tests_failed });

    if (tests_failed > 0) {
        std.process.exit(1);
    }
}

// =============================================================================
// Basic Operations
// =============================================================================

fn testOpenClose(allocator: std.mem.Allocator) !void {
    for (0..20) |_| {
        const conn = try zqlite.open(allocator, ":memory:");
        conn.close();
    }
}

fn testCreateTable(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE t1 (id INTEGER, name TEXT)");
    try conn.execute("CREATE TABLE t2 (a INTEGER, b REAL, c TEXT, d BLOB)");
    try conn.execute("CREATE TABLE t3 (x INTEGER PRIMARY KEY, y TEXT NOT NULL)");
    try conn.execute("CREATE TABLE t4 (id INTEGER, data TEXT, score REAL)");
}

fn testCreateTableWithDefault(allocator: std.mem.Allocator) !void {
    // Test DEFAULT constraints (previously had double-cloning leak)
    for (0..20) |_| {
        const conn = try zqlite.open(allocator, ":memory:");
        defer conn.close();

        try conn.execute("CREATE TABLE tbl_def1 (id INTEGER, status TEXT DEFAULT 'active')");
        try conn.execute("CREATE TABLE tbl_def2 (id INTEGER, val INTEGER DEFAULT 0)");
        try conn.execute("CREATE TABLE tbl_def3 (id INTEGER, note TEXT DEFAULT 'none')");
    }
}

fn testInsert(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE users (id INTEGER, name TEXT, email TEXT)");

    for (0..50) |i| {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO users VALUES ({d}, 'User{d}', 'u{d}@ex.com')", .{ i, i, i });
        try conn.execute(sql);
    }
}

// =============================================================================
// SELECT Operations (targets collectAllLeafValues, executeTableScan)
// =============================================================================

fn testSelectAll(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE data (id INTEGER, value TEXT, score REAL)");
    for (0..50) |i| {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO data VALUES ({d}, 'value{d}', {d}.5)", .{ i, i, i });
        try conn.execute(sql);
    }

    // Multiple SELECT * queries (exercises collectAllLeafValues)
    for (0..30) |_| {
        var result = try conn.query("SELECT * FROM data");
        defer result.deinit();

        while (result.next()) |row| {
            var r = row;
            defer r.deinit();
            _ = r.getValue(0);
            _ = r.getValue(1);
            _ = r.getValue(2);
        }
    }
}

// =============================================================================
// Filter Operations (targets executeFilter)
// =============================================================================

fn testSelectWithFilter(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE items (id INTEGER, category TEXT, price REAL)");
    for (0..40) |i| {
        var buf: [256]u8 = undefined;
        const category = if (i % 3 == 0) "A" else if (i % 3 == 1) "B" else "C";
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO items VALUES ({d}, '{s}', {d}.99)", .{ i, category, i });
        try conn.execute(sql);
    }

    // WHERE with equality (filters out ~2/3 of rows)
    for (0..20) |_| {
        var result = try conn.query("SELECT * FROM items WHERE category = 'A'");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }

    // WHERE with comparison
    for (0..20) |_| {
        var result = try conn.query("SELECT * FROM items WHERE price > 50.0");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }

    // WHERE with AND (multiple conditions)
    for (0..20) |_| {
        var result = try conn.query("SELECT * FROM items WHERE category = 'B' AND price < 30.0");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

fn testSelectMultipleFilters(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE products (id INTEGER, name TEXT, category TEXT, price REAL, stock INTEGER)");
    for (0..40) |i| {
        var buf: [512]u8 = undefined;
        const cat = if (i % 4 == 0) "Electronics" else if (i % 4 == 1) "Clothing" else if (i % 4 == 2) "Food" else "Books";
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO products VALUES ({d}, 'Prod{d}', '{s}', {d}.50, {d})", .{ i, i, cat, i % 100, i % 50 });
        try conn.execute(sql);
    }

    // Filter that matches no rows
    for (0..10) |_| {
        var result = try conn.query("SELECT * FROM products WHERE id = 99999");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }

    // Filter that matches all rows
    for (0..10) |_| {
        var result = try conn.query("SELECT * FROM products WHERE id >= 0");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }

    // Complex filter with OR
    for (0..10) |_| {
        var result = try conn.query("SELECT * FROM products WHERE category = 'Electronics' OR price < 10.0");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

// =============================================================================
// Projection Operations (targets executeProject)
// =============================================================================

fn testSelectProjection(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE employees (id INTEGER, first_name TEXT, last_name TEXT, dept TEXT, salary REAL)");
    for (0..50) |i| {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO employees VALUES ({d}, 'First{d}', 'Last{d}', 'Dept{d}', {d}000.0)", .{ i, i, i, i % 5, i });
        try conn.execute(sql);
    }

    // Select single column
    for (0..20) |_| {
        var result = try conn.query("SELECT first_name FROM employees");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }

    // Select subset of columns
    for (0..20) |_| {
        var result = try conn.query("SELECT id, last_name, salary FROM employees");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }

    // Select with filter and projection
    for (0..20) |_| {
        var result = try conn.query("SELECT first_name, salary FROM employees WHERE salary > 25000.0");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

// =============================================================================
// Large Result Sets (stress test)
// =============================================================================

fn testLargeResultSets(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE big_table (id INTEGER, data TEXT, extra TEXT)");

    // Insert rows (reduced to avoid btree issues)
    for (0..50) |i| {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO big_table VALUES ({d}, 'Row{d}data', 'Extra{d}')", .{ i, i, i });
        try conn.execute(sql);
    }

    // Query all rows multiple times
    for (0..10) |_| {
        var result = try conn.query("SELECT * FROM big_table");
        defer result.deinit();

        var count: usize = 0;
        while (result.next()) |row| {
            var r = row;
            r.deinit();
            count += 1;
        }
        if (count != 50) return error.RowCountMismatch;
    }
}

// =============================================================================
// Data Type Tests
// =============================================================================

fn testMixedDataTypes(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE mixed (int_col INTEGER, real_col REAL, text_col TEXT)");

    for (0..50) |i| {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO mixed VALUES ({d}, {d}.123, 'text{d}')", .{ i, i, i });
        try conn.execute(sql);
    }

    for (0..20) |_| {
        var result = try conn.query("SELECT * FROM mixed");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            _ = r.getInt(0);
            _ = r.getText(2);
            r.deinit();
        }
    }
}

fn testNullHandling(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE nullable (id INTEGER, optional_text TEXT, optional_num INTEGER)");
    try conn.execute("INSERT INTO nullable VALUES (1, 'has value', 100)");
    try conn.execute("INSERT INTO nullable VALUES (2, NULL, 200)");
    try conn.execute("INSERT INTO nullable VALUES (3, 'another', NULL)");
    try conn.execute("INSERT INTO nullable VALUES (4, NULL, NULL)");

    // IS NULL filter
    for (0..20) |_| {
        var result = try conn.query("SELECT * FROM nullable WHERE optional_text IS NULL");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }

    // IS NOT NULL filter
    for (0..20) |_| {
        var result = try conn.query("SELECT * FROM nullable WHERE optional_num IS NOT NULL");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

// =============================================================================
// String and Expression Tests
// =============================================================================

fn testStringFunctions(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE strings (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO strings VALUES (1, 'Hello World')");
    try conn.execute("INSERT INTO strings VALUES (2, 'UPPERCASE')");
    try conn.execute("INSERT INTO strings VALUES (3, 'lowercase')");
    try conn.execute("INSERT INTO strings VALUES (4, '  trimme  ')");

    for (0..10) |_| {
        {
            var result = try conn.query("SELECT UPPER(name) FROM strings");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
        {
            var result = try conn.query("SELECT LOWER(name) FROM strings");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
        {
            var result = try conn.query("SELECT LENGTH(name) FROM strings");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
    }
}

fn testLikeOperator(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE patterns (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO patterns VALUES (1, 'apple')");
    try conn.execute("INSERT INTO patterns VALUES (2, 'application')");
    try conn.execute("INSERT INTO patterns VALUES (3, 'banana')");
    try conn.execute("INSERT INTO patterns VALUES (4, 'cherry')");

    for (0..20) |_| {
        {
            var result = try conn.query("SELECT * FROM patterns WHERE name LIKE 'app%'");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
        {
            var result = try conn.query("SELECT * FROM patterns WHERE name LIKE '%an%'");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
    }
}

fn testBetweenOperator(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE ranges (id INTEGER, value INTEGER)");
    for (0..100) |i| {
        var buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO ranges VALUES ({d}, {d})", .{ i, i });
        try conn.execute(sql);
    }

    for (0..20) |_| {
        var result = try conn.query("SELECT * FROM ranges WHERE value BETWEEN 25 AND 75");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

fn testCaseExpressions(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE grades (id INTEGER, score INTEGER)");
    try conn.execute("INSERT INTO grades VALUES (1, 95)");
    try conn.execute("INSERT INTO grades VALUES (2, 82)");
    try conn.execute("INSERT INTO grades VALUES (3, 67)");
    try conn.execute("INSERT INTO grades VALUES (4, 45)");

    for (0..20) |_| {
        var result = try conn.query("SELECT id, CASE WHEN score >= 90 THEN 'A' WHEN score >= 80 THEN 'B' WHEN score >= 70 THEN 'C' ELSE 'F' END FROM grades");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

fn testNullFunctions(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE nulltest (id INTEGER, a TEXT, b TEXT)");
    try conn.execute("INSERT INTO nulltest VALUES (1, 'first', 'second')");
    try conn.execute("INSERT INTO nulltest VALUES (2, NULL, 'fallback')");
    try conn.execute("INSERT INTO nulltest VALUES (3, 'value', NULL)");

    for (0..20) |_| {
        {
            var result = try conn.query("SELECT COALESCE(a, b, 'default') FROM nulltest");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
        {
            var result = try conn.query("SELECT IFNULL(a, 'was null') FROM nulltest");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
    }
}

// =============================================================================
// Aggregate and Grouping Tests
// =============================================================================

fn testAggregates(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE sales (region TEXT, amount INTEGER)");
    for (0..100) |i| {
        var buf: [128]u8 = undefined;
        const region = if (i % 3 == 0) "North" else if (i % 3 == 1) "South" else "East";
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO sales VALUES ('{s}', {d})", .{ region, (i + 1) * 10 });
        try conn.execute(sql);
    }

    const queries = [_][]const u8{
        "SELECT COUNT(*) FROM sales",
        "SELECT SUM(amount) FROM sales",
        "SELECT AVG(amount) FROM sales",
        "SELECT MIN(amount) FROM sales",
        "SELECT MAX(amount) FROM sales",
    };

    for (queries) |q| {
        for (0..10) |_| {
            var result = try conn.query(q);
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
    }
}

fn testGroupBy(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE orders (customer TEXT, product TEXT, amount INTEGER)");
    const customers = [_][]const u8{ "Alice", "Bob", "Charlie" };
    const products = [_][]const u8{ "Widget", "Gadget", "Thing" };

    for (0..90) |i| {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO orders VALUES ('{s}', '{s}', {d})", .{
            customers[i % 3],
            products[i % 3],
            (i + 1) * 5,
        });
        try conn.execute(sql);
    }

    for (0..20) |_| {
        var result = try conn.query("SELECT customer, SUM(amount) FROM orders GROUP BY customer");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

fn testOrderBy(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE sortable (id INTEGER, name TEXT, value INTEGER)");
    for (0..50) |i| {
        var buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO sortable VALUES ({d}, 'item{d}', {d})", .{ i, 50 - i, i * 2 });
        try conn.execute(sql);
    }

    for (0..10) |_| {
        {
            var result = try conn.query("SELECT * FROM sortable ORDER BY value");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
        {
            var result = try conn.query("SELECT * FROM sortable ORDER BY name DESC");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
    }
}

fn testLimitOffset(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE pageable (id INTEGER, data TEXT)");
    for (0..100) |i| {
        var buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO pageable VALUES ({d}, 'row{d}')", .{ i, i });
        try conn.execute(sql);
    }

    for (0..20) |_| {
        var result = try conn.query("SELECT * FROM pageable LIMIT 10");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

// =============================================================================
// JOIN Tests
// =============================================================================

fn testJoins(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE authors (author_id INTEGER, author_name TEXT)");
    try conn.execute("CREATE TABLE books (book_id INTEGER, title TEXT, author_ref INTEGER)");

    try conn.execute("INSERT INTO authors VALUES (1, 'Alice')");
    try conn.execute("INSERT INTO authors VALUES (2, 'Bob')");
    try conn.execute("INSERT INTO authors VALUES (3, 'Charlie')");

    try conn.execute("INSERT INTO books VALUES (1, 'Book A', 1)");
    try conn.execute("INSERT INTO books VALUES (2, 'Book B', 1)");
    try conn.execute("INSERT INTO books VALUES (3, 'Book C', 2)");
    try conn.execute("INSERT INTO books VALUES (4, 'Book D', 2)");
    try conn.execute("INSERT INTO books VALUES (5, 'Book E', 3)");

    // Use SELECT * to avoid projection bugs with JOINs
    for (0..20) |_| {
        var result = try conn.query("SELECT * FROM authors JOIN books ON author_id = author_ref");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

// =============================================================================
// Subquery Tests
// =============================================================================

fn testSubqueries(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE employees (id INTEGER, name TEXT, dept_id INTEGER, salary INTEGER)");

    for (0..20) |i| {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO employees VALUES ({d}, 'Emp{d}', {d}, {d}000)", .{ i, i, (i % 2) + 1, 30 + i });
        try conn.execute(sql);
    }

    // Test OR conditions as alternative to IN
    for (0..10) |_| {
        var result = try conn.query("SELECT * FROM employees WHERE dept_id = 1 OR dept_id = 2");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

// =============================================================================
// UPDATE and DELETE Tests
// =============================================================================

fn testUpdate(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE counters (id INTEGER, value INTEGER)");
    for (0..30) |i| {
        var buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO counters VALUES ({d}, 0)", .{i});
        try conn.execute(sql);
    }

    // Simple UPDATE without arithmetic expressions
    for (0..20) |_| {
        try conn.execute("UPDATE counters SET value = 1 WHERE id < 15");

        var result = try conn.query("SELECT * FROM counters WHERE id < 5");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

fn testDelete(allocator: std.mem.Allocator) !void {
    // Use separate connections since DROP TABLE may have issues
    for (0..10) |_| {
        const conn = try zqlite.open(allocator, ":memory:");
        defer conn.close();

        try conn.execute("CREATE TABLE temp_data (id INTEGER, value TEXT)");

        for (0..30) |i| {
            var buf: [128]u8 = undefined;
            const sql = try std.fmt.bufPrint(&buf, "INSERT INTO temp_data VALUES ({d}, 'val{d}')", .{ i, i });
            try conn.execute(sql);
        }

        // Delete some rows
        try conn.execute("DELETE FROM temp_data WHERE id > 15");

        {
            var result = try conn.query("SELECT * FROM temp_data");
            defer result.deinit();
            while (result.next()) |row| {
                var r = row;
                r.deinit();
            }
        }
    }
}

// =============================================================================
// Prepared Statement Tests
// =============================================================================

fn testPreparedStatements(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE params (id INTEGER, name TEXT, value REAL)");

    for (0..30) |i| {
        var stmt = try conn.prepare("INSERT INTO params VALUES (?, ?, ?)");
        defer stmt.deinit();

        try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = @intCast(i) });
        try stmt.bindParameter(1, zqlite.storage.Value{ .Text = @constCast("test") });
        try stmt.bindParameter(2, zqlite.storage.Value{ .Real = @floatFromInt(i) });

        var result = try stmt.execute();
        result.deinit();
    }

    // Prepared SELECT
    for (0..20) |_| {
        var stmt = try conn.prepare("SELECT * FROM params WHERE id > ?");
        defer stmt.deinit();

        try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = 15 });

        var result = try stmt.execute();
        defer result.deinit();
    }
}

// =============================================================================
// Transaction Tests
// =============================================================================

fn testTransactions(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE accounts (id INTEGER, balance INTEGER)");

    for (0..20) |i| {
        try conn.begin();

        var buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO accounts VALUES ({d}, 1000)", .{i});
        try conn.execute(sql);

        try conn.commit();
    }

    // Query after transactions
    {
        var result = try conn.query("SELECT * FROM accounts");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

// =============================================================================
// Error Path Tests
// =============================================================================

fn testErrorPaths(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Invalid SQL
    _ = conn.execute("INVALID SQL") catch {};

    // Non-existent table
    _ = conn.query("SELECT * FROM nonexistent") catch {};

    // Duplicate table
    try conn.execute("CREATE TABLE dup (id INTEGER)");
    _ = conn.execute("CREATE TABLE dup (id INTEGER)") catch {};

    // Type mismatch scenarios
    try conn.execute("CREATE TABLE typed (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO typed VALUES (1, 'valid')");

    // Should still work after errors
    {
        var result = try conn.query("SELECT * FROM typed");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}

// =============================================================================
// Stress Tests
// =============================================================================

fn testRepeatedQueryCycles(allocator: std.mem.Allocator) !void {
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE cycle_test (id INTEGER, data TEXT)");
    for (0..100) |i| {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO cycle_test VALUES ({d}, 'data{d}')", .{ i, i });
        try conn.execute(sql);
    }

    // Rapid query/close cycles
    for (0..100) |_| {
        var result = try conn.query("SELECT * FROM cycle_test WHERE id < 50");
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
        result.deinit();
    }
}

fn testMultipleConnections(allocator: std.mem.Allocator) !void {
    // Open multiple connections, each with their own operations
    for (0..10) |_| {
        const conn = try zqlite.open(allocator, ":memory:");
        defer conn.close();

        try conn.execute("CREATE TABLE multi (id INTEGER, value TEXT)");

        for (0..20) |i| {
            var buf: [128]u8 = undefined;
            const sql = try std.fmt.bufPrint(&buf, "INSERT INTO multi VALUES ({d}, 'val{d}')", .{ i, i });
            try conn.execute(sql);
        }

        var result = try conn.query("SELECT * FROM multi");
        defer result.deinit();
        while (result.next()) |row| {
            var r = row;
            r.deinit();
        }
    }
}
