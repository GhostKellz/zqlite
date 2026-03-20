const std = @import("std");
const storage = @import("../db/storage.zig");
const mvcc = @import("mvcc_transactions.zig");
const zsync = @import("zsync");

/// Deterministic Execution Engine - TigerBeetle Inspired
/// Ensures reproducible results across runs for financial auditing
pub const DeterministicEngine = struct {
    allocator: std.mem.Allocator,
    mvcc_manager: *mvcc.MVCCTransactionManager,
    deterministic_clock: DeterministicClock,
    hash_state: HashState,
    execution_log: std.ArrayListUnmanaged(ExecutionRecord),
    random_state: RandomState,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, mvcc_manager: *mvcc.MVCCTransactionManager, initial_seed: u64) !Self {
        return Self{
            .allocator = allocator,
            .mvcc_manager = mvcc_manager,
            .deterministic_clock = DeterministicClock.init(initial_seed),
            .hash_state = HashState.init(initial_seed),
            .execution_log = .{},
            .random_state = RandomState.init(initial_seed),
        };
    }

    /// Execute operation with deterministic guarantees
    pub fn executeOperation(self: *Self, operation: DeterministicOperation) !DeterministicResult {
        const start_timestamp = self.deterministic_clock.now();
        const operation_id = self.hash_state.hashOperation(operation);

        // Log operation for reproducibility
        const record = ExecutionRecord{
            .operation_id = operation_id,
            .timestamp = start_timestamp,
            .operation_type = operation.operation_type,
            .input_hash = self.hash_state.hashInput(operation.input),
            .deterministic_state = self.getDeterministicState(),
        };

        try self.execution_log.append(self.allocator, record);

        // Execute operation with deterministic context
        const result = try self.executeWithDeterministicContext(operation);

        // Update deterministic state
        self.updateDeterministicState(operation_id, result);

        return DeterministicResult{
            .operation_id = operation_id,
            .timestamp = start_timestamp,
            .result = result,
            .execution_hash = self.hash_state.hashResult(result),
        };
    }

    /// Execute batch of operations deterministically
    pub fn executeBatch(self: *Self, operations: []const DeterministicOperation) ![]DeterministicResult {
        var results = try self.allocator.alloc(DeterministicResult, operations.len);

        // Sort operations by deterministic order for consistent execution
        const sorted_ops = try self.allocator.alloc(DeterministicOperation, operations.len);
        defer self.allocator.free(sorted_ops);

        @memcpy(sorted_ops, operations);
        std.sort.pdq(DeterministicOperation, sorted_ops, {}, compareOperations);

        // Execute operations in deterministic order
        for (sorted_ops, 0..) |op, i| {
            results[i] = try self.executeOperation(op);
        }

        return results;
    }

    /// Get current deterministic state for verification
    pub fn getDeterministicState(self: *Self) DeterministicState {
        return DeterministicState{
            .clock_state = self.deterministic_clock.getState(),
            .hash_state = self.hash_state.getState(),
            .random_state = self.random_state.getState(),
            .execution_count = self.execution_log.items.len,
        };
    }

    /// Verify execution against expected results
    pub fn verifyExecution(self: *Self, expected_results: []const DeterministicResult) !bool {
        if (expected_results.len != self.execution_log.items.len) {
            return false;
        }

        for (expected_results, 0..) |expected, i| {
            const actual = self.execution_log.items[i];
            if (actual.operation_id != expected.operation_id or
                actual.timestamp != expected.timestamp)
            {
                return false;
            }
        }

        return true;
    }

    /// Execute operation with deterministic context
    fn executeWithDeterministicContext(self: *Self, operation: DeterministicOperation) !OperationResult {
        const tx_id = try self.mvcc_manager.beginTransaction(.RepeatableRead);
        defer self.mvcc_manager.abortTransaction(tx_id) catch {};

        const result = switch (operation.operation_type) {
            .Insert => try self.executeInsert(tx_id, operation),
            .Update => try self.executeUpdate(tx_id, operation),
            .Delete => try self.executeDelete(tx_id, operation),
            .Select => try self.executeSelect(tx_id, operation),
            .CreateTable => try self.executeCreateTable(tx_id, operation),
            .DropTable => try self.executeDropTable(tx_id, operation),
        };

        try self.mvcc_manager.commitTransaction(tx_id);
        return result;
    }

    /// Execute insert operation
    fn executeInsert(self: *Self, tx_id: mvcc.TransactionId, operation: DeterministicOperation) !OperationResult {
        const row = try self.deserializeRow(operation.input);
        defer self.freeRow(row);

        try self.mvcc_manager.writeRow(tx_id, operation.table, operation.row_id, row);

        return OperationResult{
            .success = true,
            .affected_rows = 1,
            .data = null,
        };
    }

    /// Execute update operation
    fn executeUpdate(self: *Self, tx_id: mvcc.TransactionId, operation: DeterministicOperation) !OperationResult {
        const row = try self.deserializeRow(operation.input);
        defer self.freeRow(row);

        try self.mvcc_manager.writeRow(tx_id, operation.table, operation.row_id, row);

        return OperationResult{
            .success = true,
            .affected_rows = 1,
            .data = null,
        };
    }

    /// Execute delete operation
    fn executeDelete(self: *Self, tx_id: mvcc.TransactionId, operation: DeterministicOperation) !OperationResult {
        try self.mvcc_manager.deleteRow(tx_id, operation.table, operation.row_id);

        return OperationResult{
            .success = true,
            .affected_rows = 1,
            .data = null,
        };
    }

    /// Execute select operation
    fn executeSelect(self: *Self, tx_id: mvcc.TransactionId, operation: DeterministicOperation) !OperationResult {
        const row = try self.mvcc_manager.readRow(tx_id, operation.table, operation.row_id);

        if (row) |r| {
            const data = try self.serializeRow(r);
            return OperationResult{
                .success = true,
                .affected_rows = 1,
                .data = data,
            };
        } else {
            return OperationResult{
                .success = true,
                .affected_rows = 0,
                .data = null,
            };
        }
    }

    /// Execute create table operation
    fn executeCreateTable(_: *Self, _: mvcc.TransactionId, _: DeterministicOperation) !OperationResult {
        // For simplicity, assume table creation is handled by storage engine
        return OperationResult{
            .success = true,
            .affected_rows = 0,
            .data = null,
        };
    }

    /// Execute drop table operation
    fn executeDropTable(_: *Self, _: mvcc.TransactionId, _: DeterministicOperation) !OperationResult {
        // For simplicity, assume table dropping is handled by storage engine
        return OperationResult{
            .success = true,
            .affected_rows = 0,
            .data = null,
        };
    }

    /// Update deterministic state after operation
    fn updateDeterministicState(self: *Self, operation_id: u64, result: OperationResult) void {
        self.deterministic_clock.advance();
        self.hash_state.updateWithResult(operation_id, result);
        self.random_state.advance();
    }

    /// Serialize row for deterministic storage
    fn serializeRow(self: *Self, row: storage.Row) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(self.allocator);

        try list.writer(self.allocator).writeInt(u32, @intCast(row.values.len), .little);

        for (row.values) |value| {
            try self.serializeValue(list.writer(self.allocator), value);
        }

        return try list.toOwnedSlice(self.allocator);
    }

    /// Deserialize row from deterministic storage
    fn deserializeRow(self: *Self, data: []const u8) !storage.Row {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        const num_values = try reader.readInt(u32, .little);
        const values = try self.allocator.alloc(storage.Value, num_values);

        for (values) |*value| {
            value.* = try self.deserializeValue(reader);
        }

        return storage.Row{ .values = values };
    }

    /// Serialize value
    fn serializeValue(self: *Self, writer: anytype, value: storage.Value) !void {
        _ = self;
        switch (value) {
            .Integer => |i| {
                try writer.writeByte(0);
                try writer.writeInt(i64, i, .little);
            },
            .Real => |r| {
                try writer.writeByte(1);
                try writer.writeInt(u64, @bitCast(r), .little);
            },
            .Text => |t| {
                try writer.writeByte(2);
                try writer.writeInt(u32, @intCast(t.len), .little);
                try writer.writeAll(t);
            },
            .Blob => |b| {
                try writer.writeByte(3);
                try writer.writeInt(u32, @intCast(b.len), .little);
                try writer.writeAll(b);
            },
            .Null => try writer.writeByte(4),
            .Parameter => |p| {
                try writer.writeByte(5);
                try writer.writeInt(u32, p, .little);
            },
        }
    }

    /// Deserialize value
    fn deserializeValue(self: *Self, reader: anytype) !storage.Value {
        const type_tag = try reader.readByte();
        return switch (type_tag) {
            0 => storage.Value{ .Integer = try reader.readInt(i64, .little) },
            1 => storage.Value{ .Real = @bitCast(try reader.readInt(u64, .little)) },
            2 => blk: {
                const len = try reader.readInt(u32, .little);
                const text = try self.allocator.alloc(u8, len);
                try reader.readNoEof(text);
                break :blk storage.Value{ .Text = text };
            },
            3 => blk: {
                const len = try reader.readInt(u32, .little);
                const blob = try self.allocator.alloc(u8, len);
                try reader.readNoEof(blob);
                break :blk storage.Value{ .Blob = blob };
            },
            4 => storage.Value.Null,
            5 => storage.Value{ .Parameter = try reader.readInt(u32, .little) },
            else => error.InvalidTypeTag,
        };
    }

    /// Free row memory
    fn freeRow(self: *Self, row: storage.Row) void {
        for (row.values) |value| {
            switch (value) {
                .Text => |t| self.allocator.free(t),
                .Blob => |b| self.allocator.free(b),
                else => {},
            }
        }
        self.allocator.free(row.values);
    }

    /// Generate deterministic random number
    pub fn deterministicRandom(self: *Self) u64 {
        return self.random_state.next();
    }

    /// Get execution log for auditing
    pub fn getExecutionLog(self: *Self) []const ExecutionRecord {
        return self.execution_log.items;
    }

    pub fn deinit(self: *Self) void {
        self.execution_log.deinit(self.allocator);
    }
};

