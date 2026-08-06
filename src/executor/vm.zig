const std = @import("std");
const ast = @import("../parser/ast.zig");
const planner = @import("planner.zig");
const storage = @import("../db/storage.zig");
const db = @import("../db/connection.zig");
const functions = @import("functions.zig");
const window_functions = @import("window_functions.zig");

/// Virtual machine for executing query plans
pub const VirtualMachine = struct {
    connection: *db.Connection,
    parameters: ?[]storage.Value, // Optional parameters for prepared statements
    function_evaluator: functions.FunctionEvaluator,
    /// CTE context: maps CTE names to their result rows
    cte_context: std.StringHashMap(CTEResult),
    /// Current table being scanned (for column name resolution in projection)
    current_table: ?*storage.Table,
    /// Current projected column names for CTE scans.
    current_column_names: ?[][]const u8,
    /// Table alias map: maps alias -> actual table name
    table_aliases: std.StringHashMap([]const u8),
    /// Maps alias -> Table pointer for column resolution
    alias_to_table: std.StringHashMap(*storage.Table),
    /// Maps alias/table name -> column offset in joined rows
    alias_column_offset: std.StringHashMap(usize),

    const Self = @This();

    /// Error set for condition/expression evaluation
    pub const EvalError = error{
        OutOfMemory,
        ColumnNotFound,
        DivisionByZero,
        TypeMismatch,
        InvalidOperator,
        ParameterNotBound,
        InvalidFunctionCall,
        FunctionNotFound,
        InvalidArgumentCount,
        Overflow,
    };

    /// Stored CTE result
    pub const CTEResult = struct {
        rows: []storage.Row,
        column_names: ?[][]const u8,

        pub fn deinit(self: *CTEResult, allocator: std.mem.Allocator) void {
            for (self.rows) |row| {
                for (row.values) |value| {
                    value.deinit(allocator);
                }
                allocator.free(row.values);
            }
            allocator.free(self.rows);

            if (self.column_names) |cols| {
                for (cols) |col| {
                    allocator.free(col);
                }
                allocator.free(cols);
            }
        }
    };

    /// Initialize virtual machine
    pub fn init(allocator: std.mem.Allocator, connection: *db.Connection) Self {
        // Always use the connection's allocator to ensure consistency
        _ = allocator; // Ignore passed allocator, use connection's allocator
        // VM initialization complete
        return Self{
            .connection = connection,
            .parameters = null,
            .function_evaluator = functions.FunctionEvaluator.init(connection.allocator),
            .cte_context = std.StringHashMap(CTEResult).init(connection.allocator),
            .current_table = null,
            .current_column_names = null,
            .table_aliases = std.StringHashMap([]const u8).init(connection.allocator),
            .alias_to_table = std.StringHashMap(*storage.Table).init(connection.allocator),
            .alias_column_offset = std.StringHashMap(usize).init(connection.allocator),
        };
    }

    /// Clean up VM resources including CTE context
    pub fn deinitVM(self: *Self) void {
        self.clearCTEContext();
        self.cte_context.deinit();
        self.clearTableAliases();
        self.table_aliases.deinit();
        self.alias_to_table.deinit();
        self.alias_column_offset.deinit();
    }

    /// Clear table aliases
    fn clearTableAliases(self: *Self) void {
        var iter = self.table_aliases.iterator();
        while (iter.next()) |entry| {
            self.connection.allocator.free(entry.key_ptr.*);
            self.connection.allocator.free(entry.value_ptr.*);
        }
        self.table_aliases.clearRetainingCapacity();

        var alias_iter = self.alias_to_table.iterator();
        while (alias_iter.next()) |entry| {
            self.connection.allocator.free(entry.key_ptr.*);
        }
        self.alias_to_table.clearRetainingCapacity();

        var offset_iter = self.alias_column_offset.iterator();
        while (offset_iter.next()) |entry| {
            self.connection.allocator.free(entry.key_ptr.*);
        }
        self.alias_column_offset.clearRetainingCapacity();
    }

    /// Register a table alias/name without memory leaks (checks for existing key)
    fn registerTableAlias(self: *Self, name: []const u8, table: *storage.Table) !void {
        // Check if key already exists to avoid memory leak
        if (self.alias_to_table.getPtr(name)) |ptr| {
            // Key exists, just update the value
            ptr.* = table;
        } else {
            // New key, need to dupe it
            const key = try self.connection.allocator.dupe(u8, name);
            try self.alias_to_table.put(key, table);
        }
    }

    /// Register a column offset without memory leaks (checks for existing key)
    fn registerColumnOffset(self: *Self, name: []const u8, offset: usize) !void {
        // Check if key already exists to avoid memory leak
        if (self.alias_column_offset.getPtr(name)) |ptr| {
            // Key exists, just update the value
            ptr.* = offset;
        } else {
            // New key, need to dupe it
            const key = try self.connection.allocator.dupe(u8, name);
            try self.alias_column_offset.put(key, offset);
        }
    }

    /// Parse table name with optional alias (e.g., "customers c" -> "customers", "c")
    fn parseTableNameWithAlias(self: *Self, table_str: []const u8) !struct { name: []const u8, alias: ?[]const u8 } {
        // Find space separator
        if (std.mem.indexOf(u8, table_str, " ")) |space_idx| {
            const name = try self.connection.allocator.dupe(u8, table_str[0..space_idx]);
            const alias = try self.connection.allocator.dupe(u8, table_str[space_idx + 1 ..]);
            return .{ .name = name, .alias = alias };
        }
        return .{ .name = try self.connection.allocator.dupe(u8, table_str), .alias = null };
    }

    const ResolvedTableRef = struct {
        connection: *db.Connection,
        table_name: []const u8,
    };

    const QualifiedName = struct {
        schema_name: ?[]const u8,
        name: []const u8,
    };

    fn splitQualifiedName(_: *Self, qualified_name: []const u8) !QualifiedName {
        const dot = std.mem.indexOfScalar(u8, qualified_name, '.') orelse return .{
            .schema_name = null,
            .name = qualified_name,
        };

        const schema_name = qualified_name[0..dot];
        const local_name = qualified_name[dot + 1 ..];
        if (schema_name.len == 0 or local_name.len == 0) return error.InvalidSchemaQualifiedName;
        return .{ .schema_name = schema_name, .name = local_name };
    }

    fn resolveSchemaConnection(self: *Self, schema_name: []const u8) !*db.Connection {
        if (std.mem.eql(u8, schema_name, "main")) return self.connection;
        return self.connection.getAttachedDatabase(schema_name) orelse error.SchemaNotFound;
    }

    fn resolveTableRef(self: *Self, qualified_name: []const u8) !ResolvedTableRef {
        const parts = try self.splitQualifiedName(qualified_name);
        const schema_name = parts.schema_name orelse return .{
            .connection = self.connection,
            .table_name = parts.name,
        };

        return .{
            .connection = try self.resolveSchemaConnection(schema_name),
            .table_name = parts.name,
        };
    }

    /// Clear all CTE results
    fn clearCTEContext(self: *Self) void {
        var iter = self.cte_context.iterator();
        while (iter.next()) |entry| {
            var result = entry.value_ptr.*;
            result.deinit(self.connection.allocator);
        }
        self.cte_context.clearRetainingCapacity();
    }

    /// Execute a query plan
    pub fn execute(self: *Self, plan: *planner.ExecutionPlan) !ExecutionResult {
        var result = ExecutionResult{
            .rows = .empty,
            .affected_rows = 0,
            .connection = self.connection,
        };
        errdefer result.deinit();

        for (plan.steps) |*step| {
            try self.connection.checkOperation();
            try self.executeStep(step, &result);
        }

        // Execution completed
        return result;
    }

    /// Execute a query plan with parameters (for prepared statements)
    pub fn executeWithParameters(self: *Self, plan: *planner.ExecutionPlan, parameters: []storage.Value) !ExecutionResult {
        // Set parameters for this execution
        self.parameters = parameters;
        defer self.parameters = null; // Clear parameters after execution

        return self.execute(plan);
    }

    /// Execute a single step
    fn executeStep(self: *Self, step: *planner.ExecutionStep, result: *ExecutionResult) !void {
        try self.connection.checkOperation();
        try self.connection.recordVmStep();
        switch (step.*) {
            .TableScan => |*scan| try self.executeTableScan(scan, result),
            .IndexScan => |*scan| try self.executeIndexScan(scan, result),
            .Filter => |*filter| try self.executeFilter(filter, result),
            .Project => |*project| try self.executeProject(project, result),
            .Sort => |*sort| try self.executeSort(sort, result),
            .Limit => |*limit| try self.executeLimit(limit, result),
            .Insert => |*insert| try self.executeInsert(insert, result),
            .CreateTable => |*create| try self.executeCreateTable(create, result),
            .Update => |*update| try self.executeUpdate(update, result),
            .Delete => |*delete| try self.executeDelete(delete, result),
            .NestedLoopJoin => |*join| try self.executeNestedLoopJoin(join, result),
            .HashJoin => |*join| try self.executeHashJoin(join, result),
            .Aggregate => |*agg| try self.executeAggregate(agg, result),
            .GroupBy => |*group| try self.executeGroupBy(group, result),
            .BeginTransaction => try self.executeBeginTransaction(result),
            .Commit => try self.executeCommit(result),
            .Rollback => try self.executeRollback(result),
            .Savepoint => |*savepoint| try self.executeSavepoint(savepoint, result),
            .ReleaseSavepoint => |*savepoint| try self.executeReleaseSavepoint(savepoint, result),
            .RollbackToSavepoint => |*savepoint| try self.executeRollbackToSavepoint(savepoint, result),
            .CreateIndex => |*create_idx| try self.executeCreateIndex(create_idx, result),
            .DropIndex => |*drop_idx| try self.executeDropIndex(drop_idx, result),
            .DropTable => |*drop_tbl| try self.executeDropTable(drop_tbl, result),
            .AlterTable => |*alter| try self.executeAlterTable(alter, result),
            .CreateCTE => |*cte| try self.executeCreateCTE(cte, result),
            .Pragma => |*pragma| try self.executePragma(pragma, result),
            .Analyze => |*analyze| try self.executeAnalyze(analyze, result),
            .Vacuum => try self.executeVacuum(result),
            .Explain => |*explain| try self.executeExplain(explain, result),
            .SetOperation => |*set_op| try self.executeSetOperation(set_op, result),
            .Window => |*window| try self.executeWindow(window, result),
            .Having => |*having| try self.executeHaving(having, result),
            .Distinct => try self.executeDistinct(result),
            .Attach => |*attach| try self.executeAttach(attach, result),
            .Detach => |*detach| try self.executeDetach(detach, result),
            .CreateVirtualTable => |*create_vt| try self.executeCreateVirtualTable(create_vt, result),
        }
        try self.connection.recordResultRows(result.rows.items.len);
        try self.connection.recordAffectedRows(result.affected_rows);
    }

    /// Execute CTE creation - stores the CTE result for later reference
    fn executeCreateCTE(self: *Self, cte: *planner.CreateCTEStep, result: *ExecutionResult) anyerror!void {
        // Create a temporary result to execute the CTE subquery
        var cte_result = ExecutionResult{
            .rows = .empty,
            .affected_rows = 0,
            .connection = self.connection,
        };

        // Execute the CTE's subquery steps (non-recursive since CTEs can't contain CTEs in subquery)
        for (cte.subquery_steps) |*step| {
            try self.connection.checkOperation();
            try self.executeNonCTEStep(step, &cte_result);
        }

        // Clone the result rows for storage in CTE context
        var stored_rows = try self.connection.allocator.alloc(storage.Row, cte_result.rows.items.len);
        for (cte_result.rows.items, 0..) |row, i| {
            var cloned_values = try self.connection.allocator.alloc(storage.Value, row.values.len);
            for (row.values, 0..) |value, j| {
                cloned_values[j] = try value.clone(self.connection.allocator);
            }
            stored_rows[i] = storage.Row{ .values = cloned_values };
        }

        // Clone column names if provided
        var stored_column_names: ?[][]const u8 = null;
        if (cte.column_names) |cols| {
            var cloned_cols = try self.connection.allocator.alloc([]const u8, cols.len);
            for (cols, 0..) |col, i| {
                cloned_cols[i] = try self.connection.allocator.dupe(u8, col);
            }
            stored_column_names = cloned_cols;
        }

        // Store in CTE context
        try self.cte_context.put(cte.name, CTEResult{
            .rows = stored_rows,
            .column_names = stored_column_names,
        });

        // Clean up temporary result
        cte_result.deinit();

        // CTE creation doesn't affect the main result
        _ = result;
    }

    /// Execute a step that is not a CTE (used by CTE execution to avoid recursion)
    fn executeNonCTEStep(self: *Self, step: *planner.ExecutionStep, result: *ExecutionResult) !void {
        try self.connection.checkOperation();
        try self.connection.recordVmStep();
        switch (step.*) {
            .TableScan => |*scan| try self.executeTableScan(scan, result),
            .IndexScan => |*scan| try self.executeIndexScan(scan, result),
            .Filter => |*filter| try self.executeFilter(filter, result),
            .Project => |*project| try self.executeProject(project, result),
            .Sort => |*sort| try self.executeSort(sort, result),
            .Limit => |*limit| try self.executeLimit(limit, result),
            .Insert => |*insert| try self.executeInsert(insert, result),
            .CreateTable => |*create| try self.executeCreateTable(create, result),
            .Update => |*update| try self.executeUpdate(update, result),
            .Delete => |*delete| try self.executeDelete(delete, result),
            .NestedLoopJoin => |*join| try self.executeNestedLoopJoin(join, result),
            .HashJoin => |*join| try self.executeHashJoin(join, result),
            .Aggregate => |*agg| try self.executeAggregate(agg, result),
            .GroupBy => |*group| try self.executeGroupBy(group, result),
            .BeginTransaction => try self.executeBeginTransaction(result),
            .Commit => try self.executeCommit(result),
            .Rollback => try self.executeRollback(result),
            .Savepoint => |*savepoint| try self.executeSavepoint(savepoint, result),
            .ReleaseSavepoint => |*savepoint| try self.executeReleaseSavepoint(savepoint, result),
            .RollbackToSavepoint => |*savepoint| try self.executeRollbackToSavepoint(savepoint, result),
            .CreateIndex => |*create_idx| try self.executeCreateIndex(create_idx, result),
            .DropIndex => |*drop_idx| try self.executeDropIndex(drop_idx, result),
            .DropTable => |*drop_tbl| try self.executeDropTable(drop_tbl, result),
            .AlterTable => |*alter| try self.executeAlterTable(alter, result),
            .CreateCTE => {
                // CTEs within CTEs are not supported in this version
                return error.NestedCTENotSupported;
            },
            .Pragma => |*pragma| try self.executePragma(pragma, result),
            .Analyze => |*analyze| try self.executeAnalyze(analyze, result),
            .Vacuum => try self.executeVacuum(result),
            .Explain => |*explain| try self.executeExplain(explain, result),
            .SetOperation => {
                // Nested set operations should be executed via executeStep
                return error.NestedSetOperationNotSupported;
            },
            .Window => |*window| try self.executeWindow(window, result),
            .Having => |*having| try self.executeHaving(having, result),
            .Distinct => try self.executeDistinct(result),
            .Attach => |*attach| try self.executeAttach(attach, result),
            .Detach => |*detach| try self.executeDetach(detach, result),
            .CreateVirtualTable => |*create_vt| try self.executeCreateVirtualTable(create_vt, result),
        }
        try self.connection.recordResultRows(result.rows.items.len);
        try self.connection.recordAffectedRows(result.affected_rows);
    }

    /// Execute table scan
    fn executeTableScan(self: *Self, scan: *planner.TableScanStep, result: *ExecutionResult) !void {
        // Parse table name and optional alias (e.g., "customers c" -> "customers", "c")
        const parsed = try self.parseTableNameWithAlias(scan.table_name);
        const actual_table_name = parsed.name;
        defer self.connection.allocator.free(actual_table_name);

        // First check if this is a CTE reference
        if (self.cte_context.get(actual_table_name)) |cte_result| {
            self.current_table = null;
            self.current_column_names = cte_result.column_names;

            // Use CTE results instead of table
            for (cte_result.rows) |row| {
                try self.connection.checkOperation();
                try self.connection.recordRowsScanned(1);
                // Clone the row for the result
                var cloned_values = try self.connection.allocator.alloc(storage.Value, row.values.len);
                for (row.values, 0..) |value, j| {
                    cloned_values[j] = try value.clone(self.connection.allocator);
                }
                try result.rows.append(self.connection.allocator, storage.Row{ .values = cloned_values });
                try self.connection.recordResultRows(result.rows.items.len);
            }
            if (parsed.alias) |alias| {
                self.connection.allocator.free(alias);
            }
            return;
        }

        // Executing table scan on actual table
        const resolved = try self.resolveTableRef(actual_table_name);
        const table = resolved.connection.storage_engine.getTable(resolved.table_name) orelse {
            if (parsed.alias) |alias| {
                self.connection.allocator.free(alias);
            }
            return error.TableNotFound;
        };

        self.current_column_names = null;

        // Register table alias if present
        if (parsed.alias) |alias| {
            try self.registerTableAlias(alias, table);
            self.connection.allocator.free(alias);
        }

        // Also register the table name itself for "tablename.column" references
        try self.registerTableAlias(actual_table_name, table);
        if (!std.mem.eql(u8, actual_table_name, resolved.table_name)) {
            try self.registerTableAlias(resolved.table_name, table);
        }

        // Track the current table for column name resolution in projection
        self.current_table = table;

        const rows = try table.select(self.connection.allocator);
        var transferred_rows: usize = 0;
        defer {
            for (rows[transferred_rows..]) |row| {
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }
            self.connection.allocator.free(rows);
        }

        for (rows, 0..) |row, row_index| {
            try self.connection.checkOperation();
            try self.connection.recordRowsScanned(1);
            // The row is already properly cloned by btree.selectAll - use it directly
            // Using pre-cloned row from btree
            for (row.values) |value| {
                switch (value) {
                    .Text => {
                        // Using pre-cloned text value
                    },
                    else => {},
                }
            }
            try result.rows.append(self.connection.allocator, row);
            transferred_rows = row_index + 1;
            try self.connection.recordResultRows(result.rows.items.len);
            // Row appended to result
        }
    }

    /// Execute index scan (uses index for direct lookup instead of full table scan)
    fn executeIndexScan(self: *Self, scan: *planner.IndexScanStep, result: *ExecutionResult) !void {
        // Get the table
        const resolved = try self.resolveTableRef(scan.table_name);
        const table = resolved.connection.storage_engine.getTable(resolved.table_name) orelse {
            return error.TableNotFound;
        };
        self.current_table = table;

        // Try to use the index for lookup
        if (resolved.connection.storage_engine.getIndex(scan.index_name)) |index| {
            // Convert lookup value to index key
            const key = self.valueToIndexKey(scan.lookup_value);

            // Use index search to find row_id
            if (try index.search(key)) |row_id| {
                // Get the row from the table
                if (try table.getRow(@intCast(row_id))) |row| {
                    try self.connection.recordRowsScanned(1);
                    defer {
                        for (row.values) |value| {
                            value.deinit(self.connection.allocator);
                        }
                        self.connection.allocator.free(row.values);
                    }

                    // Clone the row values for the result
                    var values = try self.connection.allocator.alloc(storage.Value, row.values.len);
                    errdefer self.connection.allocator.free(values);

                    var cloned_count: usize = 0;
                    errdefer {
                        for (values[0..cloned_count]) |v| {
                            v.deinit(self.connection.allocator);
                        }
                    }

                    for (row.values, 0..) |val, i| {
                        values[i] = try val.clone(self.connection.allocator);
                        cloned_count = i + 1;
                    }
                    try result.rows.append(self.connection.allocator, storage.Row{ .values = values });
                    try self.connection.recordResultRows(result.rows.items.len);
                }
            }
        } else {
            // Index not found, fallback to table scan
            return self.executeTableScanFallback(table, result);
        }
    }

    /// Convert a storage Value to an index key (u64)
    fn valueToIndexKey(self: *Self, value: storage.Value) u64 {
        _ = self;
        return switch (value) {
            .Integer => |i| @bitCast(i),
            .Text => |t| blk: {
                // Simple hash for text values
                var hash: u64 = 0;
                for (t) |byte| {
                    hash = hash *% 31 +% byte;
                }
                break :blk hash;
            },
            .Real => |r| @bitCast(r),
            else => 0,
        };
    }

    /// Fallback to table scan when index is unavailable
    fn executeTableScanFallback(self: *Self, table: *storage.Table, result: *ExecutionResult) !void {
        // Full table scan fallback - iterate through all rows in the table
        var row_id: i64 = 1;
        while (row_id <= @as(i64, @intCast(table.row_count))) : (row_id += 1) {
            try self.connection.checkOperation();
            try self.connection.recordRowsScanned(1);
            if (try table.getRow(row_id)) |row| {
                var values = try self.connection.allocator.alloc(storage.Value, row.values.len);
                errdefer self.connection.allocator.free(values);

                var cloned_count: usize = 0;
                errdefer {
                    for (values[0..cloned_count]) |v| {
                        v.deinit(self.connection.allocator);
                    }
                }

                for (row.values, 0..) |val, i| {
                    values[i] = try val.clone(self.connection.allocator);
                    cloned_count = i + 1;
                }
                try result.rows.append(self.connection.allocator, storage.Row{ .values = values });
                try self.connection.recordResultRows(result.rows.items.len);
            }
        }
    }

    /// Execute filter (WHERE clause)
    fn executeFilter(self: *Self, filter: *planner.FilterStep, result: *ExecutionResult) !void {
        var filtered_rows: std.ArrayListUnmanaged(storage.Row) = .empty;

        for (result.rows.items) |row| {
            try self.connection.checkOperation();
            try self.connection.recordRowsScanned(1);
            if (try self.evaluateCondition(&filter.condition, &row)) {
                try filtered_rows.append(self.connection.allocator, row);
            } else {
                // Free rows that don't match the filter condition
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }
        }

        // Only free the ArrayList structure, not its contents (they're now in filtered_rows or freed)
        result.rows.deinit(self.connection.allocator);
        result.rows = filtered_rows;
    }

    /// Execute HAVING clause (filter after GROUP BY aggregation)
    fn executeHaving(self: *Self, having: *planner.HavingStep, result: *ExecutionResult) !void {
        var filtered_rows: std.ArrayListUnmanaged(storage.Row) = .empty;

        for (result.rows.items) |row| {
            try self.connection.checkOperation();
            try self.connection.recordRowsScanned(1);
            if (try self.evaluateCondition(&having.condition, &row)) {
                try filtered_rows.append(self.connection.allocator, row);
            } else {
                // Free rows that don't match the HAVING condition
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }
        }

        // Replace result rows with filtered rows
        result.rows.deinit(self.connection.allocator);
        result.rows = filtered_rows;
    }

    /// Execute DISTINCT (remove duplicate rows)
    fn executeDistinct(self: *Self, result: *ExecutionResult) !void {
        if (result.rows.items.len <= 1) {
            // 0 or 1 rows is already distinct
            return;
        }

        var unique_rows: std.ArrayListUnmanaged(storage.Row) = .empty;
        var seen = std.StringHashMap(void).init(self.connection.allocator);
        defer seen.deinit();

        for (result.rows.items) |row| {
            try self.connection.checkOperation();
            // Build a hash key for the row by concatenating all values
            const row_key = try self.buildRowKey(&row);
            defer self.connection.allocator.free(row_key);

            if (seen.get(row_key) == null) {
                // New unique row
                try seen.put(try self.connection.allocator.dupe(u8, row_key), {});
                try unique_rows.append(self.connection.allocator, row);
            } else {
                // Duplicate row - free its memory
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }
        }

        // Free the keys in seen hashmap
        var key_iter = seen.keyIterator();
        while (key_iter.next()) |key| {
            self.connection.allocator.free(key.*);
        }

        // Replace result rows with unique rows
        result.rows.deinit(self.connection.allocator);
        result.rows = unique_rows;
    }

    /// Build a string key for a row (for deduplication)
    fn buildRowKey(self: *Self, row: *const storage.Row) ![]u8 {
        var key_parts: std.ArrayListUnmanaged(u8) = .empty;
        defer key_parts.deinit(self.connection.allocator);

        for (row.values, 0..) |value, i| {
            if (i > 0) {
                try key_parts.append(self.connection.allocator, 0); // Separator
            }
            switch (value) {
                .Null => try key_parts.appendSlice(self.connection.allocator, "NULL"),
                .Integer, .Timestamp, .Time, .Interval, .BigInt => |v| {
                    var buf: [32]u8 = undefined;
                    const slice = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?";
                    try key_parts.appendSlice(self.connection.allocator, slice);
                },
                .Date => |v| {
                    var buf: [16]u8 = undefined;
                    const slice = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?";
                    try key_parts.appendSlice(self.connection.allocator, slice);
                },
                .Real => |v| {
                    var buf: [64]u8 = undefined;
                    const slice = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "ERR";
                    try key_parts.appendSlice(self.connection.allocator, slice);
                },
                .Text, .JSON => |v| try key_parts.appendSlice(self.connection.allocator, v),
                .Blob => |v| try key_parts.appendSlice(self.connection.allocator, v),
                .JSONB => |v| {
                    // Convert JSONB to string for comparison
                    const json_str = v.toString(self.connection.allocator) catch "JSONB";
                    defer self.connection.allocator.free(json_str);
                    try key_parts.appendSlice(self.connection.allocator, json_str);
                },
                .UUID => |v| {
                    try key_parts.appendSlice(self.connection.allocator, &v);
                },
                .Boolean => |v| {
                    try key_parts.appendSlice(self.connection.allocator, if (v) "T" else "F");
                },
                .TimestampTZ => |v| {
                    var buf: [64]u8 = undefined;
                    const slice = std.fmt.bufPrint(&buf, "{d}:{s}", .{ v.timestamp, v.timezone }) catch "ERR";
                    try key_parts.appendSlice(self.connection.allocator, slice);
                },
                .Array => |v| {
                    // For arrays, include element count in key
                    var buf: [32]u8 = undefined;
                    const slice = std.fmt.bufPrint(&buf, "ARR:{d}", .{v.elements.len}) catch "ARR:?";
                    try key_parts.appendSlice(self.connection.allocator, slice);
                },
                .Parameter => |idx| {
                    var buf: [32]u8 = undefined;
                    const slice = std.fmt.bufPrint(&buf, "?{d}", .{idx}) catch "?";
                    try key_parts.appendSlice(self.connection.allocator, slice);
                },
                .FunctionCall => try key_parts.appendSlice(self.connection.allocator, "FUNC"),
                .SmallInt => |v| {
                    var buf: [16]u8 = undefined;
                    const slice = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?";
                    try key_parts.appendSlice(self.connection.allocator, slice);
                },
                .Numeric => |v| {
                    // Use the raw digits bytes for uniqueness
                    if (v.is_negative) {
                        try key_parts.appendSlice(self.connection.allocator, "-");
                    }
                    try key_parts.appendSlice(self.connection.allocator, v.digits);
                },
            }
        }

        return try key_parts.toOwnedSlice(self.connection.allocator);
    }

    /// Execute projection (SELECT columns)
    fn executeProject(self: *Self, project: *planner.ProjectStep, result: *ExecutionResult) !void {
        if (project.columns.len == 1 and std.mem.eql(u8, project.columns[0], "*")) {
            // SELECT * - return all columns, no projection needed
            return;
        }

        // Use the current table schema to map column names to indices
        const table = self.current_table;

        // Create projected rows with only selected columns
        var projected_rows: std.ArrayListUnmanaged(storage.Row) = .empty;

        for (result.rows.items) |original_row| {
            try self.connection.checkOperation();
            // Track which original indices we're using (sized based on actual row, not table schema)
            var used_indices = try self.connection.allocator.alloc(bool, original_row.values.len);
            defer self.connection.allocator.free(used_indices);
            @memset(used_indices, false);

            var projected_values: std.ArrayListUnmanaged(storage.Value) = .empty;

            for (project.columns, 0..) |col_name, col_i| {
                // Check if we have an expression for this column
                if (project.expressions) |exprs| {
                    const expr = &exprs[col_i];
                    switch (expr.*) {
                        .Case => |case_expr| {
                            // Evaluate CASE expression
                            const case_value = try self.evaluateCaseExpression(&case_expr, &original_row);
                            try projected_values.append(self.connection.allocator, case_value);
                            continue;
                        },
                        .FunctionCall => |func_call| {
                            // Evaluate function call with row context (COALESCE, NULLIF, IFNULL, etc.)
                            const func_value = try self.evaluateFunctionWithRow(func_call, &original_row);
                            try projected_values.append(self.connection.allocator, func_value);
                            continue;
                        },
                        .Simple => {
                            // Fall through to normal column lookup
                        },
                        else => {
                            // Other expressions not yet supported (Window, Aggregate in non-aggregate context)
                            try projected_values.append(self.connection.allocator, storage.Value.Null);
                            continue;
                        },
                    }
                }

                // Check if this is a qualified column name (alias.column)
                var col_idx: ?usize = null;
                if (std.mem.indexOf(u8, col_name, ".")) |dot_idx| {
                    const alias = col_name[0..dot_idx];
                    const column = col_name[dot_idx + 1 ..];

                    // Look up the table by alias and get offset
                    if (self.alias_to_table.get(alias)) |alias_table| {
                        const col_offset = self.alias_column_offset.get(alias) orelse 0;
                        for (alias_table.schema.columns, 0..) |col, idx| {
                            if (std.mem.eql(u8, col.name, column)) {
                                col_idx = col_offset + idx;
                                break;
                            }
                        }
                    }
                } else if (table) |t| {
                    // Simple column name - look up in current table
                    for (t.schema.columns, 0..) |col, idx| {
                        if (std.mem.eql(u8, col.name, col_name)) {
                            col_idx = idx;
                            break;
                        }
                    }
                } else if (self.current_column_names) |columns| {
                    for (columns, 0..) |column, idx| {
                        if (std.mem.eql(u8, column, col_name)) {
                            col_idx = idx;
                            break;
                        }
                    }
                }

                if (col_idx) |idx| {
                    if (idx < original_row.values.len) {
                        // Transfer ownership of the value
                        try projected_values.append(self.connection.allocator, original_row.values[idx]);
                        used_indices[idx] = true;
                    } else {
                        try projected_values.append(self.connection.allocator, storage.Value.Null);
                    }
                } else {
                    // Column not found, add NULL
                    try projected_values.append(self.connection.allocator, storage.Value.Null);
                }
            }

            try projected_rows.append(self.connection.allocator, storage.Row{
                .values = try projected_values.toOwnedSlice(self.connection.allocator),
            });

            // Free values that weren't used in projection
            for (original_row.values, 0..) |value, idx| {
                if (!used_indices[idx]) {
                    value.deinit(self.connection.allocator);
                }
            }
            self.connection.allocator.free(original_row.values);
        }

        result.rows.deinit(self.connection.allocator);
        result.rows = projected_rows;
    }

    /// Resolve a value, substituting parameters if needed
    /// IMPORTANT: The returned value is cloned and must be freed by the caller
    fn resolveValue(self: *Self, value: storage.Value) !storage.Value {
        return switch (value) {
            .Parameter => |param_index| blk: {
                if (self.parameters) |params| {
                    if (param_index < params.len) {
                        // Clone the parameter value so caller can safely free it
                        break :blk try self.cloneValue(params[param_index]);
                    } else {
                        return error.ParameterIndexOutOfBounds;
                    }
                } else {
                    return error.NoParametersProvided;
                }
            },
            .FunctionCall => |function_call| blk: {
                // Evaluate function call and return the result
                const ast_function_call = try self.convertStorageFunctionToAst(function_call);
                defer ast_function_call.deinit(self.connection.allocator);

                break :blk try self.function_evaluator.evaluateFunction(ast_function_call);
            },
            // For other value types, clone if they have heap allocations
            .Text => |t| storage.Value{ .Text = try self.connection.allocator.dupe(u8, t) },
            .Blob => |b| storage.Value{ .Blob = try self.connection.allocator.dupe(u8, b) },
            .JSON => |j| storage.Value{ .JSON = try self.connection.allocator.dupe(u8, j) },
            else => value, // Integer, Real, Null, etc. don't need cloning
        };
    }

    /// Evaluate a default value, including function calls
    fn evaluateDefaultValue(self: *Self, default_value: ast.DefaultValue) !storage.Value {
        return switch (default_value) {
            .Literal => |literal| {
                const storage_value = try self.convertAstValueToStorage(literal);
                return self.resolveValue(storage_value);
            },
            .FunctionCall => |function_call| {
                return self.function_evaluator.evaluateFunction(function_call);
            },
        };
    }

    /// Convert AST value to storage value
    fn convertAstValueToStorage(self: *Self, value: ast.Value) std.mem.Allocator.Error!storage.Value {
        return switch (value) {
            .Integer => |i| storage.Value{ .Integer = i },
            .Text => |t| storage.Value{ .Text = try self.connection.allocator.dupe(u8, t) },
            .Real => |r| storage.Value{ .Real = r },
            .Blob => |b| storage.Value{ .Blob = try self.connection.allocator.dupe(u8, b) },
            .Null => storage.Value.Null,
            .Parameter => |param_index| storage.Value{ .Parameter = param_index },
            .FunctionCall => |function_call| {
                const storage_func = try self.convertAstFunctionToStorage(function_call);
                return storage.Value{ .FunctionCall = storage_func };
            },
            .Case => storage.Value.Null, // CASE expressions evaluated separately
        };
    }

    /// Evaluate a storage default value
    fn evaluateStorageDefaultValue(self: *Self, default_value: storage.Column.DefaultValue) !storage.Value {
        return switch (default_value) {
            .Literal => |literal| {
                // resolveValue already clones heap-allocated values (Text, Blob, JSON)
                // so we don't need to clone again
                return try self.resolveValue(literal);
            },
            .FunctionCall => |function_call| {
                // Convert storage function call to AST function call for evaluation
                const ast_function_call = try self.convertStorageFunctionToAst(function_call);
                defer ast_function_call.deinit(self.connection.allocator);

                return self.function_evaluator.evaluateFunction(ast_function_call);
            },
        };
    }

    /// Convert AST function call to storage function call
    fn convertAstFunctionToStorage(self: *Self, function_call: ast.FunctionCall) !storage.Column.FunctionCall {
        var storage_args = try self.connection.allocator.alloc(storage.Column.FunctionArgument, function_call.arguments.len);
        for (function_call.arguments, 0..) |arg, i| {
            storage_args[i] = try self.convertAstFunctionArgToStorage(arg);
        }

        return storage.Column.FunctionCall{
            .name = try self.connection.allocator.dupe(u8, function_call.name),
            .arguments = storage_args,
        };
    }

    /// Convert AST function argument to storage function argument
    fn convertAstFunctionArgToStorage(self: *Self, arg: ast.FunctionArgument) !storage.Column.FunctionArgument {
        return switch (arg) {
            .Literal => |literal| {
                const storage_value = try self.convertAstValueToStorage(literal);
                return storage.Column.FunctionArgument{ .Literal = storage_value };
            },
            .String => |string| {
                const text_value = storage.Value{ .Text = try self.connection.allocator.dupe(u8, string) };
                return storage.Column.FunctionArgument{ .Literal = text_value };
            },
            .Column => |column| {
                return storage.Column.FunctionArgument{ .Column = try self.connection.allocator.dupe(u8, column) };
            },
            .Parameter => |param_index| {
                return storage.Column.FunctionArgument{ .Parameter = param_index };
            },
        };
    }

    /// Convert storage function call to AST function call
    fn convertStorageFunctionToAst(self: *Self, function_call: storage.Column.FunctionCall) anyerror!ast.FunctionCall {
        var ast_args = try self.connection.allocator.alloc(ast.FunctionArgument, function_call.arguments.len);
        for (function_call.arguments, 0..) |arg, i| {
            ast_args[i] = try self.convertStorageFunctionArgToAst(arg);
        }

        return ast.FunctionCall{
            .name = try self.connection.allocator.dupe(u8, function_call.name),
            .arguments = ast_args,
        };
    }

    /// Convert storage function argument to AST function argument
    fn convertStorageFunctionArgToAst(self: *Self, arg: storage.Column.FunctionArgument) anyerror!ast.FunctionArgument {
        return switch (arg) {
            .Literal => |literal| {
                const ast_value = try self.convertStorageValueToAst(literal);
                return ast.FunctionArgument{ .Literal = ast_value };
            },
            .Column => |column| {
                return ast.FunctionArgument{ .Column = try self.connection.allocator.dupe(u8, column) };
            },
            .Parameter => |param_index| {
                return ast.FunctionArgument{ .Parameter = param_index };
            },
        };
    }

    /// Convert storage value to AST value
    fn convertStorageValueToAst(self: *Self, value: storage.Value) anyerror!ast.Value {
        return switch (value) {
            .Integer => |i| ast.Value{ .Integer = i },
            .Text => |t| ast.Value{ .Text = try self.connection.allocator.dupe(u8, t) },
            .Real => |r| ast.Value{ .Real = r },
            .Blob => |b| ast.Value{ .Blob = try self.connection.allocator.dupe(u8, b) },
            .Null => ast.Value.Null,
            .Parameter => |param_index| ast.Value{ .Parameter = param_index },
            .FunctionCall => |function_call| {
                const ast_function_call = try self.convertStorageFunctionToAst(function_call);
                return ast.Value{ .FunctionCall = ast_function_call };
            },
            // PostgreSQL compatibility values
            .JSON => |j| ast.Value{ .Text = try self.connection.allocator.dupe(u8, j) },
            .JSONB => |jsonb| ast.Value{ .Text = try jsonb.toString(self.connection.allocator) },
            .UUID => |uuid| ast.Value{ .Text = try ast.UUIDUtils.toString(uuid, self.connection.allocator) },
            .Array => |array| ast.Value{ .Text = try array.toString(self.connection.allocator) },
            .Boolean => |b| ast.Value{ .Integer = if (b) 1 else 0 },
            .Timestamp => |ts| ast.Value{ .Integer = @intCast(ts) },
            .TimestampTZ => |tstz| ast.Value{ .Text = try std.fmt.allocPrint(self.connection.allocator, "{}", .{tstz.timestamp}) },
            .Date => |d| ast.Value{ .Integer = d },
            .Time => |t| ast.Value{ .Integer = @intCast(t) },
            .Interval => |i| ast.Value{ .Integer = @intCast(i) },
            .Numeric => |n| ast.Value{ .Text = try std.fmt.allocPrint(self.connection.allocator, "NUMERIC({},{})", .{ n.precision, n.scale }) },
            .SmallInt => |si| ast.Value{ .Integer = si },
            .BigInt => |bi| ast.Value{ .Integer = @intCast(bi) },
        };
    }

    /// Clone a storage default value
    fn cloneStorageDefaultValue(self: *Self, default_value: storage.Column.DefaultValue) !storage.Column.DefaultValue {
        return switch (default_value) {
            .Literal => |literal| {
                // Create a deep clone to avoid double-free issues
                const cloned_literal = try literal.clone(self.connection.allocator);
                return storage.Column.DefaultValue{ .Literal = cloned_literal };
            },
            .FunctionCall => |function_call| {
                // For function calls, create a proper deep clone
                const cloned_function_call = try self.cloneStorageFunctionCallDeep(function_call);
                return storage.Column.DefaultValue{ .FunctionCall = cloned_function_call };
            },
        };
    }

    /// Clone a storage function call (shallow - for compatibility)
    fn cloneStorageFunctionCall(self: *Self, function_call: storage.Column.FunctionCall) anyerror!storage.Column.FunctionCall {
        return self.cloneStorageFunctionCallDeep(function_call);
    }

    /// Clone a storage function call with deep cloning to prevent double-free
    fn cloneStorageFunctionCallDeep(self: *Self, function_call: storage.Column.FunctionCall) anyerror!storage.Column.FunctionCall {
        var cloned_args = try self.connection.allocator.alloc(storage.Column.FunctionArgument, function_call.arguments.len);
        errdefer self.connection.allocator.free(cloned_args);

        var args_cloned: usize = 0;
        errdefer {
            for (cloned_args[0..args_cloned]) |arg| {
                self.deallocateStorageFunctionArgument(arg);
            }
        }

        for (function_call.arguments, 0..) |arg, i| {
            cloned_args[i] = try self.cloneStorageFunctionArgumentDeep(arg);
            args_cloned = i + 1;
        }

        return storage.Column.FunctionCall{
            .name = try self.connection.allocator.dupe(u8, function_call.name),
            .arguments = cloned_args,
        };
    }

    /// Clone a storage function argument
    fn cloneStorageFunctionArgument(self: *Self, arg: storage.Column.FunctionArgument) anyerror!storage.Column.FunctionArgument {
        return self.cloneStorageFunctionArgumentDeep(arg);
    }

    /// Clone a storage function argument with deep cloning
    fn cloneStorageFunctionArgumentDeep(self: *Self, arg: storage.Column.FunctionArgument) anyerror!storage.Column.FunctionArgument {
        return switch (arg) {
            .Literal => |literal| {
                const cloned_literal = try literal.clone(self.connection.allocator);
                return storage.Column.FunctionArgument{ .Literal = cloned_literal };
            },
            .Column => |column| {
                return storage.Column.FunctionArgument{ .Column = try self.connection.allocator.dupe(u8, column) };
            },
            .Parameter => |param_index| {
                return storage.Column.FunctionArgument{ .Parameter = param_index };
            },
        };
    }

    /// Deallocate a storage function argument
    fn deallocateStorageFunctionArgument(self: *Self, arg: storage.Column.FunctionArgument) void {
        switch (arg) {
            .Literal => |literal| literal.deinit(self.connection.allocator),
            .Column => |column| self.connection.allocator.free(column),
            .Parameter => {}, // No deallocation needed
        }
    }

    fn cloneValue(self: *Self, value: storage.Value) !storage.Value {
        // Note: cloneValue called from non-table-scan operation
        const cloned = try value.clone(self.connection.allocator);
        switch (value) {
            .Text => {
                switch (cloned) {
                    .Text => {
                        // Cloning text value in non-table-scan operation
                    },
                    else => unreachable,
                }
            },
            else => {},
        }
        return cloned;
    }

    /// Evaluate an UPDATE expression against the current row values
    fn evaluateUpdateExpression(self: *Self, expr: ast.Expression, row_values: []storage.Value, table: *storage.Table) !storage.Value {
        return switch (expr) {
            .Column => |col_name| {
                // Find column index by name
                for (table.schema.columns, 0..) |col, idx| {
                    if (std.mem.eql(u8, col.name, col_name)) {
                        if (idx < row_values.len) {
                            return try row_values[idx].clone(self.connection.allocator);
                        }
                    }
                }
                return storage.Value.Null;
            },
            .Literal => |value| {
                return try self.convertAstValueToStorage(value);
            },
            .Parameter => |param_index| {
                return try self.resolveValue(storage.Value{ .Parameter = param_index });
            },
            .BinaryOp => |bin| {
                const left_val = try self.evaluateUpdateExpression(bin.left.*, row_values, table);
                defer left_val.deinit(self.connection.allocator);

                const right_val = try self.evaluateUpdateExpression(bin.right.*, row_values, table);
                defer right_val.deinit(self.connection.allocator);

                // Perform arithmetic based on operator
                return self.performArithmetic(left_val, bin.op, right_val);
            },
            .Subquery => |subquery| {
                // Execute scalar subquery and return first column of first row
                return try self.executeScalarSubquery(subquery);
            },
            .InList => {
                // InList is handled in comparison, not as standalone value
                return storage.Value.Null;
            },
        };
    }

    fn computeGeneratedColumns(self: *Self, table: *storage.Table, row_values: []storage.Value) !void {
        for (table.schema.columns, 0..) |column, idx| {
            const generated = column.generated orelse continue;
            if (!generated.stored) return error.VirtualGeneratedColumnUnsupported;

            const computed = try self.evaluateUpdateExpression(generated.expression, row_values, table);
            row_values[idx].deinit(self.connection.allocator);
            row_values[idx] = computed;
        }
    }

    /// Perform arithmetic operation on two values
    fn performArithmetic(self: *Self, left: storage.Value, op: ast.ArithmeticOp, right: storage.Value) !storage.Value {
        _ = self;
        // Extract numeric values
        const left_num: f64 = switch (left) {
            .Integer => |i| @floatFromInt(i),
            .Real => |r| r,
            else => return storage.Value.Null,
        };
        const right_num: f64 = switch (right) {
            .Integer => |i| @floatFromInt(i),
            .Real => |r| r,
            else => return storage.Value.Null,
        };

        const result: f64 = switch (op) {
            .Add => left_num + right_num,
            .Subtract => left_num - right_num,
            .Multiply => left_num * right_num,
            .Divide => if (right_num != 0) left_num / right_num else return storage.Value.Null,
            .Modulo => if (right_num != 0) @mod(left_num, right_num) else return storage.Value.Null,
        };

        // Return integer if both operands were integers and result is whole
        if (left == .Integer and right == .Integer and @floor(result) == result) {
            return storage.Value{ .Integer = @intFromFloat(result) };
        }
        return storage.Value{ .Real = result };
    }

    /// Execute limit
    fn executeLimit(self: *Self, limit: *planner.LimitStep, result: *ExecutionResult) !void {
        const start = @min(limit.offset, result.rows.items.len);
        const end = @min(start + limit.count, result.rows.items.len);

        if (start > 0 or end < result.rows.items.len) {
            // Free rows excluded by OFFSET (rows before start)
            for (result.rows.items[0..start]) |row| {
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }

            // Free rows excluded by LIMIT (rows after end)
            for (result.rows.items[end..]) |row| {
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }

            // Create new slice with limited rows
            var limited_rows: std.ArrayListUnmanaged(storage.Row) = .empty;
            for (result.rows.items[start..end]) |row| {
                try limited_rows.append(self.connection.allocator, row);
            }
            result.rows.deinit(self.connection.allocator);
            result.rows = limited_rows;
        }
    }

    fn executeSort(self: *Self, sort: *planner.SortStep, result: *ExecutionResult) !void {
        try self.sortResultRows(result, sort.order_by);
    }

    /// Execute insert
    fn executeInsert(self: *Self, insert: *planner.InsertStep, result: *ExecutionResult) !void {
        const resolved = try self.resolveTableRef(insert.table_name);
        try resolved.connection.ensureWritable();
        const table = resolved.connection.storage_engine.getTable(resolved.table_name) orelse {
            return error.TableNotFound;
        };

        // Track current table so ON CONFLICT expressions and conditions can
        // resolve column references against the target schema.
        self.current_table = table;

        for (insert.values) |row_values| {
            try self.connection.checkOperation();
            try self.connection.recordRowsScanned(1);
            // Build final values array for all table columns
            var final_values = try self.connection.allocator.alloc(storage.Value, table.schema.columns.len);
            var values_initialized: usize = 0;
            var ownership_transferred = false;
            errdefer {
                // Only cleanup if ownership wasn't transferred to the table
                if (!ownership_transferred) {
                    for (final_values[0..values_initialized]) |value| {
                        value.deinit(self.connection.allocator);
                    }
                    self.connection.allocator.free(final_values);
                }
            }

            // Initialize all values to null first
            for (final_values) |*value| {
                value.* = storage.Value.Null;
            }

            if (insert.columns) |specified_columns| {
                // INSERT with specific columns: INSERT INTO table (col1, col2) VALUES (...)
                if (specified_columns.len != row_values.len) {
                    return error.ColumnValueMismatch;
                }

                // Map provided values to specified columns
                for (specified_columns, 0..) |col_name, value_idx| {
                    // Find the column index in the table schema
                    var table_col_idx: ?usize = null;
                    for (table.schema.columns, 0..) |table_col, table_idx| {
                        if (std.mem.eql(u8, table_col.name, col_name)) {
                            if (table_col.generated != null) return error.CannotWriteGeneratedColumn;
                            table_col_idx = table_idx;
                            break;
                        }
                    }

                    if (table_col_idx == null) {
                        return error.ColumnNotFound;
                    }

                    // resolveValue already returns owned/cloned values
                    const resolved_value = try self.resolveValue(row_values[value_idx]);
                    final_values[table_col_idx.?] = resolved_value;
                    values_initialized = @max(values_initialized, table_col_idx.? + 1);
                }
            } else {
                // INSERT without column specification: INSERT INTO table VALUES (...)
                // Values are provided in table column order. FTS virtual tables keep
                // an implicit rowid backing column, so user-provided VALUES start at 1.
                var input_idx: usize = 0;
                const skip_fts_rowid = resolved.connection.storage_engine.isFTSTable(resolved.table_name);
                for (table.schema.columns, 0..) |column, target_idx| {
                    if (skip_fts_rowid and target_idx == 0 and column.is_primary_key) continue;
                    if (column.generated != null) continue;
                    if (input_idx >= row_values.len) break;

                    const resolved_value = try self.resolveValue(row_values[input_idx]);
                    final_values[target_idx] = resolved_value;
                    values_initialized = target_idx + 1;
                    input_idx += 1;
                }
                if (input_idx != row_values.len) {
                    return error.TooManyValues;
                }
                var required_input_count: usize = 0;
                for (table.schema.columns, 0..) |column, target_idx| {
                    if (skip_fts_rowid and target_idx == 0 and column.is_primary_key) continue;
                    if (column.generated != null) continue;
                    required_input_count += 1;
                }
                if (row_values.len > required_input_count) {
                    return error.TooManyValues;
                }
            }

            // Apply default values for columns that weren't specified
            for (table.schema.columns, 0..) |column, i| {
                if (column.generated != null) continue;
                if (final_values[i] == .Null) {
                    if (resolved.connection.storage_engine.isFTSTable(resolved.table_name) and i == 0 and column.is_primary_key) {
                        final_values[i] = storage.Value{ .Integer = @intCast(table.row_count) };
                        values_initialized = @max(values_initialized, i + 1);
                        continue;
                    }
                    if (column.default_value) |default_value| {
                        // Replace NULL with evaluated default value
                        const default_val = try self.evaluateStorageDefaultValue(default_value);
                        final_values[i] = default_val;
                        values_initialized = @max(values_initialized, i + 1);
                    } else if (!column.is_nullable) {
                        // Non-nullable column without default value
                        return error.MissingRequiredValue;
                    }
                    // For nullable columns without defaults, keep as NULL
                }
            }

            try self.computeGeneratedColumns(table, final_values);
            values_initialized = final_values.len;

            try self.validateCheckConstraints(table, final_values);
            try self.validateNotNullConstraints(table, final_values);
            try self.validateForeignKeyReferences(table, final_values);
            try resolved.connection.storage_engine.checkUniqueIndexes(table, final_values);

            // Handle ON CONFLICT - check for primary key conflict before insert
            if (insert.on_conflict != null) {
                // Find primary key column index
                var pk_col_idx: ?usize = null;
                for (table.schema.columns, 0..) |col, idx| {
                    if (col.is_primary_key) {
                        pk_col_idx = idx;
                        break;
                    }
                }

                if (pk_col_idx) |pk_idx| {
                    // Check if a row with this primary key already exists
                    const all_rows = try table.btree.selectAllWithKeys(self.connection.allocator);
                    defer {
                        for (all_rows) |item| {
                            for (item.row.values) |value| {
                                value.deinit(self.connection.allocator);
                            }
                            self.connection.allocator.free(item.row.values);
                        }
                        self.connection.allocator.free(all_rows);
                    }

                    var conflict_row_key: ?u64 = null;
                    for (all_rows) |item| {
                        if (!table.deleted_keys.contains(item.key)) {
                            if (self.valuesEqual(item.row.values[pk_idx], final_values[pk_idx])) {
                                conflict_row_key = item.key;
                                break;
                            }
                        }
                    }

                    if (conflict_row_key != null) {
                        switch (insert.on_conflict.?) {
                            .DoNothing => {
                                // Clean up final_values since we're not inserting
                                for (final_values) |val| {
                                    val.deinit(self.connection.allocator);
                                }
                                self.connection.allocator.free(final_values);
                                continue;
                            },
                            .DoUpdate => |on_conflict_update| {
                                // Get the existing row
                                if (try table.btree.search(conflict_row_key.?)) |existing_row| {
                                    defer {
                                        for (existing_row.values) |value| {
                                            value.deinit(self.connection.allocator);
                                        }
                                        self.connection.allocator.free(existing_row.values);
                                    }

                                    // Apply the update assignments. References to the
                                    // pseudo-table `excluded` must resolve against the
                                    // would-be-inserted row (final_values), not the
                                    // existing row.
                                    for (on_conflict_update.assignments) |assignment| {
                                        for (table.schema.columns, 0..) |col, col_idx| {
                                            if (std.mem.eql(u8, col.name, assignment.column)) {
                                                const new_value = try self.evaluateUpsertAssignment(&assignment.expr, &existing_row, table, final_values);
                                                existing_row.values[col_idx].deinit(self.connection.allocator);
                                                existing_row.values[col_idx] = new_value;
                                                break;
                                            }
                                        }
                                    }

                                    if (on_conflict_update.condition) |condition| {
                                        if (!try self.evaluateCondition(&condition, &existing_row)) {
                                            for (final_values) |val| {
                                                val.deinit(self.connection.allocator);
                                            }
                                            self.connection.allocator.free(final_values);
                                            continue;
                                        }
                                    }

                                    try self.validateCheckConstraints(table, existing_row.values);
                                    try self.validateNotNullConstraints(table, existing_row.values);
                                    try self.validateForeignKeyReferences(table, existing_row.values);

                                    var replacement_values = try self.connection.allocator.alloc(storage.Value, existing_row.values.len);
                                    var replacement_initialized: usize = 0;
                                    errdefer {
                                        for (replacement_values[0..replacement_initialized]) |value| {
                                            value.deinit(self.connection.allocator);
                                        }
                                        self.connection.allocator.free(replacement_values);
                                    }

                                    for (existing_row.values, 0..) |value, i| {
                                        replacement_values[i] = try value.clone(self.connection.allocator);
                                        replacement_initialized = i + 1;
                                    }

                                    const new_row_id: i64 = @intCast(table.row_count);

                                    if (resolved.connection.in_transaction) {
                                        const table_name_copy = try self.connection.allocator.dupe(u8, insert.table_name);
                                        try resolved.connection.logUndo(db.UndoEntry{
                                            .operation = .Update,
                                            .table_name = table_name_copy,
                                            .row_id = @intCast(conflict_row_key.?),
                                            .new_row_id = new_row_id,
                                            .old_values = null,
                                        });
                                    }

                                    try table.updateRow(self.connection.allocator, @intCast(conflict_row_key.?), replacement_values);
                                    result.affected_rows += 1;
                                    try self.connection.recordAffectedRows(result.affected_rows);

                                    // Handle RETURNING for upserted row
                                    if (insert.returning_columns) |ret_cols| {
                                        try self.addReturningRow(result, table, existing_row.values, ret_cols);
                                    }
                                }
                                // Clean up final_values since we did update instead
                                for (final_values) |val| {
                                    val.deinit(self.connection.allocator);
                                }
                                self.connection.allocator.free(final_values);
                                continue;
                            },
                        }
                    }
                }
            }

            // Insert the row and get the row_id
            const row_id = try table.insert(self.connection.allocator, final_values);
            ownership_transferred = true; // Table now owns final_values

            // Log undo entry if in transaction
            if (resolved.connection.in_transaction) {
                const table_name_copy = try self.connection.allocator.dupe(u8, insert.table_name);
                try resolved.connection.logUndo(db.UndoEntry{
                    .operation = .Insert,
                    .table_name = table_name_copy,
                    .row_id = row_id,
                    .new_row_id = null,
                    .old_values = null,
                });
            }

            if (resolved.connection.storage_engine.getFTSIndex(resolved.table_name)) |fts_index| {
                if (try table.btree.search(@intCast(row_id))) |inserted_row| {
                    defer {
                        for (inserted_row.values) |value| {
                            value.deinit(self.connection.allocator);
                        }
                        self.connection.allocator.free(inserted_row.values);
                    }

                    const fts_values = if (inserted_row.values.len > 1) inserted_row.values[1..] else inserted_row.values;
                    try fts_index.indexDocument(@intCast(row_id), fts_values);
                }
            }

            result.affected_rows += 1;
            try self.connection.recordAffectedRows(result.affected_rows);

            // Handle RETURNING clause - add inserted row to result
            if (insert.returning_columns) |ret_cols| {
                // Retrieve the just-inserted row from btree
                if (try table.btree.search(@intCast(row_id))) |inserted_row| {
                    defer {
                        for (inserted_row.values) |value| {
                            value.deinit(self.connection.allocator);
                        }
                        self.connection.allocator.free(inserted_row.values);
                    }
                    try self.addReturningRow(result, table, inserted_row.values, ret_cols);
                }
            }
        }

        if (result.affected_rows > 0) {
            try resolved.connection.storage_engine.refreshIndexesForTable(resolved.table_name);
        }

        // Invalidate query result cache for this table
        resolved.connection.invalidateResultCache(resolved.table_name);
    }

    /// Helper to add a row to result based on RETURNING columns
    fn addReturningRow(self: *Self, result: *ExecutionResult, table: *storage.Table, row_values: []storage.Value, ret_cols: [][]const u8) !void {
        var return_values = try self.connection.allocator.alloc(storage.Value, ret_cols.len);
        errdefer self.connection.allocator.free(return_values);

        for (ret_cols, 0..) |col_name, ret_idx| {
            if (std.mem.eql(u8, col_name, "*")) {
                // RETURNING * - return all columns (resize array if needed)
                self.connection.allocator.free(return_values);
                return_values = try self.connection.allocator.alloc(storage.Value, row_values.len);
                for (row_values, 0..) |val, i| {
                    return_values[i] = try val.clone(self.connection.allocator);
                }
                break;
            } else {
                // Find specific column
                for (table.schema.columns, 0..) |col, col_idx| {
                    if (std.mem.eql(u8, col.name, col_name)) {
                        return_values[ret_idx] = try row_values[col_idx].clone(self.connection.allocator);
                        break;
                    }
                }
            }
        }

        try result.rows.append(self.connection.allocator, storage.Row{ .values = return_values });
    }

    fn validateCheckConstraints(self: *Self, table: *storage.Table, row_values: []const storage.Value) !void {
        if (table.schema.check_constraints.len == 0) return;

        const row = storage.Row{ .values = @constCast(row_values) };
        const previous_table = self.current_table;
        self.current_table = table;
        defer self.current_table = previous_table;

        for (table.schema.check_constraints) |*condition| {
            const truth = try self.evaluateConditionTruth(condition, &row);
            if (truth == .False) return error.ConstraintViolation;
        }
    }

    fn validateNotNullConstraints(self: *Self, table: *storage.Table, row_values: []const storage.Value) !void {
        _ = self;
        for (table.schema.columns, 0..) |column, i| {
            if (i >= row_values.len) return error.MissingRequiredValue;
            if (!column.is_nullable and row_values[i] == .Null) return error.MissingRequiredValue;
        }
    }

    fn validateForeignKeyReferences(self: *Self, table: *storage.Table, row_values: []const storage.Value) !void {
        return self.validateForeignKeyReferencesSkipping(table, row_values, null);
    }

    fn validateForeignKeyReferencesSkipping(self: *Self, table: *storage.Table, row_values: []const storage.Value, skip_foreign_key: ?*const ast.ForeignKeyConstraint) !void {
        for (table.schema.foreign_keys) |foreign_key| {
            if (skip_foreign_key) |skip| {
                if (sameForeignKey(foreign_key, skip.*)) continue;
            }
            if (foreign_key.deferred and self.connection.in_transaction) continue;
            try self.validateOneForeignKey(table, row_values, foreign_key);
        }
    }

    fn validateOneForeignKey(self: *Self, table: *storage.Table, row_values: []const storage.Value, foreign_key: ast.ForeignKeyConstraint) !void {
        const parent_table = self.connection.storage_engine.getTable(foreign_key.reference_table) orelse return error.ConstraintViolation;
        if (foreign_key.columns) |child_columns| {
            const parent_columns = foreign_key.reference_columns orelse return error.ConstraintViolation;
            if (child_columns.len == 0 or child_columns.len != parent_columns.len) return error.ConstraintViolation;
            for (child_columns) |column| {
                const idx = table.getColumnIndex(column) orelse return error.ConstraintViolation;
                if (idx >= row_values.len) return error.ConstraintViolation;
                if (row_values[idx] == .Null) return;
            }
            if (!try self.tableHasCompositeValue(parent_table, parent_columns, table, child_columns, row_values)) return error.ConstraintViolation;
            return;
        }

        const child_column = foreign_key.column orelse return error.ConstraintViolation;
        const child_idx = table.getColumnIndex(child_column) orelse return error.ConstraintViolation;
        if (child_idx >= row_values.len) return error.ConstraintViolation;
        const child_value = row_values[child_idx];
        if (child_value == .Null) return;
        const parent_idx = parent_table.getColumnIndex(foreign_key.reference_column) orelse return error.ConstraintViolation;
        if (!try self.tableHasValue(parent_table, parent_idx, child_value)) return error.ConstraintViolation;
    }

    fn tableHasCompositeValue(self: *Self, parent_table: *storage.Table, parent_columns: []const []const u8, child_table: *storage.Table, child_columns: []const []const u8, child_values: []const storage.Value) !bool {
        const rows = try parent_table.selectWithKeys(self.connection.allocator);
        defer {
            for (rows) |item| {
                var row = item.row;
                row.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(rows);
        }
        for (rows) |item| {
            var matches = true;
            for (parent_columns, child_columns) |parent_column, child_column| {
                const parent_idx = parent_table.getColumnIndex(parent_column) orelse return error.ConstraintViolation;
                const child_idx = child_table.getColumnIndex(child_column) orelse return error.ConstraintViolation;
                if (parent_idx >= item.row.values.len or child_idx >= child_values.len or
                    !self.valuesEqual(item.row.values[parent_idx], child_values[child_idx]))
                {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    pub fn validateDeferredForeignKeys(self: *Self) !void {
        var table_it = self.connection.storage_engine.tables.iterator();
        while (table_it.next()) |entry| {
            const table = entry.value_ptr.*;
            var has_deferred = false;
            for (table.schema.foreign_keys) |foreign_key| {
                if (foreign_key.deferred) {
                    has_deferred = true;
                    break;
                }
            }
            if (!has_deferred) continue;
            const rows = try table.selectWithKeys(self.connection.allocator);
            defer {
                for (rows) |item| {
                    var row = item.row;
                    row.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(rows);
            }
            for (rows) |item| {
                for (table.schema.foreign_keys) |foreign_key| {
                    if (foreign_key.deferred) try self.validateOneForeignKey(table, item.row.values, foreign_key);
                }
            }
        }
    }

    fn sameForeignKey(a: ast.ForeignKeyConstraint, b: ast.ForeignKeyConstraint) bool {
        if (a.columns) |a_columns| {
            const b_columns = b.columns orelse return false;
            const a_refs = a.reference_columns orelse return false;
            const b_refs = b.reference_columns orelse return false;
            if (a_columns.len != b_columns.len or a_refs.len != b_refs.len) return false;
            for (a_columns, b_columns) |left, right| if (!std.mem.eql(u8, left, right)) return false;
            for (a_refs, b_refs) |left, right| if (!std.mem.eql(u8, left, right)) return false;
            return std.mem.eql(u8, a.reference_table, b.reference_table);
        }
        const a_column = a.column orelse return b.column == null;
        const b_column = b.column orelse return false;
        return std.mem.eql(u8, a_column, b_column) and
            std.mem.eql(u8, a.reference_table, b.reference_table) and
            std.mem.eql(u8, a.reference_column, b.reference_column);
    }

    fn tableHasValue(self: *Self, table: *storage.Table, column_idx: usize, value: storage.Value) !bool {
        const rows = try table.selectWithKeys(self.connection.allocator);
        defer {
            for (rows) |item| {
                for (item.row.values) |row_value| row_value.deinit(self.connection.allocator);
                self.connection.allocator.free(item.row.values);
            }
            self.connection.allocator.free(rows);
        }

        for (rows) |item| {
            if (column_idx < item.row.values.len and self.valuesEqual(item.row.values[column_idx], value)) {
                return true;
            }
        }
        return false;
    }

    fn applyParentForeignKeyDeleteActions(self: *Self, parent_table: *storage.Table, parent_values: []const storage.Value) anyerror!void {
        var table_it = self.connection.storage_engine.tables.iterator();
        while (table_it.next()) |entry| {
            const child_table = entry.value_ptr.*;
            for (child_table.schema.foreign_keys) |foreign_key| {
                if (!std.mem.eql(u8, foreign_key.reference_table, parent_table.name)) continue;
                if (foreign_key.columns != null) {
                    if (foreign_key.deferred and self.connection.in_transaction and (foreign_key.on_delete orelse .NoAction) == .NoAction) continue;
                    if (try self.childReferencesCompositeParent(child_table, foreign_key, parent_table, parent_values)) {
                        switch (foreign_key.on_delete orelse .NoAction) {
                            .Restrict, .NoAction => return error.ConstraintViolation,
                            .Cascade, .SetNull => return error.UnsupportedCompositeForeignKeyAction,
                        }
                    }
                    continue;
                }
                if (foreign_key.deferred and self.connection.in_transaction and (foreign_key.on_delete orelse .NoAction) == .NoAction) continue;
                const parent_idx = parent_table.getColumnIndex(foreign_key.reference_column) orelse return error.ConstraintViolation;
                if (parent_idx >= parent_values.len or parent_values[parent_idx] == .Null) continue;
                if (try self.childReferencesValue(child_table, foreign_key, parent_values[parent_idx])) {
                    try switch (foreign_key.on_delete orelse .NoAction) {
                        .Restrict, .NoAction => error.ConstraintViolation,
                        .Cascade => try self.deleteChildRowsReferencing(child_table, foreign_key, parent_values[parent_idx]),
                        .SetNull => try self.updateChildRowsReferencing(child_table, foreign_key, parent_values[parent_idx], storage.Value.Null),
                    };
                }
            }
        }
    }

    fn applyParentForeignKeyUpdateActions(self: *Self, parent_table: *storage.Table, old_values: []const storage.Value, new_values: []const storage.Value) anyerror!void {
        var table_it = self.connection.storage_engine.tables.iterator();
        while (table_it.next()) |entry| {
            const child_table = entry.value_ptr.*;
            for (child_table.schema.foreign_keys) |foreign_key| {
                if (!std.mem.eql(u8, foreign_key.reference_table, parent_table.name)) continue;
                if (foreign_key.columns != null) {
                    const references_old = try self.childReferencesCompositeParent(child_table, foreign_key, parent_table, old_values);
                    if (!references_old) continue;
                    const refs = foreign_key.reference_columns orelse return error.ConstraintViolation;
                    var changed = false;
                    for (refs) |column| {
                        const idx = parent_table.getColumnIndex(column) orelse return error.ConstraintViolation;
                        if (idx >= old_values.len or idx >= new_values.len) return error.ConstraintViolation;
                        if (!self.valuesEqual(old_values[idx], new_values[idx])) changed = true;
                    }
                    if (changed) switch (foreign_key.on_update orelse .NoAction) {
                        .Restrict, .NoAction => return error.ConstraintViolation,
                        .Cascade, .SetNull => return error.UnsupportedCompositeForeignKeyAction,
                    };
                    continue;
                }
                if (foreign_key.deferred and self.connection.in_transaction and (foreign_key.on_update orelse .NoAction) == .NoAction) continue;
                const parent_idx = parent_table.getColumnIndex(foreign_key.reference_column) orelse return error.ConstraintViolation;
                if (parent_idx >= old_values.len or parent_idx >= new_values.len) return error.ConstraintViolation;
                if (self.valuesEqual(old_values[parent_idx], new_values[parent_idx])) continue;
                if (old_values[parent_idx] == .Null) continue;
                if (try self.childReferencesValue(child_table, foreign_key, old_values[parent_idx])) {
                    try switch (foreign_key.on_update orelse .NoAction) {
                        .Restrict, .NoAction => error.ConstraintViolation,
                        .Cascade => try self.updateChildRowsReferencing(child_table, foreign_key, old_values[parent_idx], new_values[parent_idx]),
                        .SetNull => try self.updateChildRowsReferencing(child_table, foreign_key, old_values[parent_idx], storage.Value.Null),
                    };
                }
            }
        }
    }

    fn childReferencesValue(self: *Self, child_table: *storage.Table, foreign_key: ast.ForeignKeyConstraint, parent_value: storage.Value) !bool {
        const child_column = foreign_key.column orelse return false;
        const child_idx = child_table.getColumnIndex(child_column) orelse return error.ConstraintViolation;

        const rows = try child_table.selectWithKeys(self.connection.allocator);
        defer {
            for (rows) |item| {
                for (item.row.values) |row_value| row_value.deinit(self.connection.allocator);
                self.connection.allocator.free(item.row.values);
            }
            self.connection.allocator.free(rows);
        }

        for (rows) |item| {
            if (child_idx >= item.row.values.len) continue;
            const child_value = item.row.values[child_idx];
            if (child_value != .Null and self.valuesEqual(child_value, parent_value)) return true;
        }
        return false;
    }

    fn childReferencesCompositeParent(self: *Self, child_table: *storage.Table, foreign_key: ast.ForeignKeyConstraint, parent_table: *storage.Table, parent_values: []const storage.Value) !bool {
        const child_columns = foreign_key.columns orelse return false;
        const parent_columns = foreign_key.reference_columns orelse return error.ConstraintViolation;
        const rows = try child_table.selectWithKeys(self.connection.allocator);
        defer {
            for (rows) |item| {
                var row = item.row;
                row.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(rows);
        }
        for (rows) |item| {
            var matches = true;
            for (child_columns, parent_columns) |child_column, parent_column| {
                const child_idx = child_table.getColumnIndex(child_column) orelse return error.ConstraintViolation;
                const parent_idx = parent_table.getColumnIndex(parent_column) orelse return error.ConstraintViolation;
                if (child_idx >= item.row.values.len or parent_idx >= parent_values.len or item.row.values[child_idx] == .Null or
                    !self.valuesEqual(item.row.values[child_idx], parent_values[parent_idx]))
                {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    fn deleteChildRowsReferencing(self: *Self, child_table: *storage.Table, foreign_key: ast.ForeignKeyConstraint, parent_value: storage.Value) anyerror!void {
        const child_column = foreign_key.column orelse return error.ConstraintViolation;
        const child_idx = child_table.getColumnIndex(child_column) orelse return error.ConstraintViolation;

        const rows = try child_table.selectWithKeys(self.connection.allocator);
        defer {
            for (rows) |item| {
                for (item.row.values) |row_value| row_value.deinit(self.connection.allocator);
                self.connection.allocator.free(item.row.values);
            }
            self.connection.allocator.free(rows);
        }

        var changed = false;
        for (rows) |item| {
            if (child_idx >= item.row.values.len) continue;
            const child_value = item.row.values[child_idx];
            if (child_value == .Null or !self.valuesEqual(child_value, parent_value)) continue;

            try self.applyParentForeignKeyDeleteActions(child_table, item.row.values);

            if (self.connection.in_transaction) {
                const table_name_copy = try self.connection.allocator.dupe(u8, child_table.name);
                try self.connection.logUndo(db.UndoEntry{
                    .operation = .Delete,
                    .table_name = table_name_copy,
                    .row_id = item.key,
                    .new_row_id = null,
                    .old_values = null,
                });
            }

            try child_table.delete(self.connection.allocator, item.key);
            changed = true;
        }

        if (changed) {
            try self.connection.storage_engine.refreshIndexesForTable(child_table.name);
            self.connection.invalidateResultCache(child_table.name);
        }
    }

    fn updateChildRowsReferencing(self: *Self, child_table: *storage.Table, foreign_key: ast.ForeignKeyConstraint, parent_value: storage.Value, replacement_value: storage.Value) anyerror!void {
        const child_column = foreign_key.column orelse return error.ConstraintViolation;
        const child_idx = child_table.getColumnIndex(child_column) orelse return error.ConstraintViolation;

        const rows = try child_table.selectWithKeys(self.connection.allocator);
        defer {
            for (rows) |item| {
                for (item.row.values) |row_value| row_value.deinit(self.connection.allocator);
                self.connection.allocator.free(item.row.values);
            }
            self.connection.allocator.free(rows);
        }

        var changed = false;
        for (rows) |item| {
            if (child_idx >= item.row.values.len) continue;
            const child_value = item.row.values[child_idx];
            if (child_value == .Null or !self.valuesEqual(child_value, parent_value)) continue;

            var updated_values = try self.connection.allocator.alloc(storage.Value, item.row.values.len);
            var values_cloned: usize = 0;
            errdefer {
                for (updated_values[0..values_cloned]) |value| value.deinit(self.connection.allocator);
                self.connection.allocator.free(updated_values);
            }

            for (item.row.values, 0..) |value, i| {
                updated_values[i] = try value.clone(self.connection.allocator);
                values_cloned = i + 1;
            }
            updated_values[child_idx].deinit(self.connection.allocator);
            updated_values[child_idx] = try replacement_value.clone(self.connection.allocator);

            try self.validateNotNullConstraints(child_table, updated_values);
            try self.validateCheckConstraints(child_table, updated_values);
            try self.validateForeignKeyReferencesSkipping(child_table, updated_values, &foreign_key);
            try self.applyParentForeignKeyUpdateActions(child_table, item.row.values, updated_values);

            const new_row_id: i64 = @intCast(child_table.row_count);
            if (self.connection.in_transaction) {
                const table_name_copy = try self.connection.allocator.dupe(u8, child_table.name);
                try self.connection.logUndo(db.UndoEntry{
                    .operation = .Update,
                    .table_name = table_name_copy,
                    .row_id = item.key,
                    .new_row_id = new_row_id,
                    .old_values = null,
                });
            }

            try child_table.updateRow(self.connection.allocator, item.key, updated_values);
            changed = true;
        }

        if (changed) {
            try self.connection.storage_engine.refreshIndexesForTable(child_table.name);
            self.connection.invalidateResultCache(child_table.name);
        }
    }

    /// Execute create table
    fn executeCreateTable(self: *Self, create: *planner.CreateTableStep, result: *ExecutionResult) !void {
        try self.rejectSchemaChangeInSavepoint();
        const resolved = try self.resolveTableRef(create.table_name);
        try resolved.connection.ensureWritable();

        // Check if table exists and if_not_exists is true
        if (create.if_not_exists and resolved.connection.storage_engine.getTable(resolved.table_name) != null) {
            return; // Table already exists, skip creation
        }

        // Clone columns for the storage engine (they're owned by the planner otherwise)
        var cloned_columns = try self.connection.allocator.alloc(storage.Column, create.columns.len);

        for (create.columns, 0..) |column, i| {
            cloned_columns[i] = storage.Column{
                .name = self.connection.allocator.dupe(u8, column.name) catch {
                    // Clean up already cloned columns on failure
                    for (cloned_columns[0..i]) |c| {
                        self.connection.allocator.free(c.name);
                        if (c.default_value) |dv| dv.deinit(self.connection.allocator);
                        if (c.generated) |generated| generated.deinit(self.connection.allocator);
                    }
                    self.connection.allocator.free(cloned_columns);
                    return error.OutOfMemory;
                },
                .data_type = column.data_type,
                .is_primary_key = column.is_primary_key,
                .is_nullable = column.is_nullable,
                .is_unique = column.is_unique,
                .default_value = if (column.default_value) |default_value|
                    self.cloneStorageDefaultValue(default_value) catch {
                        self.connection.allocator.free(cloned_columns[i].name);
                        for (cloned_columns[0..i]) |c| {
                            self.connection.allocator.free(c.name);
                            if (c.default_value) |dv| dv.deinit(self.connection.allocator);
                            if (c.generated) |generated| generated.deinit(self.connection.allocator);
                        }
                        self.connection.allocator.free(cloned_columns);
                        return error.OutOfMemory;
                    }
                else
                    null,
                .generated = if (column.generated) |generated|
                    generated.clone(self.connection.allocator) catch {
                        self.connection.allocator.free(cloned_columns[i].name);
                        if (cloned_columns[i].default_value) |dv| dv.deinit(self.connection.allocator);
                        for (cloned_columns[0..i]) |c| {
                            self.connection.allocator.free(c.name);
                            if (c.default_value) |dv| dv.deinit(self.connection.allocator);
                            if (c.generated) |generated_column| generated_column.deinit(self.connection.allocator);
                        }
                        self.connection.allocator.free(cloned_columns);
                        return error.OutOfMemory;
                    }
                else
                    null,
            };
        }

        var schema = storage.TableSchema{
            .columns = cloned_columns,
            .check_constraints = create.check_constraints,
            .foreign_keys = create.foreign_keys,
        };
        defer {
            // create.check_constraints are owned by the execution plan. The
            // storage engine clones them during createTable; only cloned_columns
            // are owned by this temporary schema.
            schema.check_constraints = &.{};
            schema.foreign_keys = &.{};
            schema.deinit(self.connection.allocator);
        }

        try resolved.connection.storage_engine.createTable(resolved.table_name, schema);
        resolved.connection.invalidateResultCache(resolved.table_name);

        // Enforce inline UNIQUE column constraints by auto-creating a unique index.
        // The index is persisted in the catalog, so the constraint survives reopen.
        for (create.columns) |column| {
            if (!column.is_unique or column.is_primary_key) continue;
            try self.createAutoUniqueIndexForConnection(resolved.connection, resolved.table_name, column.name);
        }

        for (create.unique_constraints, 0..) |unique, i| {
            try self.createAutoUniqueIndexForColumnsOnConnection(resolved.connection, resolved.table_name, unique.columns, i + 1);
        }

        result.affected_rows = 1;
    }

    /// Create a deterministic unique index backing an inline UNIQUE column
    /// constraint. The index name mirrors SQLite's `sqlite_autoindex_*` scheme so
    /// it is recognizable and unlikely to collide with user index names.
    fn createAutoUniqueIndex(self: *Self, table_name: []const u8, column_name: []const u8) !void {
        return self.createAutoUniqueIndexForConnection(self.connection, table_name, column_name);
    }

    fn createAutoUniqueIndexForConnection(self: *Self, target_conn: *db.Connection, table_name: []const u8, column_name: []const u8) !void {
        const index_name = try std.fmt.allocPrint(
            self.connection.allocator,
            "sqlite_autoindex_{s}_{s}",
            .{ table_name, column_name },
        );
        defer self.connection.allocator.free(index_name);

        var columns = [_][]const u8{column_name};
        try target_conn.storage_engine.createIndex(index_name, table_name, columns[0..], true);
    }

    /// Create a deterministic unique index backing a table-level UNIQUE(...)
    /// constraint. The index is persisted in the catalog with the rest of the
    /// table metadata, so enforcement survives reopen.
    fn createAutoUniqueIndexForColumns(self: *Self, table_name: []const u8, column_names: [][]const u8, ordinal: usize) !void {
        return self.createAutoUniqueIndexForColumnsOnConnection(self.connection, table_name, column_names, ordinal);
    }

    fn createAutoUniqueIndexForColumnsOnConnection(self: *Self, target_conn: *db.Connection, table_name: []const u8, column_names: [][]const u8, ordinal: usize) !void {
        const index_name = try std.fmt.allocPrint(
            self.connection.allocator,
            "sqlite_autoindex_{s}_unique_{d}",
            .{ table_name, ordinal },
        );
        defer self.connection.allocator.free(index_name);

        try target_conn.storage_engine.createIndex(index_name, table_name, column_names, true);
    }

    /// Execute update using logical updates with transaction undo support
    fn executeUpdate(self: *Self, update: *planner.UpdateStep, result: *ExecutionResult) !void {
        const resolved = try self.resolveTableRef(update.table_name);
        try resolved.connection.ensureWritable();
        const table = resolved.connection.storage_engine.getTable(resolved.table_name) orelse {
            return error.TableNotFound;
        };

        // Track the current table for column name resolution in condition evaluation
        self.current_table = table;

        // Get all current rows with their keys for proper update tracking
        const all_rows = try table.selectWithKeys(self.connection.allocator);
        defer {
            for (all_rows) |item| {
                for (item.row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(item.row.values);
            }
            self.connection.allocator.free(all_rows);
        }

        var updated_count: u32 = 0;

        for (all_rows) |item| {
            try self.connection.checkOperation();
            try self.connection.recordRowsScanned(1);
            // Check if row matches condition
            var matches = true;
            if (update.condition) |condition| {
                matches = try self.evaluateCondition(&condition, &item.row);
            }

            if (matches) {
                // Create updated row by cloning the original and applying changes
                var updated_values = try self.connection.allocator.alloc(storage.Value, item.row.values.len);
                var values_cloned: usize = 0;
                errdefer {
                    for (updated_values[0..values_cloned]) |value| {
                        value.deinit(self.connection.allocator);
                    }
                    self.connection.allocator.free(updated_values);
                }

                for (item.row.values, 0..) |value, i| {
                    updated_values[i] = try self.cloneValue(value);
                    values_cloned = i + 1;
                }

                // Apply assignments - look up column by name to get correct index
                for (update.assignments) |assignment| {
                    var col_idx: ?usize = null;
                    for (table.schema.columns, 0..) |col, idx| {
                        if (std.mem.eql(u8, col.name, assignment.column)) {
                            if (col.generated != null) return error.CannotWriteGeneratedColumn;
                            col_idx = idx;
                            break;
                        }
                    }
                    if (col_idx) |idx| {
                        if (idx < updated_values.len) {
                            updated_values[idx].deinit(self.connection.allocator);
                            // Evaluate expression against current row values
                            updated_values[idx] = try self.evaluateUpdateExpression(assignment.expr, item.row.values, table);
                        }
                    }
                }

                try self.computeGeneratedColumns(table, updated_values);

                var returning_values: ?[]storage.Value = null;
                errdefer if (returning_values) |values| {
                    for (values) |value| {
                        value.deinit(self.connection.allocator);
                    }
                    self.connection.allocator.free(values);
                };

                if (update.returning_columns != null) {
                    returning_values = try self.connection.allocator.alloc(storage.Value, updated_values.len);
                    var returning_initialized: usize = 0;
                    errdefer if (returning_values) |values| {
                        for (values[0..returning_initialized]) |value| {
                            value.deinit(self.connection.allocator);
                        }
                    };

                    for (updated_values, 0..) |value, i| {
                        returning_values.?[i] = try value.clone(self.connection.allocator);
                        returning_initialized = i + 1;
                    }
                }

                // Get the new row_id before updating (it will be table.row_count)
                const new_row_id: i64 = @intCast(table.row_count);

                try self.validateCheckConstraints(table, updated_values);
                try self.validateNotNullConstraints(table, updated_values);
                try self.validateForeignKeyReferences(table, updated_values);
                try self.applyParentForeignKeyUpdateActions(table, item.row.values, updated_values);

                // Log undo entry before updating (if in transaction)
                if (resolved.connection.in_transaction) {
                    const table_name_copy = try self.connection.allocator.dupe(u8, update.table_name);
                    try resolved.connection.logUndo(db.UndoEntry{
                        .operation = .Update,
                        .table_name = table_name_copy,
                        .row_id = item.key, // old row_id to restore
                        .new_row_id = new_row_id, // new row_id to delete on rollback
                        .old_values = null, // Using logical deletes, old row is still in btree
                    });
                }

                // Perform logical update (marks old as deleted, inserts new)
                try table.updateRow(self.connection.allocator, item.key, updated_values);
                updated_count += 1;
                try self.connection.recordAffectedRows(updated_count);

                // Handle RETURNING clause - return the updated row values
                if (update.returning_columns) |ret_cols| {
                    try self.addReturningRow(result, table, returning_values.?, ret_cols);
                    for (returning_values.?) |value| {
                        value.deinit(self.connection.allocator);
                    }
                    self.connection.allocator.free(returning_values.?);
                    returning_values = null;
                }
            }
        }

        result.affected_rows = updated_count;

        if (updated_count > 0) {
            try resolved.connection.storage_engine.refreshIndexesForTable(resolved.table_name);
        }

        // Invalidate query result cache for this table
        resolved.connection.invalidateResultCache(resolved.table_name);
    }

    /// Execute delete using logical deletes with transaction undo support
    fn executeDelete(self: *Self, delete: *planner.DeleteStep, result: *ExecutionResult) !void {
        const resolved = try self.resolveTableRef(delete.table_name);
        try resolved.connection.ensureWritable();
        const table = resolved.connection.storage_engine.getTable(resolved.table_name) orelse {
            return error.TableNotFound;
        };

        // Track the current table for column name resolution in condition evaluation
        self.current_table = table;

        // Get all current rows with their keys for logical deletion
        const all_rows = try table.selectWithKeys(self.connection.allocator);
        defer {
            for (all_rows) |item| {
                for (item.row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(item.row.values);
            }
            self.connection.allocator.free(all_rows);
        }

        var deleted_count: u32 = 0;

        for (all_rows) |item| {
            try self.connection.checkOperation();
            try self.connection.recordRowsScanned(1);
            // Check if row matches delete condition
            var should_delete = true;
            if (delete.condition) |condition| {
                should_delete = try self.evaluateCondition(&condition, &item.row);
            }

            if (should_delete) {
                try self.applyParentForeignKeyDeleteActions(table, item.row.values);

                // Handle RETURNING clause - capture row values BEFORE delete
                if (delete.returning_columns) |ret_cols| {
                    try self.addReturningRow(result, table, item.row.values, ret_cols);
                }

                // Log undo entry before deleting (if in transaction)
                if (resolved.connection.in_transaction) {
                    const table_name_copy = try self.connection.allocator.dupe(u8, delete.table_name);
                    try resolved.connection.logUndo(db.UndoEntry{
                        .operation = .Delete,
                        .table_name = table_name_copy,
                        .row_id = item.key,
                        .new_row_id = null,
                        .old_values = null, // Using logical deletes, row is still in btree
                    });
                }

                // Perform logical delete
                try table.delete(self.connection.allocator, item.key);
                deleted_count += 1;
                try self.connection.recordAffectedRows(deleted_count);
            }
        }

        result.affected_rows = deleted_count;

        if (deleted_count > 0) {
            try resolved.connection.storage_engine.refreshIndexesForTable(resolved.table_name);
        }

        // Invalidate query result cache for this table
        resolved.connection.invalidateResultCache(resolved.table_name);
    }

    /// Evaluate a condition against a row
    fn evaluateCondition(self: *Self, condition: *const ast.Condition, row: *const storage.Row) anyerror!bool {
        return (try self.evaluateConditionTruth(condition, row)) == .True;
    }

    const SqlTruth = enum {
        True,
        False,
        Unknown,

        fn not(self: SqlTruth) SqlTruth {
            return switch (self) {
                .True => .False,
                .False => .True,
                .Unknown => .Unknown,
            };
        }
    };

    fn sqlAnd(left: SqlTruth, right: SqlTruth) SqlTruth {
        if (left == .False or right == .False) return .False;
        if (left == .Unknown or right == .Unknown) return .Unknown;
        return .True;
    }

    fn sqlOr(left: SqlTruth, right: SqlTruth) SqlTruth {
        if (left == .True or right == .True) return .True;
        if (left == .Unknown or right == .Unknown) return .Unknown;
        return .False;
    }

    fn boolTruth(value: bool) SqlTruth {
        return if (value) .True else .False;
    }

    fn evaluateConditionTruth(self: *Self, condition: *const ast.Condition, row: *const storage.Row) anyerror!SqlTruth {
        return switch (condition.*) {
            .Comparison => |*comp| try self.evaluateComparisonTruth(comp, row),
            .Logical => |*logical| {
                const left_result = try self.evaluateConditionTruth(logical.left, row);
                const right_result = try self.evaluateConditionTruth(logical.right, row);

                return switch (logical.operator) {
                    .And => sqlAnd(left_result, right_result),
                    .Or => sqlOr(left_result, right_result),
                };
            },
        };
    }

    /// Evaluate a comparison condition
    fn evaluateComparison(self: *Self, comp: *const ast.ComparisonCondition, row: *const storage.Row) !bool {
        return (try self.evaluateComparisonTruth(comp, row)) == .True;
    }

    fn evaluateComparisonTruth(self: *Self, comp: *const ast.ComparisonCondition, row: *const storage.Row) !SqlTruth {
        const left_value = try self.evaluateExpression(&comp.left, row);
        defer left_value.deinit(self.connection.allocator);

        // Handle IS NULL / IS NOT NULL (don't need to evaluate right side)
        if (comp.operator == .IsNull) {
            return boolTruth(left_value == .Null);
        }
        if (comp.operator == .IsNotNull) {
            return boolTruth(left_value != .Null);
        }

        // Handle IN / NOT IN with InList or Subquery
        if (comp.operator == .In or comp.operator == .NotIn) {
            const in_result = try self.evaluateInConditionTruth(left_value, &comp.right, row);
            return if (comp.operator == .In) in_result else in_result.not();
        }

        const right_value = try self.evaluateExpression(&comp.right, row);
        defer right_value.deinit(self.connection.allocator);

        // Handle BETWEEN / NOT BETWEEN
        if (comp.operator == .Between or comp.operator == .NotBetween) {
            if (comp.extra) |extra_expr| {
                const high_value = try self.evaluateExpression(&extra_expr, row);
                defer high_value.deinit(self.connection.allocator);

                if (left_value == .Null or right_value == .Null or high_value == .Null) return .Unknown;

                const cmp_low = self.compareValues(left_value, right_value);
                const cmp_high = self.compareValues(left_value, high_value);
                const in_range = (cmp_low == .gt or cmp_low == .eq) and (cmp_high == .lt or cmp_high == .eq);

                const result = boolTruth(in_range);
                return if (comp.operator == .Between) result else result.not();
            }
            return .False;
        }

        if (left_value == .Null or right_value == .Null) return .Unknown;

        return switch (comp.operator) {
            .Equal => boolTruth(self.compareValues(left_value, right_value) == .eq),
            .NotEqual => boolTruth(self.compareValues(left_value, right_value) != .eq),
            .LessThan => boolTruth(self.compareValues(left_value, right_value) == .lt),
            .LessThanOrEqual => {
                const cmp = self.compareValues(left_value, right_value);
                return boolTruth(cmp == .lt or cmp == .eq);
            },
            .GreaterThan => boolTruth(self.compareValues(left_value, right_value) == .gt),
            .GreaterThanOrEqual => {
                const cmp = self.compareValues(left_value, right_value);
                return boolTruth(cmp == .gt or cmp == .eq);
            },
            .Like => boolTruth(self.evaluateLike(left_value, right_value, false)),
            .NotLike => boolTruth(self.evaluateLike(left_value, right_value, true)),
            .Match => boolTruth(self.evaluateMatch(left_value, right_value)),
            .In, .NotIn => unreachable, // Already handled above
            .IsNull, .IsNotNull, .Between, .NotBetween => unreachable, // Already handled above
        };
    }

    /// Evaluate IN condition with InList or Subquery
    fn evaluateInCondition(self: *Self, left_value: storage.Value, right_expr: *const ast.Expression, row: *const storage.Row) anyerror!bool {
        return (try self.evaluateInConditionTruth(left_value, right_expr, row)) == .True;
    }

    fn evaluateInConditionTruth(self: *Self, left_value: storage.Value, right_expr: *const ast.Expression, row: *const storage.Row) anyerror!SqlTruth {
        if (left_value == .Null) return .Unknown;

        switch (right_expr.*) {
            .InList => |list| {
                // Check if left_value matches any value in the list
                var saw_null = false;
                for (list) |ast_val| {
                    const val = try self.convertAstValueToStorage(ast_val);
                    defer val.deinit(self.connection.allocator);
                    if (val == .Null) {
                        saw_null = true;
                        continue;
                    }
                    if (self.compareValues(left_value, val) == .eq) {
                        return .True;
                    }
                }
                return if (saw_null) .Unknown else .False;
            },
            .Subquery => |subquery| {
                // Execute subquery and check if left_value matches any result
                var result = try self.executeSubquery(subquery);
                defer result.deinit();

                var saw_null = false;
                for (result.rows.items) |subrow| {
                    if (subrow.values.len > 0) {
                        if (subrow.values[0] == .Null) {
                            saw_null = true;
                            continue;
                        }
                        if (self.compareValues(left_value, subrow.values[0]) == .eq) {
                            return .True;
                        }
                    }
                }
                return if (saw_null) .Unknown else .False;
            },
            else => {
                // Fall back to simple equality comparison
                const right_value = try self.evaluateExpression(right_expr, row);
                defer right_value.deinit(self.connection.allocator);
                if (right_value == .Null) return .Unknown;
                return boolTruth(self.compareValues(left_value, right_value) == .eq);
            },
        }
    }

    /// Execute a subquery and return the full result
    fn executeSubquery(self: *Self, subquery: *ast.SelectStatement) anyerror!ExecutionResult {
        // Create execution plan for subquery
        var query_planner = planner.Planner.initWithContext(
            self.connection.allocator,
            &self.connection.aggregate_function_names,
            self.connection.planner_table_stats.items,
            self.connection.planner_index_stats.items,
        );
        var cloned_stmt = try query_planner.cloneSelectStatement(subquery.*);
        defer @constCast(&cloned_stmt).deinit(self.connection.allocator);

        const stmt = ast.Statement{ .Select = cloned_stmt };
        var plan = try query_planner.plan(&stmt);
        defer plan.deinit();

        // Execute plan
        var subquery_result = ExecutionResult{
            .rows = .empty,
            .affected_rows = 0,
            .connection = self.connection,
        };

        for (plan.steps) |*step| {
            try self.executeStep(step, &subquery_result);
        }

        return subquery_result;
    }

    /// Execute a scalar subquery and return the first column of the first row
    fn executeScalarSubquery(self: *Self, subquery: *ast.SelectStatement) anyerror!storage.Value {
        var result = try self.executeSubquery(subquery);
        defer result.deinit();

        // Return first column of first row, or NULL if empty
        if (result.rows.items.len > 0 and result.rows.items[0].values.len > 0) {
            return try result.rows.items[0].values[0].clone(self.connection.allocator);
        }
        return storage.Value.Null;
    }

    /// Evaluate LIKE pattern matching with % and _ wildcards
    fn evaluateLike(self: *Self, value: storage.Value, pattern: storage.Value, negate: bool) bool {
        _ = self;
        const text = switch (value) {
            .Text => |t| t,
            else => return if (negate) true else false,
        };
        const pat = switch (pattern) {
            .Text => |p| p,
            else => return if (negate) true else false,
        };

        const matches = likeMatch(text, pat);
        return if (negate) !matches else matches;
    }

    /// Evaluate FTS MATCH operator for full-text search
    fn evaluateMatch(self: *Self, value: storage.Value, query: storage.Value) bool {
        const text = switch (value) {
            .Text => |t| t,
            else => return false,
        };
        const search_query = switch (query) {
            .Text => |q| q,
            else => return false,
        };

        var normalized_query = std.ArrayListUnmanaged(u8).empty;
        defer normalized_query.deinit(self.connection.allocator);
        normalizeMatchQuery(self.connection.allocator, search_query, &normalized_query) catch return false;

        return evaluateMatchExpression(text, normalized_query.items) catch false;
    }

    fn normalizeMatchQuery(allocator: std.mem.Allocator, query: []const u8, normalized: *std.ArrayListUnmanaged(u8)) !void {
        var i: usize = 0;
        var pending_space = false;
        while (i < query.len) {
            const c = query[i];
            if (std.ascii.isWhitespace(c)) {
                pending_space = normalized.items.len > 0;
                i += 1;
                continue;
            }

            if (c == '"') {
                if (pending_space and normalized.items.len > 0) {
                    try normalized.append(allocator, ' ');
                    pending_space = false;
                }
                try normalized.append(allocator, '"');
                i += 1;
                while (i < query.len and query[i] != '"') : (i += 1) {
                    try normalized.append(allocator, std.ascii.toLower(query[i]));
                }
                if (i < query.len and query[i] == '"') {
                    try normalized.append(allocator, '"');
                    i += 1;
                }
                continue;
            }

            var token_end = i;
            while (token_end < query.len and !std.ascii.isWhitespace(query[token_end])) : (token_end += 1) {}
            const token = query[i..token_end];
            if (pending_space and normalized.items.len > 0) {
                try normalized.append(allocator, ' ');
            }
            pending_space = false;

            if (std.ascii.eqlIgnoreCase(token, "and")) {
                try normalized.appendSlice(allocator, "AND");
            } else if (std.ascii.eqlIgnoreCase(token, "or")) {
                try normalized.appendSlice(allocator, "OR");
            } else if (std.ascii.eqlIgnoreCase(token, "not")) {
                try normalized.appendSlice(allocator, "NOT");
            } else {
                for (token) |ch| {
                    try normalized.append(allocator, std.ascii.toLower(ch));
                }
            }
            i = token_end;
        }
    }

    fn evaluateMatchExpression(text: []const u8, query: []const u8) !bool {
        var tokens = std.ArrayListUnmanaged([]const u8).empty;
        defer tokens.deinit(std.heap.page_allocator);
        try tokenizeMatchExpression(std.heap.page_allocator, query, &tokens);
        if (tokens.items.len == 0) return true;

        var parser = MatchExpressionParser{ .tokens = tokens.items, .index = 0 };
        return parser.parseExpression(text);
    }

    fn tokenizeMatchExpression(allocator: std.mem.Allocator, query: []const u8, tokens: *std.ArrayListUnmanaged([]const u8)) !void {
        var i: usize = 0;
        while (i < query.len) {
            if (std.ascii.isWhitespace(query[i])) {
                i += 1;
                continue;
            }
            if (query[i] == '"') {
                const start = i;
                i += 1;
                while (i < query.len and query[i] != '"') : (i += 1) {}
                if (i < query.len) i += 1;
                try tokens.append(allocator, query[start..i]);
                continue;
            }
            const start = i;
            while (i < query.len and !std.ascii.isWhitespace(query[i])) : (i += 1) {}
            try tokens.append(allocator, query[start..i]);
        }
    }

    const MatchExpressionParser = struct {
        tokens: []const []const u8,
        index: usize,

        fn parseExpression(self: *MatchExpressionParser, text: []const u8) bool {
            var value = self.parseTerm(text);
            while (self.peek()) |token| {
                if (!std.mem.eql(u8, token, "OR")) break;
                self.index += 1;
                const rhs = self.parseTerm(text);
                value = value or rhs;
            }
            return value;
        }

        fn parseTerm(self: *MatchExpressionParser, text: []const u8) bool {
            var value = self.parseFactor(text);
            while (self.peek()) |token| {
                if (std.mem.eql(u8, token, "OR")) break;
                if (std.mem.eql(u8, token, "AND")) {
                    self.index += 1;
                }
                const rhs = self.parseFactor(text);
                value = value and rhs;
            }
            return value;
        }

        fn parseFactor(self: *MatchExpressionParser, text: []const u8) bool {
            if (self.peek()) |token| {
                if (std.mem.eql(u8, token, "NOT")) {
                    self.index += 1;
                    return !self.parseFactor(text);
                }
                self.index += 1;
                return matchToken(text, token);
            }
            return true;
        }

        fn peek(self: *MatchExpressionParser) ?[]const u8 {
            if (self.index >= self.tokens.len) return null;
            return self.tokens[self.index];
        }
    };

    fn matchToken(text: []const u8, token: []const u8) bool {
        if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
            const phrase = token[1 .. token.len - 1];
            return containsCaseInsensitive(text, phrase);
        }

        var text_iter = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?()[]{}\"'");
        while (text_iter.next()) |word| {
            if (std.ascii.eqlIgnoreCase(word, token)) {
                return true;
            }
        }
        return false;
    }

    fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;

        var start: usize = 0;
        while (start + needle.len <= haystack.len) : (start += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) {
                return true;
            }
        }
        return false;
    }

    /// Evaluate CASE WHEN ... THEN ... ELSE ... END expression
    fn evaluateCaseExpression(self: *Self, case_expr: *const ast.CaseExpression, row: *const storage.Row) anyerror!storage.Value {
        // Evaluate each WHEN branch
        for (case_expr.branches) |branch| {
            const condition_result = try self.evaluateCondition(branch.condition, row);
            if (condition_result) {
                // Return the result value for this branch
                return try self.evaluateAstValue(&branch.result, row);
            }
        }

        // No branch matched - return ELSE value or NULL
        if (case_expr.else_result) |else_val| {
            return try self.evaluateAstValue(else_val, row);
        }
        return storage.Value.Null;
    }

    /// Evaluate an AST Value to a storage Value
    fn evaluateAstValue(self: *Self, value: *const ast.Value, row: *const storage.Row) anyerror!storage.Value {
        return switch (value.*) {
            .Integer => |i| storage.Value{ .Integer = i },
            .Text => |t| storage.Value{ .Text = try self.connection.allocator.dupe(u8, t) },
            .Real => |r| storage.Value{ .Real = r },
            .Blob => |b| storage.Value{ .Blob = try self.connection.allocator.dupe(u8, b) },
            .Null => storage.Value.Null,
            .Parameter => |param_index| {
                if (self.parameters) |params| {
                    if (param_index < params.len) {
                        return try self.resolveValue(params[param_index]);
                    }
                }
                return storage.Value.Null;
            },
            .FunctionCall => |function_call| {
                return try self.function_evaluator.evaluateFunction(function_call);
            },
            .Case => |case_expr| {
                return try self.evaluateCaseExpression(&case_expr, row);
            },
        };
    }

    /// Evaluate a function call with row context (resolves column references)
    fn evaluateFunctionWithRow(self: *Self, func_call: ast.FunctionCall, row: *const storage.Row) anyerror!storage.Value {
        const func_name = func_call.name;

        // Convert function name to lowercase for case-insensitive comparison
        const lower_name = try std.ascii.allocLowerString(self.connection.allocator, func_name);
        defer self.connection.allocator.free(lower_name);

        if (std.mem.eql(u8, lower_name, "coalesce")) {
            return self.evalCoalesceWithRow(func_call.arguments, row);
        } else if (std.mem.eql(u8, lower_name, "nullif")) {
            return self.evalNullifWithRow(func_call.arguments, row);
        } else if (std.mem.eql(u8, lower_name, "ifnull")) {
            return self.evalIfnullWithRow(func_call.arguments, row);
        } else if (std.mem.eql(u8, lower_name, "upper")) {
            return self.evalUpperWithRow(func_call.arguments, row);
        } else if (std.mem.eql(u8, lower_name, "lower")) {
            return self.evalLowerWithRow(func_call.arguments, row);
        } else if (std.mem.eql(u8, lower_name, "substr") or std.mem.eql(u8, lower_name, "substring")) {
            return self.evalSubstrWithRow(func_call.arguments, row);
        } else if (std.mem.eql(u8, lower_name, "length")) {
            return self.evalLengthWithRow(func_call.arguments, row);
        } else if (std.mem.eql(u8, lower_name, "trim")) {
            return self.evalTrimWithRow(func_call.arguments, row);
        } else {
            if (try self.evalJsonFunctionWithRow(lower_name, func_call.arguments, row)) |value| {
                return value;
            }
            if (try self.evalScalarFunctionWithRow(func_call.name, func_call.arguments, row)) |value| {
                return value;
            }
            // For other functions, use the regular function evaluator
            return try self.function_evaluator.evaluateFunction(func_call);
        }
    }

    fn evalScalarFunctionWithRow(self: *Self, name: []const u8, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!?storage.Value {
        const callback = self.connection.getScalarFunction(name) orelse return null;

        var values = try self.connection.allocator.alloc(storage.Value, arguments.len);
        var resolved: usize = 0;
        errdefer {
            for (values[0..resolved]) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(values);
        }

        for (arguments, 0..) |argument, i| {
            values[i] = try self.resolveArgumentWithRow(argument, row);
            resolved = i + 1;
        }
        defer {
            for (values) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(values);
        }

        return try callback(self.connection.allocator, values);
    }

    fn evalJsonFunctionWithRow(self: *Self, lower_name: []const u8, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!?storage.Value {
        var values = try self.connection.allocator.alloc(storage.Value, arguments.len);
        var resolved: usize = 0;
        errdefer {
            for (values[0..resolved]) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(values);
        }

        for (arguments, 0..) |argument, i| {
            values[i] = try self.resolveArgumentWithRow(argument, row);
            resolved = i + 1;
        }
        defer {
            for (values) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(values);
        }

        return try self.function_evaluator.evaluateJsonFunctionWithValues(lower_name, values);
    }

    /// COALESCE with row context
    fn evalCoalesceWithRow(self: *Self, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!storage.Value {
        if (arguments.len == 0) {
            return error.InvalidArgumentCount;
        }

        for (arguments) |arg| {
            const value = try self.resolveArgumentWithRow(arg, row);
            switch (value) {
                .Null => {
                    value.deinit(self.connection.allocator);
                    continue;
                },
                else => return value,
            }
        }

        return storage.Value.Null;
    }

    /// NULLIF with row context
    fn evalNullifWithRow(self: *Self, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!storage.Value {
        if (arguments.len != 2) {
            return error.InvalidArgumentCount;
        }

        const a = try self.resolveArgumentWithRow(arguments[0], row);
        const b = try self.resolveArgumentWithRow(arguments[1], row);
        defer b.deinit(self.connection.allocator);

        // Compare values
        const are_equal = self.valuesEqual(a, b);

        if (are_equal) {
            a.deinit(self.connection.allocator);
            return storage.Value.Null;
        } else {
            return a;
        }
    }

    /// IFNULL with row context
    fn evalIfnullWithRow(self: *Self, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!storage.Value {
        if (arguments.len != 2) {
            return error.InvalidArgumentCount;
        }

        const a = try self.resolveArgumentWithRow(arguments[0], row);

        switch (a) {
            .Null => {
                return try self.resolveArgumentWithRow(arguments[1], row);
            },
            else => return a,
        }
    }

    /// Resolve a function argument to a storage value with row context
    fn resolveArgumentWithRow(self: *Self, arg: ast.FunctionArgument, row: *const storage.Row) anyerror!storage.Value {
        return switch (arg) {
            .Literal => |value| {
                return switch (value) {
                    .Integer => |i| storage.Value{ .Integer = i },
                    .Real => |r| storage.Value{ .Real = r },
                    .Text => |t| storage.Value{ .Text = try self.connection.allocator.dupe(u8, t) },
                    .Blob => |b| storage.Value{ .Blob = try self.connection.allocator.dupe(u8, b) },
                    .Null => storage.Value.Null,
                    .Parameter => |param_index| {
                        if (self.parameters) |params| {
                            if (param_index < params.len) {
                                return try self.resolveValue(params[param_index]);
                            }
                        }
                        return storage.Value.Null;
                    },
                    .FunctionCall => |func| try self.evaluateFunctionWithRow(func, row),
                    .Case => |case_expr| try self.evaluateCaseExpression(&case_expr, row),
                };
            },
            .String => |s| storage.Value{ .Text = try self.connection.allocator.dupe(u8, s) },
            .Column => |col_name| {
                // Look up column by name in current row using table schema
                if (self.current_table) |table| {
                    for (table.schema.columns, 0..) |col, idx| {
                        if (std.mem.eql(u8, col.name, col_name)) {
                            if (idx < row.values.len) {
                                return try self.cloneValue(row.values[idx]);
                            } else {
                                return storage.Value.Null;
                            }
                        }
                    }
                }
                return storage.Value.Null;
            },
            else => storage.Value.Null,
        };
    }

    /// Compare two storage values for equality
    fn valuesEqual(self: *Self, a: storage.Value, b: storage.Value) bool {
        _ = self;
        // If types don't match, they're not equal
        if (@as(std.meta.Tag(storage.Value), a) != @as(std.meta.Tag(storage.Value), b)) {
            return false;
        }

        return switch (a) {
            .Integer => |i| i == b.Integer,
            .Real => |r| r == b.Real,
            .Text => |t| std.mem.eql(u8, t, b.Text),
            .Blob => |bl| std.mem.eql(u8, bl, b.Blob),
            .Null => true, // NULL = NULL is true for NULLIF
            else => false,
        };
    }

    /// UPPER with row context
    fn evalUpperWithRow(self: *Self, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!storage.Value {
        if (arguments.len != 1) {
            return error.InvalidArgumentCount;
        }

        const value = try self.resolveArgumentWithRow(arguments[0], row);
        defer value.deinit(self.connection.allocator);

        switch (value) {
            .Text => |text| {
                const upper = try std.ascii.allocUpperString(self.connection.allocator, text);
                return storage.Value{ .Text = upper };
            },
            .Null => return storage.Value.Null,
            else => return error.InvalidArgumentType,
        }
    }

    /// LOWER with row context
    fn evalLowerWithRow(self: *Self, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!storage.Value {
        if (arguments.len != 1) {
            return error.InvalidArgumentCount;
        }

        const value = try self.resolveArgumentWithRow(arguments[0], row);
        defer value.deinit(self.connection.allocator);

        switch (value) {
            .Text => |text| {
                const lower = try std.ascii.allocLowerString(self.connection.allocator, text);
                return storage.Value{ .Text = lower };
            },
            .Null => return storage.Value.Null,
            else => return error.InvalidArgumentType,
        }
    }

    /// SUBSTR(str, start, length) or SUBSTR(str, start) with row context
    fn evalSubstrWithRow(self: *Self, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!storage.Value {
        if (arguments.len < 2 or arguments.len > 3) {
            return error.InvalidArgumentCount;
        }

        const str_value = try self.resolveArgumentWithRow(arguments[0], row);
        defer str_value.deinit(self.connection.allocator);

        switch (str_value) {
            .Text => |text| {
                const start_value = try self.resolveArgumentWithRow(arguments[1], row);
                defer start_value.deinit(self.connection.allocator);

                const start: usize = switch (start_value) {
                    .Integer => |i| if (i < 1) 0 else @as(usize, @intCast(i - 1)), // SQL is 1-indexed
                    else => return error.InvalidArgumentType,
                };

                var length: usize = text.len;
                if (arguments.len == 3) {
                    const len_value = try self.resolveArgumentWithRow(arguments[2], row);
                    defer len_value.deinit(self.connection.allocator);
                    length = switch (len_value) {
                        .Integer => |i| if (i < 0) 0 else @as(usize, @intCast(i)),
                        else => return error.InvalidArgumentType,
                    };
                }

                if (start >= text.len) {
                    return storage.Value{ .Text = try self.connection.allocator.dupe(u8, "") };
                }

                const end = @min(start + length, text.len);
                return storage.Value{ .Text = try self.connection.allocator.dupe(u8, text[start..end]) };
            },
            .Null => return storage.Value.Null,
            else => return error.InvalidArgumentType,
        }
    }

    /// LENGTH with row context
    fn evalLengthWithRow(self: *Self, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!storage.Value {
        if (arguments.len != 1) {
            return error.InvalidArgumentCount;
        }

        const value = try self.resolveArgumentWithRow(arguments[0], row);
        defer value.deinit(self.connection.allocator);

        switch (value) {
            .Text => |text| {
                return storage.Value{ .Integer = @as(i64, @intCast(text.len)) };
            },
            .Blob => |blob| {
                return storage.Value{ .Integer = @as(i64, @intCast(blob.len)) };
            },
            .Null => return storage.Value.Null,
            else => return error.InvalidArgumentType,
        }
    }

    /// TRIM with row context (removes leading and trailing spaces)
    fn evalTrimWithRow(self: *Self, arguments: []ast.FunctionArgument, row: *const storage.Row) anyerror!storage.Value {
        if (arguments.len != 1) {
            return error.InvalidArgumentCount;
        }

        const value = try self.resolveArgumentWithRow(arguments[0], row);
        defer value.deinit(self.connection.allocator);

        switch (value) {
            .Text => |text| {
                const trimmed = std.mem.trim(u8, text, " \t\n\r");
                return storage.Value{ .Text = try self.connection.allocator.dupe(u8, trimmed) };
            },
            .Null => return storage.Value.Null,
            else => return error.InvalidArgumentType,
        }
    }

    /// Evaluate an expression against a row
    /// Evaluate the right-hand side of an ON CONFLICT DO UPDATE assignment.
    /// A bare `excluded.<column>` reference resolves to the would-be-inserted
    /// row's value (excluded_values); anything else evaluates against the
    /// existing row as a normal UPDATE expression.
    fn evaluateUpsertAssignment(
        self: *Self,
        expression: *const ast.Expression,
        existing_row: *const storage.Row,
        table: *const storage.Table,
        excluded_values: []const storage.Value,
    ) !storage.Value {
        if (expression.* == .Column) {
            const col_name = expression.Column;
            const prefix = "excluded.";
            if (std.mem.startsWith(u8, col_name, prefix)) {
                const target = col_name[prefix.len..];
                for (table.schema.columns, 0..) |col, idx| {
                    if (std.mem.eql(u8, col.name, target)) {
                        if (idx < excluded_values.len) {
                            return try self.cloneValue(excluded_values[idx]);
                        }
                        return storage.Value.Null;
                    }
                }
                return storage.Value.Null;
            }
        }
        return try self.evaluateExpression(expression, existing_row);
    }

    fn evaluateExpression(self: *Self, expression: *const ast.Expression, row: *const storage.Row) !storage.Value {
        return switch (expression.*) {
            .Column => |col_name| {
                // Check if this is a qualified name (alias.column or table.column)
                if (std.mem.indexOf(u8, col_name, ".")) |dot_idx| {
                    const alias = col_name[0..dot_idx];
                    const column = col_name[dot_idx + 1 ..];

                    // Look up the table by alias
                    if (self.alias_to_table.get(alias)) |table| {
                        // Get the column offset for this alias (for joined rows)
                        const col_offset = self.alias_column_offset.get(alias) orelse 0;

                        for (table.schema.columns, 0..) |col, idx| {
                            if (std.mem.eql(u8, col.name, column)) {
                                const actual_idx = col_offset + idx;
                                if (actual_idx < row.values.len) {
                                    return try self.cloneValue(row.values[actual_idx]);
                                } else {
                                    return storage.Value.Null;
                                }
                            }
                        }
                    }
                    // Alias not found - fall through to simple column lookup
                }

                // Look up column by name using current table schema
                if (self.current_table) |table| {
                    for (table.schema.columns, 0..) |col, idx| {
                        if (std.mem.eql(u8, col.name, col_name)) {
                            if (idx < row.values.len) {
                                return try self.cloneValue(row.values[idx]);
                            } else {
                                return storage.Value.Null;
                            }
                        }
                    }
                }
                if (self.current_column_names) |columns| {
                    for (columns, 0..) |column, idx| {
                        if (std.mem.eql(u8, column, col_name)) {
                            if (idx < row.values.len) {
                                return try self.cloneValue(row.values[idx]);
                            } else {
                                return storage.Value.Null;
                            }
                        }
                    }
                }
                // Fallback: if no table or column not found, return Null
                return storage.Value.Null;
            },
            .Literal => |value| {
                return switch (value) {
                    .Integer => |i| storage.Value{ .Integer = i },
                    .Text => |t| storage.Value{ .Text = try self.connection.allocator.dupe(u8, t) },
                    .Real => |r| storage.Value{ .Real = r },
                    .Blob => |b| storage.Value{ .Blob = try self.connection.allocator.dupe(u8, b) },
                    .Null => storage.Value.Null,
                    .Parameter => |param_index| {
                        if (self.parameters) |params| {
                            if (param_index < params.len) {
                                return try self.resolveValue(params[param_index]);
                            } else {
                                return error.ParameterIndexOutOfBounds;
                            }
                        } else {
                            return error.NoParametersProvided;
                        }
                    },
                    .FunctionCall => |function_call| {
                        // Evaluate function call immediately
                        return try self.function_evaluator.evaluateFunction(function_call);
                    },
                    .Case => |case_expr| {
                        // Evaluate CASE expression
                        return try self.evaluateCaseExpression(&case_expr, row);
                    },
                };
            },
            .Parameter => |param_index| {
                if (self.parameters) |params| {
                    if (param_index < params.len) {
                        return try self.resolveValue(params[param_index]);
                    } else {
                        return error.ParameterIndexOutOfBounds;
                    }
                } else {
                    return error.NoParametersProvided;
                }
            },
            .BinaryOp => |bin| {
                const left_val = try self.evaluateExpression(bin.left, row);
                defer left_val.deinit(self.connection.allocator);
                const right_val = try self.evaluateExpression(bin.right, row);
                defer right_val.deinit(self.connection.allocator);
                return self.performArithmetic(left_val, bin.op, right_val);
            },
            .Subquery => |subquery| {
                // Execute scalar subquery and return first column of first row
                return try self.executeScalarSubquery(subquery);
            },
            .InList => {
                // InList is handled in comparison context, not as standalone value
                return storage.Value.Null;
            },
        };
    }

    /// Compare two values
    fn compareValues(self: *Self, left: storage.Value, right: storage.Value) std.math.Order {
        _ = self; // Not needed for value comparison

        return switch (left) {
            .Integer => |l| switch (right) {
                .Integer => |r| std.math.order(l, r),
                .Real => |r| std.math.order(@as(f64, @floatFromInt(l)), r),
                else => .gt, // Non-null values are greater than null
            },
            .Real => |l| switch (right) {
                .Integer => |r| std.math.order(l, @as(f64, @floatFromInt(r))),
                .Real => |r| std.math.order(l, r),
                else => .gt,
            },
            .Text => |l| switch (right) {
                .Text => |r| std.mem.order(u8, l, r),
                else => .gt,
            },
            .Blob => |l| switch (right) {
                .Blob => |r| std.mem.order(u8, l, r),
                else => .gt,
            },
            .Null => switch (right) {
                .Null => .eq,
                else => .lt,
            },
            .Parameter => .gt, // Parameters should have been resolved before comparison
            .FunctionCall => .gt, // Function calls should have been resolved before comparison
            // PostgreSQL compatibility values
            .JSON => |l| switch (right) {
                .JSON => |r| std.mem.order(u8, l, r),
                else => .gt,
            },
            .JSONB => .gt, // Complex comparison - simplified
            .UUID => |l| switch (right) {
                .UUID => |r| std.mem.order(u8, &l, &r),
                else => .gt,
            },
            .Array => .gt, // Complex comparison - simplified
            .Boolean => |l| switch (right) {
                .Boolean => |r| if (l == r) .eq else if (l) .gt else .lt,
                else => .gt,
            },
            .Timestamp => |l| switch (right) {
                .Timestamp => |r| std.math.order(l, r),
                else => .gt,
            },
            .TimestampTZ => |l| switch (right) {
                .TimestampTZ => |r| std.math.order(l.timestamp, r.timestamp),
                else => .gt,
            },
            .Date => |l| switch (right) {
                .Date => |r| std.math.order(l, r),
                else => .gt,
            },
            .Time => |l| switch (right) {
                .Time => |r| std.math.order(l, r),
                else => .gt,
            },
            .Interval => |l| switch (right) {
                .Interval => |r| std.math.order(l, r),
                else => .gt,
            },
            .Numeric => .gt, // Complex comparison - simplified
            .SmallInt => |l| switch (right) {
                .SmallInt => |r| std.math.order(l, r),
                .Integer => |r| std.math.order(@as(i32, l), r),
                else => .gt,
            },
            .BigInt => |l| switch (right) {
                .BigInt => |r| std.math.order(l, r),
                .Integer => |r| std.math.order(@as(i64, r), l),
                else => .gt,
            },
        };
    }

    /// Execute nested loop join (simple but works for all join types)
    fn executeNestedLoopJoin(self: *Self, join: *planner.NestedLoopJoinStep, result: *ExecutionResult) !void {
        // Clear any existing rows from previous steps (join reads directly from tables)
        for (result.rows.items) |row| {
            for (row.values) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(row.values);
        }
        result.rows.clearRetainingCapacity();

        // Parse table names with aliases (e.g., "customers c" -> "customers", "c")
        const left_parsed = try self.parseTableNameWithAlias(join.left_table);
        defer self.connection.allocator.free(left_parsed.name);
        defer if (left_parsed.alias) |a| self.connection.allocator.free(a);

        const right_parsed = try self.parseTableNameWithAlias(join.right_table);
        defer self.connection.allocator.free(right_parsed.name);
        defer if (right_parsed.alias) |a| self.connection.allocator.free(a);

        // Get tables using parsed names
        const left_table = self.connection.storage_engine.getTable(left_parsed.name) orelse {
            return error.TableNotFound;
        };
        const right_table = self.connection.storage_engine.getTable(right_parsed.name) orelse {
            return error.TableNotFound;
        };

        // Register aliases for column resolution
        if (left_parsed.alias) |alias| {
            try self.registerTableAlias(alias, left_table);
            try self.registerColumnOffset(alias, 0);
        }
        // Also register by table name
        try self.registerTableAlias(left_parsed.name, left_table);
        try self.registerColumnOffset(left_parsed.name, 0);

        // Right table offset starts after all left table columns
        const right_offset = left_table.schema.columns.len;

        if (right_parsed.alias) |alias| {
            try self.registerTableAlias(alias, right_table);
            try self.registerColumnOffset(alias, right_offset);
        }
        // Also register by table name
        try self.registerTableAlias(right_parsed.name, right_table);
        try self.registerColumnOffset(right_parsed.name, right_offset);

        // Get all rows from both tables
        const left_rows = try left_table.select(self.connection.allocator);
        defer {
            for (left_rows) |row| {
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }
            self.connection.allocator.free(left_rows);
        }

        const right_rows = try right_table.select(self.connection.allocator);
        defer {
            for (right_rows) |row| {
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }
            self.connection.allocator.free(right_rows);
        }

        // Perform join logic based on join type
        for (left_rows) |left_row| {
            try self.connection.recordRowsScanned(1);
            var matched = false;

            for (right_rows) |right_row| {
                try self.connection.recordRowsScanned(1);
                // Create combined row for condition evaluation
                const combined_row = try self.combineRows(&left_row, &right_row);
                defer {
                    for (combined_row.values) |value| {
                        value.deinit(self.connection.allocator);
                    }
                    self.connection.allocator.free(combined_row.values);
                }

                // Check join condition
                if (try self.evaluateCondition(&join.condition, &combined_row)) {
                    matched = true;
                    // Add the combined row to results
                    const final_row = try self.combineRows(&left_row, &right_row);
                    try result.rows.append(self.connection.allocator, final_row);
                    try self.connection.recordResultRows(result.rows.items.len);
                }
            }

            // Handle LEFT JOIN case where no match found
            if (!matched and join.join_type == .Left) {
                const null_right_row = try self.createNullRow(right_rows[0].values.len);
                defer {
                    for (null_right_row.values) |value| {
                        value.deinit(self.connection.allocator);
                    }
                    self.connection.allocator.free(null_right_row.values);
                }

                const final_row = try self.combineRows(&left_row, &null_right_row);
                try result.rows.append(self.connection.allocator, final_row);
                try self.connection.recordResultRows(result.rows.items.len);
            }
        }

        // Handle RIGHT JOIN - iterate from right side
        if (join.join_type == .Right or join.join_type == .Full) {
            for (right_rows) |right_row| {
                try self.connection.recordRowsScanned(1);
                var matched = false;

                for (left_rows) |left_row| {
                    try self.connection.recordRowsScanned(1);
                    const combined_row = try self.combineRows(&left_row, &right_row);
                    defer {
                        for (combined_row.values) |value| {
                            value.deinit(self.connection.allocator);
                        }
                        self.connection.allocator.free(combined_row.values);
                    }

                    if (try self.evaluateCondition(&join.condition, &combined_row)) {
                        matched = true;
                        break; // We already added this in the LEFT side iteration for FULL
                    }
                }

                // Add unmatched RIGHT rows for RIGHT and FULL joins
                if (!matched and (join.join_type == .Right or join.join_type == .Full)) {
                    const null_left_row = try self.createNullRow(left_rows[0].values.len);
                    defer {
                        for (null_left_row.values) |value| {
                            value.deinit(self.connection.allocator);
                        }
                        self.connection.allocator.free(null_left_row.values);
                    }

                    const final_row = try self.combineRows(&null_left_row, &right_row);
                    try result.rows.append(self.connection.allocator, final_row);
                    try self.connection.recordResultRows(result.rows.items.len);
                }
            }
        }
    }

    /// Execute hash join (optimized for equi-joins)
    fn executeHashJoin(self: *Self, join: *planner.HashJoinStep, result: *ExecutionResult) !void {
        // Clear any existing rows from previous steps (join reads directly from tables)
        for (result.rows.items) |row| {
            for (row.values) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(row.values);
        }
        result.rows.clearRetainingCapacity();

        // Parse table names with aliases (e.g., "customers c" -> "customers", "c")
        const left_parsed = try self.parseTableNameWithAlias(join.left_table);
        defer self.connection.allocator.free(left_parsed.name);
        defer if (left_parsed.alias) |a| self.connection.allocator.free(a);

        const right_parsed = try self.parseTableNameWithAlias(join.right_table);
        defer self.connection.allocator.free(right_parsed.name);
        defer if (right_parsed.alias) |a| self.connection.allocator.free(a);

        // Get tables using parsed names
        const left_table = self.connection.storage_engine.getTable(left_parsed.name) orelse {
            return error.TableNotFound;
        };
        const right_table = self.connection.storage_engine.getTable(right_parsed.name) orelse {
            return error.TableNotFound;
        };

        // Register aliases for column resolution
        if (left_parsed.alias) |alias| {
            try self.registerTableAlias(alias, left_table);
            try self.registerColumnOffset(alias, 0);
        }
        try self.registerTableAlias(left_parsed.name, left_table);
        try self.registerColumnOffset(left_parsed.name, 0);

        // Right table offset starts after all left table columns
        const right_offset = left_table.schema.columns.len;

        if (right_parsed.alias) |alias| {
            try self.registerTableAlias(alias, right_table);
            try self.registerColumnOffset(alias, right_offset);
        }
        try self.registerTableAlias(right_parsed.name, right_table);
        try self.registerColumnOffset(right_parsed.name, right_offset);

        // Get all rows from both tables
        const left_rows = try left_table.select(self.connection.allocator);
        defer {
            for (left_rows) |row| {
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }
            self.connection.allocator.free(left_rows);
        }

        const right_rows = try right_table.select(self.connection.allocator);
        defer {
            for (right_rows) |row| {
                for (row.values) |value| {
                    value.deinit(self.connection.allocator);
                }
                self.connection.allocator.free(row.values);
            }
            self.connection.allocator.free(right_rows);
        }

        // Get column indices for join keys
        const left_key_idx = left_table.getColumnIndex(join.left_key_column) orelse {
            // Fall back to nested loop if column not found
            var nested_join = planner.NestedLoopJoinStep{
                .join_type = join.join_type,
                .left_table = join.left_table,
                .right_table = join.right_table,
                .condition = join.condition,
            };
            return self.executeNestedLoopJoin(&nested_join, result);
        };

        const right_key_idx = right_table.getColumnIndex(join.right_key_column) orelse {
            // Fall back to nested loop if column not found
            var nested_join = planner.NestedLoopJoinStep{
                .join_type = join.join_type,
                .left_table = join.left_table,
                .right_table = join.right_table,
                .condition = join.condition,
            };
            return self.executeNestedLoopJoin(&nested_join, result);
        };

        // Build hash table from right table (the "build" side)
        // Key: hash of join key value, Value: list of row indices with that key
        var hash_map = std.AutoHashMap(u64, std.ArrayList(usize)).init(self.connection.allocator);
        defer {
            var iterator = hash_map.valueIterator();
            while (iterator.next()) |list| {
                list.deinit(self.connection.allocator);
            }
            hash_map.deinit();
        }

        // Build phase: hash the right table's join key values
        for (right_rows, 0..) |row, row_idx| {
            if (right_key_idx < row.values.len) {
                const key_value = row.values[right_key_idx];
                const hash = hashValue(key_value);

                const entry = try hash_map.getOrPut(hash);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .empty;
                }
                try entry.value_ptr.append(self.connection.allocator, row_idx);
            }
        }

        // Probe phase: for each left row, look up matching right rows
        for (left_rows) |left_row| {
            if (left_key_idx >= left_row.values.len) continue;

            const left_key_value = left_row.values[left_key_idx];
            const hash = hashValue(left_key_value);

            var matched = false;

            if (hash_map.get(hash)) |matching_indices| {
                for (matching_indices.items) |right_idx| {
                    const right_row = right_rows[right_idx];

                    // Verify the actual values match (not just hash)
                    if (right_key_idx < right_row.values.len) {
                        const right_key_value = right_row.values[right_key_idx];
                        if (hashValuesEqual(left_key_value, right_key_value)) {
                            // Found a match - combine rows
                            const combined = try self.combineRows(&left_row, &right_row);
                            try result.rows.append(self.connection.allocator, combined);
                            matched = true;
                        }
                    }
                }
            }

            // Handle LEFT JOIN - include left row even if no match
            if (!matched and join.join_type == .Left) {
                const right_null_count = if (right_rows.len > 0) right_rows[0].values.len else 0;
                const combined = try self.combineRowWithNulls(&left_row, right_null_count);
                try result.rows.append(self.connection.allocator, combined);
            }
        }

        // Handle RIGHT JOIN - include unmatched right rows
        if (join.join_type == .Right or join.join_type == .Full) {
            var matched_right = try self.connection.allocator.alloc(bool, right_rows.len);
            defer self.connection.allocator.free(matched_right);
            @memset(matched_right, false);

            // Re-probe to find matched right rows
            for (left_rows) |left_row| {
                if (left_key_idx >= left_row.values.len) continue;
                const left_key_value = left_row.values[left_key_idx];
                const hash = hashValue(left_key_value);

                if (hash_map.get(hash)) |matching_indices| {
                    for (matching_indices.items) |right_idx| {
                        const right_row = right_rows[right_idx];
                        if (right_key_idx < right_row.values.len) {
                            const right_key_value = right_row.values[right_key_idx];
                            if (hashValuesEqual(left_key_value, right_key_value)) {
                                matched_right[right_idx] = true;
                            }
                        }
                    }
                }
            }

            // Add unmatched right rows with NULL left columns
            const left_null_count = if (left_rows.len > 0) left_rows[0].values.len else 0;
            for (right_rows, 0..) |right_row, idx| {
                if (!matched_right[idx]) {
                    const combined = try self.combineNullsWithRow(left_null_count, &right_row);
                    try result.rows.append(self.connection.allocator, combined);
                }
            }
        }
    }

    /// Hash a storage value for hash join
    fn hashValue(value: storage.Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        switch (value) {
            .Integer => |i| hasher.update(std.mem.asBytes(&i)),
            .Real => |r| hasher.update(std.mem.asBytes(&r)),
            .Text => |t| hasher.update(t),
            .Blob => |b| hasher.update(b),
            .Null => hasher.update(&[_]u8{0}),
            .Boolean => |b| hasher.update(&[_]u8{if (b) 1 else 0}),
            else => hasher.update(&[_]u8{0}),
        }
        return hasher.final();
    }

    /// Check if two values are equal (for hash join verification)
    fn hashValuesEqual(a: storage.Value, b: storage.Value) bool {
        return switch (a) {
            .Integer => |ia| switch (b) {
                .Integer => |ib| ia == ib,
                else => false,
            },
            .Real => |ra| switch (b) {
                .Real => |rb| ra == rb,
                else => false,
            },
            .Text => |ta| switch (b) {
                .Text => |tb| std.mem.eql(u8, ta, tb),
                else => false,
            },
            .Blob => |ba| switch (b) {
                .Blob => |bb| std.mem.eql(u8, ba, bb),
                else => false,
            },
            .Null => switch (b) {
                .Null => true,
                else => false,
            },
            .Boolean => |ba| switch (b) {
                .Boolean => |bb| ba == bb,
                else => false,
            },
            else => false,
        };
    }

    /// Combine a row with NULL values (for LEFT JOIN)
    fn combineRowWithNulls(self: *Self, left: *const storage.Row, right_null_count: usize) !storage.Row {
        const total_cols = left.values.len + right_null_count;
        var combined_values = try self.connection.allocator.alloc(storage.Value, total_cols);

        for (left.values, 0..) |value, i| {
            combined_values[i] = try value.clone(self.connection.allocator);
        }

        for (left.values.len..total_cols) |i| {
            combined_values[i] = storage.Value.Null;
        }

        return storage.Row{ .values = combined_values };
    }

    /// Combine NULL values with a row (for RIGHT JOIN)
    fn combineNullsWithRow(self: *Self, left_null_count: usize, right: *const storage.Row) !storage.Row {
        const total_cols = left_null_count + right.values.len;
        var combined_values = try self.connection.allocator.alloc(storage.Value, total_cols);

        for (0..left_null_count) |i| {
            combined_values[i] = storage.Value.Null;
        }

        for (right.values, 0..) |value, i| {
            combined_values[left_null_count + i] = try value.clone(self.connection.allocator);
        }

        return storage.Row{ .values = combined_values };
    }

    /// Combine two rows into a single row
    fn combineRows(self: *Self, left_row: *const storage.Row, right_row: *const storage.Row) !storage.Row {
        const total_columns = left_row.values.len + right_row.values.len;
        var combined_values = try self.connection.allocator.alloc(storage.Value, total_columns);
        var values_cloned: usize = 0;
        errdefer {
            for (combined_values[0..values_cloned]) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(combined_values);
        }

        // Copy left row values
        for (left_row.values, 0..) |value, i| {
            combined_values[i] = try self.cloneValue(value);
            values_cloned = i + 1;
        }

        // Copy right row values
        for (right_row.values, 0..) |value, i| {
            combined_values[left_row.values.len + i] = try self.cloneValue(value);
            values_cloned = left_row.values.len + i + 1;
        }

        return storage.Row{ .values = combined_values };
    }

    /// Create a row with all NULL values
    fn createNullRow(self: *Self, column_count: usize) !storage.Row {
        const null_values = try self.connection.allocator.alloc(storage.Value, column_count);
        for (null_values) |*value| {
            value.* = storage.Value.Null;
        }
        return storage.Row{ .values = null_values };
    }

    /// Execute aggregate operation
    fn executeAggregate(self: *Self, agg: *planner.AggregateStep, result: *ExecutionResult) !void {
        // Get table schema for column lookup
        const table = blk: {
            var table_iter = self.connection.storage_engine.tables.iterator();
            if (table_iter.next()) |entry| {
                break :blk entry.value_ptr.*;
            }
            break :blk null;
        };

        for (agg.aggregates) |aggregate_op| {
            // Find the column index for the aggregate
            const col_idx: usize = if (aggregate_op.column) |col_name| idx: {
                if (table) |t| {
                    for (t.schema.columns, 0..) |col, i| {
                        if (std.mem.eql(u8, col.name, col_name)) {
                            break :idx i;
                        }
                    }
                }
                break :idx 0;
            } else 0;

            switch (aggregate_op.function_type) {
                .Count => {
                    // COUNT(*) - count all rows in the result
                    const count = result.rows.items.len;
                    const result_value = storage.Value{ .Integer = @intCast(count) };
                    try self.finishAggregateResult(result, result_value);
                },
                .Sum => {
                    // SUM(column) - sum all numeric values in the specified column
                    var sum: f64 = 0.0;
                    for (result.rows.items) |row| {
                        if (col_idx < row.values.len) {
                            switch (row.values[col_idx]) {
                                .Integer => |i| sum += @floatFromInt(i),
                                .Real => |r| sum += r,
                                else => {}, // Skip non-numeric values
                            }
                        }
                    }
                    const result_value = storage.Value{ .Real = sum };
                    try self.finishAggregateResult(result, result_value);
                },
                .Avg => {
                    // AVG(column) - average of all numeric values
                    var sum: f64 = 0.0;
                    var count: u32 = 0;
                    for (result.rows.items) |row| {
                        if (col_idx < row.values.len) {
                            switch (row.values[col_idx]) {
                                .Integer => |i| {
                                    sum += @floatFromInt(i);
                                    count += 1;
                                },
                                .Real => |r| {
                                    sum += r;
                                    count += 1;
                                },
                                else => {}, // Skip non-numeric values
                            }
                        }
                    }
                    const avg = if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0.0;
                    const result_value = storage.Value{ .Real = avg };
                    try self.finishAggregateResult(result, result_value);
                },
                .Min => {
                    // MIN(column) - minimum value
                    var min_value: ?storage.Value = null;
                    for (result.rows.items) |row| {
                        if (col_idx < row.values.len) {
                            const current_value = row.values[col_idx];
                            if (min_value == null) {
                                min_value = try self.cloneValue(current_value);
                            } else {
                                if (self.compareValues(current_value, min_value.?) == .lt) {
                                    min_value.?.deinit(self.connection.allocator);
                                    min_value = try self.cloneValue(current_value);
                                }
                            }
                        }
                    }
                    const result_value = min_value orelse storage.Value.Null;
                    try self.finishAggregateResult(result, result_value);
                },
                .Max => {
                    // MAX(column) - maximum value
                    var max_value: ?storage.Value = null;
                    for (result.rows.items) |row| {
                        if (col_idx < row.values.len) {
                            const current_value = row.values[col_idx];
                            if (max_value == null) {
                                max_value = try self.cloneValue(current_value);
                            } else {
                                if (self.compareValues(current_value, max_value.?) == .gt) {
                                    max_value.?.deinit(self.connection.allocator);
                                    max_value = try self.cloneValue(current_value);
                                }
                            }
                        }
                    }
                    const result_value = max_value orelse storage.Value.Null;
                    try self.finishAggregateResult(result, result_value);
                },
                .GroupConcat => {
                    // GROUP_CONCAT - concatenate all values with comma separator
                    var concat: std.ArrayListUnmanaged(u8) = .empty;
                    defer concat.deinit(self.connection.allocator);
                    var first = true;
                    for (result.rows.items) |row| {
                        if (row.values.len > 0) {
                            if (!first) try concat.appendSlice(self.connection.allocator, ",");
                            first = false;
                            switch (row.values[0]) {
                                .Text => |t| try concat.appendSlice(self.connection.allocator, t),
                                .Integer => |i| {
                                    var buf: [32]u8 = undefined;
                                    const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
                                    try concat.appendSlice(self.connection.allocator, slice);
                                },
                                .Real => |r| {
                                    var buf: [64]u8 = undefined;
                                    const slice = std.fmt.bufPrint(&buf, "{d}", .{r}) catch "0";
                                    try concat.appendSlice(self.connection.allocator, slice);
                                },
                                else => {},
                            }
                        }
                    }
                    const result_value = storage.Value{ .Text = try self.connection.allocator.dupe(u8, concat.items) };
                    try self.finishAggregateResult(result, result_value);
                },
                .CountDistinct => {
                    // COUNT(DISTINCT column) - count unique values
                    var seen = std.StringHashMap(void).init(self.connection.allocator);
                    defer {
                        var iter = seen.iterator();
                        while (iter.next()) |entry| {
                            self.connection.allocator.free(entry.key_ptr.*);
                        }
                        seen.deinit();
                    }
                    for (result.rows.items) |row| {
                        if (row.values.len > 0) {
                            var key_buf: std.ArrayListUnmanaged(u8) = .empty;
                            defer key_buf.deinit(self.connection.allocator);
                            try self.appendValueToKey(&key_buf, row.values[0]);
                            const key = try self.connection.allocator.dupe(u8, key_buf.items);
                            const gop = try seen.getOrPut(key);
                            if (gop.found_existing) {
                                self.connection.allocator.free(key);
                            }
                        }
                    }
                    const result_value = storage.Value{ .Integer = @intCast(seen.count()) };
                    try self.finishAggregateResult(result, result_value);
                },
                .Stddev => {
                    // STDDEV(column) - population standard deviation
                    // First pass: calculate mean
                    var sum: f64 = 0.0;
                    var count: u32 = 0;
                    for (result.rows.items) |row| {
                        if (col_idx < row.values.len) {
                            switch (row.values[col_idx]) {
                                .Integer => |i| {
                                    sum += @floatFromInt(i);
                                    count += 1;
                                },
                                .Real => |r| {
                                    sum += r;
                                    count += 1;
                                },
                                else => {},
                            }
                        }
                    }
                    if (count == 0) {
                        const result_value = storage.Value.Null;
                        try self.finishAggregateResult(result, result_value);
                    } else {
                        const mean = sum / @as(f64, @floatFromInt(count));
                        // Second pass: calculate sum of squared differences
                        var sum_sq_diff: f64 = 0.0;
                        for (result.rows.items) |row| {
                            if (col_idx < row.values.len) {
                                switch (row.values[col_idx]) {
                                    .Integer => |i| {
                                        const val: f64 = @floatFromInt(i);
                                        const diff = val - mean;
                                        sum_sq_diff += diff * diff;
                                    },
                                    .Real => |r| {
                                        const diff = r - mean;
                                        sum_sq_diff += diff * diff;
                                    },
                                    else => {},
                                }
                            }
                        }
                        const variance = sum_sq_diff / @as(f64, @floatFromInt(count));
                        const stddev = @sqrt(variance);
                        const result_value = storage.Value{ .Real = stddev };
                        try self.finishAggregateResult(result, result_value);
                    }
                },
                .Variance => {
                    // VARIANCE(column) - population variance
                    // First pass: calculate mean
                    var sum: f64 = 0.0;
                    var count: u32 = 0;
                    for (result.rows.items) |row| {
                        if (col_idx < row.values.len) {
                            switch (row.values[col_idx]) {
                                .Integer => |i| {
                                    sum += @floatFromInt(i);
                                    count += 1;
                                },
                                .Real => |r| {
                                    sum += r;
                                    count += 1;
                                },
                                else => {},
                            }
                        }
                    }
                    if (count == 0) {
                        const result_value = storage.Value.Null;
                        try self.finishAggregateResult(result, result_value);
                    } else {
                        const mean = sum / @as(f64, @floatFromInt(count));
                        // Second pass: calculate sum of squared differences
                        var sum_sq_diff: f64 = 0.0;
                        for (result.rows.items) |row| {
                            if (col_idx < row.values.len) {
                                switch (row.values[col_idx]) {
                                    .Integer => |i| {
                                        const val: f64 = @floatFromInt(i);
                                        const diff = val - mean;
                                        sum_sq_diff += diff * diff;
                                    },
                                    .Real => |r| {
                                        const diff = r - mean;
                                        sum_sq_diff += diff * diff;
                                    },
                                    else => {},
                                }
                            }
                        }
                        const variance = sum_sq_diff / @as(f64, @floatFromInt(count));
                        const result_value = storage.Value{ .Real = variance };
                        try self.finishAggregateResult(result, result_value);
                    }
                },
                .UserDefined => {
                    const result_value = try self.evaluateUserDefinedAggregate(aggregate_op, result.rows.items, table);
                    try self.finishAggregateResult(result, result_value);
                },
            }
        }
    }

    /// Helper function to finish aggregate result
    fn finishAggregateResult(self: *Self, result: *ExecutionResult, aggregate_value: storage.Value) !void {
        // Clear existing rows and add the aggregate result
        for (result.rows.items) |row| {
            for (row.values) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(row.values);
        }
        result.rows.clearAndFree(self.connection.allocator);

        // Create a single row with the aggregate result
        var aggregate_row_values = try self.connection.allocator.alloc(storage.Value, 1);
        errdefer self.connection.allocator.free(aggregate_row_values);
        aggregate_row_values[0] = aggregate_value;

        try result.rows.append(self.connection.allocator, storage.Row{ .values = aggregate_row_values });
    }

    /// Execute group by operation
    fn executeGroupBy(self: *Self, group: *planner.GroupByStep, result: *ExecutionResult) !void {
        // Group rows by the specified columns
        // Key: hash of group column values -> list of rows in that group
        var groups = std.StringHashMap(std.ArrayList(storage.Row)).init(self.connection.allocator);
        defer {
            var iter = groups.iterator();
            while (iter.next()) |entry| {
                self.connection.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.connection.allocator);
            }
            groups.deinit();
        }

        // Get table schema for column index lookup
        const table = if (result.rows.items.len > 0) blk: {
            // Try to find table from context - for now use first table in storage
            var table_iter = self.connection.storage_engine.tables.iterator();
            if (table_iter.next()) |entry| {
                break :blk entry.value_ptr.*;
            }
            break :blk null;
        } else null;

        // Build groups
        for (result.rows.items) |row| {
            // Build group key from specified columns
            var key_parts: std.ArrayListUnmanaged(u8) = .empty;
            defer key_parts.deinit(self.connection.allocator);

            for (group.group_columns) |col_name| {
                const col_idx = if (table) |t| self.findColumnIndex(t, col_name) else null;
                const value = if (col_idx) |idx| blk: {
                    if (idx < row.values.len) {
                        break :blk row.values[idx];
                    }
                    break :blk storage.Value.Null;
                } else if (row.values.len > 0) row.values[0] else storage.Value.Null;

                // Append value representation to key
                try self.appendValueToKey(&key_parts, value);
                try key_parts.append(self.connection.allocator, '|');
            }

            const key = try self.connection.allocator.dupe(u8, key_parts.items);
            errdefer self.connection.allocator.free(key);

            // Get or create group
            const gop = try groups.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            } else {
                // Key already exists, free the duplicate
                self.connection.allocator.free(key);
            }

            // Clone row and add to group
            var cloned_values = try self.connection.allocator.alloc(storage.Value, row.values.len);
            for (row.values, 0..) |v, i| {
                cloned_values[i] = try self.cloneValue(v);
            }
            try gop.value_ptr.append(self.connection.allocator, storage.Row{ .values = cloned_values });
        }

        // Clear original rows
        for (result.rows.items) |row| {
            for (row.values) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(row.values);
        }
        result.rows.clearAndFree(self.connection.allocator);

        // Process each group and compute aggregates
        var group_iter = groups.iterator();
        while (group_iter.next()) |entry| {
            const group_rows = entry.value_ptr.items;
            if (group_rows.len == 0) continue;

            // Build result row: group columns + aggregates
            const result_col_count = group.group_columns.len + group.aggregates.len;
            var result_values = try self.connection.allocator.alloc(storage.Value, result_col_count);
            var values_set: usize = 0;
            errdefer {
                for (result_values[0..values_set]) |v| v.deinit(self.connection.allocator);
                self.connection.allocator.free(result_values);
            }

            // Add group column values from first row
            for (group.group_columns, 0..) |col_name, i| {
                const col_idx = if (table) |t| self.findColumnIndex(t, col_name) else null;
                const value = if (col_idx) |idx| blk: {
                    if (idx < group_rows[0].values.len) {
                        break :blk group_rows[0].values[idx];
                    }
                    break :blk storage.Value.Null;
                } else if (group_rows[0].values.len > 0) group_rows[0].values[0] else storage.Value.Null;

                result_values[i] = try self.cloneValue(value);
                values_set = i + 1;
            }

            // Compute aggregates for this group
            for (group.aggregates, 0..) |agg, i| {
                const agg_value = try self.computeAggregate(agg, group_rows, table);
                result_values[group.group_columns.len + i] = agg_value;
                values_set = group.group_columns.len + i + 1;
            }

            try result.rows.append(self.connection.allocator, storage.Row{ .values = result_values });

            // Clean up group rows
            for (group_rows) |row| {
                for (row.values) |v| v.deinit(self.connection.allocator);
                self.connection.allocator.free(row.values);
            }
        }
    }

    /// Find column index by name in table schema
    fn findColumnIndex(self: *Self, table: *storage.Table, col_name: []const u8) ?usize {
        _ = self;
        for (table.schema.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, col_name)) {
                return i;
            }
        }
        return null;
    }

    /// Append value representation to key buffer for grouping
    fn appendValueToKey(self: *Self, key: *std.ArrayList(u8), value: storage.Value) !void {
        switch (value) {
            .Integer => |i| {
                var buf: [32]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
                try key.appendSlice(self.connection.allocator, slice);
            },
            .Text => |t| try key.appendSlice(self.connection.allocator, t),
            .Real => |r| {
                var buf: [64]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "{d}", .{r}) catch "0";
                try key.appendSlice(self.connection.allocator, slice);
            },
            .Null => try key.appendSlice(self.connection.allocator, "NULL"),
            else => try key.appendSlice(self.connection.allocator, "?"),
        }
    }

    /// Compute aggregate value for a group of rows
    fn computeAggregate(self: *Self, agg: planner.AggregateOperation, rows: []storage.Row, table: ?*storage.Table) !storage.Value {
        const col_idx: ?usize = if (agg.column) |col_name| blk: {
            if (table) |t| {
                break :blk self.findColumnIndex(t, col_name);
            }
            break :blk null;
        } else null;

        switch (agg.function_type) {
            .Count => {
                return storage.Value{ .Integer = @intCast(rows.len) };
            },
            .Sum => {
                var sum: f64 = 0.0;
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    switch (val) {
                        .Integer => |i| sum += @floatFromInt(i),
                        .Real => |r| sum += r,
                        else => {},
                    }
                }
                return storage.Value{ .Real = sum };
            },
            .Avg => {
                var sum: f64 = 0.0;
                var count: u32 = 0;
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    switch (val) {
                        .Integer => |i| {
                            sum += @floatFromInt(i);
                            count += 1;
                        },
                        .Real => |r| {
                            sum += r;
                            count += 1;
                        },
                        else => {},
                    }
                }
                return storage.Value{ .Real = if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0.0 };
            },
            .Min => {
                var min_val: ?storage.Value = null;
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    if (min_val == null) {
                        min_val = try self.cloneValue(val);
                    } else if (self.compareValues(val, min_val.?) == .lt) {
                        min_val.?.deinit(self.connection.allocator);
                        min_val = try self.cloneValue(val);
                    }
                }
                return min_val orelse storage.Value.Null;
            },
            .Max => {
                var max_val: ?storage.Value = null;
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    if (max_val == null) {
                        max_val = try self.cloneValue(val);
                    } else if (self.compareValues(val, max_val.?) == .gt) {
                        max_val.?.deinit(self.connection.allocator);
                        max_val = try self.cloneValue(val);
                    }
                }
                return max_val orelse storage.Value.Null;
            },
            .GroupConcat => {
                var concat: std.ArrayListUnmanaged(u8) = .empty;
                defer concat.deinit(self.connection.allocator);
                var first = true;
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    if (!first) try concat.appendSlice(self.connection.allocator, ",");
                    first = false;
                    switch (val) {
                        .Text => |t| try concat.appendSlice(self.connection.allocator, t),
                        .Integer => |i| {
                            var buf: [32]u8 = undefined;
                            const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
                            try concat.appendSlice(self.connection.allocator, slice);
                        },
                        else => {},
                    }
                }
                return storage.Value{ .Text = try self.connection.allocator.dupe(u8, concat.items) };
            },
            .CountDistinct => {
                var seen = std.StringHashMap(void).init(self.connection.allocator);
                defer seen.deinit();
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    var key_buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer key_buf.deinit(self.connection.allocator);
                    try self.appendValueToKey(&key_buf, val);
                    const key = try self.connection.allocator.dupe(u8, key_buf.items);
                    const gop = try seen.getOrPut(key);
                    if (gop.found_existing) {
                        self.connection.allocator.free(key);
                    }
                }
                // Clean up keys
                var iter = seen.iterator();
                while (iter.next()) |entry| {
                    self.connection.allocator.free(entry.key_ptr.*);
                }
                return storage.Value{ .Integer = @intCast(seen.count()) };
            },
            .Stddev => {
                // STDDEV(column) - population standard deviation
                var sum: f64 = 0.0;
                var count: u32 = 0;
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    switch (val) {
                        .Integer => |i| {
                            sum += @floatFromInt(i);
                            count += 1;
                        },
                        .Real => |r| {
                            sum += r;
                            count += 1;
                        },
                        else => {},
                    }
                }
                if (count == 0) return storage.Value.Null;
                const mean = sum / @as(f64, @floatFromInt(count));
                var sum_sq_diff: f64 = 0.0;
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    switch (val) {
                        .Integer => |i| {
                            const v: f64 = @floatFromInt(i);
                            const diff = v - mean;
                            sum_sq_diff += diff * diff;
                        },
                        .Real => |r| {
                            const diff = r - mean;
                            sum_sq_diff += diff * diff;
                        },
                        else => {},
                    }
                }
                const variance = sum_sq_diff / @as(f64, @floatFromInt(count));
                return storage.Value{ .Real = @sqrt(variance) };
            },
            .Variance => {
                // VARIANCE(column) - population variance
                var sum: f64 = 0.0;
                var count: u32 = 0;
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    switch (val) {
                        .Integer => |i| {
                            sum += @floatFromInt(i);
                            count += 1;
                        },
                        .Real => |r| {
                            sum += r;
                            count += 1;
                        },
                        else => {},
                    }
                }
                if (count == 0) return storage.Value.Null;
                const mean = sum / @as(f64, @floatFromInt(count));
                var sum_sq_diff: f64 = 0.0;
                for (rows) |row| {
                    const val = self.getAggregateColumnValue(row, col_idx);
                    switch (val) {
                        .Integer => |i| {
                            const v: f64 = @floatFromInt(i);
                            const diff = v - mean;
                            sum_sq_diff += diff * diff;
                        },
                        .Real => |r| {
                            const diff = r - mean;
                            sum_sq_diff += diff * diff;
                        },
                        else => {},
                    }
                }
                return storage.Value{ .Real = sum_sq_diff / @as(f64, @floatFromInt(count)) };
            },
            .UserDefined => return self.evaluateUserDefinedAggregate(agg, rows, table),
        }
    }

    fn evaluateUserDefinedAggregate(self: *Self, agg: planner.AggregateOperation, rows: []storage.Row, table: ?*storage.Table) !storage.Value {
        const function_name = agg.function_name orelse return error.UnknownFunction;
        const callback = self.connection.getAggregateFunction(function_name) orelse return error.UnknownFunction;

        const col_idx: ?usize = if (agg.column) |col_name| blk: {
            if (table) |t| {
                break :blk self.findColumnIndex(t, col_name);
            }
            break :blk null;
        } else null;

        var values = try self.connection.allocator.alloc(storage.Value, rows.len);
        var cloned: usize = 0;
        defer {
            for (values[0..cloned]) |value| {
                value.deinit(self.connection.allocator);
            }
            self.connection.allocator.free(values);
        }

        for (rows, 0..) |row, i| {
            values[i] = try self.cloneValue(self.getAggregateColumnValue(row, col_idx));
            cloned = i + 1;
        }

        return try callback(self.connection.allocator, values);
    }

    /// Get column value for aggregate computation
    fn getAggregateColumnValue(self: *Self, row: storage.Row, col_idx: ?usize) storage.Value {
        _ = self;
        if (col_idx) |idx| {
            if (idx < row.values.len) {
                return row.values[idx];
            }
        }
        // Default to first column if no specific column
        if (row.values.len > 0) {
            return row.values[0];
        }
        return storage.Value.Null;
    }

    /// Execute BEGIN TRANSACTION
    fn executeBeginTransaction(self: *Self, result: *ExecutionResult) !void {
        _ = result;
        try self.connection.beginTransaction();
    }

    /// Execute COMMIT
    fn executeCommit(self: *Self, result: *ExecutionResult) !void {
        _ = result;
        try self.connection.commitTransaction();
    }

    /// Execute ROLLBACK
    fn executeRollback(self: *Self, result: *ExecutionResult) !void {
        _ = result;
        try self.connection.rollbackTransaction();
    }

    fn executeSavepoint(self: *Self, savepoint: *planner.SavepointStep, result: *ExecutionResult) !void {
        _ = result;
        try self.connection.createSavepoint(savepoint.name);
    }

    fn executeReleaseSavepoint(self: *Self, savepoint: *planner.SavepointStep, result: *ExecutionResult) !void {
        _ = result;
        try self.connection.releaseSavepoint(savepoint.name);
    }

    fn executeRollbackToSavepoint(self: *Self, savepoint: *planner.SavepointStep, result: *ExecutionResult) !void {
        _ = result;
        try self.connection.rollbackToSavepoint(savepoint.name);
    }

    fn rejectSchemaChangeInSavepoint(self: *Self) !void {
        if (self.connection.hasActiveSavepoints()) return error.UnsupportedDDLInSavepoint;
    }

    /// Execute CREATE INDEX
    fn executeCreateIndex(self: *Self, create_idx: *planner.CreateIndexStep, result: *ExecutionResult) !void {
        _ = result;
        try self.rejectSchemaChangeInSavepoint();
        const resolved = try self.resolveTableRef(create_idx.table_name);
        const index_parts = try self.splitQualifiedName(create_idx.index_name);
        if (index_parts.schema_name) |schema_name| {
            const index_connection = try self.resolveSchemaConnection(schema_name);
            if (index_connection != resolved.connection) return error.SchemaMismatch;
        }
        try resolved.connection.ensureWritable();

        // Check if table exists
        const table = resolved.connection.storage_engine.getTable(resolved.table_name) orelse {
            return error.TableNotFound;
        };

        // Verify columns exist
        for (create_idx.columns) |col_name| {
            if (std.mem.eql(u8, col_name, "<expr>")) continue;
            var found = false;
            for (table.schema.columns) |column| {
                if (std.mem.eql(u8, column.name, col_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return error.ColumnNotFound;
            }
        }

        // Check if index already exists
        if (resolved.connection.storage_engine.getIndex(index_parts.name) != null) {
            if (create_idx.if_not_exists) {
                return; // Silently skip if IF NOT EXISTS is specified
            }
            return error.IndexAlreadyExists;
        }

        // Create the index in storage engine
        try resolved.connection.storage_engine.createIndexEx(
            index_parts.name,
            resolved.table_name,
            create_idx.columns,
            create_idx.expressions,
            create_idx.where_clause,
            create_idx.unique,
        );
        resolved.connection.invalidateResultCache(resolved.table_name);
    }

    /// Execute DROP INDEX
    fn executeDropIndex(self: *Self, drop_idx: *planner.DropIndexStep, result: *ExecutionResult) !void {
        _ = result;
        try self.rejectSchemaChangeInSavepoint();
        const index_parts = try self.splitQualifiedName(drop_idx.index_name);
        const target_connection = if (index_parts.schema_name) |schema_name|
            try self.resolveSchemaConnection(schema_name)
        else
            self.connection;
        try target_connection.ensureWritable();

        // Check if index exists
        if (target_connection.storage_engine.getIndex(index_parts.name) == null) {
            if (drop_idx.if_exists) {
                return; // Silently skip if IF EXISTS is specified
            }
            return error.IndexNotFound;
        }

        const index = target_connection.storage_engine.getIndex(index_parts.name).?;
        target_connection.invalidateResultCache(index.table_name);

        // Drop the index
        try target_connection.storage_engine.dropIndex(index_parts.name);
    }

    /// Execute DROP TABLE
    fn executeDropTable(self: *Self, drop_tbl: *planner.DropTableStep, result: *ExecutionResult) !void {
        _ = result;
        try self.rejectSchemaChangeInSavepoint();
        const resolved = try self.resolveTableRef(drop_tbl.table_name);
        try resolved.connection.ensureWritable();

        // Check if table exists
        if (resolved.connection.storage_engine.getTable(resolved.table_name) == null) {
            if (drop_tbl.if_exists) {
                return; // Silently skip if IF EXISTS is specified
            }
            return error.TableNotFound;
        }

        // Drop the table
        try resolved.connection.storage_engine.dropTable(resolved.table_name);
        resolved.connection.invalidateResultCache(resolved.table_name);
    }

    fn executeAlterTable(self: *Self, alter: *planner.AlterTableStep, result: *ExecutionResult) !void {
        _ = result;
        try self.rejectSchemaChangeInSavepoint();
        if (self.connection.in_transaction) return error.UnsupportedDDLInTransaction;
        const resolved = try self.resolveTableRef(alter.table_name);
        try resolved.connection.ensureWritable();

        switch (alter.action) {
            .RenameTable => |new_name| {
                try resolved.connection.storage_engine.renameTable(resolved.table_name, new_name);
                resolved.connection.invalidateResultCache(resolved.table_name);
                resolved.connection.invalidateResultCache(new_name);
            },
            .RenameColumn => |rename| {
                try resolved.connection.storage_engine.renameColumn(resolved.table_name, rename.old_name, rename.new_name);
                resolved.connection.invalidateResultCache(resolved.table_name);
            },
            .AddColumn => |column| {
                try resolved.connection.storage_engine.addColumn(resolved.table_name, column);
                resolved.connection.invalidateResultCache(resolved.table_name);
            },
        }
    }

    /// Execute PRAGMA statement
    fn executePragma(self: *Self, pragma: *planner.PragmaStep, result: *ExecutionResult) !void {
        const allocator = self.connection.allocator;

        // Handle different PRAGMA commands
        if (std.ascii.eqlIgnoreCase(pragma.name, "user_version")) {
            if (pragma.value) |value| {
                if (value < 0 or value > std.math.maxInt(u32)) return error.InvalidUserVersion;
                try self.connection.setUserVersion(@intCast(value));
            }
            try self.addSingleIntegerPragmaRow(result, self.connection.getUserVersion());
        } else if (std.ascii.eqlIgnoreCase(pragma.name, "schema_version")) {
            if (pragma.value != null) return error.ReadOnlyPragma;
            try self.addSingleIntegerPragmaRow(result, self.connection.getSchemaVersion());
        } else if (std.ascii.eqlIgnoreCase(pragma.name, "integrity_check")) {
            var check = try self.connection.integrityCheck();
            defer check.deinit(allocator);

            const message = if (check.ok)
                try allocator.dupe(u8, "ok")
            else
                try std.fmt.allocPrint(allocator, "integrity_check failed: {s}", .{check.first_issue orelse "unknown issue"});

            const values = try allocator.alloc(storage.Value, 1);
            values[0] = storage.Value{ .Text = message };
            try result.rows.append(allocator, storage.Row{ .values = values });
            try self.connection.recordResultRows(result.rows.items.len);
        } else if (std.ascii.eqlIgnoreCase(pragma.name, "table_info")) {
            // PRAGMA table_info(table_name)
            // Returns: cid, name, type, notnull, dflt_value, pk
            const table_name = pragma.argument orelse return error.PragmaRequiresArgument;

            const table = self.connection.storage_engine.getTable(table_name) orelse {
                return error.TableNotFound;
            };

            // Generate rows for each column in the table
            for (table.schema.columns, 0..) |column, cid| {
                var row_values: std.ArrayListUnmanaged(storage.Value) = .empty;

                // cid (column index)
                try row_values.append(allocator, storage.Value{ .Integer = @intCast(cid) });

                // name (column name)
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, column.name) });

                // type (data type as string)
                const type_str = switch (column.data_type) {
                    .Integer => "INTEGER",
                    .Text => "TEXT",
                    .Real => "REAL",
                    .Blob => "BLOB",
                    .JSON => "JSON",
                    .JSONB => "JSONB",
                    .UUID => "UUID",
                    .Array => "ARRAY",
                    .TimestampTZ => "TIMESTAMPTZ",
                    .Interval => "INTERVAL",
                    .Numeric => "NUMERIC",
                    .Boolean => "BOOLEAN",
                    .Timestamp => "TIMESTAMP",
                    .Date => "DATE",
                    .Time => "TIME",
                    .SmallInt => "SMALLINT",
                    .BigInt => "BIGINT",
                    .Varchar => "VARCHAR",
                    .Char => "CHAR",
                };
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, type_str) });

                // notnull (1 if NOT NULL, 0 otherwise)
                try row_values.append(allocator, storage.Value{ .Integer = if (column.is_nullable) 0 else 1 });

                // dflt_value (default value or NULL)
                if (column.default_value) |default| {
                    switch (default) {
                        .Literal => |lit_value| {
                            try row_values.append(allocator, try lit_value.clone(allocator));
                        },
                        .FunctionCall => |func| {
                            // Represent function call as text
                            try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, func.name) });
                        },
                    }
                } else {
                    try row_values.append(allocator, storage.Value.Null);
                }

                // pk (1 if primary key, 0 otherwise)
                try row_values.append(allocator, storage.Value{ .Integer = if (column.is_primary_key) 1 else 0 });

                try result.rows.append(allocator, storage.Row{
                    .values = try row_values.toOwnedSlice(allocator),
                });
            }
        } else if (std.ascii.eqlIgnoreCase(pragma.name, "index_list")) {
            const table_name = pragma.argument orelse return error.PragmaRequiresArgument;
            if (self.connection.storage_engine.getTable(table_name) == null) return error.TableNotFound;
            var seq: i64 = 0;
            var index_it = self.connection.storage_engine.indexes.iterator();
            while (index_it.next()) |entry| {
                const index = entry.value_ptr.*;
                if (!std.mem.eql(u8, index.table_name, table_name)) continue;
                const values = try allocator.alloc(storage.Value, 5);
                values[0] = .{ .Integer = seq };
                values[1] = .{ .Text = try allocator.dupe(u8, index.name) };
                values[2] = .{ .Integer = if (index.is_unique) 1 else 0 };
                values[3] = .{ .Text = try allocator.dupe(u8, "c") };
                values[4] = .{ .Integer = if (index.where_clause != null) 1 else 0 };
                try result.rows.append(allocator, .{ .values = values });
                seq += 1;
            }
        } else if (std.ascii.eqlIgnoreCase(pragma.name, "foreign_key_list")) {
            const table_name = pragma.argument orelse return error.PragmaRequiresArgument;
            const table = self.connection.storage_engine.getTable(table_name) orelse return error.TableNotFound;
            for (table.schema.foreign_keys, 0..) |foreign_key, fk_id| {
                const child_count = if (foreign_key.columns) |columns| columns.len else 1;
                for (0..child_count) |seq| {
                    const child_column = if (foreign_key.columns) |columns| columns[seq] else foreign_key.column orelse return error.InvalidForeignKey;
                    const parent_column = if (foreign_key.reference_columns) |columns| columns[seq] else foreign_key.reference_column;
                    const values = try allocator.alloc(storage.Value, 8);
                    values[0] = .{ .Integer = @intCast(fk_id) };
                    values[1] = .{ .Integer = @intCast(seq) };
                    values[2] = .{ .Text = try allocator.dupe(u8, foreign_key.reference_table) };
                    values[3] = .{ .Text = try allocator.dupe(u8, child_column) };
                    values[4] = .{ .Text = try allocator.dupe(u8, parent_column) };
                    values[5] = .{ .Text = try allocator.dupe(u8, foreignKeyActionName(foreign_key.on_update)) };
                    values[6] = .{ .Text = try allocator.dupe(u8, foreignKeyActionName(foreign_key.on_delete)) };
                    values[7] = .{ .Text = try allocator.dupe(u8, "NONE") };
                    try result.rows.append(allocator, .{ .values = values });
                }
            }
        } else if (std.ascii.eqlIgnoreCase(pragma.name, "database_list")) {
            // PRAGMA database_list
            // Returns: seq, name, file
            var row_values: std.ArrayListUnmanaged(storage.Value) = .empty;
            try row_values.append(allocator, storage.Value{ .Integer = 0 }); // seq
            try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, "main") }); // name
            try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, ":memory:") }); // file

            try result.rows.append(allocator, storage.Row{
                .values = try row_values.toOwnedSlice(allocator),
            });

            var seq: i64 = 1;
            var attached_iter = self.connection.attached_databases.iterator();
            while (attached_iter.next()) |entry| {
                var attached_row: std.ArrayListUnmanaged(storage.Value) = .empty;
                try attached_row.append(allocator, storage.Value{ .Integer = seq });
                try attached_row.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, entry.key_ptr.*) });

                const attached_file = if (entry.value_ptr.*.is_memory)
                    ":memory:"
                else
                    entry.value_ptr.*.path orelse "";
                try attached_row.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, attached_file) });

                try result.rows.append(allocator, storage.Row{
                    .values = try attached_row.toOwnedSlice(allocator),
                });
                seq += 1;
            }
        } else if (std.ascii.eqlIgnoreCase(pragma.name, "table_list")) {
            // PRAGMA table_list
            // Returns: schema, name, type, ncol, wr, strict
            var table_iter = self.connection.storage_engine.tables.iterator();
            while (table_iter.next()) |entry| {
                const table_name = entry.key_ptr.*;
                const table = entry.value_ptr.*;
                var row_values: std.ArrayListUnmanaged(storage.Value) = .empty;

                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, "main") }); // schema
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, table_name) }); // name
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, "table") }); // type
                try row_values.append(allocator, storage.Value{ .Integer = @intCast(table.schema.columns.len) }); // ncol
                try row_values.append(allocator, storage.Value{ .Integer = 0 }); // wr (without rowid)
                try row_values.append(allocator, storage.Value{ .Integer = 0 }); // strict

                try result.rows.append(allocator, storage.Row{
                    .values = try row_values.toOwnedSlice(allocator),
                });
            }
        } else if (std.ascii.eqlIgnoreCase(pragma.name, "planner_stats")) {
            for (self.connection.planner_table_stats.items) |stats| {
                var row_values: std.ArrayListUnmanaged(storage.Value) = .empty;
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, "table") });
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, stats.table_name) });
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, "") });
                try row_values.append(allocator, storage.Value{ .Integer = @intCast(stats.live_rows) });
                try row_values.append(allocator, storage.Value{ .Integer = @intCast(stats.row_count) });
                try row_values.append(allocator, storage.Value{ .Integer = @intCast(stats.deleted_rows) });
                try row_values.append(allocator, storage.Value{ .Integer = stats.column_count });
                try result.rows.append(allocator, storage.Row{ .values = try row_values.toOwnedSlice(allocator) });
            }

            for (self.connection.planner_index_stats.items) |stats| {
                var row_values: std.ArrayListUnmanaged(storage.Value) = .empty;
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, "index") });
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, stats.index_name) });
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, stats.table_name) });
                try row_values.append(allocator, storage.Value{ .Integer = @intCast(stats.indexed_rows) });
                try row_values.append(allocator, storage.Value{ .Integer = @intCast(stats.distinct_values) });
                try row_values.append(allocator, storage.Value{ .Integer = if (stats.is_unique) 1 else 0 });
                try row_values.append(allocator, storage.Value{ .Text = try allocator.dupe(u8, stats.column_name) });
                try result.rows.append(allocator, storage.Row{ .values = try row_values.toOwnedSlice(allocator) });
            }
        } else {
            return error.UnknownPragma;
        }
    }

    fn foreignKeyActionName(action: ?ast.ForeignKeyAction) []const u8 {
        return switch (action orelse .NoAction) {
            .NoAction => "NO ACTION",
            .Restrict => "RESTRICT",
            .Cascade => "CASCADE",
            .SetNull => "SET NULL",
        };
    }

    fn executeAnalyze(self: *Self, analyze: *planner.AnalyzeStep, result: *ExecutionResult) !void {
        _ = result;
        try self.connection.analyze(analyze.table_name);
    }

    fn executeVacuum(self: *Self, result: *ExecutionResult) !void {
        const allocator = self.connection.allocator;
        var check = try self.connection.vacuum();
        defer check.deinit(allocator);

        const message = if (check.ok)
            try allocator.dupe(u8, "ok")
        else
            try std.fmt.allocPrint(allocator, "vacuum integrity check failed: {s}", .{check.first_issue orelse "unknown issue"});

        const values = try allocator.alloc(storage.Value, 1);
        values[0] = storage.Value{ .Text = message };
        try result.rows.append(allocator, storage.Row{ .values = values });
    }

    /// Execute EXPLAIN / EXPLAIN QUERY PLAN statement
    fn executeExplain(self: *Self, explain: *planner.ExplainStep, result: *ExecutionResult) !void {
        const allocator = self.connection.allocator;

        // EXPLAIN QUERY PLAN returns: id, parent, notused, detail
        // EXPLAIN returns: addr, opcode, p1, p2, p3, p4, p5, comment
        // We'll use the simpler EXPLAIN QUERY PLAN format for now

        for (explain.inner_steps, 0..) |step, step_idx| {
            var row_values: std.ArrayListUnmanaged(storage.Value) = .empty;

            // id (step index)
            try row_values.append(allocator, storage.Value{ .Integer = @intCast(step_idx) });

            // parent (0 for top-level steps)
            try row_values.append(allocator, storage.Value{ .Integer = 0 });

            // notused (always 0 for compatibility)
            try row_values.append(allocator, storage.Value{ .Integer = 0 });

            // detail (description of what this step does)
            const detail = try self.describeStep(&step, allocator);
            try row_values.append(allocator, storage.Value{ .Text = detail });

            try result.rows.append(allocator, storage.Row{
                .values = try row_values.toOwnedSlice(allocator),
            });
        }
    }

    /// Execute ATTACH DATABASE statement
    fn executeAttach(self: *Self, attach: *planner.AttachStep, result: *ExecutionResult) !void {
        _ = result; // ATTACH doesn't return rows
        try self.rejectSchemaChangeInSavepoint();
        try self.connection.attachDatabase(attach.file_path, attach.schema_name);
    }

    /// Execute DETACH DATABASE statement
    fn executeDetach(self: *Self, detach: *planner.DetachStep, result: *ExecutionResult) !void {
        _ = result; // DETACH doesn't return rows
        try self.rejectSchemaChangeInSavepoint();
        try self.connection.detachDatabase(detach.schema_name);
    }

    /// Execute CREATE VIRTUAL TABLE statement (FTS5)
    fn executeCreateVirtualTable(self: *Self, create_vt: *planner.CreateVirtualTableStep, result: *ExecutionResult) !void {
        _ = result; // CREATE doesn't return rows
        try self.rejectSchemaChangeInSavepoint();
        const allocator = self.connection.allocator;

        // Only FTS5 module is currently supported
        if (!std.mem.eql(u8, create_vt.module_name, "fts5") and
            !std.mem.eql(u8, create_vt.module_name, "fts4") and
            !std.mem.eql(u8, create_vt.module_name, "FTS5") and
            !std.mem.eql(u8, create_vt.module_name, "FTS4"))
        {
            return error.UnsupportedVirtualTableModule;
        }

        // Check if table already exists
        if (self.connection.storage_engine.getTable(create_vt.table_name)) |_| {
            if (create_vt.if_not_exists) {
                return; // Table already exists, IF NOT EXISTS specified
            }
            return error.TableAlreadyExists;
        }

        // Create the backing table for FTS with rowid and indexed columns
        var columns = try allocator.alloc(storage.Column, create_vt.columns.len + 1);
        var columns_owned = false;
        for (columns) |*col| {
            col.* = .{
                .name = "",
                .data_type = .Text,
                .is_nullable = true,
                .is_primary_key = false,
                .default_value = null,
            };
        }
        errdefer {
            // Clean up on error: free all column names and the array only if not yet owned by table
            if (!columns_owned) {
                for (columns) |col| {
                    if (col.name.len > 0) allocator.free(col.name);
                }
                allocator.free(columns);
            }
        }

        // First column is rowid (implicit)
        columns[0] = storage.Column{
            .name = try allocator.dupe(u8, "rowid"),
            .data_type = .Integer,
            .is_nullable = false,
            .is_primary_key = true,
            .default_value = null,
        };

        // Add indexed columns
        for (create_vt.columns, 0..) |col_name, i| {
            columns[i + 1] = storage.Column{
                .name = try allocator.dupe(u8, col_name),
                .data_type = .Text,
                .is_nullable = true,
                .is_primary_key = false,
                .default_value = null,
            };
        }

        var schema = storage.TableSchema{ .columns = columns };
        try self.connection.storage_engine.createTable(create_vt.table_name, schema);
        schema.deinit(allocator);
        columns_owned = true; // Temporary schema has been cleaned up

        // Mark this table as an FTS virtual table by creating a special FTS index
        // The FTS functionality will be handled by the MATCH operator in WHERE clause
        // If FTS creation fails, rollback by dropping the backing table
        self.connection.storage_engine.createFTSIndex(create_vt.table_name, create_vt.columns) catch |err| {
            self.connection.storage_engine.dropTable(create_vt.table_name) catch {};
            return err;
        };
        self.connection.invalidateResultCache(create_vt.table_name);
    }

    /// Execute a basic query step (no CTEs or nested set operations - breaks recursion)
    fn executeBasicStep(self: *Self, step: *planner.ExecutionStep, result: *ExecutionResult) !void {
        try self.connection.recordVmStep();
        switch (step.*) {
            .TableScan => |*scan| try self.executeTableScan(scan, result),
            .Filter => |*filter| try self.executeFilter(filter, result),
            .Project => |*project| try self.executeProject(project, result),
            .Sort => |*sort| try self.executeSort(sort, result),
            .Limit => |*limit| try self.executeLimit(limit, result),
            .NestedLoopJoin => |*join| try self.executeNestedLoopJoin(join, result),
            .HashJoin => |*join| try self.executeHashJoin(join, result),
            .Aggregate => |*agg| try self.executeAggregate(agg, result),
            .GroupBy => |*group| try self.executeGroupBy(group, result),
            .Window => |*window| try self.executeWindow(window, result),
            else => return error.UnsupportedStepInSetOperation,
        }
        try self.connection.recordResultRows(result.rows.items.len);
        try self.connection.recordAffectedRows(result.affected_rows);
    }

    /// Execute set operation (UNION/INTERSECT/EXCEPT)
    fn executeSetOperation(self: *Self, set_op: *planner.SetOperationStep, result: *ExecutionResult) !void {
        const allocator = self.connection.allocator;

        // Execute left side
        var left_result = ExecutionResult{
            .rows = .empty,
            .affected_rows = 0,
            .connection = self.connection,
        };
        defer left_result.deinit();

        for (set_op.left_steps) |*step| {
            try self.executeBasicStep(step, &left_result);
        }

        // Execute right side
        var right_result = ExecutionResult{
            .rows = .empty,
            .affected_rows = 0,
            .connection = self.connection,
        };
        defer right_result.deinit();

        for (set_op.right_steps) |*step| {
            try self.executeBasicStep(step, &right_result);
        }

        // Perform the set operation
        switch (set_op.operation) {
            .Union => {
                // UNION removes duplicates
                try self.unionRows(&left_result.rows, &right_result.rows, result, false);
            },
            .UnionAll => {
                // UNION ALL keeps all rows
                try self.unionRows(&left_result.rows, &right_result.rows, result, true);
            },
            .Intersect => {
                // INTERSECT returns only rows in both
                try self.intersectRows(&left_result.rows, &right_result.rows, result, false);
            },
            .IntersectAll => {
                // INTERSECT ALL keeps duplicates
                try self.intersectRows(&left_result.rows, &right_result.rows, result, true);
            },
            .Except => {
                // EXCEPT returns rows in left but not in right
                try self.exceptRows(&left_result.rows, &right_result.rows, result, false);
            },
            .ExceptAll => {
                // EXCEPT ALL keeps duplicates
                try self.exceptRows(&left_result.rows, &right_result.rows, result, true);
            },
        }

        // Apply ORDER BY if specified
        if (set_op.order_by) |order_by| {
            try self.sortResultRows(result, order_by);
        }

        // Apply LIMIT/OFFSET if specified
        if (set_op.offset) |offset| {
            // Remove first 'offset' rows
            const actual_offset = @min(offset, result.rows.items.len);
            // Free the rows being removed
            for (result.rows.items[0..actual_offset]) |row| {
                for (row.values) |value| {
                    value.deinit(allocator);
                }
                allocator.free(row.values);
            }
            // Shift remaining rows
            if (actual_offset < result.rows.items.len) {
                std.mem.copyForwards(storage.Row, result.rows.items[0..], result.rows.items[actual_offset..]);
            }
            result.rows.shrinkRetainingCapacity(result.rows.items.len - actual_offset);
        }

        if (set_op.limit) |limit| {
            // Keep only first 'limit' rows
            const actual_limit = @min(limit, result.rows.items.len);
            // Free extra rows
            for (result.rows.items[actual_limit..]) |row| {
                for (row.values) |value| {
                    value.deinit(allocator);
                }
                allocator.free(row.values);
            }
            result.rows.shrinkRetainingCapacity(actual_limit);
        }
    }

    /// Union two row sets
    fn unionRows(self: *Self, left: *std.ArrayList(storage.Row), right: *std.ArrayList(storage.Row), result: *ExecutionResult, keep_duplicates: bool) !void {
        const allocator = self.connection.allocator;

        // Add all left rows
        for (left.items) |row| {
            var cloned_values = try allocator.alloc(storage.Value, row.values.len);
            for (row.values, 0..) |value, i| {
                cloned_values[i] = try value.clone(allocator);
            }
            try result.rows.append(allocator, storage.Row{ .values = cloned_values });
        }

        // Add right rows (checking for duplicates if needed)
        for (right.items) |row| {
            if (!keep_duplicates) {
                // Check if row already exists
                var found = false;
                for (result.rows.items) |existing| {
                    if (self.rowsEqual(existing, row)) {
                        found = true;
                        break;
                    }
                }
                if (found) continue;
            }

            var cloned_values = try allocator.alloc(storage.Value, row.values.len);
            for (row.values, 0..) |value, i| {
                cloned_values[i] = try value.clone(allocator);
            }
            try result.rows.append(allocator, storage.Row{ .values = cloned_values });
        }
    }

    /// Intersect two row sets
    fn intersectRows(self: *Self, left: *std.ArrayList(storage.Row), right: *std.ArrayList(storage.Row), result: *ExecutionResult, keep_duplicates: bool) !void {
        const allocator = self.connection.allocator;

        for (left.items) |left_row| {
            // Check if this row exists in right
            var found = false;
            for (right.items) |right_row| {
                if (self.rowsEqual(left_row, right_row)) {
                    found = true;
                    break;
                }
            }

            if (found) {
                // Check for duplicates in result if needed
                if (!keep_duplicates) {
                    var already_added = false;
                    for (result.rows.items) |existing| {
                        if (self.rowsEqual(existing, left_row)) {
                            already_added = true;
                            break;
                        }
                    }
                    if (already_added) continue;
                }

                var cloned_values = try allocator.alloc(storage.Value, left_row.values.len);
                for (left_row.values, 0..) |value, i| {
                    cloned_values[i] = try value.clone(allocator);
                }
                try result.rows.append(allocator, storage.Row{ .values = cloned_values });
            }
        }
    }

    fn addSingleIntegerPragmaRow(self: *Self, result: *ExecutionResult, value: u32) !void {
        const values = try self.connection.allocator.alloc(storage.Value, 1);
        values[0] = storage.Value{ .Integer = @intCast(value) };
        try result.rows.append(self.connection.allocator, storage.Row{ .values = values });
        try self.connection.recordResultRows(result.rows.items.len);
    }

    /// Except (difference) two row sets
    fn exceptRows(self: *Self, left: *std.ArrayList(storage.Row), right: *std.ArrayList(storage.Row), result: *ExecutionResult, keep_duplicates: bool) !void {
        const allocator = self.connection.allocator;

        for (left.items) |left_row| {
            // Check if this row exists in right
            var found_in_right = false;
            for (right.items) |right_row| {
                if (self.rowsEqual(left_row, right_row)) {
                    found_in_right = true;
                    break;
                }
            }

            if (!found_in_right) {
                // Check for duplicates in result if needed
                if (!keep_duplicates) {
                    var already_added = false;
                    for (result.rows.items) |existing| {
                        if (self.rowsEqual(existing, left_row)) {
                            already_added = true;
                            break;
                        }
                    }
                    if (already_added) continue;
                }

                var cloned_values = try allocator.alloc(storage.Value, left_row.values.len);
                for (left_row.values, 0..) |value, i| {
                    cloned_values[i] = try value.clone(allocator);
                }
                try result.rows.append(allocator, storage.Row{ .values = cloned_values });
            }
        }
    }

    /// Check if two rows are equal
    fn rowsEqual(self: *Self, a: storage.Row, b: storage.Row) bool {
        if (a.values.len != b.values.len) return false;

        for (a.values, b.values) |va, vb| {
            if (!self.valuesEqual(va, vb)) return false;
        }
        return true;
    }

    /// Execute window function step - applies window functions to the result set
    fn executeWindow(self: *Self, window_step: *planner.WindowStep, result: *ExecutionResult) !void {
        const allocator = self.connection.allocator;

        if (result.rows.items.len == 0) return;

        // Build mapping from column name to index in the RAW table rows
        var raw_column_indices = std.StringHashMap(usize).init(allocator);
        defer raw_column_indices.deinit();

        if (self.current_table) |table| {
            for (table.schema.columns, 0..) |col, i| {
                try raw_column_indices.put(col.name, i);
            }
        }

        // First, project the non-window columns from each row
        // This transforms rows from [id, name, department, salary] to [name, salary]
        var projected_rows: std.ArrayListUnmanaged(storage.Row) = .empty;

        for (result.rows.items) |original_row| {
            // Extract only the projected columns
            const num_projected = window_step.projected_columns.len;
            const num_window_funcs = window_step.window_functions.len;
            var new_values = try allocator.alloc(storage.Value, num_projected + num_window_funcs);

            // Project each non-window column
            for (window_step.projected_columns, 0..) |col_name, i| {
                if (raw_column_indices.get(col_name)) |raw_idx| {
                    if (raw_idx < original_row.values.len) {
                        // Clone the value (since we'll free the original row)
                        new_values[i] = try self.cloneValue(original_row.values[raw_idx]);
                    } else {
                        new_values[i] = storage.Value.Null;
                    }
                } else {
                    new_values[i] = storage.Value.Null;
                }
            }

            // Initialize window function slots to Null (will be filled below)
            for (num_projected..num_projected + num_window_funcs) |i| {
                new_values[i] = storage.Value.Null;
            }

            try projected_rows.append(allocator, storage.Row{ .values = new_values });

            // Free the original row values
            for (original_row.values) |value| {
                value.deinit(allocator);
            }
            allocator.free(original_row.values);
        }

        // Replace result rows with projected rows
        result.rows.deinit(allocator);
        result.rows = projected_rows;

        // Build column name to index mapping for the PROJECTED rows
        // (now "salary" is at index 1, not index 3)
        var column_indices = std.StringHashMap(usize).init(allocator);
        defer column_indices.deinit();

        for (window_step.projected_columns, 0..) |col_name, i| {
            try column_indices.put(col_name, i);
        }

        // Create window executor
        var executor = window_functions.WindowExecutor.init(allocator);

        // Process each window function
        for (window_step.window_functions, 0..) |window_func, wf_idx| {
            const window_slot = window_step.projected_columns.len + wf_idx;
            const resolved_spec = window_functions.WindowExecutor.resolveWindowSpecification(window_func.window_spec, window_step.window_definitions) orelse window_func.window_spec;
            var partition_indices: std.ArrayListUnmanaged(usize) = .empty;
            defer partition_indices.deinit(allocator);

            if (resolved_spec.partition_by) |partition_cols| {
                for (partition_cols) |col_name| {
                    if (column_indices.get(col_name)) |idx| {
                        try partition_indices.append(allocator, idx);
                    }
                }
            }

            try self.executeWindowFunctionOverGroups(
                &executor,
                window_func,
                resolved_spec,
                window_slot,
                &column_indices,
                partition_indices.items,
                result,
            );
        }

        if (window_step.output_column_count < window_step.projected_columns.len) {
            try self.trimHiddenWindowColumns(window_step, result);
        }
    }

    fn trimHiddenWindowColumns(self: *Self, window_step: *planner.WindowStep, result: *ExecutionResult) !void {
        const allocator = self.connection.allocator;
        const output_count = window_step.output_column_count;
        const projected_count = window_step.projected_columns.len;
        const window_count = window_step.window_functions.len;

        for (result.rows.items) |*row| {
            var new_values = try allocator.alloc(storage.Value, output_count + window_count);

            for (0..output_count) |idx| {
                new_values[idx] = row.values[idx];
            }
            for (0..window_count) |idx| {
                new_values[output_count + idx] = row.values[projected_count + idx];
            }

            for (output_count..projected_count) |idx| {
                row.values[idx].deinit(allocator);
            }

            allocator.free(row.values);
            row.values = new_values;
        }
    }

    fn executeWindowFunctionOverGroups(
        self: *Self,
        executor: *window_functions.WindowExecutor,
        window_func: ast.WindowFunction,
        resolved_spec: ast.WindowSpecification,
        window_slot: usize,
        column_indices: *std.StringHashMap(usize),
        partition_indices: []const usize,
        result: *ExecutionResult,
    ) !void {
        const allocator = self.connection.allocator;
        const row_count = result.rows.items.len;

        if (row_count == 0) return;

        var assigned = try allocator.alloc(bool, row_count);
        defer allocator.free(assigned);
        @memset(assigned, false);

        for (0..row_count) |row_idx| {
            if (assigned[row_idx]) continue;

            var group = std.ArrayListUnmanaged(usize).empty;
            defer group.deinit(allocator);

            if (partition_indices.len == 0) {
                for (0..row_count) |idx| {
                    assigned[idx] = true;
                    try group.append(allocator, idx);
                }
            } else {
                assigned[row_idx] = true;
                try group.append(allocator, row_idx);

                for (row_idx + 1..row_count) |candidate_idx| {
                    if (assigned[candidate_idx]) continue;
                    if (self.rowsMatchOnColumns(result.rows.items[row_idx], result.rows.items[candidate_idx], partition_indices)) {
                        assigned[candidate_idx] = true;
                        try group.append(allocator, candidate_idx);
                    }
                }
            }

            try self.applyWindowFunctionToGroup(
                executor,
                window_func,
                resolved_spec,
                window_slot,
                column_indices,
                group.items,
                result,
            );
        }
    }

    fn applyWindowFunctionToGroup(
        self: *Self,
        executor: *window_functions.WindowExecutor,
        window_func: ast.WindowFunction,
        resolved_spec: ast.WindowSpecification,
        window_slot: usize,
        column_indices: *std.StringHashMap(usize),
        group_indices: []const usize,
        result: *ExecutionResult,
    ) !void {
        const allocator = self.connection.allocator;

        const ordered_indices = try allocator.alloc(usize, group_indices.len);
        defer allocator.free(ordered_indices);
        @memcpy(ordered_indices, group_indices);

        if (resolved_spec.order_by) |order_by| {
            self.sortProjectedRowIndices(result.rows.items, ordered_indices, order_by, column_indices);
        }

        const ordered_rows = try allocator.alloc(storage.Row, ordered_indices.len);
        defer allocator.free(ordered_rows);
        for (ordered_indices, 0..) |row_idx, i| {
            ordered_rows[i] = result.rows.items[row_idx];
        }

        var context = try window_functions.WindowContext.initWithOrderBy(
            allocator,
            ordered_rows,
            resolved_spec.order_by,
            column_indices.*,
        );
        defer context.deinit();

        for (ordered_indices, 0..) |original_row_idx, local_idx| {
            context.current_row = local_idx;
            var resolved_window_func = window_func;
            resolved_window_func.window_spec = resolved_spec;
            const window_value = try executor.executeWindowFunction(resolved_window_func, &context);
            result.rows.items[original_row_idx].values[window_slot].deinit(allocator);
            result.rows.items[original_row_idx].values[window_slot] = window_value;
        }
    }

    fn rowsMatchOnColumns(self: *Self, a: storage.Row, b: storage.Row, column_indices: []const usize) bool {
        for (column_indices) |col_idx| {
            if (col_idx >= a.values.len or col_idx >= b.values.len) {
                return false;
            }
            if (!self.valuesEqual(a.values[col_idx], b.values[col_idx])) {
                return false;
            }
        }
        return true;
    }

    fn sortProjectedRowIndices(
        self: *Self,
        rows: []storage.Row,
        indices: []usize,
        order_by: []ast.OrderByClause,
        column_indices: *std.StringHashMap(usize),
    ) void {
        if (indices.len <= 1) return;

        var i: usize = 0;
        while (i < indices.len - 1) : (i += 1) {
            var j: usize = 0;
            while (j < indices.len - 1 - i) : (j += 1) {
                var should_swap = false;

                for (order_by) |clause| {
                    const col_idx = column_indices.get(clause.column) orelse continue;
                    const left = rows[indices[j]].values[col_idx];
                    const right = rows[indices[j + 1]].values[col_idx];
                    const cmp = self.compareValues(left, right);

                    const swap_this = if (clause.direction == .Desc)
                        cmp == .lt
                    else
                        cmp == .gt;
                    if (swap_this) should_swap = true;
                    if (cmp != .eq) break;
                }

                if (should_swap) {
                    const tmp = indices[j];
                    indices[j] = indices[j + 1];
                    indices[j + 1] = tmp;
                }
            }
        }
    }

    /// Partition boundary info
    const PartitionBoundary = struct {
        start: usize,
        end: usize,
    };

    /// Find partition boundaries based on partition column values
    fn findPartitionBoundaries(self: *Self, rows: []storage.Row, partition_indices: []const usize) ![]PartitionBoundary {
        const allocator = self.connection.allocator;

        if (rows.len == 0) {
            return try allocator.alloc(PartitionBoundary, 0);
        }

        var boundaries: std.ArrayListUnmanaged(PartitionBoundary) = .empty;

        var partition_start: usize = 0;
        var i: usize = 1;

        while (i < rows.len) : (i += 1) {
            // Check if partition key changed
            var key_changed = false;
            for (partition_indices) |col_idx| {
                if (col_idx < rows[i].values.len and col_idx < rows[partition_start].values.len) {
                    if (!self.valuesEqual(rows[i].values[col_idx], rows[partition_start].values[col_idx])) {
                        key_changed = true;
                        break;
                    }
                }
            }

            if (key_changed) {
                try boundaries.append(allocator, PartitionBoundary{ .start = partition_start, .end = i });
                partition_start = i;
            }
        }

        // Add final partition
        try boundaries.append(allocator, PartitionBoundary{ .start = partition_start, .end = rows.len });

        return try boundaries.toOwnedSlice(allocator);
    }

    /// Sort result rows by ORDER BY columns
    fn sortResultRows(self: *Self, result: *ExecutionResult, order_by: []ast.OrderByClause) !void {
        // Simple bubble sort for now (can optimize later)
        const items = result.rows.items;
        if (items.len <= 1) return;

        var i: usize = 0;
        while (i < items.len - 1) : (i += 1) {
            var j: usize = 0;
            while (j < items.len - 1 - i) : (j += 1) {
                var should_swap = false;

                // Compare by each ORDER BY clause
                for (order_by) |clause| {
                    // Look up column index from table schema
                    const col_idx: usize = if (self.current_table) |t|
                        self.findColumnIndex(t, clause.column) orelse 0
                    else
                        0;

                    if (col_idx < items[j].values.len and col_idx < items[j + 1].values.len) {
                        const cmp = self.compareSortValues(items[j].values[col_idx], items[j + 1].values[col_idx]);
                        // Respect sort direction (ASC vs DESC)
                        const should_swap_this = if (clause.direction == .Desc)
                            cmp == .lt
                        else
                            cmp == .gt;
                        if (should_swap_this) should_swap = true;
                        if (cmp != .eq) break;
                    }
                }

                if (should_swap) {
                    const tmp = items[j];
                    items[j] = items[j + 1];
                    items[j + 1] = tmp;
                }
            }
        }
    }

    fn compareSortValues(self: *Self, left: storage.Value, right: storage.Value) std.math.Order {
        if (left == .Text and right == .Text) {
            const left_number = std.fmt.parseFloat(f64, left.Text) catch null;
            const right_number = std.fmt.parseFloat(f64, right.Text) catch null;
            if (left_number != null and right_number != null) {
                return std.math.order(left_number.?, right_number.?);
            }
        }
        return self.compareValues(left, right);
    }

    /// Generate a human-readable description of an execution step
    fn describeStep(self: *Self, step: *const planner.ExecutionStep, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        return switch (step.*) {
            .TableScan => |scan| try std.fmt.allocPrint(allocator, "SCAN TABLE {s}", .{scan.table_name}),
            .IndexScan => |scan| try std.fmt.allocPrint(allocator, "INDEX SCAN {s}.{s} USING {s} rows={d} cost={d}", .{ scan.table_name, scan.column_name, scan.index_name, scan.estimated_rows, scan.estimated_cost }),
            .Filter => try allocator.dupe(u8, "FILTER"),
            .Project => try allocator.dupe(u8, "PROJECT"),
            .Sort => try allocator.dupe(u8, "SORT"),
            .Limit => |limit| try std.fmt.allocPrint(allocator, "LIMIT {d}", .{limit.count}),
            .Insert => |insert| try std.fmt.allocPrint(allocator, "INSERT INTO {s}", .{insert.table_name}),
            .CreateTable => |create| try std.fmt.allocPrint(allocator, "CREATE TABLE {s}", .{create.table_name}),
            .Update => |update| try std.fmt.allocPrint(allocator, "UPDATE {s}", .{update.table_name}),
            .Delete => |del| try std.fmt.allocPrint(allocator, "DELETE FROM {s}", .{del.table_name}),
            .NestedLoopJoin => |join| try std.fmt.allocPrint(allocator, "NESTED LOOP JOIN {s} WITH {s}", .{ join.left_table, join.right_table }),
            .HashJoin => |join| try std.fmt.allocPrint(allocator, "HASH JOIN {s} WITH {s}", .{ join.left_table, join.right_table }),
            .Aggregate => try allocator.dupe(u8, "AGGREGATE"),
            .GroupBy => try allocator.dupe(u8, "GROUP BY"),
            .BeginTransaction => try allocator.dupe(u8, "BEGIN TRANSACTION"),
            .Commit => try allocator.dupe(u8, "COMMIT"),
            .Rollback => try allocator.dupe(u8, "ROLLBACK"),
            .Savepoint => |savepoint| try std.fmt.allocPrint(allocator, "SAVEPOINT {s}", .{savepoint.name}),
            .ReleaseSavepoint => |savepoint| try std.fmt.allocPrint(allocator, "RELEASE SAVEPOINT {s}", .{savepoint.name}),
            .RollbackToSavepoint => |savepoint| try std.fmt.allocPrint(allocator, "ROLLBACK TO SAVEPOINT {s}", .{savepoint.name}),
            .CreateIndex => |idx| try std.fmt.allocPrint(allocator, "CREATE INDEX {s} ON {s}", .{ idx.index_name, idx.table_name }),
            .DropIndex => |idx| try std.fmt.allocPrint(allocator, "DROP INDEX {s}", .{idx.index_name}),
            .DropTable => |drop| try std.fmt.allocPrint(allocator, "DROP TABLE {s}", .{drop.table_name}),
            .AlterTable => |alter| try std.fmt.allocPrint(allocator, "ALTER TABLE {s}", .{alter.table_name}),
            .CreateCTE => |cte| try std.fmt.allocPrint(allocator, "CREATE CTE {s}", .{cte.name}),
            .Pragma => |pragma| try std.fmt.allocPrint(allocator, "PRAGMA {s}", .{pragma.name}),
            .Analyze => |analyze| if (analyze.table_name) |table_name|
                try std.fmt.allocPrint(allocator, "ANALYZE {s}", .{table_name})
            else
                try allocator.dupe(u8, "ANALYZE"),
            .Vacuum => try allocator.dupe(u8, "VACUUM"),
            .Explain => try allocator.dupe(u8, "EXPLAIN"),
            .SetOperation => |set_op| try std.fmt.allocPrint(allocator, "SET OPERATION {s}", .{@tagName(set_op.operation)}),
            .Window => try allocator.dupe(u8, "WINDOW"),
            .Having => try allocator.dupe(u8, "HAVING"),
            .Distinct => try allocator.dupe(u8, "DISTINCT"),
            .Attach => |attach| try std.fmt.allocPrint(allocator, "ATTACH DATABASE '{s}' AS {s}", .{ attach.file_path, attach.schema_name }),
            .Detach => |detach| try std.fmt.allocPrint(allocator, "DETACH DATABASE {s}", .{detach.schema_name}),
            .CreateVirtualTable => |create_vt| try std.fmt.allocPrint(allocator, "CREATE VIRTUAL TABLE {s} USING {s}", .{ create_vt.table_name, create_vt.module_name }),
        };
    }
};

