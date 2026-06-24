const std = @import("std");
const storage = @import("../db/storage.zig");
const ast = @import("../parser/ast.zig");

/// Window function execution context
pub const WindowContext = struct {
    allocator: std.mem.Allocator,
    rows: []storage.Row,
    current_row: usize,
    partition_start: usize,
    partition_end: usize,
    /// ORDER BY clauses for ranking functions
    order_by: ?[]const ast.OrderByClause,
    /// Column name to index mapping for the current table
    column_indices: ?std.StringHashMap(usize),
    /// Precomputed ranks for ORDER BY (computed once per partition)
    ranks: ?[]u32,
    /// Precomputed dense ranks for ORDER BY
    dense_ranks: ?[]u32,

    pub fn init(allocator: std.mem.Allocator, rows: []storage.Row) WindowContext {
        return WindowContext{
            .allocator = allocator,
            .rows = rows,
            .current_row = 0,
            .partition_start = 0,
            .partition_end = rows.len,
            .order_by = null,
            .column_indices = null,
            .ranks = null,
            .dense_ranks = null,
        };
    }

    /// Initialize with ORDER BY clause for ranking computations
    pub fn initWithOrderBy(
        allocator: std.mem.Allocator,
        rows: []storage.Row,
        order_by: ?[]const ast.OrderByClause,
        column_indices: ?std.StringHashMap(usize),
    ) !WindowContext {
        var ctx = WindowContext{
            .allocator = allocator,
            .rows = rows,
            .current_row = 0,
            .partition_start = 0,
            .partition_end = rows.len,
            .order_by = order_by,
            .column_indices = column_indices,
            .ranks = null,
            .dense_ranks = null,
        };

        // Precompute ranks if we have ORDER BY
        if (order_by != null and rows.len > 0) {
            try ctx.computeRanks();
        }

        return ctx;
    }

    /// Initialize with ORDER BY clause and explicit partition boundaries
    pub fn initWithOrderByAndPartition(
        allocator: std.mem.Allocator,
        rows: []storage.Row,
        order_by: ?[]const ast.OrderByClause,
        column_indices: ?std.StringHashMap(usize),
        partition_start: usize,
        partition_end: usize,
    ) !WindowContext {
        var ctx = WindowContext{
            .allocator = allocator,
            .rows = rows,
            .current_row = partition_start,
            .partition_start = partition_start,
            .partition_end = partition_end,
            .order_by = order_by,
            .column_indices = column_indices,
            .ranks = null,
            .dense_ranks = null,
        };

        // Precompute ranks within this partition if we have ORDER BY
        if (order_by != null and partition_end > partition_start) {
            try ctx.computeRanks();
        }

        return ctx;
    }

    /// Compute RANK and DENSE_RANK values for all rows based on ORDER BY
    fn computeRanks(self: *WindowContext) !void {
        const n = self.partition_end - self.partition_start;
        if (n == 0) return;

        self.ranks = try self.allocator.alloc(u32, n);
        self.dense_ranks = try self.allocator.alloc(u32, n);

        // Create sorted indices based on ORDER BY
        var indices = try self.allocator.alloc(usize, n);
        defer self.allocator.free(indices);
        for (0..n) |i| {
            indices[i] = self.partition_start + i;
        }

        // Sort indices based on ORDER BY values
        const sort_ctx = SortContext{
            .rows = self.rows,
            .order_by = self.order_by.?,
            .column_indices = self.column_indices,
        };
        std.mem.sort(usize, indices, sort_ctx, compareFn);

        // Assign ranks - same rank for equal values, RANK skips, DENSE_RANK doesn't
        var current_rank: u32 = 1;
        var current_dense_rank: u32 = 1;
        var rows_at_current_rank: u32 = 0;

        for (indices, 0..) |sorted_idx, i| {
            const relative_idx = sorted_idx - self.partition_start;

            if (i == 0) {
                self.ranks.?[relative_idx] = 1;
                self.dense_ranks.?[relative_idx] = 1;
                rows_at_current_rank = 1;
            } else {
                const prev_idx = indices[i - 1];
                const is_equal = areRowsEqual(self.rows, sorted_idx, prev_idx, self.order_by.?, self.column_indices);

                if (is_equal) {
                    // Same rank as previous
                    self.ranks.?[relative_idx] = current_rank;
                    self.dense_ranks.?[relative_idx] = current_dense_rank;
                    rows_at_current_rank += 1;
                } else {
                    // New rank
                    current_rank += rows_at_current_rank; // RANK skips
                    current_dense_rank += 1; // DENSE_RANK doesn't skip
                    self.ranks.?[relative_idx] = current_rank;
                    self.dense_ranks.?[relative_idx] = current_dense_rank;
                    rows_at_current_rank = 1;
                }
            }
        }
    }

    pub fn deinit(self: *WindowContext) void {
        if (self.ranks) |ranks| {
            self.allocator.free(ranks);
        }
        if (self.dense_ranks) |dense_ranks| {
            self.allocator.free(dense_ranks);
        }
    }
};