/// Deterministic clock for consistent timestamps
const DeterministicClock = struct {
    current_time: u64,
    increment: u64,

    const Self = @This();

    pub fn init(seed: u64) Self {
        return Self{
            .current_time = seed,
            .increment = 1,
        };
    }

    pub fn now(self: *Self) u64 {
        return self.current_time;
    }

    pub fn advance(self: *Self) void {
        self.current_time += self.increment;
    }

    pub fn getState(self: *Self) u64 {
        return self.current_time;
    }
};

/// Hash state for deterministic hashing
const HashState = struct {
    seed: u64,
    state: std.hash.Wyhash,

    const Self = @This();

    pub fn init(seed: u64) Self {
        return Self{
            .seed = seed,
            .state = std.hash.Wyhash.init(seed),
        };
    }

    pub fn hashOperation(self: *Self, operation: DeterministicOperation) u64 {
        var hasher = std.hash.Wyhash.init(self.seed);
        hasher.update(std.mem.asBytes(&operation.operation_type));
        hasher.update(operation.table);
        hasher.update(std.mem.asBytes(&operation.row_id));
        hasher.update(operation.input);
        return hasher.final();
    }

    pub fn hashInput(self: *Self, input: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(self.seed);
        hasher.update(input);
        return hasher.final();
    }

    pub fn hashResult(self: *Self, result: OperationResult) u64 {
        var hasher = std.hash.Wyhash.init(self.seed);
        hasher.update(std.mem.asBytes(&result.success));
        hasher.update(std.mem.asBytes(&result.affected_rows));
        if (result.data) |data| {
            hasher.update(data);
        }
        return hasher.final();
    }

    pub fn updateWithResult(self: *Self, operation_id: u64, result: OperationResult) void {
        self.state.update(std.mem.asBytes(&operation_id));
        self.state.update(std.mem.asBytes(&result.success));
        self.state.update(std.mem.asBytes(&result.affected_rows));
    }

    pub fn getState(self: *Self) u64 {
        return self.state.final();
    }
};

