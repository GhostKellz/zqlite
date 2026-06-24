const std = @import("std");
const time_utils = @import("../time_utils.zig");
const storage = @import("../db/storage.zig");
const ast = @import("../parser/ast.zig");
const Allocator = std.mem.Allocator;

pub const FunctionEvaluator = struct {
    const Self = @This();

    allocator: Allocator,

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn evaluateFunction(self: *Self, function_call: ast.FunctionCall) !storage.Value {
        const func_name = function_call.name;

        // Convert function name to lowercase for case-insensitive comparison
        const lower_name = try std.ascii.allocLowerString(self.allocator, func_name);
        defer self.allocator.free(lower_name);

        if (std.mem.eql(u8, lower_name, "now")) {
            return self.evalNow(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "current_timestamp")) {
            return self.evalCurrentTimestamp(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "current_date")) {
            return self.evalCurrentDate(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "current_time")) {
            return self.evalCurrentTime(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "datetime")) {
            return self.evalDatetime(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "strftime")) {
            return self.evalStrftime(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "unixepoch")) {
            return self.evalUnixepoch(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "julianday")) {
            return self.evalJulianday(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "date")) {
            return self.evalDate(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "time")) {
            return self.evalTime(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "coalesce")) {
            return self.evalCoalesce(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "nullif")) {
            return self.evalNullif(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "ifnull")) {
            return self.evalIfnull(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "json_valid")) {
            return self.evalJsonValid(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "json_extract")) {
            return self.evalJsonExtract(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "json_type")) {
            return self.evalJsonType(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "json_array_length")) {
            return self.evalJsonArrayLength(function_call.arguments);
        } else if (std.mem.eql(u8, lower_name, "json_object")) {
            return self.evalJsonObject(function_call.arguments);
        } else {
            return error.UnknownFunction;
        }
    }

    pub fn evaluateJsonFunctionWithValues(self: *Self, lower_name: []const u8, arguments: []const storage.Value) !?storage.Value {
        if (std.mem.eql(u8, lower_name, "json_valid")) {
            return try self.evalJsonValidValues(arguments);
        } else if (std.mem.eql(u8, lower_name, "json_extract")) {
            return try self.evalJsonExtractValues(arguments);
        } else if (std.mem.eql(u8, lower_name, "json_type")) {
            return try self.evalJsonTypeValues(arguments);
        } else if (std.mem.eql(u8, lower_name, "json_array_length")) {
            return try self.evalJsonArrayLengthValues(arguments);
        } else if (std.mem.eql(u8, lower_name, "json_object")) {
            return try self.evalJsonObjectValues(arguments);
        }

        return null;
    }

    /// COALESCE(a, b, c, ...) - returns the first non-NULL value
    fn evalCoalesce(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        if (arguments.len == 0) {
            return error.InvalidArgumentCount;
        }

        for (arguments) |arg| {
            const value = try self.resolveArgument(arg);
            switch (value) {
                .Null => {
                    value.deinit(self.allocator);
                    continue;
                },
                else => return value,
            }
        }

        return storage.Value.Null;
    }

    /// NULLIF(a, b) - returns NULL if a = b, otherwise returns a
    fn evalNullif(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        if (arguments.len != 2) {
            return error.InvalidArgumentCount;
        }

        const a = try self.resolveArgument(arguments[0]);
        const b = try self.resolveArgument(arguments[1]);
        defer b.deinit(self.allocator);

        // Compare values
        const are_equal = self.valuesEqual(a, b);

        if (are_equal) {
            a.deinit(self.allocator);
            return storage.Value.Null;
        } else {
            return a;
        }
    }

    /// IFNULL(a, b) - returns b if a is NULL, otherwise returns a
    fn evalIfnull(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        if (arguments.len != 2) {
            return error.InvalidArgumentCount;
        }

        const a = try self.resolveArgument(arguments[0]);

        switch (a) {
            .Null => {
                return try self.resolveArgument(arguments[1]);
            },
            else => return a,
        }
    }

    fn evalJsonValid(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        const values = try self.resolveArguments(arguments);
        defer self.deinitResolvedArguments(values);
        return try self.evalJsonValidValues(values);
    }

    fn evalJsonExtract(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        const values = try self.resolveArguments(arguments);
        defer self.deinitResolvedArguments(values);
        return try self.evalJsonExtractValues(values);
    }

    fn evalJsonType(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        const values = try self.resolveArguments(arguments);
        defer self.deinitResolvedArguments(values);
        return try self.evalJsonTypeValues(values);
    }

    fn evalJsonArrayLength(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        const values = try self.resolveArguments(arguments);
        defer self.deinitResolvedArguments(values);
        return try self.evalJsonArrayLengthValues(values);
    }

    fn evalJsonObject(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        const values = try self.resolveArguments(arguments);
        defer self.deinitResolvedArguments(values);
        return try self.evalJsonObjectValues(values);
    }

    fn resolveArguments(self: *Self, arguments: []ast.FunctionArgument) ![]storage.Value {
        var values = try self.allocator.alloc(storage.Value, arguments.len);
        var resolved: usize = 0;
        errdefer {
            for (values[0..resolved]) |value| {
                value.deinit(self.allocator);
            }
            self.allocator.free(values);
        }

        for (arguments, 0..) |arg, i| {
            values[i] = try self.resolveArgument(arg);
            resolved = i + 1;
        }

        return values;
    }

    fn deinitResolvedArguments(self: *Self, values: []storage.Value) void {
        for (values) |value| {
            value.deinit(self.allocator);
        }
        self.allocator.free(values);
    }

    fn evalJsonValidValues(self: *Self, arguments: []const storage.Value) !storage.Value {
        if (arguments.len != 1) return error.InvalidArgumentCount;
        const text = try self.jsonTextFromValue(arguments[0]) orelse return storage.Value{ .Integer = 0 };
        var parsed = self.parseJson(text) orelse return storage.Value{ .Integer = 0 };
        parsed.deinit();
        return storage.Value{ .Integer = 1 };
    }

    fn evalJsonExtractValues(self: *Self, arguments: []const storage.Value) !storage.Value {
        if (arguments.len != 2) return error.InvalidArgumentCount;
        const text = try self.jsonTextFromValue(arguments[0]) orelse return storage.Value.Null;
        const path = self.textFromValue(arguments[1]) orelse return error.InvalidArgumentType;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch return storage.Value.Null;
        defer parsed.deinit();

        const value = self.jsonValueAtPath(parsed.value, path) orelse return storage.Value.Null;
        return try self.storageValueFromJson(value);
    }

    fn evalJsonTypeValues(self: *Self, arguments: []const storage.Value) !storage.Value {
        if (arguments.len != 1 and arguments.len != 2) return error.InvalidArgumentCount;
        const text = try self.jsonTextFromValue(arguments[0]) orelse return storage.Value.Null;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch return storage.Value.Null;
        defer parsed.deinit();

        const value = if (arguments.len == 2) blk: {
            const path = self.textFromValue(arguments[1]) orelse return error.InvalidArgumentType;
            break :blk self.jsonValueAtPath(parsed.value, path) orelse return storage.Value.Null;
        } else parsed.value;

        return storage.Value{ .Text = try self.allocator.dupe(u8, jsonTypeName(value)) };
    }

    fn evalJsonArrayLengthValues(self: *Self, arguments: []const storage.Value) !storage.Value {
        if (arguments.len != 1 and arguments.len != 2) return error.InvalidArgumentCount;
        const text = try self.jsonTextFromValue(arguments[0]) orelse return storage.Value.Null;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch return storage.Value.Null;
        defer parsed.deinit();

        const value = if (arguments.len == 2) blk: {
            const path = self.textFromValue(arguments[1]) orelse return error.InvalidArgumentType;
            break :blk self.jsonValueAtPath(parsed.value, path) orelse return storage.Value.Null;
        } else parsed.value;

        return storage.Value{ .Integer = switch (value) {
            .array => |array| @intCast(array.items.len),
            else => 0,
        } };
    }

    fn evalJsonObjectValues(self: *Self, arguments: []const storage.Value) !storage.Value {
        if (arguments.len % 2 != 0) return error.InvalidArgumentCount;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);

        try out.append(self.allocator, '{');
        var i: usize = 0;
        while (i < arguments.len) : (i += 2) {
            if (i > 0) try out.append(self.allocator, ',');

            const key = self.textFromValue(arguments[i]) orelse return error.InvalidArgumentType;
            try appendJsonString(self.allocator, &out, key);
            try out.append(self.allocator, ':');
            try appendStorageValueAsJson(self.allocator, &out, arguments[i + 1]);
        }
        try out.append(self.allocator, '}');

        return storage.Value{ .Text = try out.toOwnedSlice(self.allocator) };
    }

    /// Compare two storage values for equality
    fn valuesEqual(self: *Self, a: storage.Value, b: storage.Value) bool {
        _ = self;
        // If types don't match, they're not equal
        if (@as(std.meta.Tag(storage.Value), a) != @as(std.meta.Tag(storage.Value), b)) {
            return false;
        }

        return switch (a) {
            .Integer => |i| i == b.Integer,
            .Real => |r| r == b.Real,
            .Text => |t| std.mem.eql(u8, t, b.Text),
            .Blob => |bl| std.mem.eql(u8, bl, b.Blob),
            .Null => true, // NULL = NULL is true for NULLIF
            else => false,
        };
    }

    fn jsonTextFromValue(self: *Self, value: storage.Value) !?[]const u8 {
        _ = self;
        return switch (value) {
            .Text, .JSON => |text| text,
            .Null => null,
            else => null,
        };
    }

    fn textFromValue(self: *Self, value: storage.Value) ?[]const u8 {
        _ = self;
        return switch (value) {
            .Text, .JSON => |text| text,
            else => null,
        };
    }

    fn parseJson(self: *Self, text: []const u8) ?std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch null;
    }

    fn jsonValueAtPath(self: *Self, root: std.json.Value, path: []const u8) ?std.json.Value {
        _ = self;
        if (path.len == 0 or path[0] != '$') return null;
        if (path.len == 1) return root;

        var current = root;
        var i: usize = 1;
        while (i < path.len) {
            switch (path[i]) {
                '.' => {
                    i += 1;
                    const start = i;
                    while (i < path.len and path[i] != '.' and path[i] != '[') : (i += 1) {}
                    if (i == start) return null;
                    const key = path[start..i];
                    current = switch (current) {
                        .object => |obj| obj.get(key) orelse return null,
                        else => return null,
                    };
                },
                '[' => {
                    i += 1;
                    const start = i;
                    while (i < path.len and path[i] != ']') : (i += 1) {}
                    if (i >= path.len or i == start) return null;
                    const index = std.fmt.parseInt(usize, path[start..i], 10) catch return null;
                    i += 1;
                    current = switch (current) {
                        .array => |array| if (index < array.items.len) array.items[index] else return null,
                        else => return null,
                    };
                },
                else => return null,
            }
        }

        return current;
    }

    fn storageValueFromJson(self: *Self, value: std.json.Value) !storage.Value {
        return switch (value) {
            .null => storage.Value.Null,
            .bool => |b| storage.Value{ .Integer = if (b) 1 else 0 },
            .integer => |i| storage.Value{ .Integer = i },
            .float => |f| storage.Value{ .Real = f },
            .number_string => |s| storage.Value{ .Text = try self.allocator.dupe(u8, s) },
            .string => |s| storage.Value{ .Text = try self.allocator.dupe(u8, s) },
            .array, .object => storage.Value{ .Text = try self.jsonStringify(value) },
        };
    }

    fn jsonStringify(self: *Self, value: std.json.Value) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try appendJsonValue(self.allocator, &out, value);
        return out.toOwnedSlice(self.allocator);
    }

    fn jsonTypeName(value: std.json.Value) []const u8 {
        return switch (value) {
            .null => "null",
            .bool => |b| if (b) "true" else "false",
            .integer => "integer",
            .float, .number_string => "real",
            .string => "text",
            .array => "array",
            .object => "object",
        };
    }

    fn appendJsonValue(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
        switch (value) {
            .null => try out.appendSlice(allocator, "null"),
            .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
            .integer => |i| try appendJsonFmt(allocator, out, "{d}", .{i}),
            .float => |f| try appendJsonFmt(allocator, out, "{d}", .{f}),
            .number_string => |s| try out.appendSlice(allocator, s),
            .string => |s| try appendJsonString(allocator, out, s),
            .array => |array| {
                try out.append(allocator, '[');
                for (array.items, 0..) |item, i| {
                    if (i > 0) try out.append(allocator, ',');
                    try appendJsonValue(allocator, out, item);
                }
                try out.append(allocator, ']');
            },
            .object => |object| {
                try out.append(allocator, '{');
                var first = true;
                var iter = object.iterator();
                while (iter.next()) |entry| {
                    if (!first) try out.append(allocator, ',');
                    first = false;
                    try appendJsonString(allocator, out, entry.key_ptr.*);
                    try out.append(allocator, ':');
                    try appendJsonValue(allocator, out, entry.value_ptr.*);
                }
                try out.append(allocator, '}');
            },
        }
    }

    fn appendStorageValueAsJson(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), value: storage.Value) !void {
        switch (value) {
            .Null => try out.appendSlice(allocator, "null"),
            .Integer => |v| try appendJsonFmt(allocator, out, "{d}", .{v}),
            .SmallInt => |v| try appendJsonFmt(allocator, out, "{d}", .{v}),
            .BigInt => |v| try appendJsonFmt(allocator, out, "{d}", .{v}),
            .Real => |v| try appendJsonFmt(allocator, out, "{d}", .{v}),
            .Boolean => |v| try out.appendSlice(allocator, if (v) "true" else "false"),
            .Text => |text| try appendJsonString(allocator, out, text),
            .JSON => |json| try out.appendSlice(allocator, json),
            .JSONB => |jsonb| {
                const json = try jsonb.toString(allocator);
                defer allocator.free(json);
                try out.appendSlice(allocator, json);
            },
            else => try appendJsonString(allocator, out, ""),
        }
    }

    fn appendJsonString(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
        try out.append(allocator, '"');
        for (text) |byte| {
            switch (byte) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => try out.append(allocator, byte),
            }
        }
        try out.append(allocator, '"');
    }

    fn appendJsonFmt(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(text);
        try out.appendSlice(allocator, text);
    }

    /// Resolve a function argument to a storage value
    fn resolveArgument(self: *Self, arg: ast.FunctionArgument) anyerror!storage.Value {
        return switch (arg) {
            .Literal => |value| {
                return switch (value) {
                    .Integer => |i| storage.Value{ .Integer = i },
                    .Real => |r| storage.Value{ .Real = r },
                    .Text => |t| storage.Value{ .Text = try self.allocator.dupe(u8, t) },
                    .Blob => |b| storage.Value{ .Blob = try self.allocator.dupe(u8, b) },
                    .Null => storage.Value.Null,
                    .Parameter => storage.Value.Null, // Parameters should be resolved before this
                    .FunctionCall => |func| try self.evaluateFunction(func),
                    .Case => storage.Value.Null, // CASE inside function not yet supported
                };
            },
            .String => |s| storage.Value{ .Text = try self.allocator.dupe(u8, s) },
            .Column => |col| {
                // Column reference inside function - not supported in this context
                _ = col;
                return storage.Value.Null;
            },
            else => storage.Value.Null,
        };
    }

    fn evalNow(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        if (arguments.len != 0) {
            return error.InvalidArgumentCount;
        }

        // Return current timestamp as ISO 8601 string
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const datetime_str = try self.formatTimestamp(timestamp);
        return storage.Value{ .Text = datetime_str };
    }

    fn evalDatetime(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        const timestamp = try self.timestampFromDateArgs(arguments);
        return storage.Value{ .Text = try self.formatTimestamp(timestamp) };
    }

    fn evalStrftime(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        if (arguments.len < 2) {
            return error.InvalidArgumentCount;
        }

        const format_str = try self.textFromFunctionArgument(arguments[0]);
        const timestamp = try self.timestampFromDateArgs(arguments[1..]);
        const formatted = try self.formatTimestampWithFormat(timestamp, format_str);
        return storage.Value{ .Text = formatted };
    }

    fn evalUnixepoch(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        return storage.Value{ .Integer = try self.timestampFromDateArgs(arguments) };
    }

    fn evalJulianday(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        const timestamp = try self.timestampFromDateArgs(arguments);
        return storage.Value{ .Real = self.timestampToJulianDay(timestamp) };
    }

    fn evalDate(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        const timestamp = try self.timestampFromDateArgs(arguments);
        return storage.Value{ .Text = try self.formatDate(timestamp) };
    }

    fn evalTime(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        const timestamp = try self.timestampFromDateArgs(arguments);
        return storage.Value{ .Text = try self.formatTime(timestamp) };
    }

    fn evalCurrentTimestamp(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        if (arguments.len != 0) {
            return error.InvalidArgumentCount;
        }

        // Return current timestamp as ISO 8601 string
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const datetime_str = try self.formatTimestamp(timestamp);
        return storage.Value{ .Text = datetime_str };
    }

    fn evalCurrentDate(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        if (arguments.len != 0) {
            return error.InvalidArgumentCount;
        }

        // Return current date as YYYY-MM-DD string
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const date_str = try self.formatDate(timestamp);
        return storage.Value{ .Text = date_str };
    }

    fn evalCurrentTime(self: *Self, arguments: []ast.FunctionArgument) !storage.Value {
        if (arguments.len != 0) {
            return error.InvalidArgumentCount;
        }

        // Return current time as HH:MM:SS string
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const time_str = try self.formatTime(timestamp);
        return storage.Value{ .Text = time_str };
    }

    fn textFromFunctionArgument(self: *Self, argument: ast.FunctionArgument) ![]const u8 {
        _ = self;
        return switch (argument) {
            .Literal => |value| switch (value) {
                .Text => |text| text,
                else => error.InvalidArgumentType,
            },
            .String => |text| text,
            else => error.InvalidArgumentType,
        };
    }

    fn timestampFromDateArgs(self: *Self, arguments: []ast.FunctionArgument) !i64 {
        var timestamp: i64 = if (arguments.len == 0) blk: {
            const ts = time_utils.getTimespec();
            break :blk ts.sec;
        } else try self.timestampFromFunctionArgument(arguments[0]);

        for (arguments[if (arguments.len == 0) 0 else 1..]) |modifier_arg| {
            const modifier = try self.textFromFunctionArgument(modifier_arg);
            timestamp = try self.applyDateModifier(timestamp, modifier);
        }

        return timestamp;
    }

    fn timestampFromFunctionArgument(self: *Self, argument: ast.FunctionArgument) !i64 {
        return switch (argument) {
            .Literal => |value| switch (value) {
                .Integer => |timestamp| timestamp,
                .Text => |text| try self.parseTimestamp(text),
                else => error.InvalidArgumentType,
            },
            .String => |text| try self.parseTimestamp(text),
            else => error.InvalidArgumentType,
        };
    }

    fn applyDateModifier(self: *Self, timestamp: i64, modifier: []const u8) !i64 {
        _ = self;
        const trimmed = std.mem.trim(u8, modifier, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "start of day")) {
            return @divFloor(timestamp, 86400) * 86400;
        }

        if (trimmed.len < 4 or (trimmed[0] != '+' and trimmed[0] != '-')) {
            return error.InvalidArgumentType;
        }

        const sign: i64 = if (trimmed[0] == '-') -1 else 1;
        var split = std.mem.tokenizeScalar(u8, trimmed[1..], ' ');
        const amount_text = split.next() orelse return error.InvalidArgumentType;
        const unit = split.next() orelse return error.InvalidArgumentType;
        if (split.next() != null) return error.InvalidArgumentType;

        const amount = try std.fmt.parseInt(i64, amount_text, 10);
        const seconds: i64 = if (std.ascii.eqlIgnoreCase(unit, "day") or std.ascii.eqlIgnoreCase(unit, "days"))
            86400
        else if (std.ascii.eqlIgnoreCase(unit, "hour") or std.ascii.eqlIgnoreCase(unit, "hours"))
            3600
        else if (std.ascii.eqlIgnoreCase(unit, "minute") or std.ascii.eqlIgnoreCase(unit, "minutes"))
            60
        else if (std.ascii.eqlIgnoreCase(unit, "second") or std.ascii.eqlIgnoreCase(unit, "seconds"))
            1
        else
            return error.InvalidArgumentType;

        return timestamp + sign * amount * seconds;
    }

    fn formatTimestamp(self: *Self, timestamp: i64) ![]u8 {
        const parts = timestampToParts(timestamp);
        return std.fmt.allocPrint(self.allocator, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            parts.year,
            parts.month,
            parts.day,
            parts.hour,
            parts.minute,
            parts.second,
        });
    }

    fn formatTimestampWithFormat(self: *Self, timestamp: i64, format: []const u8) ![]u8 {
        // Simple format implementation - in production, use proper strftime
        if (std.mem.eql(u8, format, "%s")) {
            return std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});
        } else if (std.mem.eql(u8, format, "%Y-%m-%d %H:%M:%S")) {
            return self.formatTimestamp(timestamp);
        } else if (std.mem.eql(u8, format, "%Y-%m-%d")) {
            return self.formatDate(timestamp);
        } else if (std.mem.eql(u8, format, "%H:%M:%S")) {
            return self.formatTime(timestamp);
        } else {
            // Default to ISO format
            return self.formatTimestamp(timestamp);
        }
    }

    fn formatDate(self: *Self, timestamp: i64) ![]u8 {
        const parts = timestampToParts(timestamp);
        return std.fmt.allocPrint(self.allocator, "{d}-{d:0>2}-{d:0>2}", .{ parts.year, parts.month, parts.day });
    }

    fn formatTime(self: *Self, timestamp: i64) ![]u8 {
        const parts = timestampToParts(timestamp);
        return std.fmt.allocPrint(self.allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ parts.hour, parts.minute, parts.second });
    }

    fn parseTimestamp(self: *Self, datetime_str: []const u8) !i64 {
        _ = self;
        const trimmed = std.mem.trim(u8, datetime_str, " \t\r\n");
        if (std.mem.eql(u8, datetime_str, "now")) {
            const ts = time_utils.getTimespec();
            return ts.sec;
        }

        if (std.fmt.parseInt(i64, trimmed, 10)) |timestamp| {
            return timestamp;
        } else |_| {}

        return parseIsoTimestamp(trimmed) orelse error.InvalidArgumentType;
    }

    fn timestampToJulianDay(self: *Self, timestamp: i64) f64 {
        _ = self;
        // Convert Unix timestamp to Julian Day Number
        // Unix epoch (1970-01-01) is JD 2440587.5
        const unix_epoch_jd = 2440587.5;
        const seconds_per_day = 86400.0;
        return unix_epoch_jd + (@as(f64, @floatFromInt(timestamp)) / seconds_per_day);
    }

    const DateTimeParts = struct {
        year: i64,
        month: u8,
        day: u8,
        hour: u8,
        minute: u8,
        second: u8,
    };

    fn timestampToParts(timestamp: i64) DateTimeParts {
        const days = @divFloor(timestamp, 86400);
        const seconds_in_day_i64 = @mod(timestamp, 86400);
        const civil = civilFromDays(days);

        return .{
            .year = civil.year,
            .month = civil.month,
            .day = civil.day,
            .hour = @intCast(@divFloor(seconds_in_day_i64, 3600)),
            .minute = @intCast(@divFloor(@mod(seconds_in_day_i64, 3600), 60)),
            .second = @intCast(@mod(seconds_in_day_i64, 60)),
        };
    }

    fn parseIsoTimestamp(text: []const u8) ?i64 {
        if (text.len != 10 and text.len != 19) return null;
        if (text[4] != '-' or text[7] != '-') return null;
        if (text.len == 19 and text[10] != ' ' and text[10] != 'T') return null;

        const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
        const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
        const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;

        var hour: u8 = 0;
        var minute: u8 = 0;
        var second: u8 = 0;
        if (text.len == 19) {
            if (text[13] != ':' or text[16] != ':') return null;
            hour = std.fmt.parseInt(u8, text[11..13], 10) catch return null;
            minute = std.fmt.parseInt(u8, text[14..16], 10) catch return null;
            second = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
        }

        if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
        if (hour > 23 or minute > 59 or second > 59) return null;

        const days = daysFromCivil(year, month, day);
        return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    }

    fn daysInMonth(year: i64, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) 29 else 28,
            else => 0,
        };
    }

    fn isLeapYear(year: i64) bool {
        return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    }

    fn daysFromCivil(year_input: i64, month_input: u8, day_input: u8) i64 {
        var year = year_input;
        const month: i64 = month_input;
        const day: i64 = day_input;
        year -= if (month <= 2) 1 else 0;
        const era = @divFloor(year, 400);
        const yoe = year - era * 400;
        const month_adjust: i64 = if (month > 2) -3 else 9;
        const month_prime = month + month_adjust;
        const doy = @divFloor(153 * month_prime + 2, 5) + day - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    fn civilFromDays(days_input: i64) struct { year: i64, month: u8, day: u8 } {
        const z = days_input + 719468;
        const era = @divFloor(z, 146097);
        const doe = z - era * 146097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        var year = yoe + era * 400;
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const day = doy - @divFloor(153 * mp + 2, 5) + 1;
        const month_adjust: i64 = if (mp < 10) 3 else -9;
        const month = mp + month_adjust;
        year += if (month <= 2) 1 else 0;

        return .{
            .year = year,
            .month = @intCast(month),
            .day = @intCast(day),
        };
    }
};