/// Context for sorting rows by ORDER BY clauses
const SortContext = struct {
    rows: []storage.Row,
    order_by: []const ast.OrderByClause,
    column_indices: ?std.StringHashMap(usize),
};

/// Compare function for sorting by ORDER BY
fn compareFn(ctx: SortContext, a: usize, b: usize) bool {
    const row_a = ctx.rows[a];
    const row_b = ctx.rows[b];

    for (ctx.order_by) |clause| {
        const col_idx = if (ctx.column_indices) |indices|
            indices.get(clause.column) orelse 0
        else
            0;

        if (col_idx >= row_a.values.len or col_idx >= row_b.values.len) {
            continue;
        }

        const val_a = row_a.values[col_idx];
        const val_b = row_b.values[col_idx];

        const order = compareValues(val_a, val_b);
        if (order != .eq) {
            const ascending = clause.direction == .Asc;
            return if (ascending)
                order == .lt
            else
                order == .gt;
        }
    }
    return false; // Equal
}

/// Compare two storage values
fn compareValues(a: storage.Value, b: storage.Value) std.math.Order {
    return switch (a) {
        .Integer => |ia| switch (b) {
            .Integer => |ib| std.math.order(ia, ib),
            .Real => |rb| std.math.order(@as(f64, @floatFromInt(ia)), rb),
            .Null => .gt,
            else => .gt,
        },
        .Real => |ra| switch (b) {
            .Integer => |ib| std.math.order(ra, @as(f64, @floatFromInt(ib))),
            .Real => |rb| std.math.order(ra, rb),
            .Null => .gt,
            else => .gt,
        },
        .Text => |ta| switch (b) {
            .Text => |tb| std.mem.order(u8, ta, tb),
            .Null => .gt,
            else => .gt,
        },
        .Null => switch (b) {
            .Null => .eq,
            else => .lt,
        },
        else => .eq,
    };
}

/// Check if two rows are equal based on ORDER BY columns
fn areRowsEqual(rows: []storage.Row, idx_a: usize, idx_b: usize, order_by: []const ast.OrderByClause, column_indices: ?std.StringHashMap(usize)) bool {
    const row_a = rows[idx_a];
    const row_b = rows[idx_b];

    for (order_by) |clause| {
        const col_idx = if (column_indices) |indices|
            indices.get(clause.column) orelse 0
        else
            0;

        if (col_idx >= row_a.values.len or col_idx >= row_b.values.len) {
            continue;
        }

        const val_a = row_a.values[col_idx];
        const val_b = row_b.values[col_idx];

        if (compareValues(val_a, val_b) != .eq) {
            return false;
        }
    }
    return true;
}

