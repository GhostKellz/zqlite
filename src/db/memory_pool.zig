const std = @import("std");

/// High-performance memory pool for frequent allocations
pub const MemoryPool = struct {
    allocator: std.mem.Allocator,
    pools: std.AutoHashMap(usize, Pool),
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    /// Individual pool for a specific size class
    const Pool = struct {
        free_list: ?*FreeNode,
        block_size: usize,
        total_allocated: usize,
        active_count: usize,

        const FreeNode = struct {
            next: ?*FreeNode,
        };

        fn init(block_size: usize) Pool {
            return Pool{
                .free_list = null,
                .block_size = block_size,
                .total_allocated = 0,
                .active_count = 0,
            };
        }

        fn allocate(self: *Pool, allocator: std.mem.Allocator) ![]u8 {
            if (self.free_list) |node| {
                // Reuse from free list
                self.free_list = node.next;
                self.active_count += 1;
                return @as([*]u8, @ptrCast(node))[0..self.block_size];
            }

            // Allocate new block
            const memory = try allocator.alloc(u8, self.block_size);
            self.total_allocated += self.block_size;
            self.active_count += 1;
            return memory;
        }

        fn deallocate(self: *Pool, memory: []u8) void {
            const node: *FreeNode = @ptrCast(@alignCast(memory.ptr));
            node.next = self.free_list;
            self.free_list = node;
            self.active_count -= 1;
        }

        fn getStats(self: *const Pool) PoolStats {
            return PoolStats{
                .block_size = self.block_size,
                .total_allocated = self.total_allocated,
                .active_count = self.active_count,
                .free_count = self.getFreeCount(),
            };
        }

        fn getFreeCount(self: *const Pool) u32 {
            var count: u32 = 0;
            var current = self.free_list;
            while (current) |node| {
                count += 1;
                current = node.next;
            }
            return count;
        }
    };

    /// Pool statistics
    pub const PoolStats = struct {
        block_size: usize,
        total_allocated: usize,
        active_count: usize,
        free_count: u32,
    };

    /// Global memory statistics
    pub const GlobalStats = struct {
        total_pools: u32,
        total_allocated: usize,
        total_active: usize,
        arena_used: usize,
    };

    /// Initialize memory pool
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .pools = std.AutoHashMap(usize, Pool).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// Deinitialize memory pool
    pub fn deinit(self: *Self) void {
        self.pools.deinit();
        self.arena.deinit();
    }

    /// Get size class for allocation (rounds up to next power of 2)
    fn getSizeClass(size: usize) usize {
        if (size <= 8) return 8;
        if (size <= 16) return 16;
        if (size <= 32) return 32;
        if (size <= 64) return 64;
        if (size <= 128) return 128;
        if (size <= 256) return 256;
        if (size <= 512) return 512;
        if (size <= 1024) return 1024;
        if (size <= 2048) return 2048;
        if (size <= 4096) return 4096;

        // For larger sizes, round up to next 4KB boundary
        return ((size + 4095) / 4096) * 4096;
    }

    /// Allocate memory from pool
    pub fn alloc(self: *Self, size: usize) ![]u8 {
        const size_class = getSizeClass(size);

        // Get or create pool for this size class
        const pool_result = try self.pools.getOrPut(size_class);
        if (!pool_result.found_existing) {
            pool_result.value_ptr.* = Pool.init(size_class);
        }

        const memory = try pool_result.value_ptr.allocate(self.allocator);
        return memory[0..size]; // Return only requested size
    }

    /// Allocate aligned memory from pool
    pub fn allocAligned(self: *Self, size: usize, alignment: usize) ![]u8 {
        const aligned_size = std.mem.alignForward(usize, size, alignment);
        return self.alloc(aligned_size);
    }

    /// Deallocate memory back to pool
    pub fn free(self: *Self, memory: []u8) void {
        if (memory.len == 0) return;

        const size_class = getSizeClass(memory.len);

        if (self.pools.getPtr(size_class)) |pool| {
            // Extend memory to full size class for pool
            const full_memory = memory.ptr[0..size_class];
            pool.deallocate(full_memory);
        }
        // If pool doesn't exist, memory might be from arena - ignore
    }

    /// Allocate from arena (for temporary allocations)
    pub fn allocArena(self: *Self, size: usize) ![]u8 {
        return self.arena.allocator().alloc(u8, size);
    }

    /// Reset arena (frees all arena allocations)
    pub fn resetArena(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Get statistics for a specific pool
    pub fn getPoolStats(self: *Self, size_class: usize) ?PoolStats {
        if (self.pools.get(size_class)) |pool| {
            return pool.getStats();
        }
        return null;
    }

    /// Get global memory statistics
    pub fn getGlobalStats(self: *Self) GlobalStats {
        var total_allocated: usize = 0;
        var total_active: usize = 0;

        var pool_iter = self.pools.iterator();
        while (pool_iter.next()) |entry| {
            const pool = entry.value_ptr;
            total_allocated += pool.total_allocated;
            total_active += pool.active_count * pool.block_size;
        }

        return GlobalStats{
            .total_pools = @intCast(self.pools.count()),
            .total_allocated = total_allocated,
            .total_active = total_active,
            .arena_used = self.arena.queryCapacity(),
        };
    }

    /// Cleanup unused pools (remove pools with no active allocations)
    pub fn cleanup(self: *Self) void {
        var to_remove: std.ArrayListUnmanaged(usize) = .empty;
        defer to_remove.deinit(self.allocator);

        var pool_iter = self.pools.iterator();
        while (pool_iter.next()) |entry| {
            if (entry.value_ptr.active_count == 0) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |size_class| {
            _ = self.pools.remove(size_class);
        }
    }
};

/// Pooled allocator that wraps MemoryPool
pub const PooledAllocator = struct {
    pool: *MemoryPool,

    const Self = @This();

    pub fn init(pool: *MemoryPool) Self {
        return Self{ .pool = pool };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, log2_ptr_align: u8, ra: usize) ?[*]u8 {
        _ = ra;
        const self: *Self = @ptrCast(@alignCast(ctx));
        const alignment = @as(usize, 1) << @intCast(log2_ptr_align);

        const memory = self.pool.allocAligned(len, alignment) catch return null;
        return memory.ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, new_len: usize, ra: usize) bool {
        _ = ctx;
        _ = log2_buf_align;
        _ = ra;
        // Simple resize - only allow shrinking for now
        return new_len <= buf.len;
    }

    fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, ra: usize) void {
        _ = log2_buf_align;
        _ = ra;
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.pool.free(buf);
    }
};

test "memory pool basic operations" {
    var pool = MemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    // Test allocation
    const mem1 = try pool.alloc(64);
    try std.testing.expectEqual(@as(usize, 64), mem1.len);

    const mem2 = try pool.alloc(32);
    try std.testing.expectEqual(@as(usize, 32), mem2.len);

    // Test deallocation and reuse
    pool.free(mem1);
    const mem3 = try pool.alloc(64);
    try std.testing.expectEqual(@as(usize, 64), mem3.len);

    // Test statistics
    const stats = pool.getGlobalStats();
    try std.testing.expect(stats.total_pools > 0);
    try std.testing.expect(stats.total_allocated > 0);

    pool.free(mem2);
    pool.free(mem3);
}

test "memory pool size classes" {
    try std.testing.expectEqual(@as(usize, 8), MemoryPool.getSizeClass(1));
    try std.testing.expectEqual(@as(usize, 8), MemoryPool.getSizeClass(8));
    try std.testing.expectEqual(@as(usize, 16), MemoryPool.getSizeClass(9));
    try std.testing.expectEqual(@as(usize, 16), MemoryPool.getSizeClass(16));
    try std.testing.expectEqual(@as(usize, 32), MemoryPool.getSizeClass(17));
    try std.testing.expectEqual(@as(usize, 8192), MemoryPool.getSizeClass(5000));
}

test "pooled allocator interface" {
    var pool = MemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    var pooled = PooledAllocator.init(&pool);
    const allocator = pooled.allocator();

    // Test through standard allocator interface
    const memory = try allocator.alloc(u8, 128);
    try std.testing.expectEqual(@as(usize, 128), memory.len);

    allocator.free(memory);
}