/// Random state for deterministic random numbers
const RandomState = struct {
    rng: std.rand.DefaultPrng,

    const Self = @This();

    pub fn init(seed: u64) Self {
        return Self{
            .rng = std.rand.DefaultPrng.init(seed),
        };
    }

    pub fn next(self: *Self) u64 {
        return self.rng.next();
    }

    pub fn getState(self: *Self) u64 {
        return self.rng.random().int(u64);
    }

    pub fn advance(self: *Self) void {
        _ = self.rng.next();
    }
};

/// Operation types for deterministic execution
pub const DeterministicOperationType = enum {
    Insert,
    Update,
    Delete,
    Select,
    CreateTable,
    DropTable,
};

/// Deterministic operation
pub const DeterministicOperation = struct {
    operation_type: DeterministicOperationType,
    table: []const u8,
    row_id: storage.RowId,
    input: []const u8,
};

/// Operation result
pub const OperationResult = struct {
    success: bool,
    affected_rows: u32,
    data: ?[]const u8,
};

/// Deterministic result with verification data
pub const DeterministicResult = struct {
    operation_id: u64,
    timestamp: u64,
    result: OperationResult,
    execution_hash: u64,
};

/// Execution record for auditing
pub const ExecutionRecord = struct {
    operation_id: u64,
    timestamp: u64,
    operation_type: DeterministicOperationType,
    input_hash: u64,
    deterministic_state: DeterministicState,
};