/// Window function executor
pub const WindowExecutor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WindowExecutor {
        return WindowExecutor{ .allocator = allocator };
    }

    /// Execute a window function
    pub fn executeWindowFunction(
        self: *WindowExecutor,
        function: ast.WindowFunction,
        context: *WindowContext,
    ) !storage.Value {
        return switch (function.function_type) {
            .RowNumber => try self.executeRowNumber(context),
            .Rank => try self.executeRank(context),
            .DenseRank => try self.executeDenseRank(context),
            .PercentRank => try self.executePercentRank(context),
            .CumeDist => try self.executeCumeDist(context),
            .Ntile => try self.executeNtile(function, context),
            .Lead => try self.executeLead(function, context),
            .Lag => try self.executeLag(function, context),
            .FirstValue => try self.executeFirstValue(function, context),
            .LastValue => try self.executeLastValue(function, context),
            .NthValue => try self.executeNthValue(function, context),
        };
    }

    /// Execute ROW_NUMBER() window function
    fn executeRowNumber(self: *WindowExecutor, context: *WindowContext) !storage.Value {
        _ = self;
        const row_number = context.current_row - context.partition_start + 1;
        return storage.Value{ .Integer = @intCast(row_number) };
    }

    /// Execute RANK() window function
    /// RANK assigns the same rank to rows with equal ORDER BY values,
    /// then skips the next ranks (e.g., 1, 1, 3 for two equal values)
    fn executeRank(self: *WindowExecutor, context: *WindowContext) !storage.Value {
        _ = self;
        if (context.ranks) |ranks| {
            const relative_idx = context.current_row - context.partition_start;
            if (relative_idx < ranks.len) {
                return storage.Value{ .Integer = @intCast(ranks[relative_idx]) };
            }
        }
        // Fallback: if no ORDER BY, row number equals rank
        const rank = context.current_row - context.partition_start + 1;
        return storage.Value{ .Integer = @intCast(rank) };
    }

    /// Execute DENSE_RANK() window function
    /// DENSE_RANK assigns the same rank to rows with equal ORDER BY values,
    /// without gaps (e.g., 1, 1, 2 for two equal values)
    fn executeDenseRank(self: *WindowExecutor, context: *WindowContext) !storage.Value {
        _ = self;
        if (context.dense_ranks) |dense_ranks| {
            const relative_idx = context.current_row - context.partition_start;
            if (relative_idx < dense_ranks.len) {
                return storage.Value{ .Integer = @intCast(dense_ranks[relative_idx]) };
            }
        }
        // Fallback: if no ORDER BY, row number equals dense rank
        const dense_rank = context.current_row - context.partition_start + 1;
        return storage.Value{ .Integer = @intCast(dense_rank) };
    }

    /// Execute LEAD() window function
    /// LEAD(column, offset, default) - returns value from a row offset rows after current row
    fn executeLead(self: *WindowExecutor, function: ast.WindowFunction, context: *WindowContext) !storage.Value {
        // Parse arguments: LEAD(column, [offset], [default])
        // offset defaults to 1, default value defaults to NULL
        var offset: usize = 1;
        var default_value: storage.Value = storage.Value.Null;
        var column_idx: usize = 0;

        // First argument is the column to fetch
        if (function.arguments.len > 0) {
            switch (function.arguments[0]) {
                .Column => |col_name| {
                    if (context.column_indices) |indices| {
                        column_idx = indices.get(col_name) orelse 0;
                    }
                },
                .Literal => |lit| {
                    // If literal is an integer, treat as column index
                    if (lit == .Integer) {
                        column_idx = @intCast(@max(0, lit.Integer));
                    }
                },
                else => {},
            }
        }

        // Second argument is the offset (optional, default 1)
        if (function.arguments.len > 1) {
            switch (function.arguments[1]) {
                .Literal => |lit| {
                    if (lit == .Integer) {
                        offset = @intCast(@max(0, lit.Integer));
                    }
                },
                else => {},
            }
        }

        // Third argument is the default value (optional, default NULL)
        if (function.arguments.len > 2) {
            switch (function.arguments[2]) {
                .Literal => |lit| {
                    default_value = try self.convertAstValueToStorage(lit);
                },
                else => {},
            }
        }

        const lead_row_index = context.current_row + offset;

        if (lead_row_index >= context.partition_end) {
            return default_value;
        }

        const row = context.rows[lead_row_index];
        if (column_idx < row.values.len) {
            return try row.values[column_idx].clone(self.allocator);
        }

        return default_value;
    }

    /// Execute LAG() window function
    /// LAG(column, offset, default) - returns value from a row offset rows before current row
    fn executeLag(self: *WindowExecutor, function: ast.WindowFunction, context: *WindowContext) !storage.Value {
        // Parse arguments: LAG(column, [offset], [default])
        var offset: usize = 1;
        var default_value: storage.Value = storage.Value.Null;
        var column_idx: usize = 0;

        // First argument is the column to fetch
        if (function.arguments.len > 0) {
            switch (function.arguments[0]) {
                .Column => |col_name| {
                    if (context.column_indices) |indices| {
                        column_idx = indices.get(col_name) orelse 0;
                    }
                },
                .Literal => |lit| {
                    if (lit == .Integer) {
                        column_idx = @intCast(@max(0, lit.Integer));
                    }
                },
                else => {},
            }
        }

        // Second argument is the offset
        if (function.arguments.len > 1) {
            switch (function.arguments[1]) {
                .Literal => |lit| {
                    if (lit == .Integer) {
                        offset = @intCast(@max(0, lit.Integer));
                    }
                },
                else => {},
            }
        }

        // Third argument is the default value
        if (function.arguments.len > 2) {
            switch (function.arguments[2]) {
                .Literal => |lit| {
                    default_value = try self.convertAstValueToStorage(lit);
                },
                else => {},
            }
        }

        if (context.current_row < context.partition_start + offset) {
            return default_value;
        }

        const lag_row_index = context.current_row - offset;
        const row = context.rows[lag_row_index];

        if (column_idx < row.values.len) {
            return try row.values[column_idx].clone(self.allocator);
        }

        return default_value;
    }

    /// Convert AST value to storage value
    fn convertAstValueToStorage(self: *WindowExecutor, value: ast.Value) !storage.Value {
        return switch (value) {
            .Integer => |i| storage.Value{ .Integer = i },
            .Text => |t| storage.Value{ .Text = try self.allocator.dupe(u8, t) },
            .Real => |r| storage.Value{ .Real = r },
            .Null => storage.Value.Null,
            else => storage.Value.Null,
        };
    }

    /// Apply window functions to a result set
    pub fn applyWindowFunctions(
        self: *WindowExecutor,
        rows: *std.ArrayList(storage.Row),
        window_functions: []ast.WindowFunction,
    ) !void {
        if (window_functions.len == 0) return;

        // Process each window function
        for (window_functions) |window_func| {
            // Create context with ORDER BY from window specification
            var context = try WindowContext.initWithOrderBy(
                self.allocator,
                rows.items,
                window_func.window_spec.order_by,
                null, // Column indices would come from table schema
            );
            defer context.deinit();

            // Process each row
            for (rows.items, 0..) |*row, i| {
                context.current_row = i;

                const result = try self.executeWindowFunction(window_func, &context);

                // Add the window function result as a new column
                var new_values = try self.allocator.alloc(storage.Value, row.values.len + 1);

                // Copy existing values
                for (row.values, 0..) |value, j| {
                    new_values[j] = value;
                }

                // Add window function result
                new_values[row.values.len] = result;

                // Replace the row's values
                self.allocator.free(row.values);
                row.values = new_values;
            }
        }
    }

    /// Apply window functions with column mapping for proper column reference resolution
    pub fn applyWindowFunctionsWithSchema(
        self: *WindowExecutor,
        rows: *std.ArrayList(storage.Row),
        window_functions: []ast.WindowFunction,
        column_names: []const []const u8,
        window_definitions: ?[]const ast.WindowDefinition,
    ) !void {
        if (window_functions.len == 0) return;

        // Build column name to index map
        var column_indices = std.StringHashMap(usize).init(self.allocator);
        defer column_indices.deinit();

        for (column_names, 0..) |name, idx| {
            try column_indices.put(name, idx);
        }

        // Process each window function
        for (window_functions) |window_func| {
            const resolved_spec = resolveWindowSpecification(window_func.window_spec, window_definitions) orelse window_func.window_spec;

            // Create context with ORDER BY and column indices
            var context = try WindowContext.initWithOrderBy(
                self.allocator,
                rows.items,
                resolved_spec.order_by,
                column_indices,
            );
            defer context.deinit();

            // Process each row
            for (rows.items, 0..) |*row, i| {
                context.current_row = i;

                const result = try self.executeWindowFunction(window_func, &context);

                // Add the window function result as a new column
                var new_values = try self.allocator.alloc(storage.Value, row.values.len + 1);

                // Copy existing values
                for (row.values, 0..) |value, j| {
                    new_values[j] = value;
                }

                // Add window function result
                new_values[row.values.len] = result;

                // Replace the row's values
                self.allocator.free(row.values);
                row.values = new_values;
            }
        }
    }

    pub fn resolveWindowSpecification(spec: ast.WindowSpecification, definitions: ?[]const ast.WindowDefinition) ?ast.WindowSpecification {
        const name = spec.window_name orelse return null;
        const windows = definitions orelse return null;

        for (windows) |window| {
            if (!std.mem.eql(u8, window.name, name)) continue;

            var merged = window.specification;
            if (spec.partition_by != null) merged.partition_by = spec.partition_by;
            if (spec.order_by != null) merged.order_by = spec.order_by;
            if (spec.frame_clause != null) merged.frame_clause = spec.frame_clause;
            return merged;
        }

        return null;
    }

    /// Execute PERCENT_RANK() window function
    fn executePercentRank(self: *WindowExecutor, context: *WindowContext) !storage.Value {
        _ = self;
        const partition_size = context.partition_end - context.partition_start;
        if (partition_size <= 1) return storage.Value{ .Real = 0.0 };

        const position = context.current_row - context.partition_start;
        const percent_rank = @as(f64, @floatFromInt(position)) / @as(f64, @floatFromInt(partition_size - 1));
        return storage.Value{ .Real = percent_rank };
    }

    /// Execute CUME_DIST() window function
    fn executeCumeDist(self: *WindowExecutor, context: *WindowContext) !storage.Value {
        _ = self;
        const partition_size = context.partition_end - context.partition_start;
        const position = context.current_row - context.partition_start + 1;
        const cume_dist = @as(f64, @floatFromInt(position)) / @as(f64, @floatFromInt(partition_size));
        return storage.Value{ .Real = cume_dist };
    }

    /// Execute NTILE() window function
    /// NTILE(n) - divides the partition into n buckets and returns bucket number
    fn executeNtile(self: *WindowExecutor, function: ast.WindowFunction, context: *WindowContext) !storage.Value {
        _ = self;
        const partition_size = context.partition_end - context.partition_start;
        const position = context.current_row - context.partition_start;

        // Get number of buckets from first argument (default to 4)
        var buckets: usize = 4;
        if (function.arguments.len > 0) {
            switch (function.arguments[0]) {
                .Literal => |lit| {
                    if (lit == .Integer and lit.Integer > 0) {
                        buckets = @intCast(lit.Integer);
                    }
                },
                else => {},
            }
        }

        if (buckets == 0) buckets = 1;

        // Calculate bucket assignment
        // NTILE distributes rows as evenly as possible
        const rows_per_bucket = partition_size / buckets;
        const extra_rows = partition_size % buckets;

        // First 'extra_rows' buckets get one extra row
        var bucket: usize = 1;
        var rows_counted: usize = 0;

        for (1..buckets + 1) |b| {
            const bucket_rows = rows_per_bucket + (if (b <= extra_rows) @as(usize, 1) else @as(usize, 0));
            if (position < rows_counted + bucket_rows) {
                bucket = b;
                break;
            }
            rows_counted += bucket_rows;
        }

        return storage.Value{ .Integer = @intCast(bucket) };
    }

    /// Execute FIRST_VALUE() window function
    /// FIRST_VALUE(column) - returns the first value of the specified column in the partition
    fn executeFirstValue(self: *WindowExecutor, function: ast.WindowFunction, context: *WindowContext) !storage.Value {
        const frame = resolveFrame(function, context);
        if (frame.start >= frame.end or frame.start >= context.rows.len) {
            return storage.Value.Null;
        }

        // Get column index from first argument
        var column_idx: usize = 0;
        if (function.arguments.len > 0) {
            switch (function.arguments[0]) {
                .Column => |col_name| {
                    if (context.column_indices) |indices| {
                        column_idx = indices.get(col_name) orelse 0;
                    }
                },
                .Literal => |lit| {
                    if (lit == .Integer) {
                        column_idx = @intCast(@max(0, lit.Integer));
                    }
                },
                else => {},
            }
        }

        const first_row = context.rows[frame.start];
        if (column_idx < first_row.values.len) {
            return try first_row.values[column_idx].clone(self.allocator);
        }

        return storage.Value.Null;
    }

    /// Execute LAST_VALUE() window function
    /// LAST_VALUE(column) - returns the last value of the specified column in the partition
    fn executeLastValue(self: *WindowExecutor, function: ast.WindowFunction, context: *WindowContext) !storage.Value {
        const frame = resolveFrame(function, context);
        if (frame.start >= frame.end or frame.end > context.rows.len) {
            return storage.Value.Null;
        }

        // Get column index from first argument
        var column_idx: usize = 0;
        if (function.arguments.len > 0) {
            switch (function.arguments[0]) {
                .Column => |col_name| {
                    if (context.column_indices) |indices| {
                        column_idx = indices.get(col_name) orelse 0;
                    }
                },
                .Literal => |lit| {
                    if (lit == .Integer) {
                        column_idx = @intCast(@max(0, lit.Integer));
                    }
                },
                else => {},
            }
        }

        const last_row = context.rows[frame.end - 1];
        if (column_idx < last_row.values.len) {
            return try last_row.values[column_idx].clone(self.allocator);
        }

        return storage.Value.Null;
    }

    /// Execute NTH_VALUE() window function
    /// NTH_VALUE(column, n) - returns the nth value of the column in the partition
    fn executeNthValue(self: *WindowExecutor, function: ast.WindowFunction, context: *WindowContext) !storage.Value {
        const frame = resolveFrame(function, context);

        // Get column index and N from arguments
        var column_idx: usize = 0;
        var n: usize = 1;

        if (function.arguments.len > 0) {
            switch (function.arguments[0]) {
                .Column => |col_name| {
                    if (context.column_indices) |indices| {
                        column_idx = indices.get(col_name) orelse 0;
                    }
                },
                .Literal => |lit| {
                    if (lit == .Integer) {
                        column_idx = @intCast(@max(0, lit.Integer));
                    }
                },
                else => {},
            }
        }

        if (function.arguments.len > 1) {
            switch (function.arguments[1]) {
                .Literal => |lit| {
                    if (lit == .Integer and lit.Integer > 0) {
                        n = @intCast(lit.Integer);
                    }
                },
                else => {},
            }
        }

        // N is 1-based
        const target_idx = frame.start + n - 1;
        if (target_idx >= frame.end or target_idx >= context.rows.len) {
            return storage.Value.Null;
        }

        const target_row = context.rows[target_idx];
        if (column_idx < target_row.values.len) {
            return try target_row.values[column_idx].clone(self.allocator);
        }

        return storage.Value.Null;
    }
};

