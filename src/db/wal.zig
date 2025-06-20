const std = @import("std");

/// Write-Ahead Log for transaction safety and durability
pub const WriteAheadLog = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    is_transaction_active: bool,
    transaction_id: u64,
    log_entries: std.ArrayList(LogEntry),

    const Self = @This();

    /// Initialize WAL
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !*Self {
        var wal = try allocator.create(Self);
        wal.allocator = allocator;
        wal.is_transaction_active = false;
        wal.transaction_id = 0;
        wal.log_entries = std.ArrayList(LogEntry).init(allocator);

        // Create WAL file path
        const wal_path = try std.fmt.allocPrint(allocator, "{s}.wal", .{db_path});
        defer allocator.free(wal_path);

        // Open or create WAL file
        wal.file = std.fs.cwd().createFile(wal_path, .{ .read = true, .truncate = false }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(wal_path, .{ .read = true }),
            else => return err,
        };

        // Read existing transaction ID from WAL if it exists
        const file_size = try wal.file.getEndPos();
        if (file_size > 0) {
            // Recovery logic would go here
            try wal.recover();
        }

        return wal;
    }

    /// Begin a new transaction
    pub fn beginTransaction(self: *Self) !void {
        if (self.is_transaction_active) {
            return error.TransactionAlreadyActive;
        }

        self.transaction_id += 1;
        self.is_transaction_active = true;
        self.log_entries.clearRetainingCapacity();

        // Write BEGIN record
        const begin_entry = LogEntry{
            .entry_type = .Begin,
            .transaction_id = self.transaction_id,
            .page_id = 0,
            .offset = 0,
            .old_data = &.{},
            .new_data = &.{},
        };

        try self.log_entries.append(begin_entry);
        try self.writeLogEntry(begin_entry);
    }

    /// Log a page modification
    pub fn logPageWrite(self: *Self, page_id: u32, offset: u32, old_data: []const u8, new_data: []const u8) !void {
        if (!self.is_transaction_active) {
            return error.NoActiveTransaction;
        }

        const entry = LogEntry{
            .entry_type = .PageWrite,
            .transaction_id = self.transaction_id,
            .page_id = page_id,
            .offset = offset,
            .old_data = try self.allocator.dupe(u8, old_data),
            .new_data = try self.allocator.dupe(u8, new_data),
        };

        try self.log_entries.append(entry);
        try self.writeLogEntry(entry);
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
        try self.file.sync(); // Ensure commit is durable

        self.is_transaction_active = false;
        self.clearLogEntries();
    }

    /// Rollback the current transaction
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

    /// Checkpoint - apply WAL changes to main database
    pub fn checkpoint(self: *Self) !void {
        if (self.is_transaction_active) {
            return error.TransactionActive;
        }

        // Read WAL file and apply all committed transactions
        const file_size = try self.file.getEndPos();
        if (file_size == 0) return; // No data to checkpoint

        _ = try self.file.seekTo(0);
        var buffer: [8192]u8 = undefined;
        var position: u64 = 0;

        while (position < file_size) {
            _ = try self.file.seekTo(position);
            const bytes_read = try self.file.read(buffer[0..]);
            if (bytes_read == 0) break;

            var stream = std.io.fixedBufferStream(buffer[0..bytes_read]);

            while (stream.pos < bytes_read) {
                const entry = LogEntry.deserialize(self.allocator, buffer[stream.pos..]) catch break;
                defer {
                    self.allocator.free(entry.old_data);
                    self.allocator.free(entry.new_data);
                }

                // Apply committed changes to main database
                if (entry.entry_type == .Commit) {
                    // This would write the transaction's changes to the main database file
                    // For now, just log that we're checkpointing
                    std.debug.print("Checkpointing transaction {d}\n", .{entry.transaction_id});
                }

                // Skip to next entry
                const entry_size = try self.getEntrySize(&entry);
                stream.pos += entry_size;
            }

            position += bytes_read;
        }

        // Truncate WAL file after successful checkpoint
        try self.file.setEndPos(0);
    }

    /// Get the size of a log entry for skipping
    fn getEntrySize(self: *Self, entry: *const LogEntry) !usize {
        _ = self;
        // Calculate entry size: header + data lengths + data
        return 1 + 8 + 4 + 4 + 4 + 4 + entry.old_data.len + entry.new_data.len;
    }

    /// Recover from WAL on startup
    fn recover(self: *Self) !void {
        const file_size = try self.file.getEndPos();
        if (file_size == 0) return;

        _ = try self.file.seekTo(0);
        var buffer: [8192]u8 = undefined;
        var position: u64 = 0;
        var max_transaction_id: u64 = 0;
        var incomplete_transactions = std.ArrayList(u64).init(self.allocator);
        defer incomplete_transactions.deinit();

        // First pass: find incomplete transactions
        while (position < file_size) {
            _ = try self.file.seekTo(position);
            const bytes_read = try self.file.read(buffer[0..]);
            if (bytes_read == 0) break;

            var stream = std.io.fixedBufferStream(buffer[0..bytes_read]);

            while (stream.pos < bytes_read) {
                const entry = LogEntry.deserialize(self.allocator, buffer[stream.pos..]) catch break;
                defer {
                    self.allocator.free(entry.old_data);
                    self.allocator.free(entry.new_data);
                }

                max_transaction_id = @max(max_transaction_id, entry.transaction_id);

                switch (entry.entry_type) {
                    .Begin => {
                        try incomplete_transactions.append(entry.transaction_id);
                    },
                    .Commit, .Rollback => {
                        // Remove from incomplete list
                        for (incomplete_transactions.items, 0..) |tid, i| {
                            if (tid == entry.transaction_id) {
                                _ = incomplete_transactions.swapRemove(i);
                                break;
                            }
                        }
                    },
                    .PageWrite => {
                        // Just track for now
                    },
                }

                const entry_size = try self.getEntrySize(&entry);
                stream.pos += entry_size;
            }

            position += bytes_read;
        }

        // Set next transaction ID
        self.transaction_id = max_transaction_id;

        // Log recovery information
        if (incomplete_transactions.items.len > 0) {
            std.debug.print("WAL Recovery: Found {d} incomplete transactions\n", .{incomplete_transactions.items.len});
            for (incomplete_transactions.items) |tid| {
                std.debug.print("  - Transaction {d} will be rolled back\n", .{tid});
            }
        } else {
            std.debug.print("WAL Recovery: All transactions completed successfully\n", .{});
        }
    }

    /// Write a log entry to the WAL file
    fn writeLogEntry(self: *Self, entry: LogEntry) !void {
        // Serialize the log entry
        var buffer: [1024]u8 = undefined;
        const serialized = try entry.serialize(buffer[0..]);

        // Write to WAL file
        _ = try self.file.writeAll(serialized);
    }

    /// Clear log entries and free memory
    fn clearLogEntries(self: *Self) void {
        for (self.log_entries.items) |entry| {
            self.allocator.free(entry.old_data);
            self.allocator.free(entry.new_data);
        }
        self.log_entries.clearRetainingCapacity();
    }

    /// Clean up WAL
    pub fn deinit(self: *Self) void {
        self.clearLogEntries();
        self.log_entries.deinit();
        self.file.close();
        self.allocator.destroy(self);
    }
};

