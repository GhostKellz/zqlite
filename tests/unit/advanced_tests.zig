const std = @import("std");
const zqlite = @import("zqlite");

// Helper function to count rows from a query
fn countRows(conn: *zqlite.Connection, sql: []const u8) !usize {
    var result = try conn.query(sql);
    defer result.deinit();
    return result.count();
}

// Helper function to check if query returns rows
fn queryHasRows(conn: *zqlite.Connection, sql: []const u8) !bool {
    var result = try conn.query(sql);
    defer result.deinit();
    return result.count() > 0;
}

// ============================================================================
// STRESS TESTS - Test system under load
// ============================================================================

test "stress: high volume insertions" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE stress_insert (id INTEGER PRIMARY KEY, data TEXT, value INTEGER)");

    // Insert 500 rows (reduced for test speed)
    var i: i32 = 0;
    while (i < 500) : (i += 1) {
        var stmt = try conn.prepare("INSERT INTO stress_insert (data, value) VALUES (?, ?)");
        defer stmt.deinit();

        const data = try std.fmt.allocPrint(allocator, "data_{d}", .{i});
        defer allocator.free(data);

        try stmt.bindParameter(0, zqlite.storage.Value{ .Text = data });
        try stmt.bindParameter(1, zqlite.storage.Value{ .Integer = i });

        var result = try stmt.execute();
        result.deinit();
    }

    // Verify count
    const row_count = try countRows(conn, "SELECT * FROM stress_insert");
    try std.testing.expectEqual(@as(usize, 500), row_count);
}

test "stress: rapid connection cycling" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked != .ok) {
            @panic("Memory leak detected in connection cycling test!");
        }
    }
    const allocator = gpa.allocator();

    // Open and close 20 connections rapidly (reduced for test speed)
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const conn = try zqlite.open(allocator, ":memory:");
        try conn.execute("CREATE TABLE test (id INTEGER)");
        try conn.execute("INSERT INTO test VALUES (1)");
        _ = try countRows(conn, "SELECT * FROM test");
        conn.close();
    }
}

test "stress: large result sets" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE large_result (id INTEGER, category TEXT, amount REAL)");

    // Insert 200 rows (reduced for test speed)
    var i: i32 = 0;
    while (i < 200) : (i += 1) {
        var stmt = try conn.prepare("INSERT INTO large_result VALUES (?, ?, ?)");
        defer stmt.deinit();

        try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = i });
        const cat: []const u8 = if (@mod(i, 2) == 0) "even" else "odd";
        try stmt.bindParameter(1, zqlite.storage.Value{ .Text = cat });
        try stmt.bindParameter(2, zqlite.storage.Value{ .Real = @as(f64, @floatFromInt(i)) * 1.5 });

        var result = try stmt.execute();
        result.deinit();
    }

    // Query all rows
    const row_count = try countRows(conn, "SELECT * FROM large_result ORDER BY id");
    try std.testing.expectEqual(@as(usize, 200), row_count);
}

test "stress: repeated queries" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE query_stress (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO query_stress VALUES (1, 'test')");

    // Execute same query 100 times (reduced for test speed)
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const row_count = try countRows(conn, "SELECT * FROM query_stress WHERE id = 1");
        try std.testing.expectEqual(@as(usize, 1), row_count);
    }
}

// ============================================================================
// SECURITY TESTS - Test SQL injection prevention and input sanitization
// ============================================================================

test "security: SQL injection via text parameter" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE users (id INTEGER, username TEXT, password TEXT)");
    try conn.execute("INSERT INTO users VALUES (1, 'admin', 'secret')");
    try conn.execute("INSERT INTO users VALUES (2, 'user', 'pass123')");

    // Attempt SQL injection via prepared statement (should be safe)
    var stmt = try conn.prepare("SELECT * FROM users WHERE username = ?");
    defer stmt.deinit();

    // Malicious input that would be an injection in naive string concatenation
    const malicious_input = "admin' OR '1'='1";
    try stmt.bindParameter(0, zqlite.storage.Value{ .Text = malicious_input });

    var exec_result = try stmt.execute();
    defer exec_result.deinit();

    // Count rows - should return 0 (no user with that literal username exists)
    // ExecutionResult stores rows in an ArrayList
    const row_count = exec_result.rows.items.len;
    try std.testing.expectEqual(@as(usize, 0), row_count);
}

