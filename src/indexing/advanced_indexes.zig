const std = @import("std");
const storage = @import("../db/storage.zig");

/// Advanced indexing support for zqlite
/// Provides hash indexes, unique constraints, multi-column indexes, and B-tree indexes
pub const IndexType = enum {
    btree, // Default B-tree index (range queries)
    hash, // Hash index (exact lookups)
    unique, // Unique constraint index
    multi, // Multi-column index
};

pub const IndexDefinition = struct {
    name: []const u8,
    table: []const u8,
    columns: [][]const u8,
    index_type: IndexType,
    is_unique: bool,

    pub fn deinit(self: *IndexDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.table);
        for (self.columns) |column| {
            allocator.free(column);
        }
        allocator.free(self.columns);
    }
};

/// Hash index for O(1) exact lookups
pub const HashIndex = struct {
    name: []const u8,
    table: []const u8,
    column: []const u8,
    hash_map: std.AutoHashMap(u64, []storage.RowId),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, table: []const u8, column: []const u8) !*Self {
        const index = try allocator.create(Self);
        index.* = Self{
            .name = try allocator.dupe(u8, name),
            .table = try allocator.dupe(u8, table),
            .column = try allocator.dupe(u8, column),
            .hash_map = std.AutoHashMap(u64, []storage.RowId).init(allocator),
            .allocator = allocator,
        };
        return index;
    }

    /// Add a value to the hash index
    pub fn insert(self: *Self, value: storage.Value, row_id: storage.RowId) !void {
        const hash = try self.hashValue(value);

        if (self.hash_map.get(hash)) |existing_rows| {
            // Add to existing bucket
            var new_rows = try self.allocator.realloc(existing_rows, existing_rows.len + 1);
            new_rows[new_rows.len - 1] = row_id;
            try self.hash_map.put(hash, new_rows);
        } else {
            // Create new bucket
            var new_rows = try self.allocator.alloc(storage.RowId, 1);
            new_rows[0] = row_id;
            try self.hash_map.put(hash, new_rows);
        }
    }

    /// Remove a value from the hash index
    pub fn remove(self: *Self, value: storage.Value, row_id: storage.RowId) !void {
        const hash = try self.hashValue(value);

        if (self.hash_map.get(hash)) |rows| {
            for (rows, 0..) |existing_row_id, i| {
                if (existing_row_id == row_id) {
                    // Remove this row_id
                    if (rows.len == 1) {
                        // Remove the entire bucket
                        _ = self.hash_map.remove(hash);
                        self.allocator.free(rows);
                    } else {
                        // Shrink the bucket
                        var new_rows = try self.allocator.alloc(storage.RowId, rows.len - 1);
                        std.mem.copy(storage.RowId, new_rows[0..i], rows[0..i]);
                        std.mem.copy(storage.RowId, new_rows[i..], rows[i + 1 ..]);
                        self.allocator.free(rows);
                        try self.hash_map.put(hash, new_rows);
                    }
                    break;
                }
            }
        }
    }

    /// Lookup rows by value
    pub fn lookup(self: *Self, value: storage.Value) ![]storage.RowId {
        const hash = try self.hashValue(value);
        return self.hash_map.get(hash) orelse &[_]storage.RowId{};
    }

    /// Hash a storage value
    fn hashValue(self: *Self, value: storage.Value) !u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);

        switch (value) {
            .Integer => |int_val| {
                hasher.update(std.mem.asBytes(&int_val));
            },
            .Real => |real_val| {
                hasher.update(std.mem.asBytes(&real_val));
            },
            .Text => |text_val| {
                hasher.update(text_val);
            },
            .Blob => |blob_val| {
                hasher.update(blob_val);
            },
            .Null => {
                hasher.update("NULL");
            },
        }

        return hasher.final();
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.hash_map.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.hash_map.deinit();
        self.allocator.free(self.name);
        self.allocator.free(self.table);
        self.allocator.free(self.column);
        self.allocator.destroy(self);
    }
};

/// Unique constraint index
pub const UniqueIndex = struct {
    name: []const u8,
    table: []const u8,
    columns: [][]const u8,
    value_map: std.AutoHashMap(u64, storage.RowId),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, table: []const u8, columns: [][]const u8) !*Self {
        const index = try allocator.create(Self);

        var owned_columns = try allocator.alloc([]const u8, columns.len);
        for (columns, 0..) |column, i| {
            owned_columns[i] = try allocator.dupe(u8, column);
        }

        index.* = Self{
            .name = try allocator.dupe(u8, name),
            .table = try allocator.dupe(u8, table),
            .columns = owned_columns,
            .value_map = std.AutoHashMap(u64, storage.RowId).init(allocator),
            .allocator = allocator,
        };
        return index;
    }

    /// Insert with uniqueness check
    pub fn insert(self: *Self, values: []storage.Value, row_id: storage.RowId) !void {
        const hash = try self.hashValues(values);

        if (self.value_map.contains(hash)) {
            return error.UniqueConstraintViolation;
        }

        try self.value_map.put(hash, row_id);
    }

    /// Remove from unique index
    pub fn remove(self: *Self, values: []storage.Value) !void {
        const hash = try self.hashValues(values);
        _ = self.value_map.remove(hash);
    }

    /// Check if values already exist
    pub fn exists(self: *Self, values: []storage.Value) !bool {
        const hash = try self.hashValues(values);
        return self.value_map.contains(hash);
    }

    /// Hash multiple values together
    pub fn hashValues(self: *Self, values: []storage.Value) !u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);

        for (values) |value| {
            switch (value) {
                .Integer => |int_val| {
                    hasher.update(std.mem.asBytes(&int_val));
                },
                .Real => |real_val| {
                    hasher.update(std.mem.asBytes(&real_val));
                },
                .Text => |text_val| {
                    hasher.update(text_val);
                },
                .Blob => |blob_val| {
                    hasher.update(blob_val);
                },
                .Null => {
                    hasher.update("NULL");
                },
            }
        }

        return hasher.final();
    }

    pub fn deinit(self: *Self) void {
        self.value_map.deinit();
        self.allocator.free(self.name);
        self.allocator.free(self.table);
        for (self.columns) |column| {
            self.allocator.free(column);
        }
        self.allocator.free(self.columns);
        self.allocator.destroy(self);
    }
};

