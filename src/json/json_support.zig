const std = @import("std");

/// JSON support for zqlite
/// Provides native JSON column type and query functions
/// JSON value type that can be stored in the database
pub const JsonValue = union(enum) {
    object: std.StringHashMap(JsonValue),
    array: std.ArrayListUnmanaged(JsonValue),
    string: []const u8,
    number: f64,
    boolean: bool,
    null: void,

    const Self = @This();

    /// Parse JSON from string
    pub fn parse(allocator: std.mem.Allocator, json_str: []const u8) !Self {
        var parser = std.json.Parser.init(allocator, false);
        defer parser.deinit();

        var tree = try parser.parse(json_str);
        defer tree.deinit();

        return try jsonValueFromStd(allocator, tree.root);
    }

    /// Convert to JSON string
    pub fn stringify(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        try self.stringifyInto(buffer.writer(allocator));
        return try buffer.toOwnedSlice(allocator);
    }

    /// Convert to JSON string (write to writer)
    fn stringifyInto(self: Self, writer: anytype) !void {
        switch (self) {
            .object => |obj| {
                try writer.writeByte('{');
                var first = true;
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writer.print("\"{s}\":", .{entry.key_ptr.*});
                    try entry.value_ptr.stringifyInto(writer);
                }
                try writer.writeByte('}');
            },
            .array => |arr| {
                try writer.writeByte('[');
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(',');
                    try item.stringifyInto(writer);
                }
                try writer.writeByte(']');
            },
            .string => |str| {
                try writer.print("\"{s}\"", .{str});
            },
            .number => |num| {
                try writer.print("{d}", .{num});
            },
            .boolean => |b| {
                try writer.writeAll(if (b) "true" else "false");
            },
            .null => {
                try writer.writeAll("null");
            },
        }
    }

    /// Extract value at JSON path (e.g., "$.user.name")
    pub fn extract(self: Self, path: []const u8) ?JsonValue {
        if (path.len == 0 or path[0] != '$') return null;

        var current = self;
        var i: usize = 1; // Skip '$'

        while (i < path.len) {
            if (path[i] == '.') {
                i += 1; // Skip '.'
                const start = i;

                // Find end of key
                while (i < path.len and path[i] != '.' and path[i] != '[') {
                    i += 1;
                }

                const key = path[start..i];

                switch (current) {
                    .object => |obj| {
                        current = obj.get(key) orelse return null;
                    },
                    else => return null,
                }
            } else if (path[i] == '[') {
                i += 1; // Skip '['
                const start = i;

                // Find closing bracket
                while (i < path.len and path[i] != ']') {
                    i += 1;
                }

                if (i >= path.len) return null;

                const index_str = path[start..i];
                const index = std.fmt.parseInt(usize, index_str, 10) catch return null;
                i += 1; // Skip ']'

                switch (current) {
                    .array => |arr| {
                        if (index >= arr.items.len) return null;
                        current = arr.items[index];
                    },
                    else => return null,
                }
            } else {
                return null;
            }
        }

        return current;
    }

    /// Check if JSON contains a value (for LIKE operations)
    pub fn contains(self: Self, search_value: []const u8) bool {
        switch (self) {
            .object => |obj| {
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    if (std.mem.indexOf(u8, entry.key_ptr.*, search_value) != null) return true;
                    if (entry.value_ptr.contains(search_value)) return true;
                }
                return false;
            },
            .array => |arr| {
                for (arr.items) |item| {
                    if (item.contains(search_value)) return true;
                }
                return false;
            },
            .string => |str| {
                return std.mem.indexOf(u8, str, search_value) != null;
            },
            .number => |num| {
                var buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&buf, "{d}", .{num}) catch return false;
                return std.mem.indexOf(u8, num_str, search_value) != null;
            },
            .boolean => |b| {
                const bool_str = if (b) "true" else "false";
                return std.mem.eql(u8, bool_str, search_value);
            },
            .null => {
                return std.mem.eql(u8, "null", search_value);
            },
        }
    }

    /// Deep clone the JSON value
    pub fn clone(self: Self, allocator: std.mem.Allocator) !JsonValue {
        switch (self) {
            .object => |obj| {
                var new_obj = std.StringHashMap(JsonValue).init(allocator);
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const value = try entry.value_ptr.clone(allocator);
                    try new_obj.put(key, value);
                }
                return JsonValue{ .object = new_obj };
            },
            .array => |arr| {
                var new_arr: std.ArrayListUnmanaged(JsonValue) = .empty;
                for (arr.items) |item| {
                    try new_arr.append(allocator, try item.clone(allocator));
                }
                return JsonValue{ .array = new_arr };
            },
            .string => |str| {
                return JsonValue{ .string = try allocator.dupe(u8, str) };
            },
            .number => |num| {
                return JsonValue{ .number = num };
            },
            .boolean => |b| {
                return JsonValue{ .boolean = b };
            },
            .null => {
                return JsonValue{ .null = {} };
            },
        }
    }

    /// Free allocated memory
    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        switch (self) {
            .object => |obj| {
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                // Note: HashMap deinit doesn't free the HashMap itself if it was allocated
            },
            .array => |arr| {
                for (arr.items) |item| {
                    item.deinit(allocator);
                }
                // Note: ArrayList deinit doesn't free the ArrayList itself if it was allocated
            },
            .string => |str| {
                allocator.free(str);
            },
            else => {},
        }
    }

    /// Convert from std.json.Value
    fn jsonValueFromStd(allocator: std.mem.Allocator, std_value: std.json.Value) !JsonValue {
        switch (std_value) {
            .object => |obj| {
                var result = std.StringHashMap(JsonValue).init(allocator);
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const value = try jsonValueFromStd(allocator, entry.value_ptr.*);
                    try result.put(key, value);
                }
                return JsonValue{ .object = result };
            },
            .array => |arr| {
                var result: std.ArrayListUnmanaged(JsonValue) = .empty;
                for (arr.items) |item| {
                    try result.append(allocator, try jsonValueFromStd(allocator, item));
                }
                return JsonValue{ .array = result };
            },
            .string => |str| {
                return JsonValue{ .string = try allocator.dupe(u8, str) };
            },
            .number_string => |num_str| {
                const num = std.fmt.parseFloat(f64, num_str) catch 0.0;
                return JsonValue{ .number = num };
            },
            .integer => |int| {
                return JsonValue{ .number = @floatFromInt(int) };
            },
            .float => |float| {
                return JsonValue{ .number = float };
            },
            .bool => |b| {
                return JsonValue{ .boolean = b };
            },
            .null => {
                return JsonValue{ .null = {} };
            },
        }
    }
};

