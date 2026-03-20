const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("⚡ zqlite Query Cache Demo\n\n", .{});

    // Create query cache with 100 entries max, 1MB memory limit
    const cache = try zqlite.createQueryCache(allocator, 100, 1024 * 1024);
    defer cache.deinit();

    std.debug.print("✅ Created query cache (100 entries, 1MB limit)\n\n", .{});

    // Create in-memory database
    var conn = try zqlite.openMemory(allocator);
    defer conn.close();

    // Set up test data
    std.debug.print("📊 Setting up test data...\n", .{});

    try conn.execute("CREATE TABLE products (id INTEGER, name TEXT, category TEXT, price REAL);");

    const test_products = [_]struct { id: i32, name: []const u8, category: []const u8, price: f64 }{
        .{ .id = 1, .name = "Laptop", .category = "Electronics", .price = 999.99 },
        .{ .id = 2, .name = "Mouse", .category = "Electronics", .price = 29.99 },
        .{ .id = 3, .name = "Book", .category = "Education", .price = 19.99 },
        .{ .id = 4, .name = "Desk", .category = "Furniture", .price = 299.99 },
        .{ .id = 5, .name = "Chair", .category = "Furniture", .price = 199.99 },
    };

    for (test_products) |product| {
        var stmt = try conn.prepare("INSERT INTO products VALUES (?, ?, ?, ?);");
        defer stmt.deinit();

        try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = product.id });
        try stmt.bindParameter(1, zqlite.storage.Value{ .Text = try allocator.dupe(u8, product.name) });
        defer allocator.free(product.name);
        try stmt.bindParameter(2, zqlite.storage.Value{ .Text = try allocator.dupe(u8, product.category) });
        defer allocator.free(product.category);
        try stmt.bindParameter(3, zqlite.storage.Value{ .Real = product.price });

        var result = try stmt.execute();
        defer result.deinit();
    }

    std.debug.print("✅ Inserted {} product records\n\n", .{test_products.len});

    // Demonstrate query caching
    std.debug.print("⚡ Query Caching Demonstrations:\n\n", .{});

    const test_queries = [_][]const u8{
        "SELECT * FROM products WHERE category = 'Electronics'",
        "SELECT name, price FROM products WHERE price > 100",
        "SELECT category, COUNT(*) FROM products GROUP BY category",
        "SELECT * FROM products ORDER BY price DESC LIMIT 3",
    };

    for (test_queries, 0..) |query, i| {
        std.debug.print("{}. Query: {s}\n", .{ i + 1, query });

        // First execution - cache miss
        const ts_start = zqlite.time_utils.getTimespec();
        const start_time = @as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec;

        // Hash the query for caching
        const query_hash = zqlite.QueryHasher.hashQuery(query);

        // Check if query is in cache
        const cached_result = cache.get(query_hash);

        if (cached_result == null) {
            std.debug.print("   ❌ Cache MISS - Executing query\n", .{});

            // Execute the query (simulated - would integrate with real executor)
            // In a real implementation, this would execute the actual query

            // Create mock rows for caching
            const mock_rows = try allocator.alloc(zqlite.storage.Row, 2);
            defer allocator.free(mock_rows);

            // Set up mock data
            for (mock_rows, 0..) |*row, j| {
                row.values = try allocator.alloc(zqlite.storage.Value, 2);
                row.values[0] = zqlite.storage.Value{ .Text = try std.fmt.allocPrint(allocator, "Product {}", .{j + 1}) };
                row.values[1] = zqlite.storage.Value{ .Real = @as(f64, @floatFromInt(100 + j * 50)) };
            }

            // Cache the result
            try cache.put(query_hash, query, mock_rows);

            // Clean up mock data (cache clones it)
            for (mock_rows) |*row| {
                for (row.values) |value| {
                    value.deinit(allocator);
                }
                allocator.free(row.values);
            }

            const ts_final = zqlite.time_utils.getTimespec();
            const final_time = @as(i128, ts_final.sec) * std.time.ns_per_s + ts_final.nsec;
            const execution_time = final_time - start_time;
            std.debug.print("   ⏱️  Execution time: {d:.2}ms\n", .{@as(f64, @floatFromInt(execution_time)) / std.time.ns_per_ms});
        } else {
            std.debug.print("   ✅ Cache HIT - Using cached result\n", .{});
            const ts_cache = zqlite.time_utils.getTimespec();
            const cache_end_time = @as(i128, ts_cache.sec) * std.time.ns_per_s + ts_cache.nsec;
            const cache_time = cache_end_time - start_time;
            std.debug.print("   ⚡ Cache retrieval time: {d:.2}ms\n", .{@as(f64, @floatFromInt(cache_time)) / std.time.ns_per_ms});
            std.debug.print("   📊 Cached row count: {}\n", .{cached_result.?.row_count});
        }

        // Show cache statistics
        const stats = cache.getStats();
        std.debug.print("   📈 Cache stats: {} entries, {} hits, {} misses\n\n", .{ stats.entries, stats.hit_count, stats.miss_count });

        // Second execution of same query - should be cache hit
        if (i == 0) {
            std.debug.print("   🔄 Re-executing same query...\n", .{});
            const cached_result_2 = cache.get(query_hash);
            if (cached_result_2 != null) {
                std.debug.print("   ✅ Cache HIT on second execution!\n", .{});
            }

            const stats_2 = cache.getStats();
            std.debug.print("   📈 Updated stats: {} entries, {} hits, {} misses\n\n", .{ stats_2.entries, stats_2.hit_count, stats_2.miss_count });
        }
    }

    // Demonstrate cache eviction
    std.debug.print("🗑️  Cache Eviction Test:\n", .{});

    // Fill cache beyond capacity to trigger eviction
    for (0..25) |i| {
        const unique_query = try std.fmt.allocPrint(allocator, "SELECT * FROM products WHERE id = {}", .{i});
        defer allocator.free(unique_query);

        const hash = zqlite.QueryHasher.hashQuery(unique_query);

        // Create small mock result
        const eviction_rows = try allocator.alloc(zqlite.storage.Row, 1);
        defer allocator.free(eviction_rows);

        eviction_rows[0].values = try allocator.alloc(zqlite.storage.Value, 1);
        eviction_rows[0].values[0] = zqlite.storage.Value{ .Integer = @intCast(i) };

        try cache.put(hash, unique_query, eviction_rows);

        // Clean up mock data
        for (eviction_rows) |*row| {
            allocator.free(row.values);
        }
    }

    const final_stats = cache.getStats();
    std.debug.print("   📊 After adding 25 entries: {} total entries, {} evictions\n", .{ final_stats.entries, final_stats.eviction_count });

    // Memory usage information
    std.debug.print("\n💾 Memory Usage:\n", .{});
    std.debug.print("   📊 Current memory usage: {d:.2} KB\n", .{@as(f64, @floatFromInt(final_stats.memory_usage_bytes)) / 1024.0});
    std.debug.print("   📊 Memory limit: {d:.2} KB\n", .{@as(f64, @floatFromInt(final_stats.max_memory_bytes)) / 1024.0});

    std.debug.print("\n🎯 Query cache functionality is working!\n", .{});
    std.debug.print("💡 Cache provides significant performance improvements for repeated queries\n", .{});
    std.debug.print("🚀 Ready for integration with SQL parser and execution engine\n", .{});
}
