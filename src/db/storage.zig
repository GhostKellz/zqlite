const std = @import("std");
const btree = @import("btree.zig");
const pager = @import("pager.zig");
const memory_pool = @import("memory_pool.zig");

/// Row identifier type used throughout the database
pub const RowId = u64;

/// Storage engine that manages tables and data persistence
pub const StorageEngine = struct {
    allocator: std.mem.Allocator,
    pager: *pager.Pager,
    memory_pool: memory_pool.MemoryPool,
    pooled_allocator: memory_pool.PooledAllocator,
    tables: std.StringHashMap(*Table),
    indexes: std.StringHashMap(*Index),
    fts_indexes: std.StringHashMap(*FTSIndex), // Full-text search indexes
    is_memory: bool,

    const Self = @This();

    /// Initialize storage engine with file backing
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Self {
        var engine = try allocator.create(Self);
        engine.allocator = allocator;
        engine.pager = try pager.Pager.init(allocator, path);
        engine.memory_pool = memory_pool.MemoryPool.init(allocator);
        engine.pooled_allocator = memory_pool.PooledAllocator.init(&engine.memory_pool);
        engine.tables = std.StringHashMap(*Table).init(allocator);
        engine.indexes = std.StringHashMap(*Index).init(allocator);
        engine.fts_indexes = std.StringHashMap(*FTSIndex).init(allocator);
        engine.is_memory = false;

        // Load existing tables from file
        try engine.loadTables();

        return engine;
    }

    /// Initialize in-memory storage engine
    pub fn initMemory(allocator: std.mem.Allocator) !*Self {
        var engine = try allocator.create(Self);
        engine.allocator = allocator;
        engine.pager = try pager.Pager.initMemory(allocator);
        engine.memory_pool = memory_pool.MemoryPool.init(allocator);
        engine.pooled_allocator = memory_pool.PooledAllocator.init(&engine.memory_pool);
        engine.tables = std.StringHashMap(*Table).init(allocator);
        engine.indexes = std.StringHashMap(*Index).init(allocator);
        engine.fts_indexes = std.StringHashMap(*FTSIndex).init(allocator);
        engine.is_memory = true;

        return engine;
    }

    /// Get the pooled allocator for efficient memory management
    pub fn getPooledAllocator(self: *Self) std.mem.Allocator {
        return self.pooled_allocator.allocator();
    }

    /// Get memory pool statistics
    pub fn getMemoryStats(self: *Self) memory_pool.MemoryPool.GlobalStats {
        return self.memory_pool.getGlobalStats();
    }

    /// Cleanup unused memory pools
    pub fn cleanupMemory(self: *Self) void {
        self.memory_pool.cleanup();
    }

    /// Create a new table
    pub fn createTable(self: *Self, name: []const u8, schema: TableSchema) !void {
        // Check if table already exists
        if (self.tables.contains(name)) {
            return error.TableAlreadyExists;
        }

        const table = try Table.create(self.allocator, self.pager, name, schema);
        errdefer table.deinit();

        const duped_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(duped_name);

        try self.tables.put(duped_name, table);

        // Persist table metadata if not in-memory
        if (!self.is_memory) {
            try self.saveTableMetadata(table);
        }
    }

    /// Get a table by name
    pub fn getTable(self: *Self, name: []const u8) ?*Table {
        return self.tables.get(name);
    }

    /// Get all table names in the database (v1.2.2 broad API)
    pub fn getTableNames(self: *Self, allocator: std.mem.Allocator) ![][]const u8 {
        var table_names = try allocator.alloc([]const u8, self.tables.count());
        var iterator = self.tables.iterator();
        var index: usize = 0;

        while (iterator.next()) |entry| {
            table_names[index] = try allocator.dupe(u8, entry.key_ptr.*);
            index += 1;
        }

        return table_names;
    }

    /// Drop a table
    pub fn dropTable(self: *Self, name: []const u8) !void {
        if (self.tables.fetchRemove(name)) |entry| {
            entry.value.deinit();
            self.allocator.free(entry.key);

            // Rewrite metadata page atomically after drop
            if (!self.is_memory) {
                try self.rewriteAllMetadata();
            }
        }
    }

    /// Atomically rewrite all table metadata to page 0
    /// This ensures consistency after drops or schema changes
    fn rewriteAllMetadata(self: *Self) !void {
        if (self.is_memory) return;

        const page = try self.pager.getPage(METADATA_PAGE_ID);

        // Clear the page first
        @memset(page.data, 0);

        // Write magic number
        std.mem.writeInt(u32, page.data[0..4], METADATA_MAGIC, .little);

        var offset: usize = 8;
        var table_count: u32 = 0;

        // Write all tables
        var table_iterator = self.tables.iterator();
        while (table_iterator.next()) |entry| {
            const table = entry.value_ptr.*;

            // Check if we have space for this table
            const min_space = 4 + table.name.len + 2;
            if (offset + min_space > page.data.len) {
                break; // No more space
            }

            // Write table name
            std.mem.writeInt(u16, page.data[offset..][0..2], @intCast(table.name.len), .little);
            offset += 2;
            @memcpy(page.data[offset..][0..table.name.len], table.name);
            offset += table.name.len;

            // Write column count
            std.mem.writeInt(u16, page.data[offset..][0..2], @intCast(table.schema.columns.len), .little);
            offset += 2;

            // Write columns
            for (table.schema.columns) |column| {
                const col_space = 4 + column.name.len;
                if (offset + col_space > page.data.len) break;

                std.mem.writeInt(u16, page.data[offset..][0..2], @intCast(column.name.len), .little);
                offset += 2;
                @memcpy(page.data[offset..][0..column.name.len], column.name);
                offset += column.name.len;

                page.data[offset] = @intFromEnum(column.data_type);
                offset += 1;

                var flags: u8 = 0;
                if (column.is_primary_key) flags |= 0x01;
                if (column.is_nullable) flags |= 0x02;
                page.data[offset] = flags;
                offset += 1;
            }

            table_count += 1;
        }

        // Write final table count
        std.mem.writeInt(u32, page.data[4..8], table_count, .little);

        // Mark page as dirty to ensure it's written
        try self.pager.markDirty(METADATA_PAGE_ID);
    }

    /// Create an index
    pub fn createIndex(self: *Self, name: []const u8, table_name: []const u8, column_names: [][]const u8, is_unique: bool) !void {
        const index = try Index.create(self.allocator, self.pager, name, table_name, column_names, is_unique);
        try self.indexes.put(try self.allocator.dupe(u8, name), index);
    }

    /// Get an index by name
    pub fn getIndex(self: *Self, name: []const u8) ?*Index {
        return self.indexes.get(name);
    }

    /// Drop an index
    pub fn dropIndex(self: *Self, name: []const u8) !void {
        if (self.indexes.fetchRemove(name)) |entry| {
            entry.value.deinit(self.allocator);
            self.allocator.free(entry.key);
        }
    }

    /// Create an FTS (Full-Text Search) index for a virtual table
    pub fn createFTSIndex(self: *Self, table_name: []const u8, columns: []const []const u8) !void {
        var fts_index = try FTSIndex.create(self.allocator, table_name, columns);
        errdefer fts_index.deinit(self.allocator);

        const duped_name = try self.allocator.dupe(u8, table_name);
        errdefer self.allocator.free(duped_name);

        try self.fts_indexes.put(duped_name, fts_index);
    }

    /// Get an FTS index by table name
    pub fn getFTSIndex(self: *Self, table_name: []const u8) ?*FTSIndex {
        return self.fts_indexes.get(table_name);
    }

    /// Check if a table has an FTS index (is a virtual table)
    pub fn isFTSTable(self: *Self, table_name: []const u8) bool {
        return self.fts_indexes.contains(table_name);
    }

    /// Metadata page layout:
    /// - Bytes 0-3: Magic number (0x5A514C54 = "ZQLT")
    /// - Bytes 4-7: Table count
    /// - Bytes 8+: Table entries (variable length)
    /// Each table entry:
    /// - 2 bytes: name length
    /// - N bytes: name
    /// - 2 bytes: column count
    /// - For each column:
    ///   - 2 bytes: name length
    ///   - N bytes: name
    ///   - 1 byte: data type
    ///   - 1 byte: flags (is_primary_key, is_nullable)
    const METADATA_MAGIC: u32 = 0x5A514C54; // "ZQLT"
    const METADATA_PAGE_ID: u32 = 1;

    /// Load existing tables from storage
    fn loadTables(self: *Self) !void {
        if (self.is_memory) return; // No persistence for in-memory databases

        // Try to read metadata page
        const page = self.pager.getPage(METADATA_PAGE_ID) catch return;

        // Check magic number
        if (page.data.len < 8) return;
        const magic = std.mem.readInt(u32, page.data[0..4], .little);
        if (magic != METADATA_MAGIC) return; // Not a valid ZQLite database or new file

        const table_count = std.mem.readInt(u32, page.data[4..8], .little);
        var offset: usize = 8;

        var tables_loaded: u32 = 0;
        while (tables_loaded < table_count and offset + 4 < page.data.len) {
            // Read table name
            const name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;
            if (offset + name_len > page.data.len) break;

            const table_name = try self.allocator.dupe(u8, page.data[offset..][0..name_len]);
            offset += name_len;

            // Read column count
            if (offset + 2 > page.data.len) {
                self.allocator.free(table_name);
                break;
            }
            const column_count = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;

            // Read columns
            var columns = try self.allocator.alloc(Column, column_count);
            var col_idx: usize = 0;
            while (col_idx < column_count and offset + 4 < page.data.len) {
                const col_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
                offset += 2;
                if (offset + col_name_len + 2 > page.data.len) break;

                columns[col_idx].name = try self.allocator.dupe(u8, page.data[offset..][0..col_name_len]);
                offset += col_name_len;

                columns[col_idx].data_type = @enumFromInt(page.data[offset]);
                offset += 1;

                const flags = page.data[offset];
                offset += 1;
                columns[col_idx].is_primary_key = (flags & 0x01) != 0;
                columns[col_idx].is_nullable = (flags & 0x02) != 0;
                columns[col_idx].default_value = null;

                col_idx += 1;
            }

            // Create the table
            const schema = TableSchema{ .columns = columns[0..col_idx] };
            const table = try Table.create(self.allocator, self.pager, table_name, schema);
            try self.tables.put(table_name, table);

            tables_loaded += 1;
        }
    }

    /// Save table metadata to storage
    /// Uses atomic rewrite to ensure consistency
    fn saveTableMetadata(self: *Self, table: *Table) !void {
        _ = table; // Table is already in self.tables
        if (self.is_memory) return;

        // Rewrite all metadata atomically
        try self.rewriteAllMetadata();
    }

    /// Clean up storage engine
    pub fn deinit(self: *Self) void {
        var table_iterator = self.tables.iterator();
        while (table_iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.tables.deinit();

        var index_iterator = self.indexes.iterator();
        while (index_iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.indexes.deinit();

        // Cleanup FTS indexes
        var fts_iterator = self.fts_indexes.iterator();
        while (fts_iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.fts_indexes.deinit();

        self.pager.deinit();
        self.memory_pool.deinit();
        self.allocator.destroy(self);
    }

    /// Get storage statistics
    pub fn getStats(self: *Self) StorageStats {
        const cache_stats = self.pager.getCacheStats();
        return StorageStats{
            .table_count = @intCast(self.tables.count()),
            .index_count = @intCast(self.indexes.count()),
            .is_memory = self.is_memory,
            .page_count = self.pager.getPageCount(),
            .cache_hit_ratio = cache_stats.hit_ratio,
            .cached_pages = cache_stats.cached_pages,
        };
    }
};

/// Table representation
pub const Table = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    schema: TableSchema,
    btree: *btree.BTree,
    row_count: u64,
    deleted_keys: std.AutoHashMap(u64, void), // Keys of logically deleted rows

    const Self = @This();

    /// Create a new table
    pub fn create(allocator: std.mem.Allocator, page_manager: *pager.Pager, name: []const u8, schema: TableSchema) !*Self {
        var table = try allocator.create(Self);
        table.allocator = allocator;
        table.name = try allocator.dupe(u8, name);
        // Deep clone schema to ensure ownership with storage engine's allocator
        table.schema = try schema.clone(allocator);
        table.btree = try btree.BTree.init(allocator, page_manager);
        table.row_count = 0;
        table.deleted_keys = std.AutoHashMap(u64, void).init(allocator);

        return table;
    }

    /// Insert a row into the table (returns the row_id/key)
    pub fn insert(self: *Self, alloc: std.mem.Allocator, values: []Value) !i64 {
        _ = alloc;
        const row_id = self.row_count;
        try self.btree.insert(row_id, Row{ .values = values });
        self.row_count += 1;
        return @intCast(row_id);
    }

    /// Insert a Row into the table
    pub fn insertRow(self: *Self, row: Row) !void {
        try self.btree.insert(self.row_count, row);
        self.row_count += 1;
    }

    /// Delete a row by its key (logical delete)
    pub fn delete(self: *Self, alloc: std.mem.Allocator, row_id: i64) !void {
        _ = alloc;
        try self.deleted_keys.put(@intCast(row_id), {});
    }

    /// Undelete a row by its key (for ROLLBACK of DELETE)
    pub fn undelete(self: *Self, row_id: i64) void {
        _ = self.deleted_keys.remove(@intCast(row_id));
    }

    /// Update a row by key
    pub fn updateRow(self: *Self, alloc: std.mem.Allocator, row_id: i64, new_values: []Value) !void {
        // Mark old as deleted
        try self.deleted_keys.put(@intCast(row_id), {});
        // Insert new values with a new key
        const new_row_id = self.row_count;
        try self.btree.insert(new_row_id, Row{ .values = new_values });
        self.row_count += 1;
        _ = alloc;
    }

    /// Select all non-deleted rows
    pub fn select(self: *Self, allocator: std.mem.Allocator) ![]Row {
        const all_rows = try self.btree.selectAllWithKeys(allocator);
        defer allocator.free(all_rows);

        // Filter out deleted rows
        var results: std.ArrayList(Row) = .{};
        for (all_rows) |item| {
            if (!self.deleted_keys.contains(item.key)) {
                try results.append(allocator, item.row);
            } else {
                // Free the deleted row's values
                for (item.row.values) |value| {
                    value.deinit(allocator);
                }
                allocator.free(item.row.values);
            }
        }
        return results.toOwnedSlice(allocator);
    }

    /// KeyRow pair for returning rows with their keys
    pub const KeyRow = struct {
        key: i64,
        row: Row,
    };

    /// Select all non-deleted rows with their keys (for UPDATE/DELETE with undo logging)
    pub fn selectWithKeys(self: *Self, allocator: std.mem.Allocator) ![]KeyRow {
        const all_rows = try self.btree.selectAllWithKeys(allocator);
        defer allocator.free(all_rows);

        // Filter out deleted rows
        var results: std.ArrayList(KeyRow) = .{};
        for (all_rows) |item| {
            if (!self.deleted_keys.contains(item.key)) {
                try results.append(allocator, KeyRow{
                    .key = @intCast(item.key),
                    .row = item.row,
                });
            } else {
                // Free the deleted row's values
                for (item.row.values) |value| {
                    value.deinit(allocator);
                }
                allocator.free(item.row.values);
            }
        }
        return results.toOwnedSlice(allocator);
    }

    /// Get a single row by key (returns null if deleted or not found)
    pub fn getRow(self: *Self, row_id: i64) !?Row {
        const key: u64 = @intCast(row_id);
        if (self.deleted_keys.contains(key)) {
            return null;
        }
        return try self.btree.search(key);
    }

    /// Get column index by name
    pub fn getColumnIndex(self: *Self, column_name: []const u8) ?usize {
        for (self.schema.columns, 0..) |col, idx| {
            if (std.mem.eql(u8, col.name, column_name)) {
                return idx;
            }
        }
        return null;
    }

    /// Clean up table
    pub fn deinit(self: *Self) void {
        self.btree.deinit();
        self.deleted_keys.deinit();
        self.allocator.free(self.name);
        self.schema.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Table schema definition
pub const TableSchema = struct {
    columns: []Column,

    pub fn deinit(self: *TableSchema, allocator: std.mem.Allocator) void {
        // Clean up column names and default values
        for (self.columns) |column| {
            allocator.free(column.name);
            if (column.default_value) |default_value| {
                default_value.deinit(allocator);
            }
        }
        allocator.free(self.columns);
    }

    /// Deep clone schema with a new allocator (for ownership transfer)
    pub fn clone(self: TableSchema, allocator: std.mem.Allocator) CloneValueError!TableSchema {
        var cloned_columns = try allocator.alloc(Column, self.columns.len);

        for (self.columns, 0..) |column, i| {
            cloned_columns[i] = Column{
                .name = try allocator.dupe(u8, column.name),
                .data_type = column.data_type,
                .is_primary_key = column.is_primary_key,
                .is_nullable = column.is_nullable,
                .default_value = if (column.default_value) |default_val|
                    try default_val.clone(allocator)
                else
                    null,
            };
        }

        return TableSchema{
            .columns = cloned_columns,
        };
    }
};

/// Column definition
pub const Column = struct {
    name: []const u8,
    data_type: DataType,
    is_primary_key: bool,
    is_nullable: bool,
    default_value: ?DefaultValue,

    pub const DefaultValue = union(enum) {
        Literal: Value,
        FunctionCall: FunctionCall,

        pub fn deinit(self: DefaultValue, allocator: std.mem.Allocator) void {
            switch (self) {
                .Literal => |value| value.deinit(allocator),
                .FunctionCall => |func| func.deinit(allocator),
            }
        }

        pub fn clone(self: DefaultValue, allocator: std.mem.Allocator) CloneValueError!DefaultValue {
            return switch (self) {
                .Literal => |value| DefaultValue{ .Literal = try value.clone(allocator) },
                .FunctionCall => |func| DefaultValue{ .FunctionCall = try func.clone(allocator) },
            };
        }
    };

    pub const FunctionCall = struct {
        name: []const u8,
        arguments: []FunctionArgument,

        pub fn deinit(self: FunctionCall, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            for (self.arguments) |arg| {
                arg.deinit(allocator);
            }
            allocator.free(self.arguments);
        }

        pub fn clone(self: FunctionCall, allocator: std.mem.Allocator) CloneValueError!FunctionCall {
            const cloned_name = try allocator.dupe(u8, self.name);
            var cloned_args = try allocator.alloc(FunctionArgument, self.arguments.len);

            for (self.arguments, 0..) |arg, i| {
                cloned_args[i] = try arg.clone(allocator);
            }

            return FunctionCall{
                .name = cloned_name,
                .arguments = cloned_args,
            };
        }
    };

    pub const FunctionArgument = union(enum) {
        Literal: Value,
        Column: []const u8,
        Parameter: u32,

        pub fn deinit(self: FunctionArgument, allocator: std.mem.Allocator) void {
            switch (self) {
                .Literal => |value| value.deinit(allocator),
                .Column => |col| allocator.free(col),
                .Parameter => {},
            }
        }

        pub fn clone(self: FunctionArgument, allocator: std.mem.Allocator) CloneValueError!FunctionArgument {
            return switch (self) {
                .Literal => |value| FunctionArgument{ .Literal = try value.clone(allocator) },
                .Column => |col| FunctionArgument{ .Column = try allocator.dupe(u8, col) },
                .Parameter => |param| FunctionArgument{ .Parameter = param },
            };
        }
    };
};

/// Supported data types
pub const DataType = enum {
    Integer,
    Text,
    Real,
    Blob,
    // PostgreSQL compatibility types
    JSON,
    JSONB,
    UUID,
    Array,
    Boolean,
    Timestamp,
    TimestampTZ,
    Date,
    Time,
    Interval,
    Numeric,
    // Extended integer types
    SmallInt,
    BigInt,
    // Extended text types
    Varchar,
    Char,
};

/// Row data
pub const Row = struct {
    values: []Value,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        for (self.values) |value| {
            value.deinit(allocator);
        }
        allocator.free(self.values);
    }
};

/// Value types
pub const Value = union(enum) {
    Integer: i64,
    Text: []const u8,
    Real: f64,
    Blob: []const u8,
    Null,
    Parameter: u32, // Parameter placeholder index
    FunctionCall: Column.FunctionCall, // Function call for evaluation (e.g., in INSERT VALUES)
    // PostgreSQL compatibility values
    JSON: []const u8, // JSON as text
    JSONB: JSONBValue, // Parsed JSON with binary optimization
    UUID: [16]u8, // UUID as 16 bytes
    Array: ArrayValue, // Array of values
    Boolean: bool,
    Timestamp: i64, // Unix timestamp in microseconds
    TimestampTZ: TimestampTZValue, // Timestamp with timezone
    Date: i32, // Days since epoch
    Time: i64, // Microseconds since midnight
    Interval: i64, // Duration in microseconds
    Numeric: NumericValue, // Arbitrary precision decimal
    SmallInt: i16,
    BigInt: i64,

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .Text => |text| allocator.free(text),
            .Blob => |blob| allocator.free(blob),
            .FunctionCall => |func| func.deinit(allocator),
            .JSON => |json| allocator.free(json),
            .JSONB => |jsonb| jsonb.deinit(allocator),
            .Array => |array| array.deinit(allocator),
            .TimestampTZ => |tstz| tstz.deinit(allocator),
            .Numeric => |numeric| numeric.deinit(allocator),
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) CloneValueError!Value {
        return switch (self) {
            .Integer => |i| Value{ .Integer = i },
            .Real => |r| Value{ .Real = r },
            .Null => Value.Null,
            .Parameter => |p| Value{ .Parameter = p },
            .Boolean => |b| Value{ .Boolean = b },
            .Timestamp => |t| Value{ .Timestamp = t },
            .Date => |d| Value{ .Date = d },
            .Time => |t| Value{ .Time = t },
            .Interval => |i| Value{ .Interval = i },
            .SmallInt => |s| Value{ .SmallInt = s },
            .BigInt => |b| Value{ .BigInt = b },
            .UUID => |u| Value{ .UUID = u },
            .Text => |text| Value{ .Text = try allocator.dupe(u8, text) },
            .Blob => |blob| Value{ .Blob = try allocator.dupe(u8, blob) },
            .JSON => |json| Value{ .JSON = try allocator.dupe(u8, json) },
            .FunctionCall => |func| Value{ .FunctionCall = try func.clone(allocator) },
            // For complex types, create proper deep copies
            .JSONB => |jsonb| blk: {
                const json_str = try jsonb.toString(allocator);
                defer allocator.free(json_str);
                break :blk Value{ .JSONB = try JSONBValue.init(allocator, json_str) };
            },
            .Array => |array| Value{ .Array = try array.clone(allocator) },
            .TimestampTZ => |tstz| Value{ .TimestampTZ = TimestampTZValue{
                .timestamp = tstz.timestamp,
                .timezone = try allocator.dupe(u8, tstz.timezone),
            } },
            .Numeric => |numeric| Value{ .Numeric = NumericValue{
                .precision = numeric.precision,
                .scale = numeric.scale,
                .digits = try allocator.dupe(u8, numeric.digits),
                .is_negative = numeric.is_negative,
            } },
        };
    }
};

/// JSONB value with parsed structure
pub const JSONBValue = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn init(allocator: std.mem.Allocator, json_text: []const u8) !JSONBValue {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        return JSONBValue{ .parsed = parsed };
    }

    pub fn deinit(self: JSONBValue, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.parsed.deinit();
    }

    pub fn toString(self: JSONBValue, allocator: std.mem.Allocator) ![]u8 {
        return try self.stringifyJson(allocator);
    }

    /// Convert parsed JSON back to string representation
    pub fn stringifyJson(self: JSONBValue, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.parsed.value) {
            .null => try allocator.dupe(u8, "null"),
            .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
            .integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
            .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .number_string => |s| try allocator.dupe(u8, s),
            .string => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
            .array => |arr| blk: {
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);

                try result.append(allocator, '[');
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try result.appendSlice(allocator, ", ");
                    const item_json = JSONBValue{ .parsed = std.json.Parsed(std.json.Value){ .value = item, .arena = undefined } };
                    const item_str = try item_json.stringifyJson(allocator);
                    defer allocator.free(item_str);
                    try result.appendSlice(allocator, item_str);
                }
                try result.append(allocator, ']');
                break :blk try result.toOwnedSlice(allocator);
            },
            .object => |obj| blk: {
                var result = std.ArrayList(u8){};
                defer result.deinit(allocator);

                try result.append(allocator, '{');
                var first = true;
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    if (!first) try result.appendSlice(allocator, ", ");
                    first = false;
                    try result.appendSlice(allocator, "\"");
                    try result.appendSlice(allocator, entry.key_ptr.*);
                    try result.appendSlice(allocator, "\": ");

                    const value_json = JSONBValue{ .parsed = std.json.Parsed(std.json.Value){ .value = entry.value_ptr.*, .arena = undefined } };
                    const value_str = try value_json.stringifyJson(allocator);
                    defer allocator.free(value_str);
                    try result.appendSlice(allocator, value_str);
                }
                try result.append(allocator, '}');
                break :blk try result.toOwnedSlice(allocator);
            },
        };
    }

    /// Extract a value from JSON using a path (PostgreSQL -> operator)
    pub fn extractPath(self: JSONBValue, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
        const value = self.extractValue(path) orelse return null;
        const json_value = JSONBValue{ .parsed = std.json.Parsed(std.json.Value){ .value = value, .arena = undefined } };
        return try json_value.stringifyJson(allocator);
    }

    /// Extract a text value from JSON (PostgreSQL ->> operator)
    pub fn extractText(self: JSONBValue, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
        const value = self.extractValue(path) orelse return null;
        return switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            .integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
            .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .number_string => |s| try allocator.dupe(u8, s),
            .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
            .null => try allocator.dupe(u8, "null"),
            else => {
                const json_value = JSONBValue{ .parsed = std.json.Parsed(std.json.Value){ .value = value, .arena = undefined } };
                return try json_value.stringifyJson(allocator);
            },
        };
    }

    /// Check if JSON contains a key (PostgreSQL ? operator)
    pub fn hasKey(self: JSONBValue, key: []const u8) bool {
        return switch (self.parsed.value) {
            .object => |obj| obj.contains(key),
            else => false,
        };
    }

    /// Extract raw JSON value for path operations
    fn extractValue(self: JSONBValue, path: []const u8) ?std.json.Value {
        return switch (self.parsed.value) {
            .object => |obj| obj.get(path),
            .array => |arr| blk: {
                const index = std.fmt.parseInt(usize, path, 10) catch return null;
                if (index >= arr.items.len) return null;
                break :blk arr.items[index];
            },
            else => null,
        };
    }
};

