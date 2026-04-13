const std = @import("std");
const time_utils = @import("../time_utils.zig");
const storage = @import("../db/storage.zig");
const parser = @import("../parser/parser.zig");
const ast = @import("../parser/ast.zig");

/// Query result cache for improved performance using intrusive doubly-linked list
pub const QueryCache = struct {
    allocator: std.mem.Allocator,
    cache_entries: std.HashMap(u64, *CacheEntry, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    lru_list: std.DoublyLinkedList = .{},
    max_entries: usize,
    max_memory_bytes: usize,
    current_memory_usage: usize,
    hit_count: u64,
    miss_count: u64,
    eviction_count: u64,

    const Self = @This();

    /// Initialize query cache
    pub fn init(allocator: std.mem.Allocator, max_entries: usize, max_memory_bytes: usize) !*Self {
        var cache = try allocator.create(Self);
        cache.allocator = allocator;
        cache.cache_entries = std.HashMap(u64, *CacheEntry, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator);
        cache.lru_list = .{};
        cache.max_entries = max_entries;
        cache.max_memory_bytes = max_memory_bytes;
        cache.current_memory_usage = 0;
        cache.hit_count = 0;
        cache.miss_count = 0;
        cache.eviction_count = 0;

        return cache;
    }

    /// Get cached query result
    pub fn get(self: *Self, sql_hash: u64) ?*CachedResult {
        if (self.cache_entries.get(sql_hash)) |entry| {
            // Move to front of LRU list (most recently used)
            self.lru_list.remove(&entry.lru_node);
            self.lru_list.prepend(&entry.lru_node);

            entry.access_count += 1;
            const ts = time_utils.getTimespec();
            entry.last_accessed = ts.sec;

            self.hit_count += 1;
            return &entry.result;
        }

        self.miss_count += 1;
        return null;
    }

    /// Store query result in cache
    pub fn put(self: *Self, sql_hash: u64, sql: []const u8, result: []storage.Row) !void {
        const ts = time_utils.getTimespec();
        const timestamp = ts.sec;
        const referenced_tables = try self.extractTableNames(sql);

        // Check if entry already exists
        if (self.cache_entries.get(sql_hash)) |existing_entry| {
            // Update existing entry
            existing_entry.result.deinit(self.allocator);
            self.freeReferencedTables(existing_entry.referenced_tables);
            existing_entry.result = try self.cloneResult(result);
            existing_entry.last_accessed = timestamp;
            existing_entry.access_count += 1;
            existing_entry.referenced_tables = referenced_tables;

            // Move to front
            self.lru_list.remove(&existing_entry.lru_node);
            self.lru_list.prepend(&existing_entry.lru_node);
            return;
        }

        // Create new entry
        const entry = try self.allocator.create(CacheEntry);
        entry.hash = sql_hash;
        entry.sql = try self.allocator.dupe(u8, sql);
        entry.result = try self.cloneResult(result);
        entry.created_at = timestamp;
        entry.last_accessed = timestamp;
        entry.access_count = 1;
        entry.referenced_tables = referenced_tables;
        entry.memory_size = self.calculateEntrySize(entry);

        // Add to cache
        try self.cache_entries.put(sql_hash, entry);
        self.lru_list.prepend(&entry.lru_node);

        self.current_memory_usage += entry.memory_size;

        // Evict if necessary
        try self.evictIfNeeded();
    }

    /// Clone result rows for caching
    fn cloneResult(self: *Self, rows: []storage.Row) !CachedResult {
        const cloned_rows = try self.allocator.alloc(storage.Row, rows.len);

        for (rows, 0..) |row, i| {
            const cloned_values = try self.allocator.alloc(storage.Value, row.values.len);
            for (row.values, 0..) |value, j| {
                cloned_values[j] = try self.cloneValue(value);
            }
            cloned_rows[i] = storage.Row{ .values = cloned_values };
        }

        return CachedResult{
            .rows = cloned_rows,
            .row_count = rows.len,
        };
    }

    /// Clone a storage value
    fn cloneValue(self: *Self, value: storage.Value) !storage.Value {
        return switch (value) {
            .Integer => |i| storage.Value{ .Integer = i },
            .Text => |text| storage.Value{ .Text = try self.allocator.dupe(u8, text) },
            .Real => |r| storage.Value{ .Real = r },
            .Blob => |blob| storage.Value{ .Blob = try self.allocator.dupe(u8, blob) },
            .JSON => |json| storage.Value{ .JSON = try self.allocator.dupe(u8, json) },
            .JSONB => |jsonb| storage.Value{ .JSONB = storage.JSONBValue.init(self.allocator, try jsonb.toString(self.allocator)) catch return storage.Value.Null },
            .UUID => |uuid| storage.Value{ .UUID = uuid },
            .Boolean => |b| storage.Value{ .Boolean = b },
            .Timestamp => |ts| storage.Value{ .Timestamp = ts },
            .Date => |d| storage.Value{ .Date = d },
            .Time => |t| storage.Value{ .Time = t },
            .SmallInt => |si| storage.Value{ .SmallInt = si },
            .BigInt => |bi| storage.Value{ .BigInt = bi },
            .Null => storage.Value.Null,
            .Parameter => |p| storage.Value{ .Parameter = p },
            else => storage.Value.Null, // For complex types, store as null for simplicity
        };
    }

    /// Calculate memory size of a cache entry
    fn calculateEntrySize(self: *Self, entry: *CacheEntry) usize {
        _ = self;
        var size: usize = @sizeOf(CacheEntry);
        size += entry.sql.len;

        for (entry.result.rows) |row| {
            size += @sizeOf(storage.Row);
            for (row.values) |value| {
                size += switch (value) {
                    .Text => |text| text.len,
                    .Blob => |blob| blob.len,
                    .JSON => |json| json.len,
                    else => @sizeOf(storage.Value),
                };
            }
        }

        return size;
    }

    /// Evict entries if cache limits are exceeded
    fn evictIfNeeded(self: *Self) !void {
        while ((self.cache_entries.count() > self.max_entries) or
            (self.current_memory_usage > self.max_memory_bytes))
        {
            if (self.lru_list.last) |last_node| {
                const entry = CacheEntry.fromNode(last_node);
                try self.evictEntry(entry);
            } else {
                break;
            }
        }
    }

    /// Evict a specific cache entry
    fn evictEntry(self: *Self, entry: *CacheEntry) !void {
        // Remove from hash map
        _ = self.cache_entries.remove(entry.hash);

        // Remove from LRU list
        self.lru_list.remove(&entry.lru_node);

        // Update memory usage
        self.current_memory_usage -= entry.memory_size;

        // Clean up entry
        entry.result.deinit(self.allocator);
        self.allocator.free(entry.sql);
        self.freeReferencedTables(entry.referenced_tables);
        self.allocator.destroy(entry);

        self.eviction_count += 1;
    }

    /// Clear all cached entries
    pub fn clear(self: *Self) void {
        while (self.lru_list.first) |first_node| {
            const entry = CacheEntry.fromNode(first_node);
            self.evictEntry(entry) catch {};
        }

        self.hit_count = 0;
        self.miss_count = 0;
        self.eviction_count = 0;
    }

    /// Get cache statistics
    pub fn getStats(self: *Self) CacheStats {
        const total_requests = self.hit_count + self.miss_count;
        const hit_rate = if (total_requests > 0)
            @as(f64, @floatFromInt(self.hit_count)) / @as(f64, @floatFromInt(total_requests))
        else
            0.0;

        return CacheStats{
            .entries = self.cache_entries.count(),
            .max_entries = self.max_entries,
            .memory_usage_bytes = self.current_memory_usage,
            .max_memory_bytes = self.max_memory_bytes,
            .hit_count = self.hit_count,
            .miss_count = self.miss_count,
            .eviction_count = self.eviction_count,
            .hit_rate = hit_rate,
        };
    }

    /// Remove expired entries based on TTL
    pub fn cleanupExpired(self: *Self, ttl_seconds: i64) !void {
        const ts = time_utils.getTimespec();
        const current_time = ts.sec;
        var entries_to_remove: std.ArrayListUnmanaged(*CacheEntry) = .empty;
        defer entries_to_remove.deinit(self.allocator);

        var iterator = self.cache_entries.iterator();
        while (iterator.next()) |entry| {
            if (current_time - entry.value_ptr.*.last_accessed > ttl_seconds) {
                try entries_to_remove.append(self.allocator, entry.value_ptr.*);
            }
        }

        for (entries_to_remove.items) |entry| {
            try self.evictEntry(entry);
        }
    }

    /// Invalidate cache entries that might be affected by a table update
    pub fn invalidateTable(self: *Self, table_name: []const u8) !void {
        var entries_to_remove: std.ArrayListUnmanaged(*CacheEntry) = .empty;
        defer entries_to_remove.deinit(self.allocator);

        var iterator = self.cache_entries.iterator();
        while (iterator.next()) |entry| {
            if (entryReferencesTable(entry.value_ptr.*.referenced_tables, table_name)) {
                try entries_to_remove.append(self.allocator, entry.value_ptr.*);
            }
        }

        for (entries_to_remove.items) |entry| {
            try self.evictEntry(entry);
        }
    }

    /// Cleanup cache
    pub fn deinit(self: *Self) void {
        self.clear();
        self.cache_entries.deinit();
        self.allocator.destroy(self);
    }

    fn extractTableNames(self: *Self, sql: []const u8) ![][]const u8 {
        var parsed = parser.parse(self.allocator, sql) catch {
            return try self.allocator.alloc([]const u8, 0);
        };
        defer parsed.deinit();

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (names.items) |name| {
                self.allocator.free(name);
            }
            names.deinit(self.allocator);
        }

        try collectStatementTables(self.allocator, &names, parsed.statement);
        return try names.toOwnedSlice(self.allocator);
    }

    fn freeReferencedTables(self: *Self, names: [][]const u8) void {
        for (names) |name| {
            self.allocator.free(name);
        }
        self.allocator.free(names);
    }
};

