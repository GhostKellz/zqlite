const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🎯 zqlite PostgreSQL Array Operations Demo\n\n", .{});

    // Create in-memory database
    var conn = try zqlite.openMemory(allocator);
    defer conn.close();

    // Create table with array columns
    try conn.execute("CREATE TABLE products (id INTEGER, name TEXT, tags ARRAY, prices ARRAY, categories ARRAY);");

    std.debug.print("📊 Setting up array test data...\n", .{});

    // Test array creation and operations
    std.debug.print("\n🔧 Array Creation and Basic Operations:\n", .{});

    // Create integer array
    const int_values = [_]zqlite.storage.Value{
        zqlite.storage.Value{ .Integer = 10 },
        zqlite.storage.Value{ .Integer = 20 },
        zqlite.storage.Value{ .Integer = 30 },
        zqlite.storage.Value{ .Integer = 40 },
    };

    const int_array = try zqlite.storage.ArrayValue.init(allocator, zqlite.storage.DataType.Integer, &int_values);
    defer int_array.deinit(allocator);

    std.debug.print("1. Integer Array: len = {}\n", .{int_array.len()});

    // Test array indexing (1-based like PostgreSQL)
    if (int_array.get(1)) |first| {
        switch (first) {
            .Integer => |val| std.debug.print("   First element (index 1): {}\n", .{val}),
            else => {},
        }
    }

    if (int_array.get(4)) |last| {
        switch (last) {
            .Integer => |val| std.debug.print("   Last element (index 4): {}\n", .{val}),
            else => {},
        }
    }

    // Test array to string conversion (PostgreSQL format)
    const int_array_str = try int_array.toString(allocator);
    defer allocator.free(int_array_str);
    std.debug.print("   PostgreSQL format: {s}\n", .{int_array_str});

    // Create text array
    const text_values = [_]zqlite.storage.Value{
        zqlite.storage.Value{ .Text = try allocator.dupe(u8, "electronics") },
        zqlite.storage.Value{ .Text = try allocator.dupe(u8, "gadgets") },
        zqlite.storage.Value{ .Text = try allocator.dupe(u8, "mobile") },
    };
    defer {
        for (text_values) |val| {
            switch (val) {
                .Text => |text| allocator.free(text),
                else => {},
            }
        }
    }

    const text_array = try zqlite.storage.ArrayValue.init(allocator, zqlite.storage.DataType.Text, &text_values);
    defer text_array.deinit(allocator);

    std.debug.print("\n2. Text Array: len = {}\n", .{text_array.len()});
    const text_array_str = try text_array.toString(allocator);
    defer allocator.free(text_array_str);
    std.debug.print("   PostgreSQL format: {s}\n", .{text_array_str});

    // Test array containment operations
    std.debug.print("\n🔍 Array Containment Operations:\n", .{});

    const search_value = zqlite.storage.Value{ .Integer = 20 };
    const contains_20 = int_array.contains(search_value);
    const contains_99 = int_array.contains(zqlite.storage.Value{ .Integer = 99 });

    std.debug.print("1. Array contains 20: {}\n", .{contains_20});
    std.debug.print("2. Array contains 99: {}\n", .{contains_99});

    // Test text array containment
    const search_text = zqlite.storage.Value{ .Text = try allocator.dupe(u8, "mobile") };
    defer allocator.free(search_text.Text);
    const contains_mobile = text_array.contains(search_text);
    std.debug.print("3. Text array contains 'mobile': {}\n", .{contains_mobile});

    // Test array overlap operations
    std.debug.print("\n🔀 Array Overlap Operations:\n", .{});

    const overlap_values = [_]zqlite.storage.Value{
        zqlite.storage.Value{ .Integer = 20 },
        zqlite.storage.Value{ .Integer = 50 },
        zqlite.storage.Value{ .Integer = 60 },
    };

    const overlap_array = try zqlite.storage.ArrayValue.init(allocator, zqlite.storage.DataType.Integer, &overlap_values);
    defer overlap_array.deinit(allocator);

    const has_overlap = int_array.overlaps(overlap_array);
    std.debug.print("1. Arrays overlap: {}\n", .{has_overlap});

    const no_overlap_values = [_]zqlite.storage.Value{
        zqlite.storage.Value{ .Integer = 100 },
        zqlite.storage.Value{ .Integer = 200 },
    };

    const no_overlap_array = try zqlite.storage.ArrayValue.init(allocator, zqlite.storage.DataType.Integer, &no_overlap_values);
    defer no_overlap_array.deinit(allocator);

    const no_overlap = int_array.overlaps(no_overlap_array);
    std.debug.print("2. Arrays no overlap: {}\n", .{no_overlap});

    // Test multidimensional arrays concept
    std.debug.print("\n📋 Multidimensional Array Concept:\n", .{});

    // Create array of arrays (conceptually)
    const matrix_row1 = [_]zqlite.storage.Value{
        zqlite.storage.Value{ .Integer = 1 },
        zqlite.storage.Value{ .Integer = 2 },
        zqlite.storage.Value{ .Integer = 3 },
    };

    const matrix_row2 = [_]zqlite.storage.Value{
        zqlite.storage.Value{ .Integer = 4 },
        zqlite.storage.Value{ .Integer = 5 },
        zqlite.storage.Value{ .Integer = 6 },
    };

    const row1_array = try zqlite.storage.ArrayValue.init(allocator, zqlite.storage.DataType.Integer, &matrix_row1);
    defer row1_array.deinit(allocator);

    const row2_array = try zqlite.storage.ArrayValue.init(allocator, zqlite.storage.DataType.Integer, &matrix_row2);
    defer row2_array.deinit(allocator);

    std.debug.print("1. Matrix Row 1: len = {}\n", .{row1_array.len()});
    std.debug.print("2. Matrix Row 2: len = {}\n", .{row2_array.len()});

    // Simulate database array operations
    std.debug.print("\n💾 Database Array Operations Simulation:\n", .{});

    // Insert product with arrays using prepared statement
    var stmt = try conn.prepare("INSERT INTO products (id, name, tags, prices, categories) VALUES (?, ?, ?, ?, ?);");
    defer stmt.deinit();

    // Create sample data
    const product_tags = try allocator.dupe(u8, "{\"electronics\",\"mobile\",\"smartphone\"}");
    defer allocator.free(product_tags);

    const product_prices = try allocator.dupe(u8, "{599.99,699.99,799.99}");
    defer allocator.free(product_prices);

    const product_categories = try allocator.dupe(u8, "{\"phones\",\"gadgets\"}");
    defer allocator.free(product_categories);

    try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = 1 });
    const product_name = try allocator.dupe(u8, "Smartphone Pro");
    try stmt.bindParameter(1, zqlite.storage.Value{ .Text = product_name });
    defer allocator.free(product_name);
    const param_tags = try allocator.dupe(u8, product_tags);
    try stmt.bindParameter(2, zqlite.storage.Value{ .Text = param_tags });
    defer allocator.free(param_tags);
    const param_prices = try allocator.dupe(u8, product_prices);
    try stmt.bindParameter(3, zqlite.storage.Value{ .Text = param_prices });
    defer allocator.free(param_prices);
    const param_categories = try allocator.dupe(u8, product_categories);
    try stmt.bindParameter(4, zqlite.storage.Value{ .Text = param_categories });
    defer allocator.free(param_categories);

    var result = try stmt.execute();
    defer result.deinit();

    std.debug.print("✅ Inserted product with array columns\n", .{});

    // Demonstrate PostgreSQL array operators
    std.debug.print("\n🔧 PostgreSQL Array Operators (Concepts):\n", .{});

    std.debug.print("1. Containment (@>):     [1,2,3] @> [2]        → true\n", .{});
    std.debug.print("2. Contained by (<@):    [2] <@ [1,2,3]       → true\n", .{});
    std.debug.print("3. Overlap (&&):         [1,2,3] && [2,4]     → true\n", .{});
    std.debug.print("4. Array concatenation: [1,2] || [3,4]       → [1,2,3,4]\n", .{});
    std.debug.print("5. Array indexing:       array[1]             → first element\n", .{});
    std.debug.print("6. Array slicing:        array[2:4]           → elements 2-4\n", .{});

    // Index operations concept
    std.debug.print("\n🗂️  Array Indexing Concepts:\n", .{});

    std.debug.print("1. GIN Index:     CREATE INDEX idx_tags ON products USING GIN(tags);\n", .{});
    std.debug.print("2. Array queries: SELECT * FROM products WHERE tags @> '{{electronics}}';\n", .{});
    std.debug.print("3. Element query: SELECT * FROM products WHERE 'mobile' = ANY(tags);\n", .{});
    std.debug.print("4. Array length:  SELECT array_length(tags, 1) FROM products;\n", .{});

    // Performance considerations
    std.debug.print("\n⚡ Performance Notes:\n", .{});

    std.debug.print("• Arrays are best for small to medium collections (< 1000 elements)\n", .{});
    std.debug.print("• Use GIN indexes for array containment queries (@>, <@, &&)\n", .{});
    std.debug.print("• Consider normalization for large or frequently updated arrays\n", .{});
    std.debug.print("• Array operations are generally faster than JSON for simple lists\n", .{});

    std.debug.print("\n🎯 PostgreSQL array operations are working!\n", .{});
    std.debug.print("💡 Arrays provide efficient storage for collections of homogeneous data\n", .{});
    std.debug.print("🚀 Ready for integration with SQL parser and GIN indexing\n", .{});
}