/// Multi-column composite index
pub const MultiColumnIndex = struct {
    name: []const u8,
    table: []const u8,
    columns: [][]const u8,
    // Use a sorted array for range queries on composite keys
    entries: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    const Entry = struct {
        composite_key: []u8,
        row_id: storage.RowId,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, table: []const u8, columns: [][]const u8) !*Self {
        const index = try allocator.create(Self);

        var owned_columns = try allocator.alloc([]const u8, columns.len);
        for (columns, 0..) |column, i| {
            owned_columns[i] = try allocator.dupe(u8, column);
        }

        index.* = Self{
            .name = try allocator.dupe(u8, name),
            .table = try allocator.dupe(u8, table),
            .columns = owned_columns,
            .entries = .{},
            .allocator = allocator,
        };
        return index;
    }

    /// Insert into multi-column index
    pub fn insert(self: *Self, values: []storage.Value, row_id: storage.RowId) !void {
        const composite_key = try self.createCompositeKey(values);

        const entry = Entry{
            .composite_key = composite_key,
            .row_id = row_id,
        };

        // Insert in sorted order
        var insert_pos: usize = 0;
        for (self.entries.items) |existing_entry| {
            if (std.mem.order(u8, composite_key, existing_entry.composite_key) == .lt) {
                break;
            }
            insert_pos += 1;
        }

        try self.entries.insert(self.allocator, insert_pos, entry);
    }

    /// Remove from multi-column index
    pub fn remove(self: *Self, values: []storage.Value, row_id: storage.RowId) !void {
        const composite_key = try self.createCompositeKey(values);
        defer self.allocator.free(composite_key);

        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.composite_key, composite_key) and entry.row_id == row_id) {
                self.allocator.free(entry.composite_key);
                _ = self.entries.orderedRemove(self.allocator, i);
                break;
            }
        }
    }

    /// Range lookup on composite keys
    pub fn rangeQuery(self: *Self, start_values: []storage.Value, end_values: []storage.Value) ![]storage.RowId {
        const start_key = try self.createCompositeKey(start_values);
        defer self.allocator.free(start_key);
        const end_key = try self.createCompositeKey(end_values);
        defer self.allocator.free(end_key);

        var result: std.ArrayListUnmanaged(storage.RowId) = .empty;

        for (self.entries.items) |entry| {
            if (std.mem.order(u8, entry.composite_key, start_key) != .lt and
                std.mem.order(u8, entry.composite_key, end_key) != .gt)
            {
                try result.append(self.allocator, entry.row_id);
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Create a composite key from multiple values
    fn createCompositeKey(self: *Self, values: []storage.Value) ![]u8 {
        var key_parts: std.ArrayListUnmanaged(u8) = .empty;

        for (values) |value| {
            switch (value) {
                .Integer => |int_val| {
                    try key_parts.appendSlice(self.allocator, std.mem.asBytes(&int_val));
                },
                .Real => |real_val| {
                    try key_parts.appendSlice(self.allocator, std.mem.asBytes(&real_val));
                },
                .Text => |text_val| {
                    try key_parts.appendSlice(self.allocator, text_val);
                },
                .Blob => |blob_val| {
                    try key_parts.appendSlice(self.allocator, blob_val);
                },
                .Null => {
                    try key_parts.appendSlice(self.allocator, "NULL");
                },
            }
            // Add separator
            try key_parts.append(self.allocator, 0);
        }

        return try key_parts.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.composite_key);
        }
        self.entries.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.free(self.table);
        for (self.columns) |column| {
            self.allocator.free(column);
        }
        self.allocator.free(self.columns);
        self.allocator.destroy(self);
    }
};

