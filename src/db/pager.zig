const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const encryption = @import("encryption.zig");
const Io = std.Io;

/// Doubly-linked list node for O(1) LRU operations
const LRUNode = struct {
    page_id: u32,
    prev: ?*LRUNode = null,
    next: ?*LRUNode = null,
};

/// High-performance LRU cache for pages
const LRUCache = struct {
    allocator: std.mem.Allocator,
    capacity: u32,
    page_map: std.AutoHashMap(u32, *Page),
    node_map: std.AutoHashMap(u32, *LRUNode), // Maps page_id to LRU node
    head: ?*LRUNode = null, // Most recently used
    tail: ?*LRUNode = null, // Least recently used

    fn init(allocator: std.mem.Allocator, capacity: u32) LRUCache {
        return LRUCache{
            .allocator = allocator,
            .capacity = capacity,
            .page_map = std.AutoHashMap(u32, *Page).init(allocator),
            .node_map = std.AutoHashMap(u32, *LRUNode).init(allocator),
        };
    }

    fn deinit(self: *LRUCache) void {
        // Clean up nodes
        var node_iter = self.node_map.iterator();
        while (node_iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.node_map.deinit();
        self.page_map.deinit();
    }

    fn moveToHead(self: *LRUCache, node: *LRUNode) void {
        if (self.head == node) return; // Already at head

        // Remove from current position
        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.tail = node.next; // node was tail
        }

        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.head = node.prev; // node was head
        }

        // Add to head
        node.prev = self.head;
        node.next = null;

        if (self.head) |head| {
            head.next = node;
        }
        self.head = node;

        if (self.tail == null) {
            self.tail = node;
        }
    }

    fn addToHead(self: *LRUCache, node: *LRUNode) void {
        node.prev = self.head;
        node.next = null;

        if (self.head) |head| {
            head.next = node;
        }
        self.head = node;

        if (self.tail == null) {
            self.tail = node;
        }
    }

    fn removeTail(self: *LRUCache) ?*LRUNode {
        const tail = self.tail orelse return null;

        if (tail.next) |next| {
            next.prev = tail.prev;
        } else {
            self.head = tail.prev; // tail was head
        }

        if (tail.prev) |prev| {
            prev.next = tail.next;
        } else {
            self.tail = tail.next; // tail was tail
        }

        return tail;
    }

    fn get(self: *LRUCache, page_id: u32) ?*Page {
        const page = self.page_map.get(page_id) orelse return null;

        if (self.node_map.get(page_id)) |node| {
            self.moveToHead(node);
        }

        return page;
    }

    fn put(self: *LRUCache, page_id: u32, page: *Page) !?*Page {
        if (self.page_map.get(page_id)) |existing_page| {
            // Update existing
            try self.page_map.put(page_id, page);
            if (self.node_map.get(page_id)) |node| {
                self.moveToHead(node);
            }
            return existing_page;
        }

        // Check capacity
        var evicted_page: ?*Page = null;
        if (self.page_map.count() >= self.capacity) {
            if (self.removeTail()) |tail_node| {
                if (self.page_map.fetchRemove(tail_node.page_id)) |entry| {
                    evicted_page = entry.value;
                }
                _ = self.node_map.remove(tail_node.page_id);
                self.allocator.destroy(tail_node);
            }
        }

        // Add new page
        const new_node = try self.allocator.create(LRUNode);
        new_node.* = LRUNode{ .page_id = page_id };

        try self.page_map.put(page_id, page);
        try self.node_map.put(page_id, new_node);
        self.addToHead(new_node);

        return evicted_page;
    }

    fn remove(self: *LRUCache, page_id: u32) ?*Page {
        const page = self.page_map.fetchRemove(page_id) orelse return null;

        if (self.node_map.fetchRemove(page_id)) |entry| {
            const node = entry.value;

            // Remove from linked list
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.tail = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.head = node.prev;
            }

            self.allocator.destroy(node);
        }

        return page.value;
    }

    fn count(self: *LRUCache) u32 {
        return @intCast(self.page_map.count());
    }

    fn iterator(self: *LRUCache) std.AutoHashMap(u32, *Page).Iterator {
        return self.page_map.iterator();
    }
};