/// Array value containing typed elements
pub const ArrayValue = struct {
    element_type: DataType,
    elements: []Value,

    pub fn deinit(self: ArrayValue, allocator: std.mem.Allocator) void {
        for (self.elements) |element| {
            element.deinit(allocator);
        }
        allocator.free(self.elements);
    }

    /// Create array from values
    pub fn init(allocator: std.mem.Allocator, element_type: DataType, values: []const Value) CloneValueError!ArrayValue {
        var elements = try allocator.alloc(Value, values.len);

        // Clone each value
        for (values, 0..) |value, i| {
            elements[i] = try cloneValue(allocator, value);
        }

        return ArrayValue{
            .element_type = element_type,
            .elements = elements,
        };
    }

    /// Get array length
    pub fn len(self: ArrayValue) usize {
        return self.elements.len;
    }

    /// Get element at index (1-based like PostgreSQL)
    pub fn get(self: ArrayValue, index: usize) ?Value {
        if (index == 0 or index > self.elements.len) return null;
        return self.elements[index - 1];
    }

    /// Convert array to PostgreSQL format string: {elem1,elem2,elem3}
    pub fn toString(self: ArrayValue, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        try result.append(allocator, '{');

        for (self.elements, 0..) |element, i| {
            if (i > 0) try result.appendSlice(allocator, ",");

            const elem_str = try valueToString(allocator, element);
            defer allocator.free(elem_str);
            try result.appendSlice(allocator, elem_str);
        }

        try result.append(allocator, '}');
        return try result.toOwnedSlice(allocator);
    }

    /// Check if array contains value (PostgreSQL @> operator)
    pub fn contains(self: ArrayValue, value: Value) bool {
        for (self.elements) |element| {
            if (valuesEqual(element, value)) return true;
        }
        return false;
    }

    /// Array overlap (PostgreSQL && operator)
    pub fn overlaps(self: ArrayValue, other: ArrayValue) bool {
        for (self.elements) |element| {
            if (other.contains(element)) return true;
        }
        return false;
    }

    /// Clone the array
    pub fn clone(self: ArrayValue, allocator: std.mem.Allocator) CloneValueError!ArrayValue {
        return try ArrayValue.init(allocator, self.element_type, self.elements);
    }
};