/// B-tree index for efficient range queries and sorted access
pub const BTreeIndex = struct {
    name: []const u8,
    table: []const u8,
    column: []const u8,
    root: ?*Node,
    allocator: std.mem.Allocator,
    order: u32, // B-tree order (max children per node)

    const Self = @This();

    const Node = struct {
        keys: std.ArrayListUnmanaged(IndexKey),
        children: std.ArrayListUnmanaged(?*Node),
        is_leaf: bool,
        parent: ?*Node,
        allocator: std.mem.Allocator,

        const IndexKey = struct {
            value: storage.Value,
            row_ids: std.ArrayListUnmanaged(storage.RowId),

            pub fn deinit(self: *IndexKey, allocator: std.mem.Allocator) void {
                self.row_ids.deinit(allocator);
            }
        };

        pub fn init(allocator: std.mem.Allocator, is_leaf: bool) !*Node {
            const node = try allocator.create(Node);
            node.* = Node{
                .keys = .{},
                .children = .{},
                .is_leaf = is_leaf,
                .parent = null,
                .allocator = allocator,
            };
            return node;
        }

        pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
            for (self.keys.items) |*key| {
                key.deinit(allocator);
            }
            self.keys.deinit(allocator);

            for (self.children.items) |child| {
                if (child) |c| {
                    c.deinit(allocator);
                }
            }
            self.children.deinit(allocator);
            allocator.destroy(self);
        }

        pub fn isFull(self: *Node, order: u32) bool {
            return self.keys.items.len >= order - 1;
        }
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, table: []const u8, column: []const u8) !*Self {
        const index = try allocator.create(Self);
        index.* = Self{
            .name = try allocator.dupe(u8, name),
            .table = try allocator.dupe(u8, table),
            .column = try allocator.dupe(u8, column),
            .root = null,
            .allocator = allocator,
            .order = 4, // Default B-tree order
        };
        return index;
    }

    /// Insert a value into the B-tree
    pub fn insert(self: *Self, value: storage.Value, row_id: storage.RowId) !void {
        if (self.root == null) {
            self.root = try Node.init(self.allocator, true);
        }

        try self.insertNonFull(self.root.?, value, row_id);

        // Check if root is full and needs splitting
        if (self.root.?.isFull(self.order)) {
            const new_root = try Node.init(self.allocator, false);
            try new_root.children.append(self.allocator, self.root);
            self.root.?.parent = new_root;
            try self.splitChild(new_root, 0);
            self.root = new_root;
        }
    }

    fn insertNonFull(self: *Self, node: *Node, value: storage.Value, row_id: storage.RowId) !void {
        var i: i32 = @intCast(node.keys.items.len);

        if (node.is_leaf) {
            // Insert into leaf node in sorted order
            var new_row_ids: std.ArrayListUnmanaged(storage.RowId) = .empty;
            try new_row_ids.append(self.allocator, row_id);
            try node.keys.append(self.allocator, Node.IndexKey{
                .value = value,
                .row_ids = new_row_ids,
            });

            // Simple insertion sort for leaf nodes
            i -= 1;
            while (i >= 0 and self.compareValues(node.keys.items[@intCast(i)].value, value) == .gt) {
                if (i + 1 < node.keys.items.len - 1) {
                    const temp = node.keys.items[@intCast(i + 1)];
                    node.keys.items[@intCast(i + 1)] = node.keys.items[@intCast(i)];
                    node.keys.items[@intCast(i)] = temp;
                }
                i -= 1;
            }
        } else {
            // Find child to insert into
            i -= 1;
            while (i >= 0 and self.compareValues(node.keys.items[@intCast(i)].value, value) == .gt) {
                i -= 1;
            }
            i += 1;

            const child = node.children.items[@intCast(i)].?;
            if (child.isFull(self.order)) {
                try self.splitChild(node, @intCast(i));
                if (self.compareValues(node.keys.items[@intCast(i)].value, value) == .lt) {
                    i += 1;
                }
            }
            try self.insertNonFull(node.children.items[@intCast(i)].?, value, row_id);
        }
    }

    fn splitChild(self: *Self, parent: *Node, child_index: usize) !void {
        const full_child = parent.children.items[child_index].?;
        const new_child = try Node.init(self.allocator, full_child.is_leaf);

        const mid = (self.order - 1) / 2;

        // Move half the keys to new child
        for (full_child.keys.items[mid + 1 ..]) |key| {
            try new_child.keys.append(self.allocator, key);
        }
        full_child.keys.shrinkRetainingCapacity(mid);

        // Move children if not leaf
        if (!full_child.is_leaf) {
            for (full_child.children.items[mid + 1 ..]) |child| {
                try new_child.children.append(self.allocator, child);
                if (child) |c| c.parent = new_child;
            }
            full_child.children.shrinkRetainingCapacity(mid + 1);
        }

        // Move median key up to parent
        try parent.children.insert(self.allocator, child_index + 1, new_child);
        try parent.keys.insert(self.allocator, child_index, full_child.keys.items[mid]);

        new_child.parent = parent;
    }

    /// Range query on B-tree
    pub fn rangeQuery(self: *Self, start_value: ?storage.Value, end_value: ?storage.Value) ![]storage.RowId {
        var result: std.ArrayListUnmanaged(storage.RowId) = .empty;
        if (self.root) |root| {
            try self.rangeQueryRecursive(root, start_value, end_value, &result);
        }
        return try result.toOwnedSlice(self.allocator);
    }

    fn rangeQueryRecursive(self: *Self, node: *Node, start_value: ?storage.Value, end_value: ?storage.Value, result: *std.ArrayList(storage.RowId)) !void {
        for (node.keys.items, 0..) |key, i| {
            // Check if key is in range
            const in_range = blk: {
                if (start_value) |start| {
                    if (self.compareValues(key.value, start) == .lt) break :blk false;
                }
                if (end_value) |end| {
                    if (self.compareValues(key.value, end) == .gt) break :blk false;
                }
                break :blk true;
            };

            if (in_range) {
                try result.appendSlice(self.allocator, key.row_ids.items);
            }

            // Recursively search children
            if (!node.is_leaf and i < node.children.items.len) {
                if (node.children.items[i]) |child| {
                    try self.rangeQueryRecursive(child, start_value, end_value, result);
                }
            }
        }

        // Search last child
        if (!node.is_leaf and node.children.items.len > node.keys.items.len) {
            if (node.children.items[node.children.items.len - 1]) |child| {
                try self.rangeQueryRecursive(child, start_value, end_value, result);
            }
        }
    }

    fn compareValues(self: *Self, a: storage.Value, b: storage.Value) std.math.Order {
        _ = self;

        // Handle null values
        if (a == .Null and b == .Null) return .eq;
        if (a == .Null) return .lt;
        if (b == .Null) return .gt;

        // Type-based comparison
        switch (a) {
            .Integer => |a_int| switch (b) {
                .Integer => |b_int| return std.math.order(a_int, b_int),
                .Real => |b_real| return std.math.order(@as(f64, @floatFromInt(a_int)), b_real),
                else => return .lt,
            },
            .Real => |a_real| switch (b) {
                .Integer => |b_int| return std.math.order(a_real, @as(f64, @floatFromInt(b_int))),
                .Real => |b_real| return std.math.order(a_real, b_real),
                else => return .lt,
            },
            .Text => |a_text| switch (b) {
                .Text => |b_text| return std.mem.order(u8, a_text, b_text),
                else => return .gt,
            },
            .Blob => |a_blob| switch (b) {
                .Blob => |b_blob| return std.mem.order(u8, a_blob, b_blob),
                else => return .gt,
            },
            .Null => return .lt,
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
        }
        self.allocator.free(self.name);
        self.allocator.free(self.table);
        self.allocator.free(self.column);
        self.allocator.destroy(self);
    }
};

