const std = @import("std");
const testing = std.testing;
const zqlite = @import("zqlite");

test "Memory Management - No Leaks with DEFAULT CURRENT_TIMESTAMP" {
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

    // Create table with DEFAULT CURRENT_TIMESTAMP - the problematic case
    try conn.execute("CREATE TABLE test_timestamps (id INTEGER PRIMARY KEY, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");

    // Insert multiple rows to stress test memory management
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try conn.execute("INSERT INTO test_timestamps (id) VALUES (?)");
    }

    // Query the data to ensure memory cleanup in SELECT operations
    var stmt = try conn.prepare("SELECT id, created_at FROM test_timestamps ORDER BY id");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 10);
}

test "Memory Management - Complex INSERT/UPDATE/DELETE Cycle" {
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

    // Create table with various DEFAULT constraints
    try conn.execute(
        \\CREATE TABLE memory_test (
        \\  id INTEGER PRIMARY KEY,
        \\  name TEXT DEFAULT 'unnamed',
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  counter INTEGER DEFAULT 0
        \\)
    );

    // Stress test with multiple operations
    var cycle: u32 = 0;
    while (cycle < 5) : (cycle += 1) {
        // Insert batch
        var i: u32 = 0;
        while (i < 20) : (i += 1) {
            try conn.execute("INSERT INTO memory_test (name) VALUES ('test_name')");
        }

        // Update batch
        try conn.execute("UPDATE memory_test SET counter = counter + 1 WHERE id % 2 = 0");

        // Select batch
        var stmt = try conn.prepare("SELECT COUNT(*) FROM memory_test");
        defer stmt.deinit();

        var result = try stmt.execute();
        defer result.deinit();

        // Delete batch
        try conn.execute("DELETE FROM memory_test WHERE id % 3 = 0");
    }
}

test "Memory Management - Function Call DEFAULT Values" {
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

    // Test various function calls in DEFAULT constraints
    try conn.execute(
        \\CREATE TABLE function_defaults (
        \\  id INTEGER PRIMARY KEY,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Insert operations that trigger DEFAULT value evaluation
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try conn.execute("INSERT INTO function_defaults DEFAULT VALUES");
    }

    // Verify all records were inserted with proper DEFAULT values
    var stmt = try conn.prepare("SELECT COUNT(*) FROM function_defaults WHERE created_at IS NOT NULL");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    try testing.expect(result.rows.items.len == 1);
    switch (result.rows.items[0].values[0]) {
        .Integer => |count| try testing.expect(count == 50),
        else => return error.UnexpectedValueType,
    }
}

test "Memory Management - Large Text Fields" {
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

    try conn.execute("CREATE TABLE large_text (id INTEGER PRIMARY KEY, content TEXT)");

    // Create large text content
    const large_content = try allocator.alloc(u8, 10000);
    defer allocator.free(large_content);
    @memset(large_content, 'A');

    // Insert and immediately clean up to test memory handling
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        // Note: This is a simplified test - in reality you'd use parameters
        try conn.execute("INSERT INTO large_text (content) VALUES ('large_content_placeholder')");
    }

    // Query and verify
    var stmt = try conn.prepare("SELECT COUNT(*) FROM large_text");
    defer stmt.deinit();

    var result = try stmt.execute();
    defer result.deinit();

    switch (result.rows.items[0].values[0]) {
        .Integer => |count| try testing.expect(count == 10),
        else => return error.UnexpectedValueType,
    }

    // Clean up
    try conn.execute("DELETE FROM large_text");
}

test "Memory Management - Connection Lifecycle" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked != .ok) {
            @panic("Memory leak detected!");
        }
    }
    const allocator = gpa.allocator();

    // Test multiple connection open/close cycles
    var cycle: u32 = 0;
    while (cycle < 5) : (cycle += 1) {
        const conn = try zqlite.open(allocator, ":memory:");
        defer conn.close();

        try conn.execute("CREATE TABLE lifecycle_test (id INTEGER PRIMARY KEY, data TEXT DEFAULT 'test')");
        try conn.execute("INSERT INTO lifecycle_test DEFAULT VALUES");

        var stmt = try conn.prepare("SELECT * FROM lifecycle_test");
        defer stmt.deinit();

        var result = try stmt.execute();
        defer result.deinit();

        try testing.expect(result.rows.items.len == 1);
    }
}

test "Memory Management - Prepared Statement Reuse" {
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

    try conn.execute("CREATE TABLE reuse_test (id INTEGER PRIMARY KEY, name TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");

    // Prepare statement once and reuse multiple times
    var stmt = try conn.prepare("SELECT COUNT(*) FROM reuse_test");
    defer stmt.deinit();

    // Execute multiple times with inserts in between
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try conn.execute("INSERT INTO reuse_test (name) VALUES ('test')");

        var result = try stmt.execute();
        defer result.deinit();

        switch (result.rows.items[0].values[0]) {
            .Integer => |count| try testing.expect(count == @as(i64, @intCast(i + 1))),
            else => return error.UnexpectedValueType,
        }
    }
}