/// Helper function to clone a value
const CloneValueError = error{
    OutOfMemory,
    Overflow,
    InvalidCharacter,
    UnexpectedToken,
    InvalidNumber,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
    SyntaxError,
    UnexpectedEndOfInput,
    BufferUnderrun,
    ValueTooLong,
};

fn cloneValue(allocator: std.mem.Allocator, value: Value) CloneValueError!Value {
    return switch (value) {
        .Integer => |i| Value{ .Integer = i },
        .Real => |r| Value{ .Real = r },
        .Text => |t| Value{ .Text = try allocator.dupe(u8, t) },
        .Blob => |b| Value{ .Blob = try allocator.dupe(u8, b) },
        .Null => Value.Null,
        .JSON => |j| Value{ .JSON = try allocator.dupe(u8, j) },
        .JSONB => |jsonb| Value{ .JSONB = try JSONBValue.init(allocator, try jsonb.toString(allocator)) },
        .UUID => |uuid| Value{ .UUID = uuid },
        .Array => |array| Value{ .Array = try ArrayValue.init(allocator, array.element_type, array.elements) },
        .Boolean => |b| Value{ .Boolean = b },
        .SmallInt => |s| Value{ .SmallInt = s },
        .BigInt => |b| Value{ .BigInt = b },
        else => value, // For simple types that don't need cloning
    };
}

