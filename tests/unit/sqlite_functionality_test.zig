const std = @import("std");
const testing = std.testing;
const zqlite = @import("zqlite");

test "SQLite Basic CRUD Operations" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create in-memory database
    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Test CREATE TABLE
    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)");

    // Test INSERT
    try conn.execute("INSERT INTO users (name, age) VALUES ('Alice', 25)");
    try conn.execute("INSERT INTO users (name, age) VALUES ('Bob', 30)");
    try conn.execute("INSERT INTO users (name, age) VALUES ('Charlie', 35)");

    // Test SELECT COUNT
    var stmt = try conn.prepare("SELECT COUNT(*) FROM users");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 1);
    const count_value = result.rows.items[0].values[0];
    switch (count_value) {
        .Integer => |count| try testing.expect(count == 3),
        else => return error.UnexpectedValueType,
    }
}

test "SQLite Data Types Support" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Test various SQLite data types
    try conn.execute(
        \\CREATE TABLE type_test (
        \\  id INTEGER PRIMARY KEY,
        \\  text_col TEXT,
        \\  real_col REAL,
        \\  blob_col BLOB,
        \\  null_col TEXT
        \\)
    );

    try conn.execute("INSERT INTO type_test (text_col, real_col, null_col) VALUES ('hello', 3.14, NULL)");

    var stmt = try conn.prepare("SELECT text_col, real_col, null_col FROM type_test WHERE id = 1");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 1);
    const row = result.rows.items[0];

    // Test TEXT type
    switch (row.values[0]) {
        .Text => |text| try testing.expectEqualStrings("hello", text),
        else => return error.UnexpectedValueType,
    }

    // Test REAL type
    switch (row.values[1]) {
        .Real => |real| try testing.expect(@abs(real - 3.14) < 0.01),
        else => return error.UnexpectedValueType,
    }

    // Test NULL type
    switch (row.values[2]) {
        .Null => {},
        else => return error.ExpectedNull,
    }
}

test "SQLite WHERE Clauses and Filtering" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Setup test data
    try conn.execute("CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, price REAL, category TEXT)");
    try conn.execute("INSERT INTO products (name, price, category) VALUES ('Laptop', 999.99, 'Electronics')");
    try conn.execute("INSERT INTO products (name, price, category) VALUES ('Book', 19.99, 'Education')");
    try conn.execute("INSERT INTO products (name, price, category) VALUES ('Phone', 599.99, 'Electronics')");
    try conn.execute("INSERT INTO products (name, price, category) VALUES ('Pen', 2.99, 'Office')");

    // Test numeric comparison
    var stmt = try conn.prepare("SELECT name FROM products WHERE price > 500");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 2); // Laptop and Phone

    // Test text comparison
    var stmt2 = try conn.prepare("SELECT name FROM products WHERE category = 'Electronics'");
    defer stmt2.deinit();

    var result2 = try stmt2.execute();
    defer result2.deinit();

    try testing.expect(result2.rows.items.len == 2); // Laptop and Phone
}

test "SQLite UPDATE and DELETE Operations" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE inventory (id INTEGER PRIMARY KEY, item TEXT, quantity INTEGER)");
    try conn.execute("INSERT INTO inventory (item, quantity) VALUES ('Apples', 100)");
    try conn.execute("INSERT INTO inventory (item, quantity) VALUES ('Bananas', 50)");
    try conn.execute("INSERT INTO inventory (item, quantity) VALUES ('Oranges', 75)");

    // Test UPDATE
    try conn.execute("UPDATE inventory SET quantity = 120 WHERE item = 'Apples'");

    var stmt = try conn.prepare("SELECT quantity FROM inventory WHERE item = 'Apples'");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 1);
    switch (result.rows.items[0].values[0]) {
        .Integer => |qty| try testing.expect(qty == 120),
        else => return error.UnexpectedValueType,
    }

    // Test DELETE
    try conn.execute("DELETE FROM inventory WHERE item = 'Bananas'");

    var stmt2 = try conn.prepare("SELECT COUNT(*) FROM inventory");
    defer stmt2.deinit();

    var result2 = try stmt2.execute();
    defer result2.deinit();

    switch (result2.rows.items[0].values[0]) {
        .Integer => |count| try testing.expect(count == 2), // Should have 2 items left
        else => return error.UnexpectedValueType,
    }
}