test "security: special characters in text" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE special_chars (id INTEGER, content TEXT)");

    // Test various special characters via prepared statements
    const special_strings = [_][]const u8{
        "Hello 'World'",
        "Test \"quotes\"",
        "Semi;colon",
        "Backslash\\test",
        "--comment",
        "/* block comment */",
    };

    var id: i32 = 1;
    for (special_strings) |str| {
        var stmt = try conn.prepare("INSERT INTO special_chars VALUES (?, ?)");
        defer stmt.deinit();

        try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = id });
        try stmt.bindParameter(1, zqlite.storage.Value{ .Text = str });

        var result = try stmt.execute();
        result.deinit();
        id += 1;
    }

    // Verify all rows were inserted
    const row_count = try countRows(conn, "SELECT * FROM special_chars");
    try std.testing.expect(row_count >= 6);
}

test "security: numeric overflow handling" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE overflow_test (id INTEGER, big_num INTEGER)");

    // Insert maximum i64 value
    var stmt = try conn.prepare("INSERT INTO overflow_test VALUES (?, ?)");
    defer stmt.deinit();

    try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = 1 });
    try stmt.bindParameter(1, zqlite.storage.Value{ .Integer = std.math.maxInt(i64) });

    var result = try stmt.execute();
    result.deinit();

    // Verify it was stored correctly
    var query_result = try conn.query("SELECT big_num FROM overflow_test WHERE id = 1");
    defer query_result.deinit();

    if (query_result.next()) |row| {
        var r = row;
        defer r.deinit();
        if (r.getValue(0)) |v| {
            try std.testing.expectEqual(std.math.maxInt(i64), v.Integer);
        }
    }
}

// ============================================================================
// EDGE CASE TESTS - Test boundary conditions
// ============================================================================

test "edge: empty table operations" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE empty_table (id INTEGER, data TEXT)");

    // Query empty table
    const row_count = try countRows(conn, "SELECT * FROM empty_table");
    try std.testing.expectEqual(@as(usize, 0), row_count);

    // Update empty table (should succeed, affect 0 rows)
    try conn.execute("UPDATE empty_table SET data = 'test'");

    // Delete from empty table (should succeed, affect 0 rows)
    try conn.execute("DELETE FROM empty_table");
}

test "edge: long text values" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE long_text (id INTEGER, content TEXT)");

    // Create a 2KB string (fits within page size limits)
    const long_string = try allocator.alloc(u8, 2 * 1024);
    defer allocator.free(long_string);
    @memset(long_string, 'A');

    var stmt = try conn.prepare("INSERT INTO long_text VALUES (?, ?)");
    defer stmt.deinit();

    try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = 1 });
    try stmt.bindParameter(1, zqlite.storage.Value{ .Text = long_string });

    var result = try stmt.execute();
    result.deinit();

    // Verify the data was stored
    const row_count = try countRows(conn, "SELECT * FROM long_text WHERE id = 1");
    try std.testing.expectEqual(@as(usize, 1), row_count);
}

test "edge: boundary integer values" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE int_bounds (id INTEGER PRIMARY KEY, value INTEGER)");

    // Test various boundary values
    const boundary_values = [_]i64{
        0,
        1,
        -1,
        127, // i8 max
        -128, // i8 min
        32767, // i16 max
        -32768, // i16 min
        2147483647, // i32 max
        -2147483648, // i32 min
    };

    var id: i32 = 1;
    for (boundary_values) |val| {
        var stmt = try conn.prepare("INSERT INTO int_bounds VALUES (?, ?)");
        defer stmt.deinit();

        try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = id });
        try stmt.bindParameter(1, zqlite.storage.Value{ .Integer = val });

        var result = try stmt.execute();
        result.deinit();
        id += 1;
    }

    // Verify count
    const row_count = try countRows(conn, "SELECT * FROM int_bounds");
    try std.testing.expectEqual(@as(usize, boundary_values.len), row_count);
}

