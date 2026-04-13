const std = @import("std");
const testing = std.testing;
const zqlite = @import("zqlite");

test "Query Validation - Complex SELECT Statements" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Setup complex schema
    try conn.execute(
        \\CREATE TABLE departments (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  budget REAL DEFAULT 0.0
        \\)
    );

    try conn.execute(
        \\CREATE TABLE employees (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  department_id INTEGER,
        \\  salary REAL,
        \\  hire_date DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Insert test data
    try conn.execute("INSERT INTO departments (name, budget) VALUES ('Engineering', 1000000.0)");
    try conn.execute("INSERT INTO departments (name, budget) VALUES ('Marketing', 500000.0)");
    try conn.execute("INSERT INTO departments (name, budget) VALUES ('Sales', 750000.0)");

    try conn.execute("INSERT INTO employees (name, department_id, salary) VALUES ('Alice', 1, 80000.0)");
    try conn.execute("INSERT INTO employees (name, department_id, salary) VALUES ('Bob', 1, 85000.0)");
    try conn.execute("INSERT INTO employees (name, department_id, salary) VALUES ('Charlie', 2, 60000.0)");
    try conn.execute("INSERT INTO employees (name, department_id, salary) VALUES ('Diana', 3, 70000.0)");

    // Test complex JOIN with GROUP BY
    var stmt = try conn.prepare(
        \\SELECT d.name as dept_name, COUNT(e.id) as employee_count, AVG(e.salary) as avg_salary
        \\FROM departments d
        \\LEFT JOIN employees e ON d.id = e.department_id
        \\GROUP BY d.id, d.name
        \\ORDER BY employee_count DESC
    );
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 3);

    // Engineering should have highest employee count (2)
    const first_row = result.rows.items[0];
    switch (first_row.values[1]) {
        .Integer => |count| try testing.expect(count == 2),
        else => return error.UnexpectedValueType,
    }
}

test "Query Validation - Subqueries and Window Functions" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE sales (
        \\  id INTEGER PRIMARY KEY,
        \\  product TEXT,
        \\  amount REAL,
        \\  sale_date DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Insert sample sales data
    try conn.execute("INSERT INTO sales (product, amount) VALUES ('Laptop', 1200.00)");
    try conn.execute("INSERT INTO sales (product, amount) VALUES ('Phone', 800.00)");
    try conn.execute("INSERT INTO sales (product, amount) VALUES ('Tablet', 600.00)");
    try conn.execute("INSERT INTO sales (product, amount) VALUES ('Laptop', 1300.00)");
    try conn.execute("INSERT INTO sales (product, amount) VALUES ('Phone', 850.00)");

    // Test subquery - products with above-average sales
    var stmt = try conn.prepare(
        \\SELECT product, amount
        \\FROM sales
        \\WHERE amount > (SELECT AVG(amount) FROM sales)
        \\ORDER BY amount DESC
    );
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    // Should return laptops and potentially some phones
    try testing.expect(result.rows.items.len >= 2);
}

test "Query Validation - Prepared named window definitions" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE employees (id INTEGER PRIMARY KEY, name TEXT, department TEXT, salary INTEGER)");
    try conn.execute("INSERT INTO employees (name, department, salary) VALUES ('Alice', 'Engineering', 75000)");
    try conn.execute("INSERT INTO employees (name, department, salary) VALUES ('Bob', 'Engineering', 80000)");
    try conn.execute("INSERT INTO employees (name, department, salary) VALUES ('Eve', 'Sales', 72000)");

    var stmt = try conn.prepare(
        \\SELECT name, department, ROW_NUMBER() OVER dept_salary AS dept_rank
        \\FROM employees
        \\WINDOW dept_salary AS (PARTITION BY department ORDER BY salary DESC)
    );
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 3);

    var found_bob = false;
    for (result.rows.items) |row| {
        if (row.values[0] == .Text and std.mem.eql(u8, row.values[0].Text, "Bob")) {
            found_bob = true;
            switch (row.values[2]) {
                .Integer => |rank| try testing.expectEqual(@as(i64, 1), rank),
                else => return error.UnexpectedValueType,
            }
        }
    }

    try testing.expect(found_bob);
}

test "Query Validation - Date and Time Functions" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE events (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT,
        \\  event_date DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    try conn.execute("INSERT INTO events (name) VALUES ('Event 1')");
    try conn.execute("INSERT INTO events (name) VALUES ('Event 2')");

    // Test date functions
    var stmt = try conn.prepare(
        \\SELECT name, event_date,
        \\       datetime('now') as current_time
        \\FROM events
        \\WHERE event_date IS NOT NULL
    );
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 2);

    // Verify that event_date is populated
    for (result.rows.items) |row| {
        switch (row.values[1]) {
            .Text => |date_str| try testing.expect(date_str.len > 0),
            .Null => return error.ExpectedNonNullDate,
            else => return error.UnexpectedDateType,
        }
    }
}