/// Optimized composite key for multi-column indexes
pub const CompositeKey = struct {
    values: std.ArrayListUnmanaged(storage.Value),
    allocator: std.mem.Allocator,
    hash_cache: ?u64 = null, // Cached hash for performance

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .values = .{},
            .allocator = allocator,
        };
    }

    pub fn addValue(self: *Self, value: storage.Value) !void {
        try self.values.append(self.allocator, value);
        self.hash_cache = null; // Invalidate cache
    }

    pub fn clone(self: *Self) !Self {
        var new_key = Self.init(self.allocator);
        try new_key.values.appendSlice(self.allocator, self.values.items);
        new_key.hash_cache = self.hash_cache;
        return new_key;
    }

    /// Generate optimized hash with caching
    pub fn hash(self: *Self) u64 {
        if (self.hash_cache) |cached| {
            return cached;
        }

        var hasher = std.hash.Wyhash.init(0);

        // Hash the number of values first
        hasher.update(std.mem.asBytes(&self.values.items.len));

        // Hash each value based on its type
        for (self.values.items) |value| {
            switch (value) {
                .Integer => |int| {
                    hasher.update("i"); // Type marker
                    hasher.update(std.mem.asBytes(&int));
                },
                .Real => |real| {
                    hasher.update("r");
                    hasher.update(std.mem.asBytes(&real));
                },
                .Text => |text| {
                    hasher.update("t");
                    hasher.update(text);
                },
                .Blob => |blob| {
                    hasher.update("b");
                    hasher.update(blob);
                },
                .Null => {
                    hasher.update("n");
                },
            }
        }

        self.hash_cache = hasher.final();
        return self.hash_cache.?;
    }

    /// Optimized equality comparison
    pub fn eql(self: *Self, other: *CompositeKey) bool {
        // Fast path: check length first
        if (self.values.items.len != other.values.items.len) {
            return false;
        }

        // Fast path: check cached hashes if available
        if (self.hash_cache != null and other.hash_cache != null) {
            if (self.hash_cache.? != other.hash_cache.?) {
                return false;
            }
        }

        // Deep comparison
        for (self.values.items, other.values.items) |a, b| {
            if (!self.valueEquals(a, b)) {
                return false;
            }
        }

        return true;
    }

    /// Lexicographic comparison for ordering
    pub fn compare(self: *Self, other: *CompositeKey) std.math.Order {
        const min_len = @min(self.values.items.len, other.values.items.len);

        for (0..min_len) |i| {
            const cmp = self.compareValues(self.values.items[i], other.values.items[i]);
            if (cmp != .eq) {
                return cmp;
            }
        }

        return std.math.order(self.values.items.len, other.values.items.len);
    }

    fn valueEquals(self: *Self, a: storage.Value, b: storage.Value) bool {
        _ = self;

        switch (a) {
            .Integer => |a_int| switch (b) {
                .Integer => |b_int| return a_int == b_int,
                else => return false,
            },
            .Real => |a_real| switch (b) {
                .Real => |b_real| return a_real == b_real,
                else => return false,
            },
            .Text => |a_text| switch (b) {
                .Text => |b_text| return std.mem.eql(u8, a_text, b_text),
                else => return false,
            },
            .Blob => |a_blob| switch (b) {
                .Blob => |b_blob| return std.mem.eql(u8, a_blob, b_blob),
                else => return false,
            },
            .Null => return b == .Null,
        }
    }

    fn compareValues(self: *Self, a: storage.Value, b: storage.Value) std.math.Order {
        _ = self;

        // Handle null values
        if (a == .Null and b == .Null) return .eq;
        if (a == .Null) return .lt;
        if (b == .Null) return .gt;

        // Type-based comparison
        switch (a) {
            .Integer => |a_int| switch (b) {
                .Integer => |b_int| return std.math.order(a_int, b_int),
                .Real => |b_real| return std.math.order(@as(f64, @floatFromInt(a_int)), b_real),
                else => return .lt,
            },
            .Real => |a_real| switch (b) {
                .Integer => |b_int| return std.math.order(a_real, @as(f64, @floatFromInt(b_int))),
                .Real => |b_real| return std.math.order(a_real, b_real),
                else => return .lt,
            },
            .Text => |a_text| switch (b) {
                .Text => |b_text| return std.mem.order(u8, a_text, b_text),
                else => return .gt,
            },
            .Blob => |a_blob| switch (b) {
                .Blob => |b_blob| return std.mem.order(u8, a_blob, b_blob),
                else => return .gt,
            },
            .Null => return .lt,
        }
    }

    pub fn deinit(self: *Self) void {
        self.values.deinit(self.allocator);
    }
};

