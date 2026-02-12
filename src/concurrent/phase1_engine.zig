const std = @import("std");
const mvcc = @import("mvcc_transactions.zig");
const storage = @import("../db/storage.zig");
const time_utils = @import("../time_utils.zig");

/// Two-Phase Commit Coordinator (Phase 1 Engine)
///
/// Implements the "prepare" phase of two-phase commit for distributed transactions.
/// This coordinator manages:
/// - Lock acquisition across participating nodes
/// - Transaction validation before commit
/// - Vote collection (prepared/abort)
/// - Timeout handling and recovery
///
/// Integrates with MVCCTransactionManager for single-node transactions and
/// can be extended to work with ClusterManager for distributed coordination.
pub const Phase1Engine = struct {
    allocator: std.mem.Allocator,
    mvcc_manager: *mvcc.MVCCTransactionManager,
    active_preparations: std.AutoHashMap(TransactionId, *Phase1State),
    timeout_ms: u64,
    mutex: std.Thread.Mutex,
    metrics: Phase1Metrics,

    const Self = @This();
    const TransactionId = mvcc.TransactionId;

    /// Initialize a new Phase1 engine
    pub fn init(allocator: std.mem.Allocator, mvcc_manager: *mvcc.MVCCTransactionManager) !*Self {
        const engine = try allocator.create(Self);
        engine.* = Self{
            .allocator = allocator,
            .mvcc_manager = mvcc_manager,
            .active_preparations = std.AutoHashMap(TransactionId, *Phase1State).init(allocator),
            .timeout_ms = 30000, // 30 second default timeout
            .mutex = .{},
            .metrics = Phase1Metrics.init(),
        };
        return engine;
    }

    /// Begin phase 1 (prepare) for a transaction
    /// Returns a Phase1Handle for tracking the preparation state
    pub fn beginPhase1(self: *Self, transaction_id: TransactionId, participants: []const ParticipantNode) !Phase1Handle {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already preparing
        if (self.active_preparations.contains(transaction_id)) {
            return error.TransactionAlreadyPreparing;
        }

        const ts = time_utils.getTimespec();
        const now_ms: u64 = @intCast(@divTrunc(@as(i128, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000), 1));

        // Create phase 1 state
        const state = try self.allocator.create(Phase1State);
        state.* = Phase1State{
            .transaction_id = transaction_id,
            .status = .Preparing,
            .participants = try self.allocator.dupe(ParticipantNode, participants),
            .votes = std.AutoHashMap([]const u8, Vote).init(self.allocator),
            .locks_acquired = std.ArrayList(ResourceLock).init(self.allocator),
            .started_at = now_ms,
            .timeout_at = now_ms + self.timeout_ms,
        };

        try self.active_preparations.put(transaction_id, state);
        self.metrics.preparations_started += 1;

        return Phase1Handle{
            .engine = self,
            .transaction_id = transaction_id,
        };
    }

    /// Request locks on resources for phase 1
    pub fn requestLocks(self: *Self, transaction_id: TransactionId, locks: []const ResourceLock) !LockResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const state = self.active_preparations.get(transaction_id) orelse
            return error.TransactionNotFound;

        if (state.status != .Preparing) {
            return error.InvalidTransactionState;
        }

        // Attempt to acquire each lock
        var acquired_count: u32 = 0;
        var failed_resource: ?[]const u8 = null;

        for (locks) |lock| {
            // Check for conflicts with existing locks
            const can_acquire = self.checkLockCompatibility(lock);
            if (can_acquire) {
                try state.locks_acquired.append(lock);
                acquired_count += 1;
            } else {
                failed_resource = lock.resource_id;
                break;
            }
        }

        if (failed_resource) |resource| {
            // Rollback acquired locks
            self.rollbackLocks(state);
            self.metrics.lock_conflicts += 1;
            return LockResult{
                .success = false,
                .acquired_count = acquired_count,
                .failed_resource = resource,
            };
        }

        self.metrics.locks_acquired += acquired_count;
        return LockResult{
            .success = true,
            .acquired_count = acquired_count,
            .failed_resource = null,
        };
    }

    /// Validate transaction before commit (part of phase 1)
    pub fn validateTransaction(self: *Self, transaction_id: TransactionId) !ValidationResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const state = self.active_preparations.get(transaction_id) orelse
            return error.TransactionNotFound;

        if (state.status != .Preparing) {
            return error.InvalidTransactionState;
        }

        // Perform validation checks
        var validation_errors = std.ArrayList(ValidationError).init(self.allocator);

        // Check 1: Verify all locks are still held
        for (state.locks_acquired.items) |lock| {
            if (!self.isLockStillValid(lock)) {
                try validation_errors.append(ValidationError{
                    .code = .LockExpired,
                    .resource = lock.resource_id,
                    .message = "Lock expired during validation",
                });
            }
        }

        // Check 2: Verify no conflicting commits occurred
        const conflicts = self.checkForConflicts(state);
        if (conflicts) {
            try validation_errors.append(ValidationError{
                .code = .ConflictDetected,
                .resource = null,
                .message = "Conflicting transaction detected",
            });
        }

        // Check 3: Verify timeout not exceeded
        const ts = time_utils.getTimespec();
        const now_ms: u64 = @intCast(@divTrunc(@as(i128, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000), 1));
        if (now_ms > state.timeout_at) {
            try validation_errors.append(ValidationError{
                .code = .Timeout,
                .resource = null,
                .message = "Transaction preparation timeout exceeded",
            });
        }

        const is_valid = validation_errors.items.len == 0;
        if (is_valid) {
            self.metrics.validations_passed += 1;
        } else {
            self.metrics.validations_failed += 1;
        }

        return ValidationResult{
            .is_valid = is_valid,
            .errors = try validation_errors.toOwnedSlice(),
        };
    }

    /// Collect votes from participants (for distributed transactions)
    pub fn collectVotes(self: *Self, transaction_id: TransactionId) !VoteResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const state = self.active_preparations.get(transaction_id) orelse
            return error.TransactionNotFound;

        if (state.status != .Preparing) {
            return error.InvalidTransactionState;
        }

        var prepared_count: u32 = 0;
        var abort_count: u32 = 0;
        var pending_count: u32 = 0;

        // In a distributed system, this would send prepare requests to each participant
        // and collect their votes. For now, we simulate with local validation.
        for (state.participants) |participant| {
            if (state.votes.get(participant.node_id)) |vote| {
                switch (vote) {
                    .Prepared => prepared_count += 1,
                    .Abort => abort_count += 1,
                    .Pending => pending_count += 1,
                }
            } else {
                // Participant hasn't voted yet - simulate local vote
                const vote = self.simulateParticipantVote(state, participant);
                try state.votes.put(participant.node_id, vote);
                switch (vote) {
                    .Prepared => prepared_count += 1,
                    .Abort => abort_count += 1,
                    .Pending => pending_count += 1,
                }
            }
        }

        // Determine overall result
        const total_participants = @as(u32, @intCast(state.participants.len));
        const decision: VoteDecision = if (abort_count > 0)
            .Abort
        else if (prepared_count == total_participants)
            .Commit
        else
            .Pending;

        if (decision == .Commit) {
            state.status = .Prepared;
            self.metrics.successful_preparations += 1;
        } else if (decision == .Abort) {
            state.status = .Aborted;
            self.metrics.aborted_preparations += 1;
        }

        return VoteResult{
            .decision = decision,
            .prepared_count = prepared_count,
            .abort_count = abort_count,
            .pending_count = pending_count,
            .total_participants = total_participants,
        };
    }

    /// Abort phase 1 preparation
    pub fn abortPhase1(self: *Self, transaction_id: TransactionId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const state = self.active_preparations.get(transaction_id) orelse
            return error.TransactionNotFound;

        // Release all acquired locks
        self.rollbackLocks(state);

        // Mark as aborted
        state.status = .Aborted;

        // Cleanup
        try self.cleanupState(transaction_id);

        self.metrics.aborted_preparations += 1;
    }

    /// Get current phase 1 state for a transaction
    pub fn getPhase1State(self: *Self, transaction_id: TransactionId) ?Phase1Status {
        self.mutex.lock();
        defer self.mutex.unlock();

        const state = self.active_preparations.get(transaction_id) orelse return null;
        return state.status;
    }

    /// Complete phase 1 and transition to phase 2 (commit)
    /// Should be called after successful vote collection
    pub fn completePhase1(self: *Self, transaction_id: TransactionId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const state = self.active_preparations.get(transaction_id) orelse
            return error.TransactionNotFound;

        if (state.status != .Prepared) {
            return error.InvalidTransactionState;
        }

        // Transition to committed state
        state.status = .Committed;

        // Cleanup (locks will be released by phase 2)
        try self.cleanupState(transaction_id);
    }

    // ========== Internal Helper Functions ==========

    fn checkLockCompatibility(self: *Self, lock: ResourceLock) bool {
        _ = self;
        // In a full implementation, this would check against a global lock table
        // For now, assume all locks are compatible (optimistic)
        _ = lock;
        return true;
    }

    fn isLockStillValid(self: *Self, lock: ResourceLock) bool {
        _ = self;
        // Check if lock hasn't been released or timed out
        _ = lock;
        return true;
    }

    fn checkForConflicts(self: *Self, state: *Phase1State) bool {
        _ = self;
        _ = state;
        // In a full implementation, check version chains for conflicts
        return false;
    }

    fn simulateParticipantVote(self: *Self, state: *Phase1State, participant: ParticipantNode) Vote {
        _ = self;
        _ = state;
        _ = participant;
        // Simulate successful prepare for local testing
        return .Prepared;
    }

    fn rollbackLocks(self: *Self, state: *Phase1State) void {
        _ = self;
        state.locks_acquired.clearRetainingCapacity();
    }

    fn cleanupState(self: *Self, transaction_id: TransactionId) !void {
        if (self.active_preparations.fetchRemove(transaction_id)) |kv| {
            const state = kv.value;
            self.allocator.free(state.participants);
            state.votes.deinit();
            state.locks_acquired.deinit();
            self.allocator.destroy(state);
        }
    }

    /// Set transaction timeout
    pub fn setTimeout(self: *Self, timeout_ms: u64) void {
        self.timeout_ms = timeout_ms;
    }

    /// Get metrics
    pub fn getMetrics(self: *Self) Phase1Metrics {
        return self.metrics;
    }

    pub fn deinit(self: *Self) void {
        // Clean up all active preparations
        var iterator = self.active_preparations.valueIterator();
        while (iterator.next()) |state| {
            self.allocator.free(state.*.participants);
            state.*.votes.deinit();
            state.*.locks_acquired.deinit();
            self.allocator.destroy(state.*);
        }
        self.active_preparations.deinit();
        self.allocator.destroy(self);
    }
};