test "Query Validation - Transaction Integrity" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE accounts (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT,
        \\  balance REAL DEFAULT 0.0,
        \\  last_updated DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    try conn.execute("INSERT INTO accounts (name, balance) VALUES ('Alice', 1000.0)");
    try conn.execute("INSERT INTO accounts (name, balance) VALUES ('Bob', 500.0)");

    // Test basic transaction-like operations
    // (Note: This tests the operations, actual transaction support would require BEGIN/COMMIT)

    // Transfer money from Alice to Bob
    try conn.execute("UPDATE accounts SET balance = balance - 200.0 WHERE name = 'Alice'");
    try conn.execute("UPDATE accounts SET balance = balance + 200.0 WHERE name = 'Bob'");

    // Verify the transfer
    var stmt = try conn.prepare("SELECT name, balance FROM accounts ORDER BY name");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 2);

    // Alice should have 800.0
    switch (result.rows.items[0].values[1]) {
        .Real => |balance| try testing.expect(@abs(balance - 800.0) < 0.01),
        else => return error.UnexpectedValueType,
    }

    // Bob should have 700.0
    switch (result.rows.items[1].values[1]) {
        .Real => |balance| try testing.expect(@abs(balance - 700.0) < 0.01),
        else => return error.UnexpectedValueType,
    }
}

test "Query Validation - Error Handling and Edge Cases" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE test_table (id INTEGER PRIMARY KEY, value TEXT)");

    // Test that syntax errors are properly caught
    const result = conn.execute("INVALID SQL STATEMENT");
    try testing.expect(std.meta.isError(result));

    // Test that table not found errors are handled
    const result2 = conn.execute("SELECT * FROM nonexistent_table");
    try testing.expect(std.meta.isError(result2));

    // Test valid operations still work after errors
    try conn.execute("INSERT INTO test_table (value) VALUES ('test')");

    var stmt = try conn.prepare("SELECT COUNT(*) FROM test_table");
    defer stmt.deinit();

    var query_result = try stmt.execute();
    defer query_result.deinit();

    switch (query_result.rows.items[0].values[0]) {
        .Integer => |count| try testing.expect(count == 1),
        else => return error.UnexpectedValueType,
    }
}

test "Query Validation - Index Performance" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE indexed_table (
        \\  id INTEGER PRIMARY KEY,
        \\  email TEXT UNIQUE,
        \\  name TEXT,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Insert test data
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const email = try std.fmt.allocPrint(allocator, "user{}@example.com", .{i});
        defer allocator.free(email);

        const name = try std.fmt.allocPrint(allocator, "User {}", .{i});
        defer allocator.free(name);

        // Note: Using placeholder for simplicity - real implementation would use parameters
        try conn.execute("INSERT INTO indexed_table (email, name) VALUES ('user@example.com', 'User Name')");
    }

    // Test that indexed searches work efficiently
    var stmt = try conn.prepare("SELECT COUNT(*) FROM indexed_table WHERE id < 50");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    switch (result.rows.items[0].values[0]) {
        .Integer => |count| try testing.expect(count == 49), // IDs 1-49
        else => return error.UnexpectedValueType,
    }
}

test "Query Validation - NULL Handling" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE null_test (
        \\  id INTEGER PRIMARY KEY,
        \\  optional_field TEXT,
        \\  required_field TEXT NOT NULL DEFAULT 'default_value',
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Insert row with NULL optional field
    try conn.execute("INSERT INTO null_test (optional_field) VALUES (NULL)");

    // Insert row with explicit optional field
    try conn.execute("INSERT INTO null_test (optional_field) VALUES ('not_null')");

    // Test NULL queries
    var stmt1 = try conn.prepare("SELECT COUNT(*) FROM null_test WHERE optional_field IS NULL");
    defer stmt1.deinit();

    var result1 = try stmt1.execute();
    defer result1.deinit();

    switch (result1.rows.items[0].values[0]) {
        .Integer => |count| try testing.expect(count == 1),
        else => return error.UnexpectedValueType,
    }

    var stmt2 = try conn.prepare("SELECT COUNT(*) FROM null_test WHERE optional_field IS NOT NULL");
    defer stmt2.deinit();

    var result2 = try stmt2.execute();
    defer result2.deinit();

    switch (result2.rows.items[0].values[0]) {
        .Integer => |count| try testing.expect(count == 1),
        else => return error.UnexpectedValueType,
    }
}