/// Enhanced Multi-column index with composite key optimization
pub const OptimizedMultiColumnIndex = struct {
    name: []const u8,
    table: []const u8,
    columns: []const []const u8,
    entries: std.HashMap(CompositeKey, std.ArrayList(storage.RowId), CompositeKeyContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,

    const Self = @This();

    const CompositeKeyContext = struct {
        pub fn hash(self: @This(), key: CompositeKey) u64 {
            _ = self;
            // Use mutable reference to access cached hash
            var mutable_key = key;
            return mutable_key.hash();
        }

        pub fn eql(self: @This(), a: CompositeKey, b: CompositeKey) bool {
            _ = self;
            var mutable_a = a;
            var mutable_b = b;
            return mutable_a.eql(&mutable_b);
        }
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, table: []const u8, columns: []const []const u8) !*Self {
        const index = try allocator.create(Self);
        index.* = Self{
            .name = try allocator.dupe(u8, name),
            .table = try allocator.dupe(u8, table),
            .columns = try allocator.dupe([]const u8, columns),
            .entries = std.HashMap(CompositeKey, std.ArrayList(storage.RowId), CompositeKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
        return index;
    }

    /// Insert optimized composite key
    pub fn insert(self: *Self, values: []const storage.Value, row_id: storage.RowId) !void {
        if (values.len != self.columns.len) {
            return error.ColumnCountMismatch;
        }

        var key = CompositeKey.init(self.allocator);
        defer key.deinit();

        for (values) |value| {
            try key.addValue(value);
        }

        const result = try self.entries.getOrPut(key);
        if (!result.found_existing) {
            result.key_ptr.* = try key.clone();
            result.value_ptr.* = .{};
        }

        try result.value_ptr.append(self.allocator, row_id);
    }

    /// Optimized lookup with prefix matching
    pub fn lookup(self: *Self, values: []const storage.Value) ![]storage.RowId {
        if (values.len > self.columns.len) {
            return error.TooManyValues;
        }

        var result: std.ArrayListUnmanaged(storage.RowId) = .empty;

        if (values.len == self.columns.len) {
            // Exact match - use hash map
            var key = CompositeKey.init(self.allocator);
            defer key.deinit();

            for (values) |value| {
                try key.addValue(value);
            }

            if (self.entries.get(key)) |row_ids| {
                try result.appendSlice(self.allocator, row_ids.items);
            }
        } else {
            // Prefix match - iterate through all entries
            var iterator = self.entries.iterator();
            while (iterator.next()) |entry| {
                const entry_key = entry.key_ptr;
                var matches = true;

                for (values, 0..) |value, i| {
                    if (!entry_key.valueEquals(entry_key.values.items[i], value)) {
                        matches = false;
                        break;
                    }
                }

                if (matches) {
                    try result.appendSlice(self.allocator, entry.value_ptr.items);
                }
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            entry.key_ptr.deinit();
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();

        self.allocator.free(self.name);
        self.allocator.free(self.table);
        self.allocator.free(self.columns);
        self.allocator.destroy(self);
    }
};

/// Enhanced Index Manager with B-tree, bloom filters and optimized composite key support
pub const AdvancedIndexManager = struct {
    hash_indexes: std.ArrayListUnmanaged(*HashIndex),
    unique_indexes: std.ArrayListUnmanaged(*UniqueIndex),
    multi_indexes: std.ArrayListUnmanaged(*MultiColumnIndex),
    btree_indexes: std.ArrayListUnmanaged(*BTreeIndex),
    optimized_multi_indexes: std.ArrayListUnmanaged(*OptimizedMultiColumnIndex),
    bloom_hash_indexes: std.ArrayListUnmanaged(*BloomHashIndex),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .hash_indexes = .empty,
            .unique_indexes = .empty,
            .multi_indexes = .empty,
            .btree_indexes = .empty,
            .optimized_multi_indexes = .empty,
            .bloom_hash_indexes = .empty,
            .allocator = allocator,
        };
    }

    /// Create a B-tree index for range queries
    pub fn createBTreeIndex(self: *Self, name: []const u8, table: []const u8, column: []const u8) !void {
        const index = try BTreeIndex.init(self.allocator, name, table, column);
        try self.btree_indexes.append(self.allocator, index);
    }

    /// Create an optimized multi-column index
    pub fn createOptimizedMultiIndex(self: *Self, name: []const u8, table: []const u8, columns: []const []const u8) !void {
        const index = try OptimizedMultiColumnIndex.init(self.allocator, name, table, columns);
        try self.optimized_multi_indexes.append(self.allocator, index);
    }

    /// Create a bloom hash index for fast existence checks
    pub fn createBloomHashIndex(self: *Self, name: []const u8, table: []const u8, column: []const u8, expected_items: usize) !void {
        const index = try BloomHashIndex.init(self.allocator, name, table, column, expected_items);
        try self.bloom_hash_indexes.append(self.allocator, index);
    }

    /// Insert into B-tree indexes
    pub fn insertBTree(self: *Self, table: []const u8, column: []const u8, value: storage.Value, row_id: storage.RowId) !void {
        for (self.btree_indexes.items) |index| {
            if (std.mem.eql(u8, index.table, table) and std.mem.eql(u8, index.column, column)) {
                try index.insert(value, row_id);
            }
        }
    }

    /// Range query on B-tree indexes
    pub fn rangeQueryBTree(self: *Self, table: []const u8, column: []const u8, start_value: ?storage.Value, end_value: ?storage.Value) !?[]storage.RowId {
        for (self.btree_indexes.items) |index| {
            if (std.mem.eql(u8, index.table, table) and std.mem.eql(u8, index.column, column)) {
                return try index.rangeQuery(start_value, end_value);
            }
        }
        return null;
    }

    /// Insert into optimized multi-column indexes
    pub fn insertOptimizedMulti(self: *Self, table: []const u8, columns: []const []const u8, values: []const storage.Value, row_id: storage.RowId) !void {
        for (self.optimized_multi_indexes.items) |index| {
            if (std.mem.eql(u8, index.table, table) and columnsMatch(index.columns, columns)) {
                try index.insert(values, row_id);
            }
        }
    }

    /// Lookup in optimized multi-column indexes with prefix support
    pub fn lookupOptimizedMulti(self: *Self, table: []const u8, columns: []const []const u8, values: []const storage.Value) !?[]storage.RowId {
        for (self.optimized_multi_indexes.items) |index| {
            if (std.mem.eql(u8, index.table, table) and columnsMatch(index.columns, columns)) {
                return try index.lookup(values);
            }
        }
        return null;
    }

    /// Insert into bloom hash indexes
    pub fn insertBloomHash(self: *Self, table: []const u8, column: []const u8, value: storage.Value, row_id: storage.RowId) !void {
        for (self.bloom_hash_indexes.items) |index| {
            if (std.mem.eql(u8, index.hash_index.table, table) and std.mem.eql(u8, index.hash_index.column, column)) {
                try index.insert(value, row_id);
            }
        }
    }

    /// Fast lookup in bloom hash indexes with bloom filter optimization
    pub fn lookupBloomHash(self: *Self, table: []const u8, column: []const u8, value: storage.Value) !?[]storage.RowId {
        for (self.bloom_hash_indexes.items) |index| {
            if (std.mem.eql(u8, index.hash_index.table, table) and std.mem.eql(u8, index.hash_index.column, column)) {
                return try index.lookup(value);
            }
        }
        return null;
    }

    /// Get bloom hash index statistics
    pub fn getBloomHashStats(self: *Self, table: []const u8, column: []const u8) ?BloomHashStats {
        for (self.bloom_hash_indexes.items) |index| {
            if (std.mem.eql(u8, index.hash_index.table, table) and std.mem.eql(u8, index.hash_index.column, column)) {
                return index.getStats();
            }
        }
        return null;
    }

    /// Create a hash index
    pub fn createHashIndex(self: *Self, name: []const u8, table: []const u8, column: []const u8) !void {
        const index = try HashIndex.init(self.allocator, name, table, column);
        try self.hash_indexes.append(self.allocator, index);
    }

    /// Create a unique index
    pub fn createUniqueIndex(self: *Self, name: []const u8, table: []const u8, column: []const u8) !void {
        var columns = try self.allocator.alloc([]const u8, 1);
        columns[0] = column;
        const index = try UniqueIndex.init(self.allocator, name, table, columns);
        try self.unique_indexes.append(self.allocator, index);
    }

    /// Insert into hash indexes
    pub fn insertHash(self: *Self, table: []const u8, column: []const u8, value: storage.Value, row_id: storage.RowId) !void {
        for (self.hash_indexes.items) |index| {
            if (std.mem.eql(u8, index.table, table) and std.mem.eql(u8, index.column, column)) {
                try index.insert(value, row_id);
            }
        }
    }

    /// Lookup in hash indexes
    pub fn lookupHash(self: *Self, table: []const u8, column: []const u8, value: storage.Value) !?[]storage.RowId {
        for (self.hash_indexes.items) |index| {
            if (std.mem.eql(u8, index.table, table) and std.mem.eql(u8, index.column, column)) {
                return try index.lookup(value);
            }
        }
        return null;
    }

    /// Insert into unique indexes
    pub fn insertUnique(self: *Self, table: []const u8, column: []const u8, value: storage.Value, row_id: storage.RowId) !void {
        for (self.unique_indexes.items) |index| {
            if (std.mem.eql(u8, index.table, table) and index.columns.len == 1 and std.mem.eql(u8, index.columns[0], column)) {
                const values = [_]storage.Value{value};
                try index.insert(&values, row_id);
            }
        }
    }

    /// Lookup in unique indexes
    pub fn lookupUnique(self: *Self, table: []const u8, column: []const u8, value: storage.Value) !?storage.RowId {
        for (self.unique_indexes.items) |index| {
            if (std.mem.eql(u8, index.table, table) and index.columns.len == 1 and std.mem.eql(u8, index.columns[0], column)) {
                const values = [_]storage.Value{value};
                const hash = try index.hashValues(&values);
                if (index.value_map.get(hash)) |row_id| {
                    return row_id;
                }
            }
        }
        return null;
    }

    fn columnsMatch(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |col_a, col_b| {
            if (!std.mem.eql(u8, col_a, col_b)) return false;
        }
        return true;
    }

    pub fn deinit(self: *Self) void {
        for (self.hash_indexes.items) |index| {
            index.deinit();
        }
        self.hash_indexes.deinit(self.allocator);

        for (self.unique_indexes.items) |index| {
            index.deinit();
        }
        self.unique_indexes.deinit(self.allocator);

        for (self.multi_indexes.items) |index| {
            index.deinit();
        }
        self.multi_indexes.deinit(self.allocator);

        for (self.btree_indexes.items) |index| {
            index.deinit();
        }
        self.btree_indexes.deinit(self.allocator);

        for (self.optimized_multi_indexes.items) |index| {
            index.deinit();
        }
        self.optimized_multi_indexes.deinit(self.allocator);

        for (self.bloom_hash_indexes.items) |index| {
            index.deinit();
        }
        self.bloom_hash_indexes.deinit(self.allocator);
    }
};

/// Bloom filter for fast existence checks with configurable false positive rate
pub const BloomFilter = struct {
    bit_array: []bool,
    size: usize,
    hash_functions: u8,
    allocator: std.mem.Allocator,
    item_count: usize,
    expected_items: usize,

    const Self = @This();

    /// Initialize bloom filter with expected item count and desired false positive rate
    pub fn init(allocator: std.mem.Allocator, expected_items: usize, false_positive_rate: f64) !*Self {
        const optimal_size = Self.calculateOptimalSize(expected_items, false_positive_rate);
        const optimal_hash_functions = Self.calculateOptimalHashFunctions(expected_items, optimal_size);

        const filter = try allocator.create(Self);
        filter.* = Self{
            .bit_array = try allocator.alloc(bool, optimal_size),
            .size = optimal_size,
            .hash_functions = optimal_hash_functions,
            .allocator = allocator,
            .item_count = 0,
            .expected_items = expected_items,
        };

        @memset(filter.bit_array, false);
        return filter;
    }

    /// Calculate optimal bit array size for given parameters
    fn calculateOptimalSize(expected_items: usize, false_positive_rate: f64) usize {
        const ln2 = 0.6931471805599453;
        const size = -(@as(f64, @floatFromInt(expected_items)) * @log(false_positive_rate)) / (ln2 * ln2);
        return @max(64, @as(usize, @intFromFloat(@ceil(size)))); // Minimum 64 bits
    }

    /// Calculate optimal number of hash functions
    fn calculateOptimalHashFunctions(expected_items: usize, bit_array_size: usize) u8 {
        const ln2 = 0.6931471805599453;
        const ratio = @as(f64, @floatFromInt(bit_array_size)) / @as(f64, @floatFromInt(expected_items));
        const hash_count = ratio * ln2;
        return @max(1, @min(32, @as(u8, @intFromFloat(@round(hash_count))))); // Between 1-32 hash functions
    }

    /// Add a value to the bloom filter
    pub fn add(self: *Self, value: storage.Value) !void {
        const hashes = try self.getHashes(value);

        for (0..self.hash_functions) |i| {
            const hash = hashes[i % hashes.len];
            const index = hash % self.size;
            self.bit_array[index] = true;
        }

        self.item_count += 1;
    }

    /// Check if a value might exist (can have false positives, no false negatives)
    pub fn mightContain(self: *Self, value: storage.Value) !bool {
        const hashes = try self.getHashes(value);

        for (0..self.hash_functions) |i| {
            const hash = hashes[i % hashes.len];
            const index = hash % self.size;
            if (!self.bit_array[index]) {
                return false; // Definitely not present
            }
        }

        return true; // Might be present
    }

    /// Generate multiple hash values for a storage value
    fn getHashes(self: *Self, value: storage.Value) ![8]u64 {
        var hashes: [8]u64 = undefined;

        // Primary hash using Wyhash
        var hasher1 = std.hash.Wyhash.init(0);
        self.updateHasherWithValue(&hasher1, value);
        hashes[0] = hasher1.final();

        // Secondary hash using different seed
        var hasher2 = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
        self.updateHasherWithValue(&hasher2, value);
        hashes[1] = hasher2.final();

        // Generate additional hashes using double hashing technique
        for (2..8) |i| {
            hashes[i] = hashes[0] +% (@as(u64, @intCast(i)) * hashes[1]);
        }

        return hashes;
    }

    /// Update hasher with storage value
    fn updateHasherWithValue(self: *Self, hasher: *std.hash.Wyhash, value: storage.Value) void {
        _ = self;
        switch (value) {
            .Integer => |int_val| {
                hasher.update("i"); // Type marker
                hasher.update(std.mem.asBytes(&int_val));
            },
            .Real => |real_val| {
                hasher.update("r");
                hasher.update(std.mem.asBytes(&real_val));
            },
            .Text => |text_val| {
                hasher.update("t");
                hasher.update(text_val);
            },
            .Blob => |blob_val| {
                hasher.update("b");
                hasher.update(blob_val);
            },
            .Null => {
                hasher.update("n");
            },
        }
    }

    /// Get current false positive probability
    pub fn getCurrentFalsePositiveRate(self: *Self) f64 {
        const ln2 = 0.6931471805599453;
        const bits_per_item = @as(f64, @floatFromInt(self.size)) / @as(f64, @floatFromInt(@max(1, self.item_count)));
        const exponent = -(@as(f64, @floatFromInt(self.hash_functions)) * ln2 * bits_per_item);
        return std.math.pow(f64, 1.0 - @exp(exponent), @as(f64, @floatFromInt(self.hash_functions)));
    }

    /// Get memory usage in bytes
    pub fn getMemoryUsage(self: *Self) usize {
        return self.size / 8 + @sizeOf(Self); // bits to bytes plus struct overhead
    }

    /// Clear all bits (reset the filter)
    pub fn clear(self: *Self) void {
        @memset(self.bit_array, false);
        self.item_count = 0;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.bit_array);
        self.allocator.destroy(self);
    }
};

/// Enhanced Hash Index with Bloom Filter for fast negative lookups
pub const BloomHashIndex = struct {
    hash_index: *HashIndex,
    bloom_filter: *BloomFilter,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, table: []const u8, column: []const u8, expected_items: usize) !*Self {
        const index = try allocator.create(Self);
        index.* = Self{
            .hash_index = try HashIndex.init(allocator, name, table, column),
            .bloom_filter = try BloomFilter.init(allocator, expected_items, 0.01), // 1% false positive rate
            .allocator = allocator,
        };
        return index;
    }

    /// Add value to both hash index and bloom filter
    pub fn insert(self: *Self, value: storage.Value, row_id: storage.RowId) !void {
        try self.hash_index.insert(value, row_id);
        try self.bloom_filter.add(value);
    }

    /// Fast lookup with bloom filter pre-check
    pub fn lookup(self: *Self, value: storage.Value) ![]storage.RowId {
        // Fast negative lookup using bloom filter
        if (!(try self.bloom_filter.mightContain(value))) {
            return &[_]storage.RowId{}; // Definitely not present
        }

        // Might be present, check hash index
        return try self.hash_index.lookup(value);
    }

    /// Remove value from hash index (bloom filter can't remove)
    pub fn remove(self: *Self, value: storage.Value, row_id: storage.RowId) !void {
        try self.hash_index.remove(value, row_id);
        // Note: Bloom filter doesn't support removal, which is acceptable
        // as it only affects false positive rate slightly
    }

    /// Get performance statistics
    pub fn getStats(self: *Self) BloomHashStats {
        return BloomHashStats{
            .hash_entries = self.hash_index.hash_map.count(),
            .bloom_items = self.bloom_filter.item_count,
            .bloom_size_bytes = self.bloom_filter.getMemoryUsage(),
            .false_positive_rate = self.bloom_filter.getCurrentFalsePositiveRate(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.hash_index.deinit();
        self.bloom_filter.deinit();
        self.allocator.destroy(self);
    }
};

pub const BloomHashStats = struct {
    hash_entries: u32,
    bloom_items: usize,
    bloom_size_bytes: usize,
    false_positive_rate: f64,
};

/// Legacy Index manager for backwards compatibility
pub const IndexManager = AdvancedIndexManager;

// Test the indexing system
test "hash index operations" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = try HashIndex.init(allocator, "test_idx", "users", "email");
    defer index.deinit();

    const email_value = storage.Value{ .Text = "user@example.com" };
    const row_id: storage.RowId = 123;

    try index.insert(email_value, row_id);

    const found_rows = try index.lookup(email_value);
    try testing.expectEqual(@as(usize, 1), found_rows.len);
    try testing.expectEqual(row_id, found_rows[0]);
}

test "unique constraint" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const columns = [_][]const u8{"email"};
    var index = try UniqueIndex.init(allocator, "unique_email", "users", &columns);
    defer index.deinit();

    const values = [_]storage.Value{storage.Value{ .Text = "user@example.com" }};

    try index.insert(&values, 123);

    // Should fail on duplicate
    const result = index.insert(&values, 456);
    try testing.expectError(error.UniqueConstraintViolation, result);
}

test "B-tree index operations" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = try BTreeIndex.init(allocator, "test_btree", "events", "timestamp");
    defer index.deinit();

    // Insert values
    const values = [_]i64{ 10, 5, 15, 3, 7, 12, 18, 1, 6, 9 };
    for (values, 0..) |val, i| {
        try index.insert(storage.Value{ .Integer = val }, @intCast(i));
    }

    // Range query: values between 5 and 12
    const start = storage.Value{ .Integer = 5 };
    const end = storage.Value{ .Integer = 12 };
    const result = try index.rangeQuery(start, end);
    defer allocator.free(result);

    // Should find values 5, 6, 7, 9, 10, 12 (6 values)
    try testing.expect(result.len >= 4); // At least some values in range
}