/// Handle for tracking a phase 1 preparation
pub const Phase1Handle = struct {
    engine: *Phase1Engine,
    transaction_id: mvcc.TransactionId,

    const Self = @This();

    /// Request locks
    pub fn requestLocks(self: Self, locks: []const ResourceLock) !LockResult {
        return self.engine.requestLocks(self.transaction_id, locks);
    }

    /// Validate
    pub fn validate(self: Self) !ValidationResult {
        return self.engine.validateTransaction(self.transaction_id);
    }

    /// Collect votes
    pub fn collectVotes(self: Self) !VoteResult {
        return self.engine.collectVotes(self.transaction_id);
    }

    /// Abort
    pub fn abort(self: Self) !void {
        return self.engine.abortPhase1(self.transaction_id);
    }

    /// Complete (transition to phase 2)
    pub fn complete(self: Self) !void {
        return self.engine.completePhase1(self.transaction_id);
    }

    /// Get current status
    pub fn getStatus(self: Self) ?Phase1Status {
        return self.engine.getPhase1State(self.transaction_id);
    }
};

/// Phase 1 preparation state
pub const Phase1State = struct {
    transaction_id: mvcc.TransactionId,
    status: Phase1Status,
    participants: []const ParticipantNode,
    votes: std.AutoHashMap([]const u8, Vote),
    locks_acquired: std.ArrayList(ResourceLock),
    started_at: u64,
    timeout_at: u64,
};