/// Cache entry storing query result and metadata
const CacheEntry = struct {
    hash: u64,
    sql: []const u8,
    result: CachedResult,
    created_at: i64,
    last_accessed: i64,
    access_count: u64,
    referenced_tables: [][]const u8,
    memory_size: usize,
    /// Intrusive node for LRU list - use @fieldParentPtr to get back to CacheEntry
    lru_node: std.DoublyLinkedList.Node = .{},

    /// Get CacheEntry from its lru_node pointer
    pub fn fromNode(node: *std.DoublyLinkedList.Node) *CacheEntry {
        return @fieldParentPtr("lru_node", node);
    }
};

/// Cached query result
pub const CachedResult = struct {
    rows: []storage.Row,
    row_count: usize,

    pub fn deinit(self: *CachedResult, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| {
            row.deinit(allocator);
        }
        allocator.free(self.rows);
    }
};

/// Cache statistics
pub const CacheStats = struct {
    entries: u32,
    max_entries: usize,
    memory_usage_bytes: usize,
    max_memory_bytes: usize,
    hit_count: u64,
    miss_count: u64,
    eviction_count: u64,
    hit_rate: f64,
};

/// Hash function for SQL queries
pub const QueryHasher = struct {
    /// Create hash for SQL query (case-insensitive, whitespace normalized)
    pub fn hashQuery(sql: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);

        // Normalize SQL by removing extra whitespace and converting to lowercase
        var prev_was_space = false;
        for (sql) |char| {
            if (std.ascii.isWhitespace(char)) {
                if (!prev_was_space) {
                    hasher.update(&[_]u8{' '});
                    prev_was_space = true;
                }
            } else {
                const lower_char = std.ascii.toLower(char);
                hasher.update(&[_]u8{lower_char});
                prev_was_space = false;
            }
        }

        return hasher.final();
    }
};