test "SQLite JOINS" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Setup tables for JOIN test
    try conn.execute("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, product TEXT, amount REAL)");

    try conn.execute("INSERT INTO customers (name) VALUES ('Alice')");
    try conn.execute("INSERT INTO customers (name) VALUES ('Bob')");

    try conn.execute("INSERT INTO orders (customer_id, product, amount) VALUES (1, 'Laptop', 999.99)");
    try conn.execute("INSERT INTO orders (customer_id, product, amount) VALUES (1, 'Mouse', 29.99)");
    try conn.execute("INSERT INTO orders (customer_id, product, amount) VALUES (2, 'Keyboard', 79.99)");

    // Test INNER JOIN
    var stmt = try conn.prepare(
        \\SELECT c.name, o.product, o.amount
        \\FROM customers c
        \\INNER JOIN orders o ON c.id = o.customer_id
        \\WHERE c.name = 'Alice'
    );
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 2); // Alice has 2 orders
}

test "SQLite GROUP BY and Aggregation" {
    try runGroupByAggregationExecution();
}

pub fn runGroupByAggregationExecution() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE sales (id INTEGER PRIMARY KEY, region TEXT, amount REAL)");
    try conn.execute("INSERT INTO sales (region, amount) VALUES ('North', 1000.00)");
    try conn.execute("INSERT INTO sales (region, amount) VALUES ('North', 1500.00)");
    try conn.execute("INSERT INTO sales (region, amount) VALUES ('South', 800.00)");
    try conn.execute("INSERT INTO sales (region, amount) VALUES ('South', 1200.00)");

    // Test GROUP BY with SUM
    var stmt = try conn.prepare("SELECT region, SUM(amount) as total FROM sales GROUP BY region ORDER BY region");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 2);

    var found_north = false;
    for (result.rows.items) |row| {
        if (row.values.len < 2) return error.UnexpectedValueType;
        if (row.values[0] == .Text and std.mem.eql(u8, row.values[0].Text, "North")) {
            found_north = true;
            switch (row.values[1]) {
                .Real => |total| try testing.expect(@abs(total - 2500.0) < 0.01),
                .Integer => |total| try testing.expectEqual(@as(i64, 2500), total),
                else => return error.UnexpectedValueType,
            }
        }
    }

    try testing.expect(found_north);
}

test "SQLite DEFAULT CURRENT_TIMESTAMP" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Test CREATE TABLE with DEFAULT CURRENT_TIMESTAMP
    try conn.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");

    // Insert without specifying timestamp
    try conn.execute("INSERT INTO events (name) VALUES ('Test Event')");

    var stmt = try conn.prepare("SELECT name, created_at FROM events WHERE id = 1");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 1);

    // Verify that created_at is not null and contains a timestamp
    switch (result.rows.items[0].values[1]) {
        .Text => |timestamp| {
            try testing.expect(timestamp.len > 0);
            // Should contain date format like "2025-10-08 13:34:14"
            try testing.expect(std.mem.indexOf(u8, timestamp, "-") != null);
        },
        else => return error.ExpectedTimestamp,
    }
}

test "SQLite INSERT RETURNING execution" {
    try runInsertReturningExecution();
}

pub fn runInsertReturningExecution() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER DEFAULT 21)");

    var result = try conn.query("INSERT INTO users (id, name) VALUES (1, 'Alice') RETURNING id, name, age");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.count());
    var row = result.next().?;
    defer row.deinit();
    try testing.expectEqual(@as(usize, 3), row.columnCount());
    try testing.expectEqual(@as(i64, 1), row.getIntByName("id").?);
    try testing.expectEqualStrings("Alice", row.getTextByName("name").?);
    try testing.expectEqual(@as(i64, 21), row.getIntByName("age").?);
}

