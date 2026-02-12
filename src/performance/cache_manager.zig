const std = @import("std");
const storage = @import("../db/storage.zig");
const planner = @import("../executor/planner.zig");
const ast = @import("../parser/ast.zig");
const zqlite = @import("../zqlite.zig");

/// Get current time in milliseconds using compat clock
fn getMilliTimestamp() i64 {
    const ts = zqlite.time_utils.getTimespec();
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// High-performance cache manager for zqlite v1.2.5
/// Provides B-tree node caching and query plan caching
pub const CacheManager = struct {
    allocator: std.mem.Allocator,
    btree_cache: BTreeCache,
    query_plan_cache: QueryPlanCache,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, btree_cache_size: usize, plan_cache_size: usize) !Self {
        return Self{
            .allocator = allocator,
            .btree_cache = try BTreeCache.init(allocator, btree_cache_size),
            .query_plan_cache = try QueryPlanCache.init(allocator, plan_cache_size),
        };
    }

    pub fn deinit(self: *Self) void {
        self.btree_cache.deinit();
        self.query_plan_cache.deinit();
    }
};

/// LRU cache for B-tree nodes to improve read performance
pub const BTreeCache = struct {
    allocator: std.mem.Allocator,
    cache: std.hash_map.HashMap(u32, CachedNode, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    lru_list: std.doubly_linked_list.DoublyLinkedList(u32),
    node_to_list_node: std.hash_map.HashMap(u32, *std.doubly_linked_list.DoublyLinkedList(u32).Node, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    max_size: usize,
    current_size: usize,

    const CachedNode = struct {
        page_id: u32,
        data: []u8,
        is_dirty: bool,
        last_accessed: i64,
        access_count: u32,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_size: usize) !Self {
        return Self{
            .allocator = allocator,
            .cache = std.hash_map.HashMap(u32, CachedNode, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .lru_list = std.doubly_linked_list.DoublyLinkedList(u32){},
            .node_to_list_node = std.hash_map.HashMap(u32, *std.doubly_linked_list.DoublyLinkedList(u32).Node, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .max_size = max_size,
            .current_size = 0,
        };
    }

    /// Get node from cache
    pub fn get(self: *Self, page_id: u32) ?[]const u8 {
        if (self.cache.getPtr(page_id)) |cached_node| {
            // Update access statistics
            cached_node.last_accessed = getMilliTimestamp();
            cached_node.access_count += 1;

            // Move to front of LRU list
            self.moveToFront(page_id);

            return cached_node.data;
        }

        return null;
    }

    /// Put node in cache
    pub fn put(self: *Self, page_id: u32, data: []const u8, is_dirty: bool) !void {
        // Check if already in cache
        if (self.cache.contains(page_id)) {
            // Update existing entry
            var cached_node = self.cache.getPtr(page_id).?;
            self.allocator.free(cached_node.data);
            cached_node.data = try self.allocator.dupe(u8, data);
            cached_node.is_dirty = is_dirty;
            cached_node.last_accessed = getMilliTimestamp();
            cached_node.access_count += 1;

            self.moveToFront(page_id);
            return;
        }

        // Evict if at capacity
        while (self.current_size >= self.max_size) {
            try self.evictLRU();
        }

        // Add new entry
        const cached_node = CachedNode{
            .page_id = page_id,
            .data = try self.allocator.dupe(u8, data),
            .is_dirty = is_dirty,
            .last_accessed = getMilliTimestamp(),
            .access_count = 1,
        };

        try self.cache.put(page_id, cached_node);

        // Add to LRU list
        const list_node = try self.allocator.create(std.doubly_linked_list.DoublyLinkedList(u32).Node);
        list_node.data = page_id;
        self.lru_list.prepend(list_node);
        try self.node_to_list_node.put(page_id, list_node);

        self.current_size += 1;
    }

    /// Mark node as dirty
    pub fn markDirty(self: *Self, page_id: u32) void {
        if (self.cache.getPtr(page_id)) |cached_node| {
            cached_node.is_dirty = true;
        }
    }

    /// Flush all dirty nodes (returns list of dirty page IDs and their data)
    pub fn flushDirty(self: *Self) !std.ArrayList(struct { page_id: u32, data: []const u8 }) {
        var dirty_nodes = std.ArrayList(struct { page_id: u32, data: []const u8 }).init(self.allocator);

        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.is_dirty) {
                try dirty_nodes.append(.{
                    .page_id = entry.key_ptr.*,
                    .data = entry.value_ptr.data,
                });
                entry.value_ptr.is_dirty = false;
            }
        }

        return dirty_nodes;
    }

    /// Get cache statistics
    pub fn getStats(self: *Self) CacheStats {
        var hit_rate: f64 = 0;
        var total_accesses: u32 = 0;

        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            total_accesses += entry.value_ptr.access_count;
        }

        if (total_accesses > 0) {
            hit_rate = @as(f64, @floatFromInt(total_accesses - self.current_size)) / @as(f64, @floatFromInt(total_accesses));
        }

        return CacheStats{
            .hit_rate = hit_rate,
            .total_entries = self.current_size,
            .max_entries = self.max_size,
            .memory_usage_kb = self.estimateMemoryUsage() / 1024,
        };
    }

    fn moveToFront(self: *Self, page_id: u32) void {
        if (self.node_to_list_node.get(page_id)) |list_node| {
            self.lru_list.remove(list_node);
            self.lru_list.prepend(list_node);
        }
    }

    fn evictLRU(self: *Self) !void {
        if (self.lru_list.last) |last_node| {
            const page_id = last_node.data;

            // Remove from all data structures
            if (self.cache.get(page_id)) |cached_node| {
                self.allocator.free(cached_node.data);
            }
            _ = self.cache.remove(page_id);
            _ = self.node_to_list_node.remove(page_id);

            self.lru_list.remove(last_node);
            self.allocator.destroy(last_node);

            self.current_size -= 1;
        }
    }

    fn estimateMemoryUsage(self: *Self) usize {
        var total_size: usize = 0;

        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            total_size += entry.value_ptr.data.len;
        }

        // Add overhead for hash maps and list nodes
        total_size += self.cache.capacity() * (@sizeOf(u32) + @sizeOf(CachedNode));
        total_size += self.node_to_list_node.capacity() * (@sizeOf(u32) + @sizeOf(*std.doubly_linked_list.DoublyLinkedList(u32).Node));

        return total_size;
    }

    pub fn deinit(self: *Self) void {
        // Free cached data
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.data);
        }
        self.cache.deinit();

        // Free list nodes
        var list_iterator = self.node_to_list_node.iterator();
        while (list_iterator.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.node_to_list_node.deinit();
    }
};