fn entryReferencesTable(referenced_tables: [][]const u8, table_name: []const u8) bool {
    for (referenced_tables) |referenced| {
        if (std.ascii.eqlIgnoreCase(referenced, table_name)) {
            return true;
        }
    }
    return false;
}

fn appendTableName(allocator: std.mem.Allocator, names: *std.ArrayListUnmanaged([]const u8), table_name: []const u8) !void {
    for (names.items) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, table_name)) {
            return;
        }
    }

    try names.append(allocator, try allocator.dupe(u8, table_name));
}

fn collectStatementTables(allocator: std.mem.Allocator, names: *std.ArrayListUnmanaged([]const u8), statement: ast.Statement) !void {
    switch (statement) {
        .Select => |select| try collectSelectTables(allocator, names, select),
        .Insert => |insert| try appendTableName(allocator, names, insert.table),
        .Update => |update| try appendTableName(allocator, names, update.table),
        .Delete => |delete| try appendTableName(allocator, names, delete.table),
        .CompoundSelect => |compound| {
            try collectSelectTables(allocator, names, compound.left.*);
            try collectStatementTables(allocator, names, compound.right.*);
        },
        .With => |with_stmt| {
            for (with_stmt.cte_definitions) |cte| {
                try collectSelectTables(allocator, names, cte.query);
            }
            try collectSelectTables(allocator, names, with_stmt.main_query);
        },
        else => {},
    }
}