/// Result of query execution
pub const ExecutionResult = struct {
    rows: std.ArrayListUnmanaged(storage.Row),
    affected_rows: u32,
    connection: *db.Connection, // Store connection to access consistent allocator

    pub fn deinit(self: *ExecutionResult) void {
        const allocator = self.connection.allocator;
        // Cleaning up execution result
        for (self.rows.items) |row| {
            // Cleaning row values
            for (row.values) |value| {
                switch (value) {
                    .Text => {
                        // Freeing text value
                    },
                    .Integer => {
                        // Freeing integer value
                    },
                    else => {
                        // Freeing other value
                    },
                }
                value.deinit(allocator);
            }
            // Freeing values array
            allocator.free(row.values);
        }
        self.rows.deinit(allocator);
        // Cleanup completed
    }
};

/// SQL LIKE pattern matching with % and _ wildcards
/// % matches zero or more characters
/// _ matches exactly one character
fn likeMatch(text: []const u8, pattern: []const u8) bool {
    var ti: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];
            if (pc == '%') {
                // Remember position for backtracking
                star_pi = pi;
                star_ti = ti;
                pi += 1;
                continue;
            } else if (pc == '_' or std.ascii.toLower(pc) == std.ascii.toLower(text[ti])) {
                // Match single character or exact match (case-insensitive)
                ti += 1;
                pi += 1;
                continue;
            }
        }
        // No match - try backtracking to last %
        if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    // Skip trailing % in pattern
    while (pi < pattern.len and pattern[pi] == '%') {
        pi += 1;
    }

    return pi == pattern.len;
}

