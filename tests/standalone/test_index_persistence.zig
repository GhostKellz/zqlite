const std = @import("std");
const zqlite = @import("zqlite");
const temp_dir = @import("temp_dir.zig");

fn textIndexKey(text: []const u8) u64 {
    var hash: u64 = 0;
    for (text) |byte| {
        hash = hash *% 31 +% byte;
    }
    return hash;
}

/// Test index persistence across connections
var test_dir: temp_dir.TempDir = undefined;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    test_dir = try .init(init.io, allocator, "zqlite-index");
    defer test_dir.deinit();

    std.log.info("=== Index Persistence Tests ===", .{});

    try testBasicIndexPersistence(allocator);
    try testUniqueIndexPersistence(allocator);
    try testMultiColumnIndexPersistence(allocator);

    std.log.info("=== ALL INDEX PERSISTENCE TESTS PASSED ===", .{});
}

fn testBasicIndexPersistence(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Basic index persistence", .{});
    const path = try test_dir.dbPath("basic.db");
    defer allocator.free(path);

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

        const index = conn.storage_engine.getIndex("idx_users_email") orelse return error.IndexMissingAfterReopen;
        const row_id = try index.search(textIndexKey("bob@test.com")) orelse return error.IndexLookupFailedAfterReopen;
        const row = try conn.storage_engine.getTable("users").?.getRow(@intCast(row_id)) orelse return error.IndexRowMissingAfterReopen;
        defer {
            for (row.values) |value| {
                value.deinit(allocator);
            }
            allocator.free(row.values);
        }

        std.debug.assert(row.values.len == 3);
        std.debug.assert(std.mem.eql(u8, row.values[2].Text, "bob@test.com"));

        // Query using indexed column
        var result = try conn.query("SELECT * FROM users WHERE email = 'bob@test.com'");
        defer result.deinit();

        std.debug.assert(result.rows.items.len == 1);
        std.log.info("[PASS] Basic index persistence", .{});
    }
}

fn testUniqueIndexPersistence(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Unique index persistence", .{});
    const path = try test_dir.dbPath("unique.db");
    defer allocator.free(path);

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

    // Third connection: verify post-reopen inserts refresh the index contents too
    {
        var conn = try zqlite.open(allocator, path);
        defer conn.close();

        try conn.execute("INSERT INTO products (id, sku) VALUES (4, 'SKU-004')");

        const index = conn.storage_engine.getIndex("idx_products_sku") orelse return error.UniqueIndexMissingAfterInsert;
        const row_id = try index.search(textIndexKey("SKU-004")) orelse return error.UniqueIndexNotUpdatedAfterInsert;
        const row = try conn.storage_engine.getTable("products").?.getRow(@intCast(row_id)) orelse return error.UniqueIndexRowMissingAfterInsert;
        defer {
            for (row.values) |value| {
                value.deinit(allocator);
            }
            allocator.free(row.values);
        }

        std.debug.assert(std.mem.eql(u8, row.values[1].Text, "SKU-004"));
    }
}

fn testMultiColumnIndexPersistence(allocator: std.mem.Allocator) !void {
    std.log.info("[TEST] Multi-column index persistence", .{});
    const path = try test_dir.dbPath("multi.db");
    defer allocator.free(path);

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
