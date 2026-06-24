const std = @import("std");
const file_io = @import("file_io.zig");

/// Write-Ahead Log for transaction safety and durability
pub const WriteAheadLog = struct {
    allocator: std.mem.Allocator,
    fd: ?file_io.File,
    is_transaction_active: bool,
    transaction_id: u64,
    log_entries: std.ArrayListUnmanaged(LogEntry),
    wal_path: []const u8,
    fault_once: ?FaultPoint,

    const Self = @This();

    /// Maximum size for a single data field in a WAL entry (64KB)
    /// This prevents DoS via memory exhaustion from malformed WAL files
    pub const MAX_DATA_FIELD_SIZE: u32 = 64 * 1024;

    /// Maximum total size for old_data + new_data combined (128KB)
    pub const MAX_ENTRY_DATA_SIZE: u32 = 128 * 1024;

    pub const FaultPoint = enum {
        read,
        write,
        partial_write,
        sync,
        truncate,
    };

    pub const Stats = struct {
        path: []const u8,
        size_bytes: u64,
        active_transaction: bool,
        transaction_id: u64,
        buffered_entries: usize,
    };

    pub fn injectFaultOnce(self: *Self, point: FaultPoint) void {
        self.fault_once = point;
    }

    pub fn getStats(self: *Self) !Stats {
        return .{
            .path = self.wal_path,
            .size_bytes = try self.getFileSize(),
            .active_transaction = self.is_transaction_active,
            .transaction_id = self.transaction_id,
            .buffered_entries = self.log_entries.items.len,
        };
    }

    fn consumeFault(self: *Self, point: FaultPoint) bool {
        if (self.fault_once == point) {
            self.fault_once = null;
            return true;
        }
        return false;
    }

    /// Initialize WAL
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !*Self {
        var wal = try allocator.create(Self);
        errdefer allocator.destroy(wal);

        wal.allocator = allocator;
        wal.fd = null;
        wal.is_transaction_active = false;
        wal.transaction_id = 0;
        wal.log_entries = .empty;
        wal.fault_once = null;

        // Create WAL path: db_path + "-wal"
        const wal_path = try std.fmt.allocPrint(allocator, "{s}-wal", .{db_path});
        errdefer allocator.free(wal_path);
        wal.wal_path = wal_path;

        const fd = file_io.open(allocator, wal_path, .read_write_create) catch |err| {
            allocator.free(wal_path);
            allocator.destroy(wal);
            return err;
        };
        wal.fd = fd;

        // Recover from existing WAL if present
        try wal.recover();

        return wal;
    }

    /// Begin a new transaction
    pub fn beginTransaction(self: *Self) !void {
        if (self.is_transaction_active) {
            return error.TransactionAlreadyActive;
        }

        self.transaction_id += 1;
        self.clearLogEntries();

        // Write BEGIN record
        const begin_entry = LogEntry{
            .entry_type = .Begin,
            .transaction_id = self.transaction_id,
            .page_id = 0,
            .offset = 0,
            .old_data = &.{},
            .new_data = &.{},
        };

        // Persist before marking the transaction active or recording it, so a
        // failed BEGIN leaves the WAL in a clean, inactive state.
        try self.writeLogEntry(begin_entry);
        try self.log_entries.append(self.allocator, begin_entry);
        self.is_transaction_active = true;
    }

    /// Log a page modification
    pub fn logPageWrite(self: *Self, page_id: u32, offset: u32, old_data: []const u8, new_data: []const u8) !void {
        if (!self.is_transaction_active) {
            return error.NoActiveTransaction;
        }

        // SECURITY: Enforce size limits to prevent creating oversized WAL entries
        if (old_data.len > MAX_DATA_FIELD_SIZE) return error.WalEntryTooLarge;
        if (new_data.len > MAX_DATA_FIELD_SIZE) return error.WalEntryTooLarge;
        if (old_data.len + new_data.len > MAX_ENTRY_DATA_SIZE) return error.WalEntryTooLarge;

        const old_data_copy = try self.allocator.dupe(u8, old_data);
        errdefer self.allocator.free(old_data_copy);

        const new_data_copy = try self.allocator.dupe(u8, new_data);
        errdefer self.allocator.free(new_data_copy);

        const entry = LogEntry{
            .entry_type = .PageWrite,
            .transaction_id = self.transaction_id,
            .page_id = page_id,
            .offset = offset,
            .old_data = old_data_copy,
            .new_data = new_data_copy,
        };

        // Persist the record before tracking it in memory. If the write fails,
        // the errdefers above free the copies and the entry is never recorded,
        // so the in-memory undo log can never reference freed memory.
        try self.writeLogEntry(entry);
        try self.log_entries.append(self.allocator, entry);
    }

    /// Commit the current transaction
    pub fn commit(self: *Self) !void {
        if (!self.is_transaction_active) {
            return error.NoActiveTransaction;
        }

        // Write COMMIT record
        const commit_entry = LogEntry{
            .entry_type = .Commit,
            .transaction_id = self.transaction_id,
            .page_id = 0,
            .offset = 0,
            .old_data = &.{},
            .new_data = &.{},
        };

        try self.writeLogEntry(commit_entry);

        // Sync to ensure commit is durable
        if (self.fd) |fd| {
            if (self.consumeFault(.sync)) return error.InjectedSyncFailure;
            try file_io.sync(fd);
        }

        self.is_transaction_active = false;
        self.clearLogEntries();
    }

    /// Rollback the current transaction (no page restoration)
    pub fn rollback(self: *Self) !void {
        if (!self.is_transaction_active) {
            return error.NoActiveTransaction;
        }

        // Write ROLLBACK record
        const rollback_entry = LogEntry{
            .entry_type = .Rollback,
            .transaction_id = self.transaction_id,
            .page_id = 0,
            .offset = 0,
            .old_data = &.{},
            .new_data = &.{},
        };

        try self.writeLogEntry(rollback_entry);

        self.is_transaction_active = false;
        self.clearLogEntries();
    }

    /// Rollback the current transaction and restore pages from old_data
    /// This physically undoes all page modifications made during the transaction
    pub fn rollbackWithPager(self: *Self, target_pager: *@import("pager.zig").Pager) !void {
        if (!self.is_transaction_active) {
            return error.NoActiveTransaction;
        }

        // Restore pages from old_data in reverse order (LIFO)
        // This ensures proper undo semantics for overlapping writes
        var i = self.log_entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.log_entries.items[i];

            if (entry.entry_type == .PageWrite and entry.old_data.len > 0) {
                // Restore the old page data
                const page = try target_pager.getPage(entry.page_id);
                const end_offset = entry.offset + @as(u32, @intCast(entry.old_data.len));

                if (end_offset <= page.data.len) {
                    @memcpy(page.data[entry.offset..end_offset], entry.old_data);
                    try target_pager.markDirty(entry.page_id);
                }
            }
        }

        // Flush restored pages to disk
        try target_pager.flush();

        // Write ROLLBACK record to WAL
        const rollback_entry = LogEntry{
            .entry_type = .Rollback,
            .transaction_id = self.transaction_id,
            .page_id = 0,
            .offset = 0,
            .old_data = &.{},
            .new_data = &.{},
        };

        try self.writeLogEntry(rollback_entry);

        self.is_transaction_active = false;
        self.clearLogEntries();

        // Truncate WAL after rollback
        try self.truncateFile();
    }

    /// Checkpoint - apply WAL changes to main database
    pub fn checkpoint(self: *Self) !void {
        try self.checkpointToPager(null);
    }

    /// Checkpoint with a specific pager target
    pub fn checkpointToPager(self: *Self, target_pager: ?*@import("pager.zig").Pager) !void {
        if (self.is_transaction_active) {
            return error.TransactionActive;
        }

        const file_size = try self.getFileSize();
        if (file_size == 0) return;

        // First pass: collect all committed transaction IDs
        var committed_transactions = std.AutoHashMap(u64, void).init(self.allocator);
        defer committed_transactions.deinit();

        var position: i64 = 0;
        var buffer: [8192]u8 = undefined;

        while (@as(u64, @intCast(position)) < file_size) {
            const bytes_read = try self.readAt(&buffer, position);
            if (bytes_read < 25) break;

            var buffer_pos: usize = 0;
            while (buffer_pos + 25 <= bytes_read) {
                const entry = LogEntry.deserialize(self.allocator, buffer[buffer_pos..bytes_read]) catch |err| {
                    if (err == error.BufferTooSmall and buffer_pos == 0 and bytes_read >= 25) {
                        const old_data_len = std.mem.readInt(u32, buffer[17..21], .little);
                        const new_data_len = std.mem.readInt(u32, buffer[21..25], .little);
                        const full_entry_size = 25 + old_data_len + new_data_len;
                        const remaining_file = file_size - @as(u64, @intCast(position));
                        if (full_entry_size == 0 or full_entry_size > remaining_file) break;

                        const large_buf = try self.allocator.alloc(u8, full_entry_size);
                        defer self.allocator.free(large_buf);

                        const large_read = try self.readAt(large_buf, position);
                        if (large_read < full_entry_size) break;

                        const large_entry = try LogEntry.deserialize(self.allocator, large_buf);
                        defer {
                            if (large_entry.old_data.len > 0) self.allocator.free(large_entry.old_data);
                            if (large_entry.new_data.len > 0) self.allocator.free(large_entry.new_data);
                        }

                        if (large_entry.entry_type == .Commit) {
                            try committed_transactions.put(large_entry.transaction_id, {});
                        }

                        position += @as(i64, @intCast(full_entry_size));
                        continue;
                    }
                    if (err != error.BufferTooSmall) return err;
                    break;
                };
                defer {
                    if (entry.old_data.len > 0) self.allocator.free(entry.old_data);
                    if (entry.new_data.len > 0) self.allocator.free(entry.new_data);
                }

                if (entry.entry_type == .Commit) {
                    try committed_transactions.put(entry.transaction_id, {});
                }

                const entry_size = getEntrySize(&entry);
                if (entry_size == 0 or entry_size > (bytes_read - buffer_pos)) break;
                buffer_pos += entry_size;
                position += @as(i64, @intCast(entry_size));
            }

            if (buffer_pos == 0) break;
        }

        // Second pass: apply page writes from committed transactions
        if (target_pager) |pager_inst| {
            position = 0;

            while (@as(u64, @intCast(position)) < file_size) {
                const bytes_read = try self.readAt(&buffer, position);
                if (bytes_read < 25) break;

                var buffer_pos: usize = 0;
                while (buffer_pos + 25 <= bytes_read) {
                    const entry = LogEntry.deserialize(self.allocator, buffer[buffer_pos..bytes_read]) catch |err| {
                        if (err == error.BufferTooSmall and buffer_pos == 0 and bytes_read >= 25) {
                            const old_data_len = std.mem.readInt(u32, buffer[17..21], .little);
                            const new_data_len = std.mem.readInt(u32, buffer[21..25], .little);
                            const full_entry_size = 25 + old_data_len + new_data_len;
                            const remaining_file = file_size - @as(u64, @intCast(position));
                            if (full_entry_size == 0 or full_entry_size > remaining_file) break;

                            const large_buf = try self.allocator.alloc(u8, full_entry_size);
                            defer self.allocator.free(large_buf);

                            const large_read = try self.readAt(large_buf, position);
                            if (large_read < full_entry_size) break;

                            const large_entry = try LogEntry.deserialize(self.allocator, large_buf);
                            defer {
                                if (large_entry.old_data.len > 0) self.allocator.free(large_entry.old_data);
                                if (large_entry.new_data.len > 0) self.allocator.free(large_entry.new_data);
                            }

                            if (large_entry.entry_type == .PageWrite and committed_transactions.contains(large_entry.transaction_id)) {
                                const page = try pager_inst.getPage(large_entry.page_id);
                                const end_offset = large_entry.offset + @as(u32, @intCast(large_entry.new_data.len));
                                if (end_offset > page.data.len) return error.WalEntryOutOfBounds;
                                @memcpy(page.data[large_entry.offset..end_offset], large_entry.new_data);
                                try pager_inst.markDirty(large_entry.page_id);
                            }

                            position += @as(i64, @intCast(full_entry_size));
                            continue;
                        }
                        if (err != error.BufferTooSmall) return err;
                        break;
                    };
                    defer {
                        if (entry.old_data.len > 0) self.allocator.free(entry.old_data);
                        if (entry.new_data.len > 0) self.allocator.free(entry.new_data);
                    }

                    if (entry.entry_type == .PageWrite and committed_transactions.contains(entry.transaction_id)) {
                        const page = try pager_inst.getPage(entry.page_id);
                        const end_offset = entry.offset + @as(u32, @intCast(entry.new_data.len));
                        if (end_offset > page.data.len) return error.WalEntryOutOfBounds;
                        @memcpy(page.data[entry.offset..end_offset], entry.new_data);
                        try pager_inst.markDirty(entry.page_id);
                    }

                    const entry_size = getEntrySize(&entry);
                    if (entry_size == 0 or entry_size > (bytes_read - buffer_pos)) break;
                    buffer_pos += entry_size;
                    position += @as(i64, @intCast(entry_size));
                }

                if (buffer_pos == 0) break;
            }

            // Flush all dirty pages to disk
            try pager_inst.flush();
        }

        // Truncate WAL file after successful checkpoint
        try self.truncateFile();
    }

    /// Get the size of a log entry
    fn getEntrySize(entry: *const LogEntry) usize {
        return 1 + 8 + 4 + 4 + 4 + 4 + entry.old_data.len + entry.new_data.len;
    }

    /// Recover from WAL on startup
    fn recover(self: *Self) !void {
        const file_size = try self.getFileSize();
        if (file_size == 0) return;

        var buffer: [8192]u8 = undefined;
        var position: i64 = 0;
        var max_transaction_id: u64 = 0;

        while (@as(u64, @intCast(position)) < file_size) {
            const bytes_read = try self.readAt(&buffer, position);
            if (bytes_read < 25) break;

            var buffer_pos: usize = 0;
            while (buffer_pos + 25 <= bytes_read) {
                const entry = LogEntry.deserialize(self.allocator, buffer[buffer_pos..bytes_read]) catch |err| {
                    if (err == error.BufferTooSmall and buffer_pos == 0 and bytes_read >= 25) {
                        const old_data_len = std.mem.readInt(u32, buffer[17..21], .little);
                        const new_data_len = std.mem.readInt(u32, buffer[21..25], .little);
                        const full_entry_size = 25 + old_data_len + new_data_len;
                        const remaining_file = file_size - @as(u64, @intCast(position));
                        if (full_entry_size == 0 or full_entry_size > remaining_file) break;

                        const large_buf = try self.allocator.alloc(u8, full_entry_size);
                        defer self.allocator.free(large_buf);

                        const large_read = try self.readAt(large_buf, position);
                        if (large_read < full_entry_size) break;

                        const large_entry = try LogEntry.deserialize(self.allocator, large_buf);
                        defer {
                            if (large_entry.old_data.len > 0) self.allocator.free(large_entry.old_data);
                            if (large_entry.new_data.len > 0) self.allocator.free(large_entry.new_data);
                        }

                        max_transaction_id = @max(max_transaction_id, large_entry.transaction_id);
                        position += @as(i64, @intCast(full_entry_size));
                        continue;
                    }
                    if (err != error.BufferTooSmall) return err;
                    break;
                };
                defer {
                    if (entry.old_data.len > 0) self.allocator.free(entry.old_data);
                    if (entry.new_data.len > 0) self.allocator.free(entry.new_data);
                }

                max_transaction_id = @max(max_transaction_id, entry.transaction_id);

                const entry_size = getEntrySize(&entry);
                if (entry_size == 0 or entry_size > (bytes_read - buffer_pos)) break;
                buffer_pos += entry_size;
                position += @as(i64, @intCast(entry_size));
            }

            if (buffer_pos == 0) break;
        }

        self.transaction_id = max_transaction_id;
    }

    /// Write a log entry to the WAL file
    fn writeLogEntry(self: *Self, entry: LogEntry) !void {
        // Serialize the log entry
        const max_size = 25 + entry.old_data.len + entry.new_data.len;
        const buffer = try self.allocator.alloc(u8, max_size);
        defer self.allocator.free(buffer);

        const serialized = try entry.serialize(buffer);

        // Append to WAL file (write at end)
        const file_size = try self.getFileSize();
        try self.writeAtAll(serialized, @as(i64, @intCast(file_size)));
    }

    fn getFileSize(self: *Self) !u64 {
        if (self.fd) |fd_val| {
            return file_io.size(fd_val);
        }
        return error.FileNotOpen;
    }

    fn readAt(self: *Self, buf: []u8, offset: i64) !usize {
        if (self.fd) |fd_val| {
            if (self.consumeFault(.read)) return error.InjectedReadFailure;
            return file_io.readAtAll(fd_val, buf, offset);
        }
        return error.FileNotOpen;
    }

    fn writeAtAll(self: *Self, buf: []const u8, offset: i64) !void {
        if (self.fd) |fd_val| {
            if (self.consumeFault(.write)) return error.InjectedWriteFailure;
            if (self.consumeFault(.partial_write)) {
                const partial_len = @max(@as(usize, 1), buf.len / 2);
                try file_io.writeAtAll(fd_val, buf[0..partial_len], offset);
                return error.InjectedPartialWrite;
            }
            return file_io.writeAtAll(fd_val, buf, offset);
        }
        return error.FileNotOpen;
    }

    fn truncateFile(self: *Self) !void {
        if (self.consumeFault(.truncate)) return error.InjectedTruncateFailure;
        if (self.fd) |wal_fd| {
            try file_io.truncate(wal_fd, 0);
            return;
        }
        return error.FileNotOpen;
    }

    /// Clear log entries and free memory
    fn clearLogEntries(self: *Self) void {
        for (self.log_entries.items) |entry| {
            if (entry.old_data.len > 0) {
                // Check if this is an allocated slice (not a literal empty slice)
                const old_ptr = @intFromPtr(entry.old_data.ptr);
                if (old_ptr != 0) {
                    self.allocator.free(entry.old_data);
                }
            }
            if (entry.new_data.len > 0) {
                const new_ptr = @intFromPtr(entry.new_data.ptr);
                if (new_ptr != 0) {
                    self.allocator.free(entry.new_data);
                }
            }
        }
        self.log_entries.clearRetainingCapacity();
    }

    /// Clean up WAL
    pub fn deinit(self: *Self) void {
        self.clearLogEntries();
        self.log_entries.deinit(self.allocator);

        if (self.fd) |fd| {
            file_io.close(fd);
        }

        self.allocator.free(self.wal_path);
        self.allocator.destroy(self);
    }
};