/// Query plan cache to avoid re-planning identical queries
pub const QueryPlanCache = struct {
    allocator: std.mem.Allocator,
    cache: std.hash_map.HashMap(u64, CachedPlan, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    max_size: usize,

    const CachedPlan = struct {
        sql_hash: u64,
        plan: planner.ExecutionPlan,
        created_at: i64,
        last_used: i64,
        use_count: u32,
        avg_execution_time_ms: f64,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_size: usize) !Self {
        return Self{
            .allocator = allocator,
            .cache = std.hash_map.HashMap(u64, CachedPlan, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
            .max_size = max_size,
        };
    }

    /// Get cached plan
    pub fn get(self: *Self, sql: []const u8) ?*planner.ExecutionPlan {
        const hash = self.hashSQL(sql);

        if (self.cache.getPtr(hash)) |cached_plan| {
            cached_plan.last_used = getMilliTimestamp();
            cached_plan.use_count += 1;
            return &cached_plan.plan;
        }

        return null;
    }

    /// Put plan in cache
    pub fn put(self: *Self, sql: []const u8, plan: planner.ExecutionPlan) !void {
        const hash = self.hashSQL(sql);
        const current_time = getMilliTimestamp();

        // Evict if at capacity
        while (self.cache.count() >= self.max_size) {
            try self.evictOldest();
        }

        const cached_plan = CachedPlan{
            .sql_hash = hash,
            .plan = plan,
            .created_at = current_time,
            .last_used = current_time,
            .use_count = 1,
            .avg_execution_time_ms = 0.0,
        };

        try self.cache.put(hash, cached_plan);
    }

    /// Update execution statistics
    pub fn updateExecutionStats(self: *Self, sql: []const u8, execution_time_ms: f64) void {
        const hash = self.hashSQL(sql);

        if (self.cache.getPtr(hash)) |cached_plan| {
            const alpha = 0.1; // Smoothing factor for exponential moving average
            if (cached_plan.avg_execution_time_ms == 0.0) {
                cached_plan.avg_execution_time_ms = execution_time_ms;
            } else {
                cached_plan.avg_execution_time_ms = alpha * execution_time_ms + (1.0 - alpha) * cached_plan.avg_execution_time_ms;
            }
        }
    }

    /// Get cache statistics
    pub fn getStats(self: *Self) PlanCacheStats {
        var total_use_count: u32 = 0;
        const total_plans = self.cache.count();
        var avg_execution_time: f64 = 0.0;

        if (total_plans > 0) {
            var iterator = self.cache.iterator();
            while (iterator.next()) |entry| {
                total_use_count += entry.value_ptr.use_count;
                avg_execution_time += entry.value_ptr.avg_execution_time_ms;
            }
            avg_execution_time /= @as(f64, @floatFromInt(total_plans));
        }

        return PlanCacheStats{
            .total_plans = total_plans,
            .total_uses = total_use_count,
            .avg_execution_time_ms = avg_execution_time,
            .hit_ratio = if (total_use_count > total_plans)
                @as(f64, @floatFromInt(total_use_count - total_plans)) / @as(f64, @floatFromInt(total_use_count))
            else
                0.0,
        };
    }

    /// Clear expired plans (older than specified age in milliseconds)
    pub fn clearExpired(self: *Self, max_age_ms: i64) !void {
        const current_time = getMilliTimestamp();
        var expired_hashes = std.ArrayList(u64).init(self.allocator);
        defer expired_hashes.deinit();

        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            if (current_time - entry.value_ptr.created_at > max_age_ms) {
                try expired_hashes.append(entry.key_ptr.*);
            }
        }

        for (expired_hashes.items) |hash| {
            if (self.cache.get(hash)) |cached_plan| {
                cached_plan.plan.deinit();
            }
            _ = self.cache.remove(hash);
        }
    }

    fn hashSQL(self: *Self, sql: []const u8) u64 {
        _ = self; // Remove unused variable warning

        // Simple hash function - in production, use a better hash like xxHash
        var hash: u64 = 0;
        for (sql) |byte| {
            hash = hash *% 31 +% byte;
        }
        return hash;
    }

    fn evictOldest(self: *Self) !void {
        var oldest_hash: ?u64 = null;
        var oldest_time: i64 = getMilliTimestamp();

        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_used < oldest_time) {
                oldest_time = entry.value_ptr.last_used;
                oldest_hash = entry.key_ptr.*;
            }
        }

        if (oldest_hash) |hash| {
            if (self.cache.get(hash)) |cached_plan| {
                cached_plan.plan.deinit();
            }
            _ = self.cache.remove(hash);
        }
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.plan.deinit();
        }
        self.cache.deinit();
    }
};

pub const CacheStats = struct {
    hit_rate: f64,
    total_entries: usize,
    max_entries: usize,
    memory_usage_kb: usize,
};

pub const PlanCacheStats = struct {
    total_plans: usize,
    total_uses: u32,
    avg_execution_time_ms: f64,
    hit_ratio: f64,
};