/// Page-based storage manager using POSIX file descriptors
pub const Pager = struct {
    allocator: std.mem.Allocator,
    fd: ?posix.fd_t,
    cache: LRUCache,
    next_page_id: u32,
    page_size: u32,
    is_memory: bool,
    cache_hits: u64,
    cache_misses: u64,
    encryption: encryption.Encryption,

    const Self = @This();
    pub const DEFAULT_PAGE_SIZE = 4096;
    const MAX_CACHED_PAGES = 1000;

    /// Initialize pager with file backing
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Self {
        var pager = try allocator.create(Self);
        pager.allocator = allocator;
        pager.fd = null;
        pager.cache = LRUCache.init(allocator, MAX_CACHED_PAGES);
        pager.page_size = DEFAULT_PAGE_SIZE;
        pager.is_memory = false;
        pager.next_page_id = 1;
        pager.cache_hits = 0;
        pager.cache_misses = 0;
        pager.encryption = encryption.Encryption.initPlain();

        if (comptime native_os == .windows) {
            allocator.destroy(pager);
            return error.Unsupported;
        }

        // Convert path to null-terminated string for posix
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        // Open or create the database file using POSIX
        const fd = posix.openat(posix.AT.FDCWD, path_z, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
        }, 0o644) catch |err| {
            allocator.destroy(pager);
            return err;
        };
        pager.fd = fd;

        // Read existing page count from file size using lseek
        const file_size = getFileSize(fd) catch 0;
        if (file_size > 0) {
            pager.next_page_id = @intCast(file_size / DEFAULT_PAGE_SIZE + 1);
        }

        return pager;
    }

    /// Initialize in-memory pager
    pub fn initMemory(allocator: std.mem.Allocator) !*Self {
        var pager = try allocator.create(Self);
        pager.allocator = allocator;
        pager.fd = null;
        pager.cache = LRUCache.init(allocator, MAX_CACHED_PAGES);
        pager.page_size = DEFAULT_PAGE_SIZE;
        pager.is_memory = true;
        pager.next_page_id = 1;
        pager.cache_hits = 0;
        pager.cache_misses = 0;
        pager.encryption = encryption.Encryption.initPlain();

        return pager;
    }

    /// Allocate a new page
    pub fn allocatePage(self: *Self) !u32 {
        const page_id = self.next_page_id;
        self.next_page_id += 1;

        // Create new page
        const page = try self.allocator.create(Page);
        page.* = Page{
            .id = page_id,
            .data = try self.allocator.alloc(u8, self.page_size),
            .is_dirty = true,
        };

        // Zero out the page
        @memset(page.data, 0);

        // Add to cache (handles eviction automatically)
        if (try self.cache.put(page_id, page)) |evicted_page| {
            // Handle evicted page
            if (evicted_page.is_dirty) {
                try self.writePage(evicted_page);
            }
            self.allocator.free(evicted_page.data);
            self.allocator.destroy(evicted_page);
        }

        return page_id;
    }

    /// Get a page (from cache or storage)
    pub fn getPage(self: *Self, page_id: u32) !*Page {
        // Check cache first (automatically updates LRU)
        if (self.cache.get(page_id)) |page| {
            self.cache_hits += 1;
            return page;
        }

        self.cache_misses += 1;

        // Load from storage
        const page = try self.allocator.create(Page);
        page.* = Page{
            .id = page_id,
            .data = try self.allocator.alloc(u8, self.page_size),
            .is_dirty = false,
        };

        if (!self.is_memory) {
            const offset: i64 = @as(i64, page_id - 1) * @as(i64, self.page_size);
            if (self.fd) |fd| {
                const bytes_read = try preadAll(fd, page.data, offset);
                if (bytes_read < self.page_size) {
                    @memset(page.data[bytes_read..], 0);
                }
            } else {
                @memset(page.data, 0);
            }
        } else {
            // In-memory: page doesn't exist yet, zero it out
            @memset(page.data, 0);
        }

        // Add to cache (handles eviction and LRU automatically)
        if (try self.cache.put(page_id, page)) |evicted_page| {
            // Handle evicted page
            if (evicted_page.is_dirty) {
                try self.writePage(evicted_page);
            }
            self.allocator.free(evicted_page.data);
            self.allocator.destroy(evicted_page);
        }

        return page;
    }

    /// Mark a page as dirty (needs to be written to storage)
    pub fn markDirty(self: *Self, page_id: u32) !void {
        if (self.cache.get(page_id)) |page| {
            page.is_dirty = true;
        } else {
            return error.PageNotInCache;
        }
    }

    /// Flush all dirty pages to storage
    pub fn flush(self: *Self) !void {
        if (self.is_memory) return; // No flushing needed for in-memory

        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            const page = entry.value_ptr.*;
            if (page.is_dirty) {
                try self.writePage(page);
                page.is_dirty = false;
            }
        }

        // Sync file to disk
        if (self.fd) |fd| {
            posix.fdatasync(fd) catch {};
        }
    }

    /// Write a page to storage using pwrite
    fn writePage(self: *Self, page: *Page) !void {
        const offset: i64 = @as(i64, page.id - 1) * @as(i64, self.page_size);
        if (self.fd) |fd| {
            try pwriteAll(fd, page.data, offset);
        }
    }

    /// Get cache statistics
    pub fn getCacheStats(self: *Self) CacheStats {
        return CacheStats{
            .hits = self.cache_hits,
            .misses = self.cache_misses,
            .hit_ratio = if (self.cache_hits + self.cache_misses > 0)
                @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(self.cache_hits + self.cache_misses))
            else
                0.0,
            .cached_pages = self.cache.count(),
        };
    }

    /// Get total number of pages
    pub fn getPageCount(self: *Self) u32 {
        return self.next_page_id - 1;
    }

    /// Clean up pager
    pub fn deinit(self: *Self) void {
        // Flush any remaining dirty pages
        self.flush() catch {};

        // Clean up cache
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            const page = entry.value_ptr.*;
            self.allocator.free(page.data);
            self.allocator.destroy(page);
        }
        self.cache.deinit();

        // Close file
        if (self.fd) |fd| {
            Io.Threaded.closeFd(fd);
        }

        self.allocator.destroy(self);
    }
};