fn collectSelectTables(allocator: std.mem.Allocator, names: *std.ArrayListUnmanaged([]const u8), select: ast.SelectStatement) !void {
    if (select.table) |table_name| {
        try appendTableName(allocator, names, table_name);
    }
    for (select.joins) |join| {
        try appendTableName(allocator, names, join.table);
    }
}

test "query cache basic operations" {
    const allocator = std.testing.allocator;

    const cache = try QueryCache.init(allocator, 10, 1024 * 1024); // 10 entries, 1MB
    defer cache.deinit();

    const sql = "SELECT * FROM users WHERE id = 1";
    const hash = QueryHasher.hashQuery(sql);

    // Test cache miss
    try std.testing.expect(cache.get(hash) == null);

    // Create test result
    const test_values = [_]storage.Value{ storage.Value{ .Integer = 1 }, storage.Value{ .Text = try allocator.dupe(u8, "John") } };
    defer test_values[1].deinit(allocator);

    const test_row = storage.Row{ .values = @constCast(&test_values) };
    const test_rows = [_]storage.Row{test_row};

    // Store in cache
    try cache.put(hash, sql, @constCast(&test_rows));

    // Test cache hit
    const cached_result = cache.get(hash);
    try std.testing.expect(cached_result != null);
    try std.testing.expect(cached_result.?.row_count == 1);

    // Check stats
    const stats = cache.getStats();
    try std.testing.expect(stats.hit_count == 1);
    try std.testing.expect(stats.miss_count == 1);
}

test "query hasher normalization" {
    const sql1 = "SELECT * FROM users WHERE id = 1";
    const sql2 = "  select   *   from    users   where  id =  1  ";
    const sql3 = "SELECT * FROM USERS WHERE ID = 1";

    const hash1 = QueryHasher.hashQuery(sql1);
    const hash2 = QueryHasher.hashQuery(sql2);
    const hash3 = QueryHasher.hashQuery(sql3);

    try std.testing.expect(hash1 == hash2);
    try std.testing.expect(hash1 == hash3);
}

test "query cache extracts referenced tables" {
    const allocator = std.testing.allocator;
    const cache = try QueryCache.init(allocator, 10, 1024 * 1024);
    defer cache.deinit();

    const sql = "SELECT u.id, p.name FROM users u JOIN profiles p ON u.id = p.user_id";
    const hash = QueryHasher.hashQuery(sql);

    const test_values = [_]storage.Value{storage.Value{ .Integer = 1 }};
    const test_row = storage.Row{ .values = @constCast(&test_values) };
    const test_rows = [_]storage.Row{test_row};

    try cache.put(hash, sql, @constCast(&test_rows));

    const entry = cache.cache_entries.get(hash).?;
    try std.testing.expect(entryReferencesTable(entry.referenced_tables, "users"));
    try std.testing.expect(entryReferencesTable(entry.referenced_tables, "profiles"));
    try std.testing.expect(!entryReferencesTable(entry.referenced_tables, "orders"));
}

test "query cache invalidation uses exact table names" {
    const allocator = std.testing.allocator;
    const cache = try QueryCache.init(allocator, 10, 1024 * 1024);
    defer cache.deinit();

    const sql_user = "SELECT * FROM user";
    const sql_users = "SELECT * FROM users";
    const hash_user = QueryHasher.hashQuery(sql_user);
    const hash_users = QueryHasher.hashQuery(sql_users);

    const test_values = [_]storage.Value{storage.Value{ .Integer = 1 }};
    const test_row = storage.Row{ .values = @constCast(&test_values) };
    const test_rows = [_]storage.Row{test_row};

    try cache.put(hash_user, sql_user, @constCast(&test_rows));
    try cache.put(hash_users, sql_users, @constCast(&test_rows));

    try cache.invalidateTable("user");

    try std.testing.expect(cache.get(hash_user) == null);
    try std.testing.expect(cache.get(hash_users) != null);
}