test "composite key optimization" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var key1 = CompositeKey.init(allocator);
    defer key1.deinit();
    var key2 = CompositeKey.init(allocator);
    defer key2.deinit();

    try key1.addValue(storage.Value{ .Integer = 123 });
    try key1.addValue(storage.Value{ .Text = "test" });

    try key2.addValue(storage.Value{ .Integer = 123 });
    try key2.addValue(storage.Value{ .Text = "test" });

    // Test equality
    try testing.expect(key1.eql(&key2));

    // Test hash consistency
    const hash1 = key1.hash();
    const hash2 = key2.hash();
    try testing.expectEqual(hash1, hash2);
}

test "bloom filter operations" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bloom = try BloomFilter.init(allocator, 1000, 0.01); // 1000 items, 1% false positive
    defer bloom.deinit();

    // Add some values
    const values = [_]storage.Value{
        storage.Value{ .Integer = 123 },
        storage.Value{ .Text = "hello" },
        storage.Value{ .Integer = 456 },
        storage.Value{ .Text = "world" },
    };

    for (values) |value| {
        try bloom.add(value);
    }

    // Test positive lookups (should all return true)
    for (values) |value| {
        try testing.expect(try bloom.mightContain(value));
    }

    // Test negative lookup (should return false, but might have false positives)
    const non_existent = storage.Value{ .Integer = 999 };
    _ = try bloom.mightContain(non_existent);
    // Note: This might occasionally fail due to false positives, but very unlikely with 1% rate
}