/// Get file size using lseek
fn getFileSize(fd: posix.fd_t) !u64 {
    const SEEK_END = 2;
    const SEEK_SET = 0;

    if (comptime native_os == .windows) {
        return error.Unsupported;
    }

    const end_rc = std.os.linux.lseek(fd, 0, SEEK_END);
    if (@as(isize, @bitCast(end_rc)) < 0) {
        return error.SeekError;
    }

    const start_rc = std.os.linux.lseek(fd, 0, SEEK_SET);
    if (@as(isize, @bitCast(start_rc)) < 0) {
        return error.SeekError;
    }

    return end_rc;
}

/// POSIX pread - read at offset without changing file position
fn preadAll(fd: posix.fd_t, buf: []u8, offset: i64) !usize {
    var total_read: usize = 0;
    while (total_read < buf.len) {
        const rc = blk: {
            if (comptime native_os == .windows) {
                return error.Unsupported;
            }
            const read_rc = std.os.linux.pread(fd, buf.ptr + total_read, buf.len - total_read, offset + @as(i64, @intCast(total_read)));
            break :blk read_rc;
        };
        const signed_rc = @as(isize, @bitCast(rc));
        if (signed_rc < 0) {
            if (@as(usize, @bitCast(-signed_rc)) == 4) continue; // EINTR
            return error.ReadError;
        }
        const bytes_read: usize = @bitCast(signed_rc);
        if (bytes_read == 0) break;
        total_read += bytes_read;
    }
    return total_read;
}

/// POSIX pwrite - write at offset without changing file position
fn pwriteAll(fd: posix.fd_t, buf: []const u8, offset: i64) !void {
    var total_written: usize = 0;
    while (total_written < buf.len) {
        const rc = blk: {
            if (comptime native_os == .windows) {
                return error.Unsupported;
            }
            const write_rc = std.os.linux.pwrite(fd, buf.ptr + total_written, buf.len - total_written, offset + @as(i64, @intCast(total_written)));
            break :blk write_rc;
        };
        const signed_rc = @as(isize, @bitCast(rc));
        if (signed_rc < 0) {
            if (@as(usize, @bitCast(-signed_rc)) == 4) continue; // EINTR
            return error.WriteError;
        }
        const bytes_written: usize = @bitCast(signed_rc);
        if (bytes_written == 0) return error.WriteError;
        total_written += bytes_written;
    }
}

/// Cache statistics
pub const CacheStats = struct {
    hits: u64,
    misses: u64,
    hit_ratio: f64,
    cached_pages: u32,
};

/// Database page
pub const Page = struct {
    id: u32,
    data: []u8,
    is_dirty: bool,
};

test "pager creation" {
    const allocator = std.testing.allocator;
    const pager = try Pager.initMemory(allocator);
    defer pager.deinit();

    try std.testing.expect(pager.is_memory);
    try std.testing.expectEqual(@as(u32, 1), pager.next_page_id);
}

test "page allocation" {
    const allocator = std.testing.allocator;
    const pager = try Pager.initMemory(allocator);
    defer pager.deinit();

    const page_id = try pager.allocatePage();
    try std.testing.expectEqual(@as(u32, 1), page_id);
    try std.testing.expectEqual(@as(u32, 2), pager.next_page_id);
}

test "file persistence" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_path = try std.fs.path.join(allocator, &.{ tmp_dir.path, "zqlite_pager_test.db" });
    defer allocator.free(test_path);

    // Create pager and write data
    {
        const pager = try Pager.init(allocator, test_path);
        defer pager.deinit();

        const page_id = try pager.allocatePage();
        const page = try pager.getPage(page_id);
        @memcpy(page.data[0..5], "hello");
        page.is_dirty = true;
        try pager.flush();
    }

    // Reopen and verify data persisted
    {
        const pager = try Pager.init(allocator, test_path);
        defer pager.deinit();

        const page = try pager.getPage(1);
        try std.testing.expectEqualSlices(u8, "hello", page.data[0..5]);
    }
}
