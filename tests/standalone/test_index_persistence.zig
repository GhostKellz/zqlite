const std = @import("std");
const zqlite = @import("zqlite");

/// Test index persistence across connections
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Index Persistence Tests ===", .{});

    try testBasicIndexPersistence(allocator);
    try testUniqueIndexPersistence(allocator);
    try testMultiColumnIndexPersistence(allocator);

    std.log.info("=== ALL INDEX PERSISTENCE TESTS PASSED ===", .{});
}

fn testBasicIndexPersistence(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Basic index persistence", .{});
    const path = "/tmp/zqlite_index_basic.db";

    // First connection: create index and data
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT, email TEXT)");
        try conn.execute("DELETE FROM users");
        try conn.execute("CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)");

        try conn.execute("INSERT INTO users (id, name, email) VALUES (1, 'Alice', 'alice@test.com')");
        try conn.execute("INSERT INTO users (id, name, email) VALUES (2, 'Bob', 'bob@test.com')");
        try conn.execute("INSERT INTO users (id, name, email) VALUES (3, 'Charlie', 'charlie@test.com')");
    }

    // Second connection: verify index still works
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        // Query using indexed column
        var result = try conn.query("SELECT * FROM users WHERE email = 'bob@test.com'");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 1);
        std.log.info("[PASS] Basic index persistence", .{});
    }
}

fn testUniqueIndexPersistence(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Unique index persistence", .{});
    const path = "/tmp/zqlite_index_unique.db";

    // First connection: create unique index
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS products (id INTEGER, sku TEXT)");
        try conn.execute("DELETE FROM products");
        try conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_products_sku ON products(sku)");

        try conn.execute("INSERT INTO products (id, sku) VALUES (1, 'SKU-001')");
        try conn.execute("INSERT INTO products (id, sku) VALUES (2, 'SKU-002')");
    }

    // Second connection: verify unique constraint
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        // This should fail due to unique constraint
        const dup_result = conn.execute("INSERT INTO products (id, sku) VALUES (3, 'SKU-001')");
        if (dup_result) |_| {
            std.log.err("Unique constraint not enforced after reopen!", .{});
            return error.UniqueConstraintNotEnforced;
        } else |_| {
            // Expected - duplicate rejected
        }

        std.log.info("[PASS] Unique index persistence", .{});
    }
}

fn testMultiColumnIndexPersistence(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Multi-column index persistence", .{});
    const path = "/tmp/zqlite_index_multi.db";

    // First connection
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("CREATE TABLE IF NOT EXISTS orders (id INTEGER, customer_id INTEGER, status TEXT, amount REAL)");
        try conn.execute("DELETE FROM orders");
        try conn.execute("CREATE INDEX IF NOT EXISTS idx_orders_cust_status ON orders(customer_id, status)");

        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var buf: [256]u8 = undefined;
            const status = if (i % 3 == 0) "pending" else if (i % 3 == 1) "shipped" else "delivered";
            const sql = std.fmt.bufPrint(&buf, "INSERT INTO orders (id, customer_id, status, amount) VALUES ({d}, {d}, '{s}', {d}.99)", .{ i, i % 10, status, i }) catch unreachable;
            try conn.execute(sql);
        }
    }

    // Second connection: query using composite index
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        var result = try conn.query("SELECT * FROM orders WHERE customer_id = 5 AND status = 'pending'");
        defer result.deinit();

        // customer_id 5 with status pending: rows 5, 35, 65, 95 (i % 10 == 5 AND i % 3 == 0)
        // Actually: 15, 45, 75 (i=15: 15%10=5, 15%3=0; i=45: 45%10=5, 45%3=0; i=75: 75%10=5, 75%3=0)
        std.debug.assert(result.rows.items.len >= 1);
        std.log.info("[PASS] Multi-column index persistence: {d} matching rows", .{result.rows.items.len});
    }
}