/// Phase 1 status
pub const Phase1Status = enum {
    Preparing,
    Prepared,
    Committed,
    Aborted,
};

/// Participant node in distributed transaction
pub const ParticipantNode = struct {
    node_id: []const u8,
    address: []const u8,
    port: u16,
};

/// Vote from a participant
pub const Vote = enum {
    Pending,
    Prepared,
    Abort,
};

/// Vote decision for the entire transaction
pub const VoteDecision = enum {
    Pending,
    Commit,
    Abort,
};

/// Resource lock for phase 1
pub const ResourceLock = struct {
    resource_id: []const u8,
    lock_type: LockType,
    table_name: []const u8,
    row_id: ?storage.RowId,
};

/// Lock type
pub const LockType = enum {
    Shared,
    Exclusive,
    IntentShared,
    IntentExclusive,
};

/// Result of lock acquisition
pub const LockResult = struct {
    success: bool,
    acquired_count: u32,
    failed_resource: ?[]const u8,
};

/// Validation result
pub const ValidationResult = struct {
    is_valid: bool,
    errors: []ValidationError,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.errors);
    }
};

/// Validation error
pub const ValidationError = struct {
    code: ValidationErrorCode,
    resource: ?[]const u8,
    message: []const u8,
};

/// Validation error codes
pub const ValidationErrorCode = enum {
    LockExpired,
    ConflictDetected,
    Timeout,
    ConstraintViolation,
    ResourceNotFound,
};