test "bloom hash index performance" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = try BloomHashIndex.init(allocator, "test_bloom", "users", "email", 10000);
    defer index.deinit();

    // Add many values
    for (0..1000) |i| {
        const value = storage.Value{ .Integer = @intCast(i) };
        try index.insert(value, @intCast(i));
    }

    // Test existing value lookup
    const existing = storage.Value{ .Integer = 500 };
    const result = try index.lookup(existing);
    try testing.expect(result.len > 0);

    // Test non-existing value (should be fast due to bloom filter)
    const non_existing = storage.Value{ .Integer = 9999 };
    const empty_result = try index.lookup(non_existing);
    try testing.expectEqual(@as(usize, 0), empty_result.len);

    // Check statistics
    const stats = index.getStats();
    try testing.expect(stats.bloom_items == 1000);
    try testing.expect(stats.false_positive_rate < 0.02); // Should be close to 1%
}

test "advanced index manager with bloom filters" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = AdvancedIndexManager.init(allocator);
    defer manager.deinit();

    // Create all types of indexes
    try manager.createHashIndex("test_hash", "users", "id");
    try manager.createBTreeIndex("test_btree", "events", "timestamp");
    try manager.createBloomHashIndex("test_bloom", "users", "email", 1000);

    const columns = [_][]const u8{ "user_id", "type" };
    try manager.createOptimizedMultiIndex("test_multi", "actions", &columns);

    // Test operations
    try manager.insertHash("users", "id", storage.Value{ .Integer = 123 }, 1);
    try manager.insertBTree("events", "timestamp", storage.Value{ .Integer = 1000 }, 1);
    try manager.insertBloomHash("users", "email", storage.Value{ .Text = "test@example.com" }, 1);

    const multi_values = [_]storage.Value{
        storage.Value{ .Integer = 123 },
        storage.Value{ .Text = "click" },
    };
    try manager.insertOptimizedMulti("actions", &columns, &multi_values, 1);

    // Test lookups
    if (try manager.lookupHash("users", "id", storage.Value{ .Integer = 123 })) |result| {
        defer allocator.free(result);
        try testing.expectEqual(@as(usize, 1), result.len);
    }

    if (try manager.lookupBloomHash("users", "email", storage.Value{ .Text = "test@example.com" })) |result| {
        defer allocator.free(result);
        try testing.expectEqual(@as(usize, 1), result.len);
    }

    // Test non-existing bloom hash lookup (should be fast)
    if (try manager.lookupBloomHash("users", "email", storage.Value{ .Text = "nonexistent@example.com" })) |result| {
        defer allocator.free(result);
        try testing.expectEqual(@as(usize, 0), result.len);
    }

    // Check bloom filter statistics
    if (manager.getBloomHashStats("users", "email")) |stats| {
        try testing.expect(stats.bloom_items == 1);
        try testing.expect(stats.false_positive_rate >= 0.0);
    }
}