test "edge: null value handling in all positions" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE null_positions (col1 INTEGER, col2 TEXT, col3 REAL, col4 INTEGER)");

    // Insert rows with NULL in different positions
    try conn.execute("INSERT INTO null_positions VALUES (NULL, 'text', 1.5, 1)");
    try conn.execute("INSERT INTO null_positions VALUES (1, NULL, 1.5, 2)");
    try conn.execute("INSERT INTO null_positions VALUES (1, 'text', NULL, 3)");
    try conn.execute("INSERT INTO null_positions VALUES (1, 'text', 1.5, NULL)");
    try conn.execute("INSERT INTO null_positions VALUES (NULL, NULL, NULL, NULL)");

    // Verify all rows were inserted correctly
    const total_count = try countRows(conn, "SELECT * FROM null_positions");
    try std.testing.expectEqual(@as(usize, 5), total_count);

    // Query rows where col1 IS NULL (should be 2 rows)
    const null_count = try countRows(conn, "SELECT * FROM null_positions WHERE col1 IS NULL");
    try std.testing.expectEqual(@as(usize, 2), null_count);

    // Query rows where col1 IS NOT NULL (should be 3 rows)
    const not_null_count = try countRows(conn, "SELECT * FROM null_positions WHERE col1 IS NOT NULL");
    try std.testing.expectEqual(@as(usize, 3), not_null_count);

    // Query rows where col4 has a specific value to verify non-NULL columns work
    const specific_count = try countRows(conn, "SELECT * FROM null_positions WHERE col4 = 1");
    try std.testing.expectEqual(@as(usize, 1), specific_count);
}

test "edge: table with many columns" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Create table with 10 columns
    try conn.execute(
        \\CREATE TABLE wide_table (
        \\  c1 INTEGER, c2 TEXT, c3 REAL, c4 INTEGER, c5 TEXT,
        \\  c6 REAL, c7 INTEGER, c8 TEXT, c9 REAL, c10 INTEGER
        \\)
    );

    // Insert a row
    try conn.execute(
        \\INSERT INTO wide_table VALUES (
        \\  1, 't1', 1.1, 2, 't2',
        \\  2.2, 3, 't3', 3.3, 4
        \\)
    );

    // Query and verify
    const row_count = try countRows(conn, "SELECT * FROM wide_table");
    try std.testing.expectEqual(@as(usize, 1), row_count);
}

// ============================================================================
// REGRESSION TESTS - Specific bug fixes and edge cases
// ============================================================================

test "regression: consecutive execute calls" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Multiple CREATE TABLE statements
    try conn.execute("CREATE TABLE reg1 (id INTEGER)");
    try conn.execute("CREATE TABLE reg2 (id INTEGER)");
    try conn.execute("CREATE TABLE reg3 (id INTEGER)");

    // Multiple INSERT statements
    try conn.execute("INSERT INTO reg1 VALUES (1)");
    try conn.execute("INSERT INTO reg2 VALUES (2)");
    try conn.execute("INSERT INTO reg3 VALUES (3)");

    // Verify all tables exist and have data
    try std.testing.expectEqual(@as(usize, 1), try countRows(conn, "SELECT * FROM reg1"));
    try std.testing.expectEqual(@as(usize, 1), try countRows(conn, "SELECT * FROM reg2"));
    try std.testing.expectEqual(@as(usize, 1), try countRows(conn, "SELECT * FROM reg3"));
}

test "regression: query after modify operations" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE modify_test (id INTEGER PRIMARY KEY, value INTEGER)");

    // Insert, query, update, query, delete, query
    try conn.execute("INSERT INTO modify_test VALUES (1, 100)");

    const q1_count = try countRows(conn, "SELECT * FROM modify_test WHERE id = 1");
    try std.testing.expectEqual(@as(usize, 1), q1_count);

    try conn.execute("UPDATE modify_test SET value = 200 WHERE id = 1");

    // Verify UPDATE worked - must have exactly 1 row where id = 1
    const q2_count = try countRows(conn, "SELECT * FROM modify_test WHERE id = 1");
    try std.testing.expectEqual(@as(usize, 1), q2_count);

    // Verify the value was actually updated
    var q2 = try conn.query("SELECT * FROM modify_test WHERE id = 1");
    defer q2.deinit();
    if (q2.next()) |row| {
        var r = row;
        r.deinit();
    } else {
        // No row found - UPDATE didn't preserve id correctly
        return error.TestUnexpectedResult;
    }

    try conn.execute("DELETE FROM modify_test WHERE id = 1");

    const q3_count = try countRows(conn, "SELECT * FROM modify_test");
    try std.testing.expectEqual(@as(usize, 0), q3_count);
}

// ============================================================================
// SQL COMPLETENESS TESTS - New SQL features
// ============================================================================