test "SQLite UPDATE RETURNING execution" {
    try runUpdateReturningExecution();
}

pub fn runUpdateReturningExecution() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.execute("INSERT INTO users VALUES (1, 'Alice')");
    try conn.execute("INSERT INTO users VALUES (2, 'Bob')");

    var result = try conn.query("UPDATE users SET name = 'Updated' WHERE id >= 1 RETURNING id, name");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.count());
    var row1 = result.next().?;
    defer row1.deinit();
    var row2 = result.next().?;
    defer row2.deinit();
    try testing.expectEqualStrings("Updated", row1.getTextByName("name").?);
    try testing.expectEqualStrings("Updated", row2.getTextByName("name").?);
}

test "SQLite DELETE RETURNING execution" {
    try runDeleteReturningExecution();
}

pub fn runDeleteReturningExecution() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.execute("INSERT INTO users VALUES (1, 'Alice')");
    try conn.execute("INSERT INTO users VALUES (2, 'Bob')");

    var result = try conn.query("DELETE FROM users WHERE id = 2 RETURNING id, name");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.count());
    var row = result.next().?;
    defer row.deinit();
    try testing.expectEqual(@as(i64, 2), row.getIntByName("id").?);
    try testing.expectEqualStrings("Bob", row.getTextByName("name").?);

    var check = try conn.query("SELECT COUNT(*) FROM users");
    defer check.deinit();
    var check_row = check.next().?;
    defer check_row.deinit();
    try testing.expectEqual(@as(i64, 1), check_row.getInt(0).?);
}

test "SQLite ON CONFLICT DO NOTHING execution" {
    try runOnConflictDoNothingExecution();
}

pub fn runOnConflictDoNothingExecution() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try conn.execute("INSERT INTO users VALUES (1, 'Alice')");
    const affected = try conn.exec("INSERT INTO users VALUES (1, 'Bob') ON CONFLICT DO NOTHING");
    try testing.expectEqual(@as(u32, 0), affected);

    var result = try conn.query("SELECT name FROM users WHERE id = 1");
    defer result.deinit();
    var row = result.next().?;
    defer row.deinit();
    try testing.expectEqualStrings("Alice", row.getText(0).?);
}

test "SQLite ON CONFLICT DO UPDATE execution" {
    try runOnConflictDoUpdateExecution();
}

pub fn runOnConflictDoUpdateExecution() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, active INTEGER)");
    try conn.execute("INSERT INTO users VALUES (1, 'Alice', 1)");
    const affected = try conn.exec("INSERT INTO users VALUES (1, 'Bob', 1) ON CONFLICT (id) DO UPDATE SET name = 'Bob' WHERE active = 1");
    try testing.expectEqual(@as(u32, 1), affected);

    var result = try conn.query("SELECT name FROM users WHERE id = 1");
    defer result.deinit();
    var row = result.next().?;
    defer row.deinit();
    try testing.expectEqualStrings("Bob", row.getText(0).?);
}

test "SQLite UPSERT with RETURNING execution" {
    try runUpsertReturningExecution();
}

pub fn runUpsertReturningExecution() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var insert_result = try conn.query("INSERT INTO users VALUES (1, 'Alice') ON CONFLICT (id) DO UPDATE SET name = 'Alice' RETURNING id, name");
    defer insert_result.deinit();
    var insert_row = insert_result.next().?;
    defer insert_row.deinit();
    try testing.expectEqualStrings("Alice", insert_row.getTextByName("name").?);

    var update_result = try conn.query("INSERT INTO users VALUES (1, 'Bob') ON CONFLICT (id) DO UPDATE SET name = 'Bob' RETURNING id, name");
    defer update_result.deinit();
    var update_row = update_result.next().?;
    defer update_row.deinit();
    try testing.expectEqualStrings("Bob", update_row.getTextByName("name").?);
}
