const std = @import("std");
const zqlite = @import("zqlite");

/// Comprehensive memory leak detection test
/// Uses GeneralPurposeAllocator to detect leaks, double-frees, and use-after-free
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("❌ MEMORY LEAK DETECTED!\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("🧪 Running comprehensive memory leak detection tests...\n\n", .{});

    // Test 1: CREATE TABLE with DEFAULT constraints
    try testCreateTableWithDefaults(allocator);

    // Test 2: INSERT with DEFAULT values
    try testInsertWithDefaults(allocator);

    // Test 3: UPDATE operations
    try testUpdateOperations(allocator);

    // Test 4: DELETE operations
    try testDeleteOperations(allocator);

    // Test 5: Multiple tables with complex schemas
    try testMultipleTablesWithComplexSchemas(allocator);

    // Test 6: Transaction operations
    try testTransactionOperations(allocator);

    // Test 7: Large dataset operations
    try testLargeDatasetOperations(allocator);

    std.debug.print("\n✅ All memory leak detection tests passed!\n", .{});
}

fn testCreateTableWithDefaults(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 1: CREATE TABLE with DEFAULT constraints\n", .{});

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Test with CURRENT_TIMESTAMP (function call)
    try conn.execute(
        \\CREATE TABLE test_defaults (
        \\  id INTEGER,
        \\  name TEXT DEFAULT 'Anonymous',
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Verify table was created
    const tables = try conn.getTableNames();
    defer {
        for (tables) |table_name| {
            allocator.free(table_name);
        }
        allocator.free(tables);
    }

    std.debug.print("  ✓ Created table with DEFAULT constraints\n", .{});
}

fn testInsertWithDefaults(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 2: INSERT with DEFAULT values\n", .{});

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE users (
        \\  id INTEGER,
        \\  username TEXT DEFAULT 'guest',
        \\  registered DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Insert without specifying default columns
    try conn.execute("INSERT INTO users (id) VALUES (1)");
    try conn.execute("INSERT INTO users (id, username) VALUES (2, 'alice')");

    var result = try conn.query("SELECT * FROM users");
    defer result.deinit();

    std.debug.print("  ✓ Inserted rows with DEFAULT values\n", .{});
}

fn testUpdateOperations(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 3: UPDATE operations\n", .{});

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE products (
        \\  id INTEGER,
        \\  name TEXT,
        \\  price REAL DEFAULT 0.0
        \\)
    );

    try conn.execute("INSERT INTO products (id, name) VALUES (1, 'Widget')");
    try conn.execute("UPDATE products SET price = 9.99 WHERE id = 1");

    var result = try conn.query("SELECT * FROM products");
    defer result.deinit();

    std.debug.print("  ✓ UPDATE operations completed\n", .{});
}

fn testDeleteOperations(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 4: DELETE operations\n", .{});

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE logs (
        \\  id INTEGER,
        \\  message TEXT,
        \\  timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    try conn.execute("INSERT INTO logs (id, message) VALUES (1, 'Log entry 1')");
    try conn.execute("INSERT INTO logs (id, message) VALUES (2, 'Log entry 2')");
    try conn.execute("DELETE FROM logs WHERE id = 1");

    var result = try conn.query("SELECT * FROM logs");
    defer result.deinit();

    std.debug.print("  ✓ DELETE operations completed\n", .{});
}

fn testMultipleTablesWithComplexSchemas(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 5: Multiple tables with complex schemas\n", .{});

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    // Create multiple tables with various DEFAULT constraints
    try conn.execute(
        \\CREATE TABLE table1 (
        \\  id INTEGER,
        \\  col1 TEXT DEFAULT 'default1',
        \\  col2 INTEGER DEFAULT 42,
        \\  col3 DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    try conn.execute(
        \\CREATE TABLE table2 (
        \\  id INTEGER,
        \\  name TEXT,
        \\  value REAL DEFAULT 3.14,
        \\  active INTEGER DEFAULT 1
        \\)
    );

    try conn.execute(
        \\CREATE TABLE table3 (
        \\  id INTEGER,
        \\  data BLOB,
        \\  created DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Insert data into each table
    try conn.execute("INSERT INTO table1 (id) VALUES (1)");
    try conn.execute("INSERT INTO table2 (id, name) VALUES (1, 'test')");
    try conn.execute("INSERT INTO table3 (id) VALUES (1)");

    std.debug.print("  ✓ Multiple complex tables created and populated\n", .{});
}

fn testTransactionOperations(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 6: Transaction operations\n", .{});

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE accounts (
        \\  id INTEGER,
        \\  balance REAL DEFAULT 0.0,
        \\  updated DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    try conn.execute("BEGIN TRANSACTION");
    try conn.execute("INSERT INTO accounts (id, balance) VALUES (1, 100.0)");
    try conn.execute("INSERT INTO accounts (id, balance) VALUES (2, 200.0)");
    try conn.execute("COMMIT");

    var result = try conn.query("SELECT * FROM accounts");
    defer result.deinit();

    std.debug.print("  ✓ Transaction operations completed\n", .{});
}

fn testLargeDatasetOperations(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 7: Large dataset operations\n", .{});

    var conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE large_table (
        \\  id INTEGER,
        \\  data TEXT DEFAULT 'default_data',
        \\  timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Insert many rows to stress-test memory management
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try conn.execute("INSERT INTO large_table (id) VALUES (1)");
    }

    var result = try conn.query("SELECT * FROM large_table");
    defer result.deinit();

    std.debug.print("  ✓ Large dataset operations completed (100 rows)\n", .{});
}