test "connection result cache invalidates after insert update delete" {
    const zqlite = @import("../zqlite.zig");
    const allocator = std.testing.allocator;

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    const cache = try QueryCache.init(allocator, 16, 1024 * 1024);
    defer cache.deinit();
    conn.setResultCache(cache);

    try conn.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)");
    try conn.execute("INSERT INTO items VALUES (1, 'one')");

    var first = try conn.query("SELECT value FROM items WHERE id = 1");
    defer first.deinit();
    try std.testing.expectEqualStrings("one", first.rows.items[0].values[0].Text);

    const hash = QueryHasher.hashQuery("SELECT value FROM items WHERE id = 1");
    try std.testing.expect(cache.get(hash) != null);

    try conn.execute("INSERT INTO items VALUES (2, 'two')");
    try std.testing.expect(cache.get(hash) == null);

    var second = try conn.query("SELECT value FROM items WHERE id = 1");
    defer second.deinit();
    try std.testing.expectEqualStrings("one", second.rows.items[0].values[0].Text);

    try conn.execute("UPDATE items SET value = 'uno' WHERE id = 1");
    try std.testing.expect(cache.get(hash) == null);

    var third = try conn.query("SELECT value FROM items WHERE id = 1");
    defer third.deinit();
    try std.testing.expectEqualStrings("uno", third.rows.items[0].values[0].Text);

    try conn.execute("DELETE FROM items WHERE id = 1");
    try std.testing.expect(cache.get(hash) == null);

    var fourth = try conn.query("SELECT value FROM items WHERE id = 1");
    defer fourth.deinit();
    try std.testing.expectEqual(@as(usize, 0), fourth.count());
}

test "connection result cache keeps overlapping table names isolated" {
    const zqlite = @import("../zqlite.zig");
    const allocator = std.testing.allocator;

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    const cache = try QueryCache.init(allocator, 16, 1024 * 1024);
    defer cache.deinit();
    conn.setResultCache(cache);

    try conn.execute("CREATE TABLE user (id INTEGER PRIMARY KEY, value TEXT)");
    try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, value TEXT)");
    try conn.execute("INSERT INTO user VALUES (1, 'singular')");
    try conn.execute("INSERT INTO users VALUES (1, 'plural')");

    const singular_sql = "SELECT value FROM user WHERE id = 1";
    const plural_sql = "SELECT value FROM users WHERE id = 1";
    const singular_hash = QueryHasher.hashQuery(singular_sql);
    const plural_hash = QueryHasher.hashQuery(plural_sql);

    var singular = try conn.query(singular_sql);
    defer singular.deinit();
    var plural = try conn.query(plural_sql);
    defer plural.deinit();

    try std.testing.expect(cache.get(singular_hash) != null);
    try std.testing.expect(cache.get(plural_hash) != null);

    try conn.execute("UPDATE user SET value = 'changed' WHERE id = 1");

    try std.testing.expect(cache.get(singular_hash) == null);
    try std.testing.expect(cache.get(plural_hash) != null);
}

test "schema changes invalidate cached selects for the table" {
    const zqlite = @import("../zqlite.zig");
    const allocator = std.testing.allocator;

    const conn = try zqlite.open(allocator, ":memory:");
    defer conn.close();

    const cache = try QueryCache.init(allocator, 16, 1024 * 1024);
    defer cache.deinit();
    conn.setResultCache(cache);

    try conn.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)");
    try conn.execute("INSERT INTO items VALUES (1, 'one')");

    const sql = "SELECT value FROM items WHERE id = 1";
    const hash = QueryHasher.hashQuery(sql);

    var first = try conn.query(sql);
    defer first.deinit();
    try std.testing.expect(cache.get(hash) != null);

    try conn.execute("DROP TABLE items");
    try std.testing.expect(cache.get(hash) == null);
}