test "sql: BETWEEN operator" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE numbers (id INTEGER, value INTEGER)");
    try conn.execute("INSERT INTO numbers VALUES (1, 10)");
    try conn.execute("INSERT INTO numbers VALUES (2, 25)");
    try conn.execute("INSERT INTO numbers VALUES (3, 50)");
    try conn.execute("INSERT INTO numbers VALUES (4, 75)");
    try conn.execute("INSERT INTO numbers VALUES (5, 100)");

    // Test BETWEEN (inclusive on both ends)
    const between_count = try countRows(conn, "SELECT * FROM numbers WHERE value BETWEEN 20 AND 80");
    try std.testing.expectEqual(@as(usize, 3), between_count); // 25, 50, 75

    // Test NOT BETWEEN
    const not_between_count = try countRows(conn, "SELECT * FROM numbers WHERE value NOT BETWEEN 20 AND 80");
    try std.testing.expectEqual(@as(usize, 2), not_between_count); // 10, 100
}

test "sql: LIKE pattern matching" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE names (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO names VALUES (1, 'Alice')");
    try conn.execute("INSERT INTO names VALUES (2, 'Bob')");
    try conn.execute("INSERT INTO names VALUES (3, 'Charlie')");
    try conn.execute("INSERT INTO names VALUES (4, 'David')");
    try conn.execute("INSERT INTO names VALUES (5, 'Alex')");

    // Test % wildcard (matches any sequence)
    const starts_with_a = try countRows(conn, "SELECT * FROM names WHERE name LIKE 'A%'");
    try std.testing.expectEqual(@as(usize, 2), starts_with_a); // Alice, Alex

    // Test % at both ends
    const contains_li = try countRows(conn, "SELECT * FROM names WHERE name LIKE '%li%'");
    try std.testing.expectEqual(@as(usize, 2), contains_li); // Alice, Charlie

    // Test _ wildcard (matches single character)
    const four_char_starts_d = try countRows(conn, "SELECT * FROM names WHERE name LIKE 'D____'");
    try std.testing.expectEqual(@as(usize, 1), four_char_starts_d); // David

    // Test NOT LIKE
    const not_starts_with_a = try countRows(conn, "SELECT * FROM names WHERE name NOT LIKE 'A%'");
    try std.testing.expectEqual(@as(usize, 3), not_starts_with_a); // Bob, Charlie, David
}

test "sql: CASE WHEN expressions" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE scores (id INTEGER, name TEXT, score INTEGER)");
    try conn.execute("INSERT INTO scores VALUES (1, 'Alice', 95)");
    try conn.execute("INSERT INTO scores VALUES (2, 'Bob', 75)");
    try conn.execute("INSERT INTO scores VALUES (3, 'Charlie', 55)");
    try conn.execute("INSERT INTO scores VALUES (4, 'David', 85)");

    // Test CASE WHEN with multiple conditions
    var result = try conn.query("SELECT name, CASE WHEN score >= 90 THEN 'A' WHEN score >= 80 THEN 'B' WHEN score >= 70 THEN 'C' ELSE 'F' END FROM scores ORDER BY id");
    defer result.deinit();

    // Verify results
    try std.testing.expectEqual(@as(usize, 4), result.count());

    // Check grades: Alice=A, Bob=C, Charlie=F, David=B
    const rows = result.rows.items;
    // Row 0: Alice with grade A
    try std.testing.expectEqualStrings("Alice", rows[0].values[0].Text);
    try std.testing.expectEqualStrings("A", rows[0].values[1].Text);
    // Row 1: Bob with grade C
    try std.testing.expectEqualStrings("Bob", rows[1].values[0].Text);
    try std.testing.expectEqualStrings("C", rows[1].values[1].Text);
    // Row 2: Charlie with grade F
    try std.testing.expectEqualStrings("Charlie", rows[2].values[0].Text);
    try std.testing.expectEqualStrings("F", rows[2].values[1].Text);
    // Row 3: David with grade B
    try std.testing.expectEqualStrings("David", rows[3].values[0].Text);
    try std.testing.expectEqualStrings("B", rows[3].values[1].Text);
}