const FrameRange = struct {
    start: usize,
    end: usize,
};

fn resolveFrame(function: ast.WindowFunction, context: *WindowContext) FrameRange {
    const clause = function.window_spec.frame_clause orelse return .{
        .start = context.partition_start,
        .end = context.current_row + 1,
    };

    if (clause.frame_type != .Rows) {
        return .{ .start = context.partition_start, .end = context.partition_end };
    }

    const start = resolveFrameBound(clause.start_bound, context, true);
    const end_bound = clause.end_bound orelse clause.start_bound;
    const end_inclusive = resolveFrameBound(end_bound, context, false);
    const end = @min(context.partition_end, end_inclusive + 1);

    if (start > end) return .{ .start = end, .end = end };
    return .{ .start = start, .end = end };
}

fn resolveFrameBound(bound: ast.FrameBound, context: *WindowContext, comptime is_start: bool) usize {
    _ = is_start;
    return switch (bound) {
        .UnboundedPreceding => context.partition_start,
        .UnboundedFollowing => context.partition_end - 1,
        .CurrentRow => context.current_row,
        .Preceding => |offset| if (offset > context.current_row - context.partition_start)
            context.partition_start
        else
            context.current_row - offset,
        .Following => |offset| @min(context.partition_end - 1, context.current_row + offset),
    };
}