/// JSON functions for SQL queries
pub const JsonFunctions = struct {
    /// json_extract(json_text, path) - Extract value at path
    pub fn extract(allocator: std.mem.Allocator, json_text: []const u8, path: []const u8) !?[]const u8 {
        const json_value = JsonValue.parse(allocator, json_text) catch return null;
        defer json_value.deinit(allocator);

        const extracted = json_value.extract(path) orelse return null;
        return try extracted.stringify(allocator);
    }

    /// json_valid(json_text) - Check if text is valid JSON
    pub fn valid(allocator: std.mem.Allocator, json_text: []const u8) bool {
        const json_value = JsonValue.parse(allocator, json_text) catch return false;
        json_value.deinit(allocator);
        return true;
    }

    /// json_type(json_text, path) - Get type of value at path
    pub fn getType(allocator: std.mem.Allocator, json_text: []const u8, path: []const u8) !?[]const u8 {
        const json_value = JsonValue.parse(allocator, json_text) catch return null;
        defer json_value.deinit(allocator);

        const extracted = json_value.extract(path) orelse return null;

        const type_name = switch (extracted) {
            .object => "object",
            .array => "array",
            .string => "text",
            .number => "real",
            .boolean => "boolean",
            .null => "null",
        };

        return try allocator.dupe(u8, type_name);
    }

    /// json_array_length(json_text, path) - Get length of array at path
    pub fn arrayLength(allocator: std.mem.Allocator, json_text: []const u8, path: []const u8) !?i64 {
        const json_value = JsonValue.parse(allocator, json_text) catch return null;
        defer json_value.deinit(allocator);

        const extracted = json_value.extract(path) orelse return null;

        switch (extracted) {
            .array => |arr| return @intCast(arr.items.len),
            else => return null,
        }
    }

    /// json_object_keys(json_text, path) - Get keys of object at path
    pub fn objectKeys(allocator: std.mem.Allocator, json_text: []const u8, path: []const u8) !?[]const u8 {
        const json_value = JsonValue.parse(allocator, json_text) catch return null;
        defer json_value.deinit(allocator);

        const extracted = json_value.extract(path) orelse return null;

        switch (extracted) {
            .object => |obj| {
                var keys: std.ArrayListUnmanaged(JsonValue) = .empty;
                defer keys.deinit(allocator);

                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    try keys.append(allocator, JsonValue{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
                }

                const keys_json = JsonValue{ .array = keys };
                return try keys_json.stringify(allocator);
            },
            else => return null,
        }
    }
};

test "json parsing and extraction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const json_str =
        \\{
        \\  "user": {
        \\    "id": 123,
        \\    "name": "Alice",
        \\    "permissions": ["read", "write"]
        \\  },
        \\  "session": {
        \\    "active": true,
        \\    "timeout": 3600
        \\  }
        \\}
    ;

    var json_value = try JsonValue.parse(allocator, json_str);
    defer json_value.deinit(allocator);

    // Test extraction
    const user_id = json_value.extract("$.user.id");
    try testing.expect(user_id != null);

    const user_name = json_value.extract("$.user.name");
    try testing.expect(user_name != null);

    const first_permission = json_value.extract("$.user.permissions[0]");
    try testing.expect(first_permission != null);

    // Test contains
    try testing.expect(json_value.contains("Alice"));
    try testing.expect(json_value.contains("read"));
    try testing.expect(!json_value.contains("admin"));
}

test "json functions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const json_str =
        \\{
        \\  "users": [
        \\    {"id": 1, "name": "Alice"},
        \\    {"id": 2, "name": "Bob"}
        \\  ]
        \\}
    ;

    // Test extract function
    const extracted = try JsonFunctions.extract(allocator, json_str, "$.users[0].name");
    try testing.expect(extracted != null);
    if (extracted) |result| {
        defer allocator.free(result);
        try testing.expect(std.mem.eql(u8, result, "\"Alice\""));
    }

    // Test valid function
    try testing.expect(JsonFunctions.valid(allocator, json_str));
    try testing.expect(!JsonFunctions.valid(allocator, "invalid json"));

    // Test array length
    const length = try JsonFunctions.arrayLength(allocator, json_str, "$.users");
    try testing.expect(length != null);
    try testing.expectEqual(@as(i64, 2), length.?);
}