/// WAL log entry types
pub const LogEntryType = enum(u8) {
    Begin = 1,
    PageWrite = 2,
    Commit = 3,
    Rollback = 4,
};

/// WAL log entry
pub const LogEntry = struct {
    entry_type: LogEntryType,
    transaction_id: u64,
    page_id: u32,
    offset: u32,
    old_data: []const u8,
    new_data: []const u8,

    /// Serialize log entry to bytes
    pub fn serialize(self: LogEntry, buffer: []u8) ![]const u8 {
        const required_size = 1 + 8 + 4 + 4 + 4 + 4 + self.old_data.len + self.new_data.len;
        if (buffer.len < required_size) return error.BufferTooSmall;

        var pos: usize = 0;

        buffer[pos] = @intFromEnum(self.entry_type);
        pos += 1;

        std.mem.writeInt(u64, buffer[pos..][0..8], self.transaction_id, .little);
        pos += 8;

        std.mem.writeInt(u32, buffer[pos..][0..4], self.page_id, .little);
        pos += 4;

        std.mem.writeInt(u32, buffer[pos..][0..4], self.offset, .little);
        pos += 4;

        std.mem.writeInt(u32, buffer[pos..][0..4], @intCast(self.old_data.len), .little);
        pos += 4;

        std.mem.writeInt(u32, buffer[pos..][0..4], @intCast(self.new_data.len), .little);
        pos += 4;

        if (self.old_data.len > 0) {
            @memcpy(buffer[pos..][0..self.old_data.len], self.old_data);
            pos += self.old_data.len;
        }

        if (self.new_data.len > 0) {
            @memcpy(buffer[pos..][0..self.new_data.len], self.new_data);
            pos += self.new_data.len;
        }

        return buffer[0..pos];
    }

    /// Deserialize log entry from bytes
    pub fn deserialize(allocator: std.mem.Allocator, buffer: []const u8) !LogEntry {
        if (buffer.len < 25) return error.BufferTooSmall;

        var pos: usize = 0;

        const entry_type: LogEntryType = switch (buffer[pos]) {
            1 => .Begin,
            2 => .PageWrite,
            3 => .Commit,
            4 => .Rollback,
            else => return error.InvalidWalEntryType,
        };
        pos += 1;

        const transaction_id = std.mem.readInt(u64, buffer[pos..][0..8], .little);
        pos += 8;

        const page_id = std.mem.readInt(u32, buffer[pos..][0..4], .little);
        pos += 4;

        const offset = std.mem.readInt(u32, buffer[pos..][0..4], .little);
        pos += 4;

        const old_data_len = std.mem.readInt(u32, buffer[pos..][0..4], .little);
        pos += 4;

        const new_data_len = std.mem.readInt(u32, buffer[pos..][0..4], .little);
        pos += 4;

        // SECURITY: Enforce size limits to prevent DoS via memory exhaustion
        if (old_data_len > WriteAheadLog.MAX_DATA_FIELD_SIZE) return error.WalEntryTooLarge;
        if (new_data_len > WriteAheadLog.MAX_DATA_FIELD_SIZE) return error.WalEntryTooLarge;
        if (old_data_len + new_data_len > WriteAheadLog.MAX_ENTRY_DATA_SIZE) return error.WalEntryTooLarge;

        if (buffer.len < pos + old_data_len + new_data_len) return error.BufferTooSmall;

        var old_data: []const u8 = &.{};
        var new_data: []const u8 = &.{};

        if (old_data_len > 0) {
            const old_data_alloc = try allocator.alloc(u8, old_data_len);
            @memcpy(old_data_alloc, buffer[pos..][0..old_data_len]);
            old_data = old_data_alloc;
            pos += old_data_len;
        }

        if (new_data_len > 0) {
            const new_data_alloc = try allocator.alloc(u8, new_data_len);
            errdefer allocator.free(new_data_alloc);
            @memcpy(new_data_alloc, buffer[pos..][0..new_data_len]);
            new_data = new_data_alloc;
        }

        return LogEntry{
            .entry_type = entry_type,
            .transaction_id = transaction_id,
            .page_id = page_id,
            .offset = offset,
            .old_data = old_data,
            .new_data = new_data,
        };
    }
};