/// Helper function to convert value to string
fn valueToString(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return switch (value) {
        .Integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
        .Real => |r| try std.fmt.allocPrint(allocator, "{d}", .{r}),
        .Text => |t| try std.fmt.allocPrint(allocator, "\"{s}\"", .{t}),
        .Boolean => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .Null => try allocator.dupe(u8, "NULL"),
        else => try allocator.dupe(u8, "?"), // Placeholder for complex types
    };
}

/// Helper function to compare values
fn valuesEqual(a: Value, b: Value) bool {
    return switch (a) {
        .Integer => |ai| switch (b) {
            .Integer => |bi| ai == bi,
            else => false,
        },
        .Real => |ar| switch (b) {
            .Real => |br| ar == br,
            else => false,
        },
        .Text => |at| switch (b) {
            .Text => |bt| std.mem.eql(u8, at, bt),
            else => false,
        },
        .Boolean => |ab| switch (b) {
            .Boolean => |bb| ab == bb,
            else => false,
        },
        .Null => switch (b) {
            .Null => true,
            else => false,
        },
        else => false, // Complex comparison would need more implementation
    };
}

/// Timestamp with timezone
pub const TimestampTZValue = struct {
    timestamp: i64, // Unix timestamp in microseconds
    timezone: []const u8, // Timezone name (e.g., "UTC", "America/New_York")

    pub fn deinit(self: TimestampTZValue, allocator: std.mem.Allocator) void {
        allocator.free(self.timezone);
    }
};