/// VM errors
const VmError = error{
    ColumnValueMismatch,
    ColumnNotFound,
    TooManyValues,
    MissingRequiredValue,
    ParameterIndexOutOfBounds,
    NoParametersProvided,
    UnresolvedParameter,
    TableNotFound,
    UnexpectedAggregate,
    NotImplemented,
};

/// Execute a parsed statement (convenience function)
pub fn execute(connection: *db.Connection, parsed: *const ast.Statement) !void {
    try connection.checkOperation();
    var vm = VirtualMachine.init(connection.allocator, connection);
    defer vm.deinitVM();

    var query_planner = planner.Planner.initWithContext(
        connection.allocator,
        &connection.aggregate_function_names,
        connection.planner_table_stats.items,
        connection.planner_index_stats.items,
    );
    var plan = try query_planner.plan(parsed);
    defer plan.deinit();

    var result = try vm.execute(&plan);
    defer result.deinit();

    // Print results based on statement type (disabled for benchmarks - verbose output)
    // Uncomment these lines for interactive/debugging use
    // switch (parsed.*) {
    //     .Select => {
    //         std.debug.print("┌─ Query Results ─┐\n", .{});
    //         if (result.rows.items.len == 0) {
    //             std.debug.print("│ No rows found   │\n", .{});
    //         } else {
    //             for (result.rows.items, 0..) |row, i| {
    //                 std.debug.print("│ Row {d}: ", .{i + 1});
    //                 for (row.values, 0..) |value, j| {
    //                     if (j > 0) std.debug.print(", ", .{});
    //                     switch (value) {
    //                         .Integer => |int| std.debug.print("{d}", .{int}),
    //                         .Text => |text| std.debug.print("'{s}'", .{text}),
    //                         .Real => |real| std.debug.print("{d:.2}", .{real}),
    //                         .Null => std.debug.print("NULL", .{}),
    //                         .Blob => std.debug.print("<blob>", .{}),
    //                         .Parameter => |param_index| std.debug.print("?{d}", .{param_index}),
    //                         .FunctionCall => std.debug.print("<function>", .{}),
    //                         .JSON => |json| std.debug.print("JSON:'{s}'", .{json}),
    //                         .JSONB => |jsonb| std.debug.print("JSONB:'{s}'", .{jsonb.toString(connection.allocator) catch "invalid"}),
    //                         .UUID => |uuid| std.debug.print("UUID:{any}", .{uuid}),
    //                         .Array => |array| std.debug.print("ARRAY:{s}", .{array.toString(connection.allocator) catch "invalid"}),
    //                         .Boolean => |b| std.debug.print("{}", .{b}),
    //                         .Timestamp => |ts| std.debug.print("TS:{d}", .{ts}),
    //                         .TimestampTZ => |tstz| std.debug.print("TSTZ:{d}({s})", .{ tstz.timestamp, tstz.timezone }),
    //                         .Date => |d| std.debug.print("DATE:{d}", .{d}),
    //                         .Time => |t| std.debug.print("TIME:{d}", .{t}),
    //                         .Interval => |interval| std.debug.print("INTERVAL:{d}", .{interval}),
    //                         .Numeric => |n| std.debug.print("NUMERIC:{s}", .{n.digits}),
    //                         .SmallInt => |si| std.debug.print("{d}", .{si}),
    //                         .BigInt => |bi| std.debug.print("{d}", .{bi}),
    //                     }
    //                 }
    //                 std.debug.print(" │\n", .{});
    //             }
    //         }
    //         std.debug.print("└─ {d} row(s) ─────┘\n", .{result.rows.items.len});
    //     },
    //     else => {
    //         std.debug.print("✅ Statement executed successfully. Affected rows: {d}\n", .{result.affected_rows});
    //     },
    // }
}