test "wal creation and basic operations" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_path = try std.fs.path.join(allocator, &.{ tmp_dir.path, "zqlite_wal_test.db" });
    defer allocator.free(test_path);
    const wal_path = try std.fmt.allocPrint(allocator, "{s}-wal", .{test_path});
    defer allocator.free(wal_path);

    // Clean up
    std.fs.cwd().deleteFile(test_path) catch {};
    std.fs.cwd().deleteFile(wal_path) catch {};

    const wal = try WriteAheadLog.init(allocator, test_path);
    defer wal.deinit();

    // Test transaction lifecycle
    try wal.beginTransaction();
    try std.testing.expect(wal.is_transaction_active);

    try wal.logPageWrite(1, 0, "old", "new");
    try wal.commit();
    try std.testing.expect(!wal.is_transaction_active);

    // Clean up
    std.fs.cwd().deleteFile(test_path) catch {};
    std.fs.cwd().deleteFile(wal_path) catch {};
}

test "wal rollback" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_path = try std.fs.path.join(allocator, &.{ tmp_dir.path, "zqlite_wal_rollback_test.db" });
    defer allocator.free(test_path);
    const wal_path = try std.fmt.allocPrint(allocator, "{s}-wal", .{test_path});
    defer allocator.free(wal_path);

    std.fs.cwd().deleteFile(test_path) catch {};
    std.fs.cwd().deleteFile(wal_path) catch {};

    const wal = try WriteAheadLog.init(allocator, test_path);
    defer wal.deinit();

    try wal.beginTransaction();
    try wal.logPageWrite(1, 0, "before", "after");
    try wal.rollback();

    try std.testing.expect(!wal.is_transaction_active);

    std.fs.cwd().deleteFile(test_path) catch {};
    std.fs.cwd().deleteFile(wal_path) catch {};
}

test "wal handles truncated entry safely" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_path = try std.fs.path.join(allocator, &.{ tmp_dir.path, "zqlite_wal_truncated.db" });
    defer allocator.free(test_path);
    const wal_path = try std.fmt.allocPrint(allocator, "{s}-wal", .{test_path});
    defer allocator.free(wal_path);

    std.fs.cwd().deleteFile(test_path) catch {};
    std.fs.cwd().deleteFile(wal_path) catch {};

    const wal = try WriteAheadLog.init(allocator, test_path);
    defer wal.deinit();

    var header: [25]u8 = undefined;
    header[0] = @intFromEnum(LogEntryType.PageWrite);
    std.mem.writeInt(u64, header[1..9], 1, .little);
    std.mem.writeInt(u32, header[9..13], 1, .little);
    std.mem.writeInt(u32, header[13..17], 0, .little);
    std.mem.writeInt(u32, header[17..21], 1024, .little);
    std.mem.writeInt(u32, header[21..25], 1024, .little);

    try wal.writeAtAll(&header, 0);

    try wal.checkpoint();

    std.fs.cwd().deleteFile(test_path) catch {};
    std.fs.cwd().deleteFile(wal_path) catch {};
}