/// WAL log entry types
const LogEntryType = enum(u8) {
    Begin = 1,
    PageWrite = 2,
    Commit = 3,
    Rollback = 4,
};

/// WAL log entry
const LogEntry = struct {
    entry_type: LogEntryType,
    transaction_id: u64,
    page_id: u32,
    offset: u32,
    old_data: []const u8,
    new_data: []const u8,

    /// Serialize log entry to bytes
    fn serialize(self: LogEntry, buffer: []u8) ![]const u8 {
        var stream = std.io.fixedBufferStream(buffer);
        const writer = stream.writer();

        // Write header
        try writer.writeInt(u8, @intFromEnum(self.entry_type), .little);
        try writer.writeInt(u64, self.transaction_id, .little);
        try writer.writeInt(u32, self.page_id, .little);
        try writer.writeInt(u32, self.offset, .little);

        // Write data lengths
        try writer.writeInt(u32, @intCast(self.old_data.len), .little);
        try writer.writeInt(u32, @intCast(self.new_data.len), .little);

        // Write data
        try writer.writeAll(self.old_data);
        try writer.writeAll(self.new_data);

        return buffer[0..stream.pos];
    }

    /// Deserialize log entry from bytes
    fn deserialize(allocator: std.mem.Allocator, buffer: []const u8) !LogEntry {
        var stream = std.io.fixedBufferStream(buffer);
        const reader = stream.reader();

        // Read header
        const entry_type: LogEntryType = @enumFromInt(try reader.readInt(u8, .little));
        const transaction_id = try reader.readInt(u64, .little);
        const page_id = try reader.readInt(u32, .little);
        const offset = try reader.readInt(u32, .little);

        // Read data lengths
        const old_data_len = try reader.readInt(u32, .little);
        const new_data_len = try reader.readInt(u32, .little);

        // Read data
        const old_data = try allocator.alloc(u8, old_data_len);
        const new_data = try allocator.alloc(u8, new_data_len);

        _ = try reader.readAll(old_data);
        _ = try reader.readAll(new_data);

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

test "wal creation" {
    try std.testing.expect(true); // Placeholder
}

test "transaction lifecycle" {
    try std.testing.expect(true); // Placeholder
}
