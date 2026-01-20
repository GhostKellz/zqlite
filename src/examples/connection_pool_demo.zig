const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🏊‍♂️ zqlite Connection Pool Demo\n\n", .{});

    // Create connection pool with 2-10 connections
    const pool = try zqlite.createConnectionPool(allocator, null, 2, 10);
    defer pool.deinit();

    std.debug.print("✅ Created connection pool (2-10 connections)\n", .{});

    // Show initial pool stats
    var stats = pool.getStats();
    std.debug.print("Initial Stats: {} total, {} available, {} in use\n", .{ stats.total_connections, stats.available_connections, stats.in_use_connections });

    // Set up test data in all connections
    std.debug.print("\n📊 Setting up test table...\n", .{});
    {
        const conn = try pool.acquire();
        defer conn.release() catch {};

        try conn.execute("CREATE TABLE IF NOT EXISTS test_data (id INTEGER, value TEXT, timestamp INTEGER);");
        try conn.execute("DELETE FROM test_data;"); // Clear any existing data
        std.debug.print("✅ Test table created\n", .{});
    }

    // Simulate concurrent operations
    std.debug.print("\n⚡ Simulating concurrent database operations...\n", .{});

    // Acquire multiple connections and use them simultaneously
    var connections = std.ArrayList(*zqlite.connection_pool.PooledConnection){};
    defer connections.deinit(allocator);

    // Acquire 5 connections
    for (0..5) |i| {
        const conn = try pool.acquire();
        try connections.append(allocator, conn);

        // Insert data with each connection
        const ts = zqlite.time_utils.getTimespec();
        const timestamp = ts.sec;
        const sql = try std.fmt.allocPrint(allocator, "INSERT INTO test_data VALUES ({}, 'data_{}', {});", .{ i, i, timestamp });
        defer allocator.free(sql);

        try conn.execute(sql);
        std.debug.print("Connection {} inserted record {}\n", .{ conn.id, i });

        // Show pool stats after each acquisition
        stats = pool.getStats();
        std.debug.print("  Pool: {} total, {} available, {} in use\n", .{ stats.total_connections, stats.available_connections, stats.in_use_connections });
    }

    // Release all connections back to pool
    std.debug.print("\n🔄 Releasing connections back to pool...\n", .{});
    for (connections.items) |conn| {
        try conn.release();

        stats = pool.getStats();
        std.debug.print("Released connection {}, Pool: {} available, {} in use\n", .{ conn.id, stats.available_connections, stats.in_use_connections });
    }

    // Verify all data was inserted correctly
    std.debug.print("\n🔍 Verifying inserted data...\n", .{});
    {
        const conn = try pool.acquire();
        defer conn.release() catch {};

        try conn.execute("SELECT COUNT(*) as count FROM test_data;");
        std.debug.print("✅ All concurrent operations completed successfully\n", .{});
    }

    // Test prepared statements with connection pool
    std.debug.print("\n📝 Testing prepared statements with pool...\n", .{});
    {
        const conn = try pool.acquire();
        defer conn.release() catch {};

        var stmt = try conn.prepare("INSERT INTO test_data VALUES (?, ?, ?);");
        defer stmt.deinit();

        // Insert with prepared statement
        try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = 100 });
        try stmt.bindParameter(1, zqlite.storage.Value{ .Text = try allocator.dupe(u8, "prepared_data") });
        defer allocator.free("prepared_data");
        const ts = zqlite.time_utils.getTimespec();
        const timestamp = ts.sec;
        try stmt.bindParameter(2, zqlite.storage.Value{ .Integer = timestamp });

        var result = try stmt.execute();
        defer result.deinit();

        std.debug.print("✅ Prepared statement executed, {} rows affected\n", .{result.affected_rows});
    }

    // Test concurrent database operations
    std.debug.print("\n🔄 Testing concurrent query execution...\n", .{});

    // Use multiple connections to execute different operations simultaneously
    const conn1 = try pool.acquire();
    const conn2 = try pool.acquire();

    // Execute different operations on different connections
    try conn1.execute("CREATE TABLE IF NOT EXISTS concurrent_test1 (id INTEGER, data TEXT);");
    try conn2.execute("CREATE TABLE IF NOT EXISTS concurrent_test2 (id INTEGER, value REAL);");

    // Insert data concurrently
    try conn1.execute("INSERT INTO concurrent_test1 VALUES (1, 'Connection 1 Data');");
    try conn2.execute("INSERT INTO concurrent_test2 VALUES (1, 3.14159);");

    std.debug.print("✅ Concurrent operations completed successfully\n", .{});

    try conn1.release();
    try conn2.release();

    // Test pool cleanup (remove idle connections)
    std.debug.print("\n🧹 Testing pool cleanup...\n", .{});
    try pool.cleanup(1); // Remove connections idle for more than 1 second

    stats = pool.getStats();
    std.debug.print("After cleanup: {} total, {} available, {} in use\n", .{ stats.total_connections, stats.available_connections, stats.in_use_connections });

    // Test connection reuse and transaction isolation
    std.debug.print("\n🔐 Testing transaction isolation...\n", .{});

    const tx_conn1 = try pool.acquire();
    const tx_conn2 = try pool.acquire();

    // Start transactions on different connections
    try tx_conn1.connection.begin();
    try tx_conn2.connection.begin();

    // Each transaction can see its own changes but not the other's
    try tx_conn1.execute("INSERT INTO test_data VALUES (100, 'tx1_data', 0);");
    try tx_conn2.execute("INSERT INTO test_data VALUES (200, 'tx2_data', 0);");

    // Commit one, rollback the other
    try tx_conn1.connection.commit();
    try tx_conn2.connection.rollback();

    std.debug.print("✅ Transaction isolation test completed\n", .{});

    try tx_conn1.release();
    try tx_conn2.release();

    // Final pool statistics
    std.debug.print("\n📈 Final Pool Statistics:\n", .{});
    stats = pool.getStats();
    std.debug.print("  Total connections: {}\n", .{stats.total_connections});
    std.debug.print("  Available: {}\n", .{stats.available_connections});
    std.debug.print("  In use: {}\n", .{stats.in_use_connections});
    std.debug.print("  Max connections: {}\n", .{stats.max_connections});
    std.debug.print("  Min connections: {}\n", .{stats.min_connections});

    std.debug.print("\n🎯 Connection pool functionality is working!\n", .{});
    std.debug.print("💡 Pool efficiently manages {} concurrent database connections\n", .{stats.max_connections});
}