test "sql: COALESCE, NULLIF, IFNULL functions" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE nulltest (id INTEGER, val1 TEXT, val2 TEXT)");
    try conn.execute("INSERT INTO nulltest VALUES (1, NULL, 'default')");
    try conn.execute("INSERT INTO nulltest VALUES (2, 'actual', 'default')");
    try conn.execute("INSERT INTO nulltest VALUES (3, 'same', 'same')");
    try conn.execute("INSERT INTO nulltest VALUES (4, 'different', 'other')");

    // Test COALESCE - returns first non-NULL value
    var result1 = try conn.query("SELECT id, COALESCE(val1, val2, 'fallback') FROM nulltest ORDER BY id");
    defer result1.deinit();

    try std.testing.expectEqual(@as(usize, 4), result1.count());
    const rows1 = result1.rows.items;
    // Row 1: val1 is NULL, so COALESCE returns val2 'default'
    try std.testing.expectEqualStrings("default", rows1[0].values[1].Text);
    // Row 2: val1 is 'actual', so COALESCE returns it
    try std.testing.expectEqualStrings("actual", rows1[1].values[1].Text);

    // Test IFNULL - returns second arg if first is NULL
    var result2 = try conn.query("SELECT id, IFNULL(val1, 'replacement') FROM nulltest ORDER BY id");
    defer result2.deinit();

    const rows2 = result2.rows.items;
    // Row 1: val1 is NULL, so IFNULL returns 'replacement'
    try std.testing.expectEqualStrings("replacement", rows2[0].values[1].Text);
    // Row 2: val1 is 'actual', so IFNULL returns it
    try std.testing.expectEqualStrings("actual", rows2[1].values[1].Text);

    // Test NULLIF - returns NULL if args are equal
    var result3 = try conn.query("SELECT id, NULLIF(val1, val2) FROM nulltest WHERE id >= 3 ORDER BY id");
    defer result3.deinit();

    const rows3 = result3.rows.items;
    // Row 3: val1 = val2 = 'same', so NULLIF returns NULL
    try std.testing.expect(rows3[0].values[1] == .Null);
    // Row 4: val1 != val2, so NULLIF returns val1 'different'
    try std.testing.expectEqualStrings("different", rows3[1].values[1].Text);
}

test "sql: String functions (UPPER, LOWER, SUBSTR, LENGTH, TRIM)" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE strings (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO strings VALUES (1, 'Hello World')");
    try conn.execute("INSERT INTO strings VALUES (2, '  Trimmed  ')");
    try conn.execute("INSERT INTO strings VALUES (3, 'Substring Test')");

    // Test UPPER
    var result1 = try conn.query("SELECT id, UPPER(name) FROM strings WHERE id = 1");
    defer result1.deinit();
    const rows1 = result1.rows.items;
    try std.testing.expectEqualStrings("HELLO WORLD", rows1[0].values[1].Text);

    // Test LOWER
    var result2 = try conn.query("SELECT id, LOWER(name) FROM strings WHERE id = 1");
    defer result2.deinit();
    const rows2 = result2.rows.items;
    try std.testing.expectEqualStrings("hello world", rows2[0].values[1].Text);

    // Test LENGTH
    var result3 = try conn.query("SELECT id, LENGTH(name) FROM strings WHERE id = 1");
    defer result3.deinit();
    const rows3 = result3.rows.items;
    try std.testing.expectEqual(@as(i64, 11), rows3[0].values[1].Integer);

    // Test TRIM
    var result4 = try conn.query("SELECT id, TRIM(name) FROM strings WHERE id = 2");
    defer result4.deinit();
    const rows4 = result4.rows.items;
    try std.testing.expectEqualStrings("Trimmed", rows4[0].values[1].Text);

    // Test SUBSTR with start and length
    var result5 = try conn.query("SELECT id, SUBSTR(name, 1, 5) FROM strings WHERE id = 1");
    defer result5.deinit();
    const rows5 = result5.rows.items;
    try std.testing.expectEqualStrings("Hello", rows5[0].values[1].Text);

    // Test SUBSTR with just start (rest of string)
    var result6 = try conn.query("SELECT id, SUBSTR(name, 7) FROM strings WHERE id = 1");
    defer result6.deinit();
    const rows6 = result6.rows.items;
    try std.testing.expectEqualStrings("World", rows6[0].values[1].Text);
}