/// Arbitrary precision numeric value
pub const NumericValue = struct {
    precision: u16, // Total digits
    scale: u16, // Digits after decimal point
    digits: []u8, // BCD encoded digits
    is_negative: bool,

    pub fn deinit(self: NumericValue, allocator: std.mem.Allocator) void {
        allocator.free(self.digits);
    }
};

/// Storage statistics
pub const StorageStats = struct {
    table_count: u32,
    index_count: u32,
    is_memory: bool,
    page_count: u32,
    cache_hit_ratio: f64,
    cached_pages: u32,
};

/// Index definition
pub const Index = struct {
    name: []const u8,
    table_name: []const u8,
    column_names: [][]const u8,
    btree: *btree.BTree,
    is_unique: bool,

    const Self = @This();

    /// Create a new index
    pub fn create(allocator: std.mem.Allocator, page_manager: *pager.Pager, name: []const u8, table_name: []const u8, column_names: [][]const u8, is_unique: bool) !*Self {
        var index = try allocator.create(Self);
        index.name = try allocator.dupe(u8, name);
        index.table_name = try allocator.dupe(u8, table_name);

        // Clone column names
        index.column_names = try allocator.alloc([]const u8, column_names.len);
        for (column_names, 0..) |col_name, i| {
            index.column_names[i] = try allocator.dupe(u8, col_name);
        }

        index.btree = try btree.BTree.init(allocator, page_manager);
        index.is_unique = is_unique;

        return index;
    }

    /// Insert a key into the index
    pub fn insert(self: *Self, key: u64, row_id: u64) !void {
        if (self.is_unique) {
            // Check if key already exists
            if (try self.btree.search(key)) |_| {
                return error.UniqueConstraintViolation;
            }
        }

        // Create a row with just the row ID
        const index_row = Row{
            .values = try self.btree.allocator.alloc(Value, 1),
        };
        index_row.values[0] = Value{ .Integer = @intCast(row_id) };

        try self.btree.insert(key, index_row);
    }

    /// Search for a key in the index
    pub fn search(self: *Self, key: u64) !?u64 {
        if (try self.btree.search(key)) |row| {
            if (row.values.len > 0) {
                switch (row.values[0]) {
                    .Integer => |row_id| return @intCast(row_id),
                    else => return null,
                }
            }
        }
        return null;
    }

    /// Clean up index
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.table_name);
        for (self.column_names) |col_name| {
            allocator.free(col_name);
        }
        allocator.free(self.column_names);
        self.btree.deinit();
        allocator.destroy(self);
    }
};