/// Deterministic state snapshot
pub const DeterministicState = struct {
    clock_state: u64,
    hash_state: u64,
    random_state: u64,
    execution_count: usize,
};

/// Compare operations for deterministic ordering
fn compareOperations(context: void, a: DeterministicOperation, b: DeterministicOperation) bool {
    _ = context;

    // First compare by operation type
    if (@intFromEnum(a.operation_type) != @intFromEnum(b.operation_type)) {
        return @intFromEnum(a.operation_type) < @intFromEnum(b.operation_type);
    }

    // Then by table name
    const table_cmp = std.mem.order(u8, a.table, b.table);
    if (table_cmp != .eq) {
        return table_cmp == .lt;
    }

    // Then by row ID
    if (a.row_id != b.row_id) {
        return a.row_id < b.row_id;
    }

    // Finally by input hash
    const a_hash = std.hash.Wyhash.hash(0, a.input);
    const b_hash = std.hash.Wyhash.hash(0, b.input);
    return a_hash < b_hash;
}

// Tests
test "deterministic engine basic operations" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage_engine = try storage.StorageEngine.initMemory(allocator);
    defer storage_engine.deinit();

    var mvcc_manager = try mvcc.MVCCTransactionManager.init(allocator, &storage_engine, null);
    defer mvcc_manager.deinit();

    var det_engine = try DeterministicEngine.init(allocator, &mvcc_manager, 12345);
    defer det_engine.deinit();

    // Test deterministic operation
    const operation = DeterministicOperation{
        .operation_type = .Insert,
        .table = "test_table",
        .row_id = 1,
        .input = &[_]u8{ 1, 0, 0, 0, 0, 123, 0, 0, 0, 0, 0, 0, 0 },
    };

    const result = try det_engine.executeOperation(operation);

    try testing.expect(result.result.success);
    try testing.expect(result.result.affected_rows == 1);

    // Test deterministic state
    const state = det_engine.getDeterministicState();
    try testing.expect(state.execution_count == 1);
}

test "deterministic batch execution" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage_engine = try storage.StorageEngine.initMemory(allocator);
    defer storage_engine.deinit();

    var mvcc_manager = try mvcc.MVCCTransactionManager.init(allocator, &storage_engine, null);
    defer mvcc_manager.deinit();

    var det_engine = try DeterministicEngine.init(allocator, &mvcc_manager, 12345);
    defer det_engine.deinit();

    // Test batch operations
    const operations = [_]DeterministicOperation{
        DeterministicOperation{
            .operation_type = .Insert,
            .table = "test_table",
            .row_id = 2,
            .input = &[_]u8{ 1, 0, 0, 0, 0, 124, 0, 0, 0, 0, 0, 0, 0 },
        },
        DeterministicOperation{
            .operation_type = .Insert,
            .table = "test_table",
            .row_id = 1,
            .input = &[_]u8{ 1, 0, 0, 0, 0, 123, 0, 0, 0, 0, 0, 0, 0 },
        },
    };

    const results = try det_engine.executeBatch(&operations);
    defer allocator.free(results);

    try testing.expect(results.len == 2);
    for (results) |result| {
        try testing.expect(result.result.success);
        try testing.expect(result.result.affected_rows == 1);
    }
}

test "deterministic random generation" {
    const testing = std.testing;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage_engine = try storage.StorageEngine.initMemory(allocator);
    defer storage_engine.deinit();

    var mvcc_manager = try mvcc.MVCCTransactionManager.init(allocator, &storage_engine, null);
    defer mvcc_manager.deinit();

    var det_engine1 = try DeterministicEngine.init(allocator, &mvcc_manager, 12345);
    defer det_engine1.deinit();

    var det_engine2 = try DeterministicEngine.init(allocator, &mvcc_manager, 12345);
    defer det_engine2.deinit();

    // Test deterministic random generation
    const random1 = det_engine1.deterministicRandom();
    const random2 = det_engine2.deterministicRandom();

    try testing.expect(random1 == random2); // Should be identical with same seed
}
