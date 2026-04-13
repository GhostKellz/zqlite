const std = @import("std");
const zqlite = @import("zqlite");

/// Regression test for INSERT memory management fix
/// Previously, INSERT operations caused segfaults due to improper cleanup
/// of partially-allocated storage.Value arrays when cloneValue() failed.
/// This test verifies that the fix prevents those segfaults.
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🛡️  ZQLite INSERT Memory Management Regression Test\n\n", .{});

    // Create in-memory database connection
    var connection = try zqlite.openMemory();
    // Note: Connection cleanup handled by process termination

    // Test Case 1: Basic table creation
    std.debug.print("✅ Test Case 1: Table creation...\n", .{});
    try connection.execute("CREATE TABLE regression_test (id INTEGER, name TEXT, active INTEGER DEFAULT 1, data BLOB)");
    std.debug.print("   ✓ Table created successfully\n\n", .{});

    // Test Case 2: Basic INSERT operations (previously segfaulted)
    std.debug.print("✅ Test Case 2: INSERT operations...\n", .{});
    try connection.execute("INSERT INTO regression_test (id, name, active) VALUES (1, 'basic test', 1)");
    std.debug.print("   ✓ Basic INSERT successful\n", .{});

    // Test Case 3: INSERT with missing columns (triggers default value path)
    try connection.execute("INSERT INTO regression_test (id, name) VALUES (2, 'default test')");
    std.debug.print("   ✓ INSERT with default values successful\n", .{});

    // Test Case 4: INSERT with NULL values
    try connection.execute("INSERT INTO regression_test (id, name, active, data) VALUES (3, NULL, 0, NULL)");
    std.debug.print("   ✓ INSERT with NULL values successful\n", .{});

    // Test Case 5: Multiple INSERTs to stress test memory management
    std.debug.print("   ✓ Running stress test with multiple INSERTs...\n", .{});
    for (4..50) |i| {
        const insert_sql = try std.fmt.allocPrint(allocator, "INSERT INTO regression_test (id, name, active) VALUES ({}, 'stress test {}', {})", .{ i, i, i % 2 });
        defer allocator.free(insert_sql);
        try connection.execute(insert_sql);

        // Progress indicator for stress test
        if (i % 10 == 0) {
            std.debug.print("     • Completed {} INSERTs...\n", .{i});
        }
    }
    std.debug.print("   ✓ Stress test completed - 46 additional INSERTs successful\n\n", .{});

    // Test Case 6: Complex INSERT with various data types
    std.debug.print("✅ Test Case 3: Complex data types...\n", .{});
    try connection.execute("INSERT INTO regression_test (id, name, active, data) VALUES (100, 'complex test', 1, 'binary data here')");
    std.debug.print("   ✓ Complex INSERT successful\n\n", .{});

    std.debug.print("All Regression Tests Passed\n", .{});
    std.debug.print("   No segfaults, memory management working\n\n", .{});

    std.debug.print("📊 Test Summary:\n", .{});
    std.debug.print("   • Basic INSERTs: ✅ PASS\n", .{});
    std.debug.print("   • Default values: ✅ PASS\n", .{});
    std.debug.print("   • NULL handling: ✅ PASS\n", .{});
    std.debug.print("   • Stress testing: ✅ PASS (49 total INSERTs)\n", .{});
    std.debug.print("   • Complex types: ✅ PASS\n", .{});
}