/// Vote collection result
pub const VoteResult = struct {
    decision: VoteDecision,
    prepared_count: u32,
    abort_count: u32,
    pending_count: u32,
    total_participants: u32,
};

/// Phase 1 engine metrics
pub const Phase1Metrics = struct {
    preparations_started: u64,
    successful_preparations: u64,
    aborted_preparations: u64,
    validations_passed: u64,
    validations_failed: u64,
    locks_acquired: u64,
    lock_conflicts: u64,

    pub fn init() Phase1Metrics {
        return .{
            .preparations_started = 0,
            .successful_preparations = 0,
            .aborted_preparations = 0,
            .validations_passed = 0,
            .validations_failed = 0,
            .locks_acquired = 0,
            .lock_conflicts = 0,
        };
    }
};

test "phase1 engine basic workflow" {
    const allocator = std.testing.allocator;

    // Create a mock MVCC manager for testing
    // In real usage, this would be a properly initialized MVCCTransactionManager
    var mock_storage = try storage.StorageEngine.init(allocator, null);
    defer mock_storage.deinit();

    var mvcc_manager = try mvcc.MVCCTransactionManager.init(allocator, &mock_storage, null);
    defer mvcc_manager.deinit();

    var engine = try Phase1Engine.init(allocator, &mvcc_manager);
    defer engine.deinit();

    // Begin phase 1 for a transaction
    const participants = [_]ParticipantNode{
        .{ .node_id = "node1", .address = "127.0.0.1", .port = 8080 },
        .{ .node_id = "node2", .address = "127.0.0.1", .port = 8081 },
    };

    const handle = try engine.beginPhase1(1, &participants);

    // Request locks
    const locks = [_]ResourceLock{
        .{ .resource_id = "users:1", .lock_type = .Exclusive, .table_name = "users", .row_id = 1 },
    };

    const lock_result = try handle.requestLocks(&locks);
    try std.testing.expect(lock_result.success);

    // Validate
    var validation = try handle.validate();
    defer validation.deinit(allocator);
    try std.testing.expect(validation.is_valid);

    // Collect votes
    const vote_result = try handle.collectVotes();
    try std.testing.expect(vote_result.decision == .Commit);

    // Complete phase 1
    try handle.complete();

    // Verify metrics
    const metrics = engine.getMetrics();
    try std.testing.expect(metrics.preparations_started == 1);
    try std.testing.expect(metrics.successful_preparations == 1);
}