test "vm creation" {
    try std.testing.expect(true); // Placeholder
}

test "FTS virtual table creation failure rollback" {
    // This test verifies that when CREATE VIRTUAL TABLE fails during FTS index creation,
    // the backing table is properly rolled back (no orphan table remains).
    // Regression test for memory safety issues identified in v1.5.3 code review.

    const testing = std.testing;

    // Use a FailingAllocator that will fail after a certain number of allocations
    // We need to find the right count where table creation succeeds but FTS creation fails
    const fail_counts_to_test = [_]usize{ 50, 60, 70, 80, 90, 100, 110, 120 };

    for (fail_counts_to_test) |fail_after| {
        const backing_allocator = testing.allocator;
        var failing_alloc = std.heap.FailingAllocator.init(backing_allocator, .{ .fail_index = fail_after });
        const alloc = failing_alloc.allocator();

        // Try to create connection and virtual table
        const conn = db.Connection.openMemory(alloc) catch continue;
        defer conn.close();

        // Try creating the virtual table - this may fail at various points
        conn.execute("CREATE VIRTUAL TABLE test_fts USING fts5(title, content)") catch |err| {
            // If it failed, verify no orphan table exists
            if (conn.storage_engine.getTable("test_fts")) |_| {
                // Orphan table found - this is the bug we're testing for
                std.debug.print("FAIL: Orphan table found after FTS creation failure at fail_index={d}\n", .{fail_after});
                return error.OrphanTableAfterFTSFailure;
            }
            // No orphan - good, the rollback worked
            _ = err;
            continue;
        };

        // If we get here, creation succeeded - verify both table and FTS index exist
        try testing.expect(conn.storage_engine.getTable("test_fts") != null);
        try testing.expect(conn.storage_engine.isFTSTable("test_fts"));
    }
}