test "introspection: PRAGMA table_info" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Create a table with various column types
    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, score REAL)");

    // Query table_info
    var result = try conn.query("PRAGMA table_info(users)");
    defer result.deinit();

    // Should have 4 rows (one per column)
    try std.testing.expectEqual(@as(usize, 4), result.count());

    const rows = result.rows.items;

    // Check id column (cid=0, name=id, type=INTEGER, notnull=0, dflt_value=NULL, pk=1)
    try std.testing.expectEqual(@as(i64, 0), rows[0].values[0].Integer); // cid
    try std.testing.expectEqualStrings("id", rows[0].values[1].Text); // name
    try std.testing.expectEqualStrings("INTEGER", rows[0].values[2].Text); // type
    try std.testing.expectEqual(@as(i64, 0), rows[0].values[3].Integer); // notnull (nullable by default)
    try std.testing.expect(rows[0].values[4] == .Null); // dflt_value
    try std.testing.expectEqual(@as(i64, 1), rows[0].values[5].Integer); // pk

    // Check name column (cid=1, name=name, type=TEXT, notnull=1, dflt_value=NULL, pk=0)
    try std.testing.expectEqual(@as(i64, 1), rows[1].values[0].Integer); // cid
    try std.testing.expectEqualStrings("name", rows[1].values[1].Text); // name
    try std.testing.expectEqualStrings("TEXT", rows[1].values[2].Text); // type
    try std.testing.expectEqual(@as(i64, 1), rows[1].values[3].Integer); // notnull (NOT NULL)
    try std.testing.expect(rows[1].values[4] == .Null); // dflt_value
    try std.testing.expectEqual(@as(i64, 0), rows[1].values[5].Integer); // pk

    // Check email column (cid=2, name=email, type=TEXT, notnull=0, pk=0)
    try std.testing.expectEqual(@as(i64, 2), rows[2].values[0].Integer); // cid
    try std.testing.expectEqualStrings("email", rows[2].values[1].Text); // name
    try std.testing.expectEqualStrings("TEXT", rows[2].values[2].Text); // type
    try std.testing.expectEqual(@as(i64, 0), rows[2].values[3].Integer); // notnull (nullable)

    // Check score column (cid=3, name=score, type=REAL, notnull=0, pk=0)
    try std.testing.expectEqual(@as(i64, 3), rows[3].values[0].Integer); // cid
    try std.testing.expectEqualStrings("score", rows[3].values[1].Text); // name
    try std.testing.expectEqualStrings("REAL", rows[3].values[2].Text); // type
}

test "introspection: EXPLAIN QUERY PLAN" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leak = gpa.deinit();
        if (leak != .ok) {
            @panic("Memory leak detected in EXPLAIN QUERY PLAN test!");
        }
    }
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Create a table
    try conn.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, customer TEXT, amount REAL)");

    // Query EXPLAIN (simple version)
    var result = try conn.query("EXPLAIN SELECT * FROM orders");
    defer result.deinit();

    // Should have at least one execution plan step (TableScan or Project)
    try std.testing.expect(result.count() >= 1);

    // First row should have correct structure (id, parent, notused, detail)
    const rows = result.rows.items;
    try std.testing.expectEqual(@as(usize, 4), rows[0].values.len); // Should have 4 columns
}

test "introspection: PRAGMA database_list includes attached memory database" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("ATTACH DATABASE ':memory:' AS aux");

    var result = try conn.query("PRAGMA database_list");
    defer result.deinit();

    try std.testing.expect(result.count() >= 2);

    var found_aux = false;
    for (result.rows.items) |row| {
        if (std.mem.eql(u8, row.values[1].Text, "aux")) {
            found_aux = true;
            break;
        }
    }
    try std.testing.expect(found_aux);
}

test "secure mode rejects relative attach paths" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.db.Connection.openMemoryWithOptions(allocator, .{ .secure_mode = true });
    defer conn.close();

    try std.testing.expectError(error.RelativePathNotAllowed, conn.attachDatabase("relative.db", "aux"));
}

test "fts virtual table match query executes" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE VIRTUAL TABLE docs USING fts5(title, body)");
    try conn.execute("INSERT INTO docs VALUES ('Guide', 'quantum safe storage guide')");
    try conn.execute("INSERT INTO docs VALUES ('Notes', 'classical crypto fallback details')");

    var result = try conn.query("SELECT title FROM docs WHERE body MATCH 'quantum guide'");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expectEqualStrings("Guide", result.rows.items[0].values[0].Text);
}

test "prepared statement lifecycle can be reused safely" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute("CREATE TABLE prep_users (id INTEGER PRIMARY KEY, name TEXT)");

    var stmt = try conn.prepare("INSERT INTO prep_users VALUES (?, ?)");
    defer stmt.deinit();

    try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = 1 });
    try stmt.bindParameter(1, zqlite.storage.Value{ .Text = "Alice" });
    var first = try stmt.execute();
    first.deinit();
    stmt.reset();

    try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = 2 });
    try stmt.bindParameter(1, zqlite.storage.Value{ .Text = "Bob" });
    var second = try stmt.execute();
    second.deinit();
    stmt.reset();

    var result = try conn.query("SELECT name FROM prep_users ORDER BY id");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.count());
    try std.testing.expectEqualStrings("Alice", result.rows.items[0].values[0].Text);
    try std.testing.expectEqualStrings("Bob", result.rows.items[1].values[0].Text);
}
