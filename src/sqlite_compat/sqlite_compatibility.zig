const std = @import("std");
const storage = @import("../db/storage.zig");
const connection = @import("../db/connection.zig");
const parser = @import("../parser/parser.zig");
const ast = @import("../parser/ast.zig");

/// SQLite compatibility layer for zqlite
/// Implements PRAGMA statements, ATTACH/DETACH, FTS, and JSON operations
pub const SQLiteCompat = struct {
    allocator: std.mem.Allocator,
    connection: *connection.Connection,
    attached_databases: std.hash_map.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    pragma_settings: PragmaSettings,
    fts_indexes: std.hash_map.HashMap([]const u8, FTSIndex, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, conn: *connection.Connection) Self {
        return Self{
            .allocator = allocator,
            .connection = conn,
            .attached_databases = std.hash_map.HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .pragma_settings = PragmaSettings.default(),
            .fts_indexes = std.hash_map.HashMap([]const u8, FTSIndex, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    /// Process PRAGMA statements
    pub fn processPragma(self: *Self, pragma_name: []const u8, value: ?[]const u8) ![]storage.Row {
        var rows = std.ArrayList(storage.Row).init(self.allocator);

        if (std.mem.eql(u8, pragma_name, "page_size")) {
            if (value) |val| {
                self.pragma_settings.page_size = try std.fmt.parseInt(u32, val, 10);
            }
            const row_value = storage.Value{ .Integer = @intCast(self.pragma_settings.page_size) };
            try rows.append(storage.Row{ .values = try self.allocator.dupe(storage.Value, &[_]storage.Value{row_value}) });
        } else if (std.mem.eql(u8, pragma_name, "cache_size")) {
            if (value) |val| {
                self.pragma_settings.cache_size = try std.fmt.parseInt(i32, val, 10);
            }
            const row_value = storage.Value{ .Integer = self.pragma_settings.cache_size };
            try rows.append(storage.Row{ .values = try self.allocator.dupe(storage.Value, &[_]storage.Value{row_value}) });
        } else if (std.mem.eql(u8, pragma_name, "journal_mode")) {
            if (value) |val| {
                self.pragma_settings.journal_mode = try self.allocator.dupe(u8, val);
            }
            const row_value = storage.Value{ .Text = self.pragma_settings.journal_mode };
            try rows.append(storage.Row{ .values = try self.allocator.dupe(storage.Value, &[_]storage.Value{row_value}) });
        } else if (std.mem.eql(u8, pragma_name, "foreign_keys")) {
            if (value) |val| {
                self.pragma_settings.foreign_keys = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "ON");
            }
            const row_value = storage.Value{ .Integer = if (self.pragma_settings.foreign_keys) 1 else 0 };
            try rows.append(storage.Row{ .values = try self.allocator.dupe(storage.Value, &[_]storage.Value{row_value}) });
        } else if (std.mem.eql(u8, pragma_name, "table_info")) {
            if (value) |table_name| {
                return try self.getTableInfo(table_name);
            }
        } else if (std.mem.eql(u8, pragma_name, "database_list")) {
            return try self.getDatabaseList();
        }

        return try rows.toOwnedSlice();
    }

    /// Attach database
    pub fn attachDatabase(self: *Self, database_path: []const u8, database_name: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, database_path);
        const name_copy = try self.allocator.dupe(u8, database_name);
        try self.attached_databases.put(name_copy, path_copy);
    }

    /// Detach database
    pub fn detachDatabase(self: *Self, database_name: []const u8) !void {
        if (self.attached_databases.get(database_name)) |path| {
            self.allocator.free(path);
            _ = self.attached_databases.remove(database_name);
        }
    }

    /// Create FTS virtual table
    pub fn createFTSTable(self: *Self, table_name: []const u8, columns: [][]const u8) !void {
        const fts_index = FTSIndex{
            .table_name = try self.allocator.dupe(u8, table_name),
            .columns = try self.allocator.dupe([]const u8, columns),
            .documents = std.hash_map.HashMap(u64, FTSDocument, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(self.allocator),
            .inverted_index = std.hash_map.HashMap([]const u8, std.ArrayList(u64), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator),
        };

        try self.fts_indexes.put(try self.allocator.dupe(u8, table_name), fts_index);

        // Create corresponding regular table for storage
        var create_sql = std.ArrayList(u8).init(self.allocator);
        defer create_sql.deinit();

        try create_sql.appendSlice("CREATE TABLE ");
        try create_sql.appendSlice(table_name);
        try create_sql.appendSlice(" (rowid INTEGER PRIMARY KEY");

        for (columns) |column| {
            try create_sql.appendSlice(", ");
            try create_sql.appendSlice(column);
            try create_sql.appendSlice(" TEXT");
        }

        try create_sql.appendSlice(")");

        _ = try self.connection.execute(create_sql.items);
    }

    /// Insert into FTS table with indexing
    pub fn insertFTS(self: *Self, table_name: []const u8, rowid: u64, values: [][]const u8) !void {
        var fts_index = self.fts_indexes.getPtr(table_name) orelse return error.FTSTableNotFound;

        // Create document
        const document = FTSDocument{
            .rowid = rowid,
            .content = try self.allocator.dupe([]const u8, values),
        };

        try fts_index.documents.put(rowid, document);

        // Build inverted index
        for (values, 0..) |content, column_idx| {
            _ = column_idx; // Suppress unused variable warning
            const words = try self.tokenizeText(content);
            defer self.allocator.free(words);

            for (words) |word| {
                var entry = fts_index.inverted_index.getPtr(word);
                if (entry == null) {
                    var new_list = std.ArrayList(u64).init(self.allocator);
                    try new_list.append(rowid);
                    try fts_index.inverted_index.put(try self.allocator.dupe(u8, word), new_list);
                } else {
                    try entry.?.append(rowid);
                }
            }
        }
    }

    /// Search FTS table
    pub fn searchFTS(self: *Self, table_name: []const u8, query: []const u8) ![]storage.Row {
        const fts_index = self.fts_indexes.get(table_name) orelse return error.FTSTableNotFound;

        const query_words = try self.tokenizeText(query);
        defer self.allocator.free(query_words);

        var matching_rowids = std.hash_map.HashMap(u64, void, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(self.allocator);
        defer matching_rowids.deinit();

        // Find documents containing all query words (AND search)
        for (query_words, 0..) |word, i| {
            if (fts_index.inverted_index.get(word)) |document_list| {
                if (i == 0) {
                    // First word - add all matching documents
                    for (document_list.items) |rowid| {
                        try matching_rowids.put(rowid, {});
                    }
                } else {
                    // Subsequent words - keep only documents that match
                    var new_matches = std.hash_map.HashMap(u64, void, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(self.allocator);
                    defer new_matches.deinit();

                    for (document_list.items) |rowid| {
                        if (matching_rowids.contains(rowid)) {
                            try new_matches.put(rowid, {});
                        }
                    }

                    matching_rowids.clearAndFree();
                    matching_rowids = new_matches.move();
                }
            }
        }

        // Convert matching rowids to result rows
        var results = std.ArrayList(storage.Row).init(self.allocator);

        var iterator = matching_rowids.iterator();
        while (iterator.next()) |entry| {
            const rowid = entry.key_ptr.*;
            if (fts_index.documents.get(rowid)) |document| {
                var row_values = std.ArrayList(storage.Value).init(self.allocator);
                try row_values.append(storage.Value{ .Integer = @intCast(rowid) });

                for (document.content) |content| {
                    try row_values.append(storage.Value{ .Text = try self.allocator.dupe(u8, content) });
                }

                try results.append(storage.Row{ .values = try row_values.toOwnedSlice() });
            }
        }

        return try results.toOwnedSlice();
    }

    /// JSON functions using std.json for proper parsing and validation
    pub const JSONFunctions = struct {
        /// Extract value from JSON at path (supports $.field syntax)
        pub fn jsonExtract(allocator: std.mem.Allocator, json_text: []const u8, path: []const u8) !storage.Value {
            // Parse JSON using std.json
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
                return storage.Value.Null; // Invalid JSON returns NULL
            };
            defer parsed.deinit();

            // Parse the path (e.g., "$.name" or "$.user.email")
            const field_path = if (std.mem.startsWith(u8, path, "$."))
                path[2..]
            else if (std.mem.startsWith(u8, path, "$"))
                path[1..]
            else
                path;

            // Navigate the JSON structure
            var current = parsed.value;
            var path_iter = std.mem.splitSequence(u8, field_path, ".");

            while (path_iter.next()) |segment| {
                if (segment.len == 0) continue;

                switch (current) {
                    .object => |obj| {
                        if (obj.get(segment)) |value| {
                            current = value;
                        } else {
                            return storage.Value.Null;
                        }
                    },
                    .array => |arr| {
                        // Handle array index like $[0] or $.items[0]
                        const index = std.fmt.parseInt(usize, segment, 10) catch return storage.Value.Null;
                        if (index < arr.items.len) {
                            current = arr.items[index];
                        } else {
                            return storage.Value.Null;
                        }
                    },
                    else => return storage.Value.Null,
                }
            }

            // Convert final value to storage.Value
            return switch (current) {
                .string => |s| storage.Value{ .Text = try allocator.dupe(u8, s) },
                .integer => |i| storage.Value{ .Integer = i },
                .float => |f| storage.Value{ .Float = f },
                .bool => |b| storage.Value{ .Integer = if (b) 1 else 0 },
                .null => storage.Value.Null,
                else => storage.Value.Null, // Objects and arrays returned as NULL (use json() for full extraction)
            };
        }

        /// Set value in JSON at path
        pub fn jsonSet(allocator: std.mem.Allocator, json_text: []const u8, path: []const u8, new_value: []const u8) ![]u8 {
            // Parse existing JSON
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
                return error.InvalidJson;
            };
            defer parsed.deinit();

            // Parse the path
            const field_path = if (std.mem.startsWith(u8, path, "$."))
                path[2..]
            else if (std.mem.startsWith(u8, path, "$"))
                path[1..]
            else
                path;

            // Parse the new value as JSON
            const new_json_value = std.json.parseFromSlice(std.json.Value, allocator, new_value, .{}) catch blk: {
                // If not valid JSON, treat as string literal
                break :blk null;
            };
            defer if (new_json_value) |v| v.deinit();

            // Navigate to parent and set value
            var current = &parsed.value;
            var path_segments = std.ArrayList([]const u8).init(allocator);
            defer path_segments.deinit();

            var path_iter = std.mem.splitSequence(u8, field_path, ".");
            while (path_iter.next()) |segment| {
                if (segment.len > 0) {
                    try path_segments.append(segment);
                }
            }

            if (path_segments.items.len == 0) {
                return error.InvalidPath;
            }

            // Navigate to parent
            for (path_segments.items[0 .. path_segments.items.len - 1]) |segment| {
                switch (current.*) {
                    .object => |*obj| {
                        if (obj.getPtr(segment)) |ptr| {
                            current = ptr;
                        } else {
                            return error.PathNotFound;
                        }
                    },
                    else => return error.PathNotFound,
                }
            }

            // Set the value
            const final_key = path_segments.items[path_segments.items.len - 1];
            switch (current.*) {
                .object => |*obj| {
                    const value_to_set: std.json.Value = if (new_json_value) |v|
                        v.value
                    else
                        .{ .string = new_value };
                    try obj.put(final_key, value_to_set);
                },
                else => return error.PathNotFound,
            }

            // Serialize back to string
            var output = std.ArrayList(u8).init(allocator);
            errdefer output.deinit();
            try std.json.stringify(parsed.value, .{}, output.writer());
            return try output.toOwnedSlice();
        }

        /// Check if JSON is valid using std.json parser
        pub fn jsonValid(allocator: std.mem.Allocator, json_text: []const u8) bool {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
                return false;
            };
            parsed.deinit();
            return true;
        }

        /// Validate JSON and return detailed error info
        pub fn jsonValidateWithError(allocator: std.mem.Allocator, json_text: []const u8) JsonValidationResult {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch |err| {
                return JsonValidationResult{
                    .valid = false,
                    .error_message = @errorName(err),
                };
            };
            parsed.deinit();
            return JsonValidationResult{
                .valid = true,
                .error_message = null,
            };
        }

        /// Get JSON type as string (for json_type() function)
        pub fn jsonType(allocator: std.mem.Allocator, json_text: []const u8) ![]const u8 {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
                return error.InvalidJson;
            };
            defer parsed.deinit();

            return switch (parsed.value) {
                .object => "object",
                .array => "array",
                .string => "text",
                .integer, .float => "real",
                .bool => "true", // SQLite returns "true" or "false"
                .null => "null",
                else => "null",
            };
        }
    };

    pub const JsonValidationResult = struct {
        valid: bool,
        error_message: ?[]const u8,
    };

    // Helper functions
    fn getTableInfo(self: *Self, table_name: []const u8) ![]storage.Row {
        _ = table_name; // Remove unused variable warning

        // Return table schema information (simplified)
        var rows = std.ArrayList(storage.Row).init(self.allocator);

        // Example table info row: cid, name, type, notnull, dflt_value, pk
        const values = [_]storage.Value{
            storage.Value{ .Integer = 0 },
            storage.Value{ .Text = "id" },
            storage.Value{ .Text = "INTEGER" },
            storage.Value{ .Integer = 1 },
            storage.Value.Null,
            storage.Value{ .Integer = 1 },
        };

        try rows.append(storage.Row{ .values = try self.allocator.dupe(storage.Value, &values) });

        return try rows.toOwnedSlice();
    }

    fn getDatabaseList(self: *Self) ![]storage.Row {
        var rows = std.ArrayList(storage.Row).init(self.allocator);

        // Main database
        const main_values = [_]storage.Value{
            storage.Value{ .Integer = 0 },
            storage.Value{ .Text = "main" },
            storage.Value{ .Text = "" },
        };
        try rows.append(storage.Row{ .values = try self.allocator.dupe(storage.Value, &main_values) });

        // Attached databases
        var iterator = self.attached_databases.iterator();
        var seq: i64 = 1;
        while (iterator.next()) |entry| {
            const values = [_]storage.Value{
                storage.Value{ .Integer = seq },
                storage.Value{ .Text = entry.key_ptr.* },
                storage.Value{ .Text = entry.value_ptr.* },
            };
            try rows.append(storage.Row{ .values = try self.allocator.dupe(storage.Value, &values) });
            seq += 1;
        }

        return try rows.toOwnedSlice();
    }

    fn tokenizeText(self: *Self, text: []const u8) ![][]const u8 {
        var words = std.ArrayList([]const u8).init(self.allocator);
        var word_start: ?usize = null;

        for (text, 0..) |char, i| {
            const is_word_char = std.ascii.isAlphanumeric(char) or char == '_';

            if (is_word_char and word_start == null) {
                word_start = i;
            } else if (!is_word_char and word_start != null) {
                const word = try self.allocator.dupe(u8, text[word_start.?..i]);
                // Convert to lowercase for case-insensitive search
                for (word) |*c| {
                    c.* = std.ascii.toLower(c.*);
                }
                try words.append(word);
                word_start = null;
            }
        }

        // Handle word at end of text
        if (word_start) |start| {
            const word = try self.allocator.dupe(u8, text[start..]);
            for (word) |*c| {
                c.* = std.ascii.toLower(c.*);
            }
            try words.append(word);
        }

        return try words.toOwnedSlice();
    }

    pub fn deinit(self: *Self) void {
        // Free attached databases
        var db_iterator = self.attached_databases.iterator();
        while (db_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.attached_databases.deinit();

        // Free FTS indexes
        var fts_iterator = self.fts_indexes.iterator();
        while (fts_iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.fts_indexes.deinit();

        if (self.pragma_settings.journal_mode.len > 0) {
            self.allocator.free(self.pragma_settings.journal_mode);
        }
    }
};

const PragmaSettings = struct {
    page_size: u32,
    cache_size: i32,
    journal_mode: []const u8,
    foreign_keys: bool,

    pub fn default() PragmaSettings {
        return PragmaSettings{
            .page_size = 4096,
            .cache_size = -2000, // 2MB default
            .journal_mode = "DELETE",
            .foreign_keys = true, // SECURITY: Enable foreign key constraints by default
        };
    }

    /// Legacy defaults with foreign keys disabled (use only for backwards compatibility)
    pub fn legacyInsecureDefaults() PragmaSettings {
        return PragmaSettings{
            .page_size = 4096,
            .cache_size = -2000,
            .journal_mode = "DELETE",
            .foreign_keys = false, // WARNING: Foreign keys disabled - may cause data integrity issues
        };
    }
};

const FTSDocument = struct {
    rowid: u64,
    content: [][]const u8,
};

const FTSIndex = struct {
    table_name: []const u8,
    columns: [][]const u8,
    documents: std.hash_map.HashMap(u64, FTSDocument, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    inverted_index: std.hash_map.HashMap([]const u8, std.ArrayList(u64), std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    pub fn deinit(self: *FTSIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);

        for (self.columns) |column| {
            allocator.free(column);
        }
        allocator.free(self.columns);

        var doc_iterator = self.documents.iterator();
        while (doc_iterator.next()) |entry| {
            for (entry.value_ptr.content) |content| {
                allocator.free(content);
            }
            allocator.free(entry.value_ptr.content);
        }
        self.documents.deinit();

        var idx_iterator = self.inverted_index.iterator();
        while (idx_iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.inverted_index.deinit();
    }
};
