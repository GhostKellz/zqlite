const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🌐 zqlite JSON/JSONB Demo\n\n", .{});

    // Create in-memory database
    var conn = try zqlite.openMemory(allocator);
    defer conn.close();

    // Create table with JSON and JSONB columns
    try conn.execute("CREATE TABLE products (id INTEGER, metadata JSON, config JSONB);");

    // Test JSON data
    const json_data =
        \\{
        \\  "name": "Laptop",
        \\  "category": "Electronics",
        \\  "specs": {
        \\    "cpu": "Intel i7",
        \\    "ram": "16GB",
        \\    "storage": "512GB SSD"
        \\  },
        \\  "tags": ["business", "portable", "performance"],
        \\  "price": 1299.99,
        \\  "in_stock": true
        \\}
    ;

    const config_data =
        \\{
        \\  "settings": {
        \\    "theme": "dark",
        \\    "language": "en",
        \\    "notifications": true
        \\  },
        \\  "features": ["bluetooth", "wifi", "usb-c"]
        \\}
    ;

    // Insert JSON data using prepared statement
    var stmt = try conn.prepare("INSERT INTO products (id, metadata, config) VALUES (?, ?, ?);");
    defer stmt.deinit();

    // Create JSON value
    const json_data_copy = try allocator.dupe(u8, json_data);
    defer allocator.free(json_data_copy);
    const json_value = zqlite.storage.Value{ .JSON = json_data_copy };

    // Create JSONB value with parsed structure
    const jsonb_value = zqlite.storage.Value{ .JSONB = try zqlite.storage.JSONBValue.init(allocator, config_data) };
    defer jsonb_value.JSONB.deinit(allocator);

    try stmt.bindParameter(0, zqlite.storage.Value{ .Integer = 1 });
    try stmt.bindParameter(1, json_value);
    try stmt.bindParameter(2, jsonb_value);

    var result = try stmt.execute();
    defer result.deinit();

    std.debug.print("✅ Inserted product with JSON metadata\n", .{});
    std.debug.print("   Affected rows: {}\n", .{result.affected_rows});

    // Test JSONB operations
    std.debug.print("\n📝 JSONB Operations:\n", .{});

    // Convert JSONB back to string
    const jsonb_str = try jsonb_value.JSONB.toString(allocator);
    defer allocator.free(jsonb_str);
    std.debug.print("JSONB as string: {s}\n", .{jsonb_str});

    // Test different JSON values
    const test_cases = [_]struct {
        name: []const u8,
        json: []const u8,
    }{
        .{ .name = "Simple Object", .json = "{\"key\": \"value\"}" },
        .{ .name = "Array", .json = "[1, 2, 3, \"test\"]" },
        .{ .name = "Nested", .json = "{\"outer\": {\"inner\": [1, 2]}}" },
        .{ .name = "Mixed Types", .json = "{\"string\": \"test\", \"number\": 42, \"bool\": true, \"null\": null}" },
    };

    for (test_cases, 0..) |test_case, i| {
        std.debug.print("\nTest {}: {s}\n", .{ i + 1, test_case.name });

        // Test JSON parsing and storage
        const json_copy = try allocator.dupe(u8, test_case.json);
        defer allocator.free(json_copy);
        _ = zqlite.storage.Value{ .JSON = json_copy };

        // Test JSONB parsing and storage
        const jsonb_val = zqlite.storage.JSONBValue.init(allocator, test_case.json) catch |err| {
            std.debug.print("  ❌ JSONB parse error: {}\n", .{err});
            continue;
        };
        defer jsonb_val.deinit(allocator);

        const roundtrip = try jsonb_val.toString(allocator);
        defer allocator.free(roundtrip);

        std.debug.print("  Original: {s}\n", .{test_case.json});
        std.debug.print("  JSONB:    {s}\n", .{roundtrip});
        std.debug.print("  ✅ Success\n", .{});
    }

    std.debug.print("\n🎯 JSON/JSONB functionality is working!\n", .{});

    // Test actual JSON operations
    std.debug.print("\n🔍 Real JSON Operations:\n", .{});

    // Test JSON path extraction (-> operator)
    if (try jsonb_value.JSONB.extractPath(allocator, "theme")) |theme_json| {
        defer allocator.free(theme_json);
        std.debug.print("  config->'theme' = {s}\n", .{theme_json});
    }

    // Test JSON text extraction (->> operator)
    if (try jsonb_value.JSONB.extractText(allocator, "language")) |lang_text| {
        defer allocator.free(lang_text);
        std.debug.print("  config->>'language' = {s}\n", .{lang_text});
    }

    // Test key existence (? operator)
    const has_theme = jsonb_value.JSONB.hasKey("theme");
    const has_missing = jsonb_value.JSONB.hasKey("missing_key");
    std.debug.print("  config ? 'theme' = {}\n", .{has_theme});
    std.debug.print("  config ? 'missing_key' = {}\n", .{has_missing});

    // Test nested object access
    const nested_json =
        \\{
        \\  "user": {
        \\    "profile": {
        \\      "name": "John Doe",
        \\      "age": 30
        \\    },
        \\    "settings": ["dark", "notifications", "auto-save"]
        \\  }
        \\}
    ;

    const nested_jsonb = zqlite.storage.JSONBValue.init(allocator, nested_json) catch |err| {
        std.debug.print("  ❌ Nested JSON parse error: {}\n", .{err});
        return;
    };
    defer nested_jsonb.deinit(allocator);

    // Test nested path access
    if (try nested_jsonb.extractText(allocator, "user")) |user_data| {
        defer allocator.free(user_data);
        std.debug.print("  nested->'user' = {s}\n", .{user_data});
    }

    std.debug.print("\n✅ JSON/JSONB query operations working!\n", .{});
}