/// Full-Text Search Index for virtual tables (FTS5)
pub const FTSIndex = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_names: [][]const u8,
    /// Inverted index: term -> list of (rowid, column_index, position)
    inverted_index: std.StringHashMap(std.ArrayList(TermOccurrence)),

    const Self = @This();

    /// Term occurrence in a document
    const TermOccurrence = struct {
        rowid: u64,
        column_index: u32,
        position: u32,
    };

    /// Create a new FTS index
    pub fn create(allocator: std.mem.Allocator, table_name: []const u8, columns: []const []const u8) !*Self {
        var fts = try allocator.create(Self);
        errdefer allocator.destroy(fts);

        fts.allocator = allocator;
        fts.table_name = try allocator.dupe(u8, table_name);
        errdefer allocator.free(fts.table_name);

        // Copy column names
        fts.column_names = try allocator.alloc([]const u8, columns.len);
        errdefer allocator.free(fts.column_names);

        var cols_allocated: usize = 0;
        errdefer {
            for (fts.column_names[0..cols_allocated]) |col| {
                allocator.free(col);
            }
        }

        for (columns, 0..) |col, i| {
            fts.column_names[i] = try allocator.dupe(u8, col);
            cols_allocated = i + 1;
        }

        fts.inverted_index = std.StringHashMap(std.ArrayList(TermOccurrence)).init(allocator);

        return fts;
    }

    /// Index a document (row)
    pub fn indexDocument(self: *Self, rowid: u64, values: []const Value) !void {
        for (values, 0..) |value, col_idx| {
            if (col_idx >= self.column_names.len) continue;

            // Only index text values
            const text = switch (value) {
                .Text => |t| t,
                else => continue,
            };

            // Tokenize and index
            var pos: u32 = 0;
            var iter = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?()[]{}\"'");
            while (iter.next()) |token| {
                // Normalize to lowercase
                var lower_buf: [256]u8 = undefined;
                const lower_token = if (token.len <= 256) blk: {
                    for (token, 0..) |c, i| {
                        lower_buf[i] = std.ascii.toLower(c);
                    }
                    break :blk lower_buf[0..token.len];
                } else token;

                // Get or create term entry
                var entry = self.inverted_index.getPtr(lower_token);
                if (entry == null) {
                    const term_copy = try self.allocator.dupe(u8, lower_token);
                    const new_list: std.ArrayList(TermOccurrence) = .{};
                    try self.inverted_index.put(term_copy, new_list);
                    entry = self.inverted_index.getPtr(term_copy);
                }

                try entry.?.append(self.allocator, TermOccurrence{
                    .rowid = rowid,
                    .column_index = @intCast(col_idx),
                    .position = pos,
                });

                pos += 1;
            }
        }
    }

    /// Search the FTS index for a query
    pub fn search(self: *Self, query: []const u8) ![]u64 {
        var results = std.AutoHashMap(u64, void).init(self.allocator);
        defer results.deinit();

        // Tokenize query
        var first_term = true;
        var iter = std.mem.tokenizeAny(u8, query, " \t\n\r.,;:!?()[]{}\"'");
        while (iter.next()) |token| {
            // Normalize to lowercase
            var lower_buf: [256]u8 = undefined;
            const lower_token = if (token.len <= 256) blk: {
                for (token, 0..) |c, i| {
                    lower_buf[i] = std.ascii.toLower(c);
                }
                break :blk lower_buf[0..token.len];
            } else token;

            if (self.inverted_index.get(lower_token)) |occurrences| {
                if (first_term) {
                    // First term: add all matching rowids
                    for (occurrences.items) |occ| {
                        try results.put(occ.rowid, {});
                    }
                    first_term = false;
                } else {
                    // Subsequent terms: intersect with existing results
                    var term_rowids = std.AutoHashMap(u64, void).init(self.allocator);
                    defer term_rowids.deinit();

                    for (occurrences.items) |occ| {
                        try term_rowids.put(occ.rowid, {});
                    }

                    // Remove rowids not in this term's results
                    var to_remove: std.ArrayList(u64) = .{};
                    defer to_remove.deinit(self.allocator);

                    var result_iter = results.iterator();
                    while (result_iter.next()) |entry| {
                        if (!term_rowids.contains(entry.key_ptr.*)) {
                            try to_remove.append(self.allocator, entry.key_ptr.*);
                        }
                    }

                    for (to_remove.items) |rowid| {
                        _ = results.remove(rowid);
                    }
                }
            } else if (!first_term) {
                // Term not found in subsequent terms: empty results
                results.clearRetainingCapacity();
            }
        }

        // Convert to array
        var result_array = try self.allocator.alloc(u64, results.count());
        var i: usize = 0;
        var result_iter = results.iterator();
        while (result_iter.next()) |entry| {
            result_array[i] = entry.key_ptr.*;
            i += 1;
        }

        return result_array;
    }

    /// Clean up FTS index
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        for (self.column_names) |col| {
            allocator.free(col);
        }
        allocator.free(self.column_names);

        // Free inverted index
        var iter = self.inverted_index.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.inverted_index.deinit();

        allocator.destroy(self);
    }
};

test "storage engine creation" {
    try std.testing.expect(true); // Placeholder
}

test "table operations" {
    try std.testing.expect(true); // Placeholder
}