test "datetime function evaluation" {
    const allocator = std.testing.allocator;

    var evaluator = FunctionEvaluator.init(allocator);

    // Test NOW() function
    const now_args = [_]ast.FunctionArgument{};
    const now_result = try evaluator.evaluateFunction(ast.FunctionCall{
        .name = "now",
        .arguments = @constCast(&now_args),
    });
    defer now_result.deinit(allocator);

    try std.testing.expect(now_result == .Text);

    // Test DATETIME('now') function
    const datetime_args = [_]ast.FunctionArgument{
        ast.FunctionArgument{ .Literal = ast.Value{ .Text = "now" } },
    };
    const datetime_result = try evaluator.evaluateFunction(ast.FunctionCall{
        .name = "datetime",
        .arguments = @constCast(&datetime_args),
    });
    defer datetime_result.deinit(allocator);

    try std.testing.expect(datetime_result == .Text);

    // Test UNIXEPOCH() function
    const unixepoch_args = [_]ast.FunctionArgument{};
    const unixepoch_result = try evaluator.evaluateFunction(ast.FunctionCall{
        .name = "unixepoch",
        .arguments = @constCast(&unixepoch_args),
    });

    try std.testing.expect(unixepoch_result == .Integer);

    // Test STRFTIME('%s', 'now') function
    const strftime_args = [_]ast.FunctionArgument{
        ast.FunctionArgument{ .Literal = ast.Value{ .Text = "%s" } },
        ast.FunctionArgument{ .Literal = ast.Value{ .Text = "now" } },
    };
    const strftime_result = try evaluator.evaluateFunction(ast.FunctionCall{
        .name = "strftime",
        .arguments = @constCast(&strftime_args),
    });
    defer strftime_result.deinit(allocator);

    try std.testing.expect(strftime_result == .Text);
}