/// Window function type enumeration
pub const WindowFunctionType = enum {
    RowNumber,
    Rank,
    DenseRank,
    Lead,
    Lag,
};

// Tests
test "window function ROW_NUMBER" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var executor = WindowExecutor.init(allocator);

    // Create test data
    var rows = std.ArrayList(storage.Row).init(allocator);
    defer {
        for (rows.items) |row| {
            allocator.free(row.values);
        }
        rows.deinit();
    }

    // Add test rows
    for (0..5) |i| {
        var values = try allocator.alloc(storage.Value, 1);
        values[0] = storage.Value{ .Integer = @intCast(i) };
        try rows.append(storage.Row{ .values = values });
    }

    // Create window function
    const window_func = ast.WindowFunction{
        .function_type = .RowNumber,
        .arguments = &[_]ast.FunctionArgument{},
        .window_spec = ast.WindowSpecification{
            .partition_by = &[_]ast.Expression{},
            .order_by = &[_]ast.OrderByClause{},
            .frame = null,
        },
    };

    // Apply window function
    try executor.applyWindowFunctions(&rows, &[_]ast.WindowFunction{window_func});

    // Verify results
    for (rows.items, 0..) |row, i| {
        try std.testing.expect(row.values.len == 2); // Original + ROW_NUMBER
        try std.testing.expect(row.values[1].Integer == @as(i32, @intCast(i + 1)));
    }
}

test "window function context" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test rows
    var values1 = try allocator.alloc(storage.Value, 1);
    values1[0] = storage.Value{ .Integer = 1 };
    var values2 = try allocator.alloc(storage.Value, 1);
    values2[0] = storage.Value{ .Integer = 2 };

    const rows = [_]storage.Row{
        storage.Row{ .values = values1 },
        storage.Row{ .values = values2 },
    };

    const context = WindowContext.init(allocator, @constCast(&rows));

    try std.testing.expect(context.rows.len == 2);
    try std.testing.expect(context.partition_start == 0);
    try std.testing.expect(context.partition_end == 2);

    allocator.free(values1);
    allocator.free(values2);
}
