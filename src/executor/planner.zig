const std = @import("std");
const ast = @import("../parser/ast.zig");
const storage = @import("../db/storage.zig");

/// Query execution planner
pub const Planner = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize planner
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Create execution plan for a statement
    pub fn plan(self: *Self, statement: *const ast.Statement) anyerror!ExecutionPlan {
        return switch (statement.*) {
            .Select => |*select| try self.planSelect(select),
            .Insert => |*insert| try self.planInsert(insert),
            .CreateTable => |*create| try self.planCreateTable(create),
            .Update => |*update| try self.planUpdate(update),
            .Delete => |*delete| try self.planDelete(delete),
            .BeginTransaction => |*trans| try self.planTransaction(trans),
            .Commit => |*trans| try self.planCommit(trans),
            .Rollback => |*trans| try self.planRollback(trans),
            .CreateIndex => |*create_idx| try self.planCreateIndex(create_idx),
            .DropIndex => |*drop_idx| try self.planDropIndex(drop_idx),
            .DropTable => |*drop_tbl| try self.planDropTable(drop_tbl),
            .With => |*with| try self.planWith(with), // Handle CTE
            .Pragma => |*pragma| try self.planPragma(pragma),
            .Explain => |*explain| try self.planExplain(explain),
            .CompoundSelect => |*compound| try self.planCompoundSelect(compound),
            .Attach => |*attach| try self.planAttach(attach),
            .Detach => |*detach| try self.planDetach(detach),
            .CreateVirtualTable => |*create_vt| try self.planCreateVirtualTable(create_vt),
        };
    }

    /// Plan SELECT statement execution
    fn planSelect(self: *Self, select: *const ast.SelectStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        // Table scan step
        try steps.append(self.allocator, ExecutionStep{
            .TableScan = TableScanStep{
                .table_name = if (select.table) |table| try self.allocator.dupe(u8, table) else "",
            },
        });

        // JOIN steps
        for (select.joins) |join| {
            const join_step = try self.planJoin(select.table orelse "", &join);
            try steps.append(self.allocator, join_step);
        }

        // Filter step (WHERE clause)
        if (select.where_clause) |where_clause| {
            try steps.append(self.allocator, ExecutionStep{
                .Filter = FilterStep{
                    .condition = try self.cloneCondition(&where_clause.condition),
                },
            });
        }

        // Check if we have aggregate functions
        const has_aggregates = self.hasAggregates(select.columns);

        if (has_aggregates) {
            // Extract aggregate operations
            var aggregates: std.ArrayListUnmanaged(AggregateOperation) = .empty;
            for (select.columns) |column| {
                if (column.expression == .Aggregate) {
                    try aggregates.append(self.allocator, AggregateOperation{
                        .function_type = column.expression.Aggregate.function_type,
                        .column = if (column.expression.Aggregate.column) |col|
                            try self.allocator.dupe(u8, col)
                        else
                            null,
                        .alias = if (column.alias) |alias|
                            try self.allocator.dupe(u8, alias)
                        else
                            null,
                    });
                }
            }

            if (select.group_by) |group_by| {
                // GROUP BY aggregation
                var group_columns: std.ArrayListUnmanaged([]const u8) = .empty;
                for (group_by) |col| {
                    try group_columns.append(self.allocator, try self.allocator.dupe(u8, col));
                }

                try steps.append(self.allocator, ExecutionStep{
                    .GroupBy = GroupByStep{
                        .group_columns = try group_columns.toOwnedSlice(self.allocator),
                        .aggregates = try aggregates.toOwnedSlice(self.allocator),
                    },
                });
            } else {
                // Simple aggregation (no GROUP BY)
                try steps.append(self.allocator, ExecutionStep{
                    .Aggregate = AggregateStep{
                        .aggregates = try aggregates.toOwnedSlice(self.allocator),
                    },
                });
            }

            // HAVING clause (filter after aggregation)
            if (select.having) |having| {
                try steps.append(self.allocator, ExecutionStep{
                    .Having = HavingStep{
                        .condition = try self.cloneCondition(&having.condition),
                    },
                });
            }
        } else {
            // Regular projection step (SELECT columns)
            var columns: std.ArrayListUnmanaged([]const u8) = .empty;
            var expressions: std.ArrayListUnmanaged(ast.ColumnExpression) = .empty;
            var has_expressions = false;
            var window_functions: std.ArrayListUnmanaged(ast.WindowFunction) = .empty;
            var window_column_names: std.ArrayListUnmanaged([]const u8) = .empty;
            var non_window_columns: std.ArrayListUnmanaged([]const u8) = .empty;

            for (select.columns) |column| {
                switch (column.expression) {
                    .Simple => |name| {
                        try columns.append(self.allocator, try self.allocator.dupe(u8, name));
                        try expressions.append(self.allocator, ast.ColumnExpression{ .Simple = try self.allocator.dupe(u8, name) });
                        try non_window_columns.append(self.allocator, try self.allocator.dupe(u8, name));
                    },
                    .Aggregate => {
                        // This shouldn't happen if has_aggregates was false
                        return error.UnexpectedAggregate;
                    },
                    .Window => |window_func| {
                        // Collect window functions for a separate WindowStep
                        const cloned_wf = try self.cloneWindowFunction(window_func);
                        try window_functions.append(self.allocator, cloned_wf);
                        // Use alias or generate a name for the window column
                        const col_name = if (column.alias) |a| a else column.name;
                        try window_column_names.append(self.allocator, try self.allocator.dupe(u8, col_name));
                        // DON'T add window columns to Project - they don't exist in table schema yet
                    },
                    .FunctionCall => |func_call| {
                        // Function calls in SELECT columns
                        const col_name = if (column.alias) |a| a else func_call.name;
                        try columns.append(self.allocator, try self.allocator.dupe(u8, col_name));
                        try expressions.append(self.allocator, ast.ColumnExpression{ .FunctionCall = try self.cloneFunctionCall(func_call) });
                        has_expressions = true;
                        try non_window_columns.append(self.allocator, try self.allocator.dupe(u8, col_name));
                    },
                    .Case => |case_expr| {
                        // Use alias or generate a name for CASE column
                        const col_name = if (column.alias) |a| a else "CASE";
                        try columns.append(self.allocator, try self.allocator.dupe(u8, col_name));
                        try expressions.append(self.allocator, ast.ColumnExpression{ .Case = try self.cloneCaseExpression(case_expr) });
                        has_expressions = true;
                        try non_window_columns.append(self.allocator, try self.allocator.dupe(u8, col_name));
                    },
                }
            }

            // Add WindowStep BEFORE Project if there are window functions
            // Window step will project non-window columns and compute window functions
            if (window_functions.items.len > 0) {
                try steps.append(self.allocator, ExecutionStep{
                    .Window = WindowStep{
                        .window_functions = try window_functions.toOwnedSlice(self.allocator),
                        .column_names = try window_column_names.toOwnedSlice(self.allocator),
                        .projected_columns = try non_window_columns.toOwnedSlice(self.allocator),
                    },
                });

                // Clean up columns/expressions arrays since Window step handles projection
                for (columns.items) |col| {
                    self.allocator.free(col);
                }
                columns.deinit(self.allocator);
                for (expressions.items) |*expr| {
                    expr.deinit(self.allocator);
                }
                expressions.deinit(self.allocator);
            } else {
                // No window functions - use regular Project step
                try steps.append(self.allocator, ExecutionStep{
                    .Project = ProjectStep{
                        .columns = try columns.toOwnedSlice(self.allocator),
                        .expressions = if (has_expressions) try expressions.toOwnedSlice(self.allocator) else null,
                    },
                });

                // Clean up expressions if not used
                if (!has_expressions) {
                    for (expressions.items) |*expr| {
                        expr.deinit(self.allocator);
                    }
                    expressions.deinit(self.allocator);
                }

                window_functions.deinit(self.allocator);
                window_column_names.deinit(self.allocator);
                // Free the strings in non_window_columns before deinit
                for (non_window_columns.items) |col| {
                    self.allocator.free(col);
                }
                non_window_columns.deinit(self.allocator);
            }
        }

        // DISTINCT step (remove duplicate rows)
        if (select.distinct) {
            try steps.append(self.allocator, ExecutionStep.Distinct);
        }

        // Limit step
        if (select.limit) |limit| {
            try steps.append(self.allocator, ExecutionStep{
                .Limit = LimitStep{
                    .count = limit,
                    .offset = select.offset orelse 0,
                },
            });
        }

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan JOIN operation
    fn planJoin(self: *Self, left_table: []const u8, join: *const ast.JoinClause) !ExecutionStep {
        // Try to determine if this is an equi-join for hash join optimization
        const equi_join_info = self.analyzeEquiJoin(&join.condition);

        if (equi_join_info) |info| {
            // Use hash join for equi-joins (more efficient for larger datasets)
            return ExecutionStep{
                .HashJoin = HashJoinStep{
                    .join_type = join.join_type,
                    .left_table = try self.allocator.dupe(u8, left_table),
                    .right_table = try self.allocator.dupe(u8, join.table),
                    .left_key_column = try self.allocator.dupe(u8, info.left_column),
                    .right_key_column = try self.allocator.dupe(u8, info.right_column),
                    .condition = try self.cloneCondition(&join.condition),
                },
            };
        } else {
            // Use nested loop join for complex conditions
            return ExecutionStep{
                .NestedLoopJoin = NestedLoopJoinStep{
                    .join_type = join.join_type,
                    .left_table = try self.allocator.dupe(u8, left_table),
                    .right_table = try self.allocator.dupe(u8, join.table),
                    .condition = try self.cloneCondition(&join.condition),
                },
            };
        }
    }

    /// Analyze if condition is an equi-join (column = column)
    fn analyzeEquiJoin(self: *Self, condition: *const ast.Condition) ?EquiJoinInfo {
        _ = self;
        switch (condition.*) {
            .Comparison => |comp| {
                if (comp.operator == .Equal) {
                    // Check if both sides are column references
                    if (comp.left == .Column and comp.right == .Column) {
                        return EquiJoinInfo{
                            .left_column = comp.left.Column,
                            .right_column = comp.right.Column,
                        };
                    }
                }
            },
            .Logical => {
                // For now, don't optimize complex logical conditions
                // Could be enhanced to handle AND of equi-joins
            },
        }
        return null;
    }

    const EquiJoinInfo = struct {
        left_column: []const u8,
        right_column: []const u8,
    };

    /// Check if any columns contain aggregate functions
    fn hasAggregates(self: *Self, columns: []ast.Column) bool {
        _ = self;
        for (columns) |column| {
            if (column.expression == .Aggregate) {
                return true;
            }
        }
        return false;
    }

    /// Plan INSERT statement execution
    fn planInsert(self: *Self, insert: *const ast.InsertStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        // Clone columns if provided
        var columns: ?[][]const u8 = null;
        if (insert.columns) |cols| {
            var cloned_cols: std.ArrayListUnmanaged([]const u8) = .empty;
            for (cols) |col| {
                try cloned_cols.append(self.allocator, try self.allocator.dupe(u8, col));
            }
            columns = try cloned_cols.toOwnedSlice(self.allocator);
        }

        // Clone values
        var values: std.ArrayListUnmanaged([]storage.Value) = .empty;
        for (insert.values) |row| {
            var cloned_row: std.ArrayListUnmanaged(storage.Value) = .empty;
            for (row) |value| {
                try cloned_row.append(self.allocator, try self.cloneValue(value));
            }
            try values.append(self.allocator, try cloned_row.toOwnedSlice(self.allocator));
        }

        // Clone ON CONFLICT if provided
        var on_conflict: ?OnConflictAction = null;
        if (insert.on_conflict) |oc| {
            switch (oc.action) {
                .DoNothing => {
                    on_conflict = .{ .DoNothing = {} };
                },
                .DoUpdate => |update| {
                    var cloned_assignments: std.ArrayListUnmanaged(UpdateAssignment) = .empty;
                    for (update.assignments) |assignment| {
                        try cloned_assignments.append(self.allocator, UpdateAssignment{
                            .column = try self.allocator.dupe(u8, assignment.column),
                            .expr = try self.cloneExpression(assignment.expr),
                        });
                    }
                    var cloned_condition: ?ast.Condition = null;
                    if (update.where_clause) |where| {
                        cloned_condition = try self.cloneCondition(&where.condition);
                    }
                    on_conflict = .{
                        .DoUpdate = .{
                            .assignments = try cloned_assignments.toOwnedSlice(self.allocator),
                            .condition = cloned_condition,
                        },
                    };
                },
            }
        }

        // Clone RETURNING columns if provided
        var returning_columns: ?[][]const u8 = null;
        if (insert.returning) |ret| {
            var cloned_ret: std.ArrayListUnmanaged([]const u8) = .empty;
            for (ret.columns) |col| {
                try cloned_ret.append(self.allocator, try self.allocator.dupe(u8, col));
            }
            returning_columns = try cloned_ret.toOwnedSlice(self.allocator);
        }

        try steps.append(self.allocator, ExecutionStep{
            .Insert = InsertStep{
                .table_name = try self.allocator.dupe(u8, insert.table),
                .columns = columns,
                .values = try values.toOwnedSlice(self.allocator),
                .on_conflict = on_conflict,
                .returning_columns = returning_columns,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan CREATE TABLE statement execution
    fn planCreateTable(self: *Self, create: *const ast.CreateTableStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        // Clone column definitions
        var columns: std.ArrayListUnmanaged(storage.Column) = .empty;
        for (create.columns) |col_def| {
            try columns.append(self.allocator, storage.Column{
                .name = try self.allocator.dupe(u8, col_def.name),
                .data_type = switch (col_def.data_type) {
                    .Integer => storage.DataType.Integer,
                    .Text => storage.DataType.Text,
                    .Real => storage.DataType.Real,
                    .Blob => storage.DataType.Blob,
                    // Map extended types to their storage equivalents
                    .DateTime => storage.DataType.Text, // Store as ISO string
                    .Timestamp => storage.DataType.Integer, // Store as Unix timestamp
                    .Boolean => storage.DataType.Integer, // Store as 0/1
                    .Date => storage.DataType.Text, // Store as ISO date
                    .Time => storage.DataType.Text, // Store as ISO time
                    .Decimal => storage.DataType.Real, // Store as float
                    .Varchar => storage.DataType.Text,
                    .Char => storage.DataType.Text,
                    .Float => storage.DataType.Real,
                    .Double => storage.DataType.Real,
                    .SmallInt => storage.DataType.Integer,
                    .BigInt => storage.DataType.Integer,
                    // PostgreSQL compatibility types
                    .JSON => storage.DataType.JSON,
                    .JSONB => storage.DataType.JSONB,
                    .UUID => storage.DataType.UUID,
                    .Array => storage.DataType.Array,
                    .TimestampTZ => storage.DataType.TimestampTZ,
                    .Interval => storage.DataType.Interval,
                    .Numeric => storage.DataType.Numeric,
                },
                .is_primary_key = blk: {
                    for (col_def.constraints) |constraint| {
                        if (constraint == .PrimaryKey) break :blk true;
                    }
                    break :blk false;
                },
                .is_nullable = blk: {
                    for (col_def.constraints) |constraint| {
                        if (constraint == .NotNull) break :blk false;
                    }
                    break :blk true;
                },
                .default_value = blk: {
                    for (col_def.constraints) |constraint| {
                        if (constraint == .Default) {
                            const default_value = try self.convertAstDefaultToStorage(constraint.Default);
                            break :blk default_value;
                        }
                    }
                    break :blk null;
                },
            });
        }

        try steps.append(self.allocator, ExecutionStep{
            .CreateTable = CreateTableStep{
                .table_name = try self.allocator.dupe(u8, create.table_name),
                .columns = try columns.toOwnedSlice(self.allocator),
                .if_not_exists = create.if_not_exists,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan UPDATE statement execution
    fn planUpdate(self: *Self, update: *const ast.UpdateStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        // Clone assignments
        var assignments: std.ArrayListUnmanaged(UpdateAssignment) = .empty;
        for (update.assignments) |assignment| {
            try assignments.append(self.allocator, UpdateAssignment{
                .column = try self.allocator.dupe(u8, assignment.column),
                .expr = try self.cloneExpression(assignment.expr),
            });
        }

        var condition: ?ast.Condition = null;
        if (update.where_clause) |where_clause| {
            condition = try self.cloneCondition(&where_clause.condition);
        }

        // Clone RETURNING columns if provided
        var returning_columns: ?[][]const u8 = null;
        if (update.returning) |ret| {
            var cloned_ret: std.ArrayListUnmanaged([]const u8) = .empty;
            for (ret.columns) |col| {
                try cloned_ret.append(self.allocator, try self.allocator.dupe(u8, col));
            }
            returning_columns = try cloned_ret.toOwnedSlice(self.allocator);
        }

        try steps.append(self.allocator, ExecutionStep{
            .Update = UpdateStep{
                .table_name = try self.allocator.dupe(u8, update.table),
                .assignments = try assignments.toOwnedSlice(self.allocator),
                .condition = condition,
                .returning_columns = returning_columns,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan DELETE statement execution
    fn planDelete(self: *Self, delete: *const ast.DeleteStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        var condition: ?ast.Condition = null;
        if (delete.where_clause) |where_clause| {
            condition = try self.cloneCondition(&where_clause.condition);
        }

        // Clone RETURNING columns if provided
        var returning_columns: ?[][]const u8 = null;
        if (delete.returning) |ret| {
            var cloned_ret: std.ArrayListUnmanaged([]const u8) = .empty;
            for (ret.columns) |col| {
                try cloned_ret.append(self.allocator, try self.allocator.dupe(u8, col));
            }
            returning_columns = try cloned_ret.toOwnedSlice(self.allocator);
        }

        try steps.append(self.allocator, ExecutionStep{
            .Delete = DeleteStep{
                .table_name = try self.allocator.dupe(u8, delete.table),
                .condition = condition,
                .returning_columns = returning_columns,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan transaction statement
    fn planTransaction(self: *Self, trans: *const ast.TransactionStatement) !ExecutionPlan {
        _ = trans;
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        try steps.append(self.allocator, ExecutionStep{
            .BeginTransaction = {},
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan commit statement
    fn planCommit(self: *Self, trans: *const ast.TransactionStatement) !ExecutionPlan {
        _ = trans;
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        try steps.append(self.allocator, ExecutionStep{
            .Commit = {},
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan rollback statement
    fn planRollback(self: *Self, trans: *const ast.TransactionStatement) !ExecutionPlan {
        _ = trans;
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        try steps.append(self.allocator, ExecutionStep{
            .Rollback = {},
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan create index statement
    fn planCreateIndex(self: *Self, create_idx: *const ast.CreateIndexStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        // Clone columns
        var columns = try self.allocator.alloc([]const u8, create_idx.columns.len);
        for (create_idx.columns, 0..) |col, i| {
            columns[i] = try self.allocator.dupe(u8, col);
        }

        try steps.append(self.allocator, ExecutionStep{
            .CreateIndex = CreateIndexStep{
                .index_name = try self.allocator.dupe(u8, create_idx.index_name),
                .table_name = try self.allocator.dupe(u8, create_idx.table_name),
                .columns = columns,
                .unique = create_idx.unique,
                .if_not_exists = create_idx.if_not_exists,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan drop index statement
    fn planDropIndex(self: *Self, drop_idx: *const ast.DropIndexStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        try steps.append(self.allocator, ExecutionStep{
            .DropIndex = DropIndexStep{
                .index_name = try self.allocator.dupe(u8, drop_idx.index_name),
                .if_exists = drop_idx.if_exists,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan drop table statement
    fn planDropTable(self: *Self, drop_tbl: *const ast.DropTableStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        try steps.append(self.allocator, ExecutionStep{
            .DropTable = DropTableStep{
                .table_name = try self.allocator.dupe(u8, drop_tbl.table_name),
                .if_exists = drop_tbl.if_exists,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Clone a condition (deep copy)
    fn cloneCondition(self: *Self, condition: *const ast.Condition) !ast.Condition {
        return switch (condition.*) {
            .Comparison => |*comp| ast.Condition{
                .Comparison = ast.ComparisonCondition{
                    .left = try self.cloneExpression(comp.left),
                    .operator = comp.operator,
                    .right = try self.cloneExpression(comp.right),
                    .extra = if (comp.extra) |extra| try self.cloneExpression(extra) else null,
                },
            },
            .Logical => |*logical| {
                const left_ptr = try self.allocator.create(ast.Condition);
                left_ptr.* = try self.cloneCondition(logical.left);

                const right_ptr = try self.allocator.create(ast.Condition);
                right_ptr.* = try self.cloneCondition(logical.right);

                return ast.Condition{
                    .Logical = ast.LogicalCondition{
                        .left = left_ptr,
                        .operator = logical.operator,
                        .right = right_ptr,
                    },
                };
            },
        };
    }

    /// Clone an expression (handles columns, literals, parameters, binary ops, subqueries, and IN lists)
    fn cloneExpression(self: *Self, expr: ast.Expression) !ast.Expression {
        return switch (expr) {
            .Column => |col| ast.Expression{ .Column = try self.allocator.dupe(u8, col) },
            .Literal => |value| ast.Expression{ .Literal = try self.cloneAstValue(value) },
            .Parameter => |param_index| ast.Expression{ .Parameter = param_index },
            .BinaryOp => |bin| blk: {
                const left_ptr = try self.allocator.create(ast.Expression);
                left_ptr.* = try self.cloneExpression(bin.left.*);

                const right_ptr = try self.allocator.create(ast.Expression);
                right_ptr.* = try self.cloneExpression(bin.right.*);

                break :blk ast.Expression{
                    .BinaryOp = ast.BinaryExpr{
                        .left = left_ptr,
                        .op = bin.op,
                        .right = right_ptr,
                    },
                };
            },
            .Subquery => |subquery| blk: {
                const cloned_subquery = try self.allocator.create(ast.SelectStatement);
                cloned_subquery.* = try self.cloneSelectStatement(subquery.*);
                break :blk ast.Expression{ .Subquery = cloned_subquery };
            },
            .InList => |list| blk: {
                var cloned_list = try self.allocator.alloc(ast.Value, list.len);
                for (list, 0..) |val, i| {
                    cloned_list[i] = try self.cloneAstValue(val);
                }
                break :blk ast.Expression{ .InList = cloned_list };
            },
        };
    }

    /// Clone a SelectStatement (for subqueries)
    pub fn cloneSelectStatement(self: *Self, stmt: ast.SelectStatement) anyerror!ast.SelectStatement {
        // Clone columns
        var cloned_columns = try self.allocator.alloc(ast.Column, stmt.columns.len);
        for (stmt.columns, 0..) |col, i| {
            cloned_columns[i] = ast.Column{
                .name = try self.allocator.dupe(u8, col.name),
                .expression = try self.cloneColumnExpression(col.expression),
                .alias = if (col.alias) |a| try self.allocator.dupe(u8, a) else null,
            };
        }

        // Clone table name
        const cloned_table: ?[]const u8 = if (stmt.table) |t| try self.allocator.dupe(u8, t) else null;

        // Clone joins
        var cloned_joins = try self.allocator.alloc(ast.JoinClause, stmt.joins.len);
        for (stmt.joins, 0..) |join, i| {
            cloned_joins[i] = ast.JoinClause{
                .join_type = join.join_type,
                .table = try self.allocator.dupe(u8, join.table),
                .condition = try self.cloneCondition(&join.condition),
            };
        }

        // Clone where clause
        const cloned_where: ?ast.WhereClause = if (stmt.where_clause) |where|
            ast.WhereClause{ .condition = try self.cloneCondition(&where.condition) }
        else
            null;

        // Clone group by
        var cloned_group_by: ?[][]const u8 = null;
        if (stmt.group_by) |group_by| {
            var cols = try self.allocator.alloc([]const u8, group_by.len);
            for (group_by, 0..) |col, i| {
                cols[i] = try self.allocator.dupe(u8, col);
            }
            cloned_group_by = cols;
        }

        // Clone having clause
        const cloned_having: ?ast.WhereClause = if (stmt.having) |having|
            ast.WhereClause{ .condition = try self.cloneCondition(&having.condition) }
        else
            null;

        // Clone order by
        var cloned_order_by: ?[]ast.OrderByClause = null;
        if (stmt.order_by) |order_by| {
            var clauses = try self.allocator.alloc(ast.OrderByClause, order_by.len);
            for (order_by, 0..) |clause, i| {
                clauses[i] = ast.OrderByClause{
                    .column = try self.allocator.dupe(u8, clause.column),
                    .direction = clause.direction,
                };
            }
            cloned_order_by = clauses;
        }

        return ast.SelectStatement{
            .columns = cloned_columns,
            .table = cloned_table,
            .joins = cloned_joins,
            .where_clause = cloned_where,
            .group_by = cloned_group_by,
            .having = cloned_having,
            .order_by = cloned_order_by,
            .limit = stmt.limit,
            .offset = stmt.offset,
            .window_definitions = null, // TODO: Clone window definitions if needed
            .distinct = stmt.distinct,
        };
    }

    /// Clone a ColumnExpression
    fn cloneColumnExpression(self: *Self, expr: ast.ColumnExpression) !ast.ColumnExpression {
        return switch (expr) {
            .Simple => |name| ast.ColumnExpression{ .Simple = try self.allocator.dupe(u8, name) },
            .Aggregate => |agg| ast.ColumnExpression{
                .Aggregate = ast.AggregateFunction{
                    .function_type = agg.function_type,
                    .column = if (agg.column) |col| try self.allocator.dupe(u8, col) else null,
                },
            },
            .Window => |window| ast.ColumnExpression{ .Window = try self.cloneWindowFunction(window) },
            .FunctionCall => |func| ast.ColumnExpression{ .FunctionCall = try self.cloneFunctionCall(func) },
            .Case => |case_expr| ast.ColumnExpression{ .Case = try self.cloneCaseExpression(case_expr) },
        };
    }

    /// Clone a value from AST to storage
    fn cloneValue(self: *Self, value: ast.Value) !storage.Value {
        const ast_storage_value = switch (value) {
            .Integer => |i| storage.Value{ .Integer = i },
            .Text => |t| storage.Value{ .Text = t }, // Don't duplicate here, let clone handle it
            .Real => |r| storage.Value{ .Real = r },
            .Blob => |b| storage.Value{ .Blob = b }, // Don't duplicate here, let clone handle it
            .Null => storage.Value.Null,
            .Parameter => |param_index| storage.Value{ .Parameter = param_index },
            .FunctionCall => |function_call| {
                // Convert function call to storage representation as FunctionCall placeholder
                // This will be evaluated at runtime by the VM
                const storage_func = try self.convertAstFunctionToStorage(function_call);
                return storage.Value{ .FunctionCall = storage_func };
            },
            .Case => {
                // CASE expressions in INSERT VALUES are not yet supported
                // They are typically used in SELECT expressions which are handled by the VM
                return error.CaseNotSupportedInInsert;
            },
        };
        return ast_storage_value.clone(self.allocator);
    }

    /// Clone a default value (preserving FunctionCall for VM evaluation)
    fn cloneDefaultValue(self: *Self, default_value: ast.DefaultValue) !ast.DefaultValue {
        return switch (default_value) {
            .Literal => |literal| ast.DefaultValue{ .Literal = try self.cloneAstValue(literal) },
            .FunctionCall => |function_call| ast.DefaultValue{ .FunctionCall = try self.cloneFunctionCall(function_call) },
        };
    }

    /// Clone a function call
    fn cloneFunctionCall(self: *Self, function_call: ast.FunctionCall) anyerror!ast.FunctionCall {
        var cloned_args = try self.allocator.alloc(ast.FunctionArgument, function_call.arguments.len);
        for (function_call.arguments, 0..) |arg, i| {
            cloned_args[i] = try self.cloneFunctionArgument(arg);
        }

        return ast.FunctionCall{
            .name = try self.allocator.dupe(u8, function_call.name),
            .arguments = cloned_args,
        };
    }

    /// Clone a function argument
    fn cloneFunctionArgument(self: *Self, arg: ast.FunctionArgument) anyerror!ast.FunctionArgument {
        return switch (arg) {
            .Literal => |literal| ast.FunctionArgument{ .Literal = try self.cloneAstValue(literal) },
            .String => |string| ast.FunctionArgument{ .String = try self.allocator.dupe(u8, string) },
            .Column => |column| ast.FunctionArgument{ .Column = try self.allocator.dupe(u8, column) },
            .Parameter => |param_index| ast.FunctionArgument{ .Parameter = param_index },
        };
    }

    /// Clone a window function
    fn cloneWindowFunction(self: *Self, window_func: ast.WindowFunction) anyerror!ast.WindowFunction {
        // Clone arguments
        var cloned_args = try self.allocator.alloc(ast.FunctionArgument, window_func.arguments.len);
        for (window_func.arguments, 0..) |arg, i| {
            cloned_args[i] = try self.cloneFunctionArgument(arg);
        }

        // Clone window specification
        const cloned_spec = try self.cloneWindowSpecification(window_func.window_spec);

        return ast.WindowFunction{
            .function_type = window_func.function_type,
            .arguments = cloned_args,
            .window_spec = cloned_spec,
        };
    }

    /// Clone a window specification
    fn cloneWindowSpecification(self: *Self, spec: ast.WindowSpecification) anyerror!ast.WindowSpecification {
        // Clone window_name
        const cloned_name: ?[]const u8 = if (spec.window_name) |name|
            try self.allocator.dupe(u8, name)
        else
            null;

        // Clone partition_by
        var cloned_partition_by: ?[][]const u8 = null;
        if (spec.partition_by) |partition_by| {
            var cols = try self.allocator.alloc([]const u8, partition_by.len);
            for (partition_by, 0..) |col, i| {
                cols[i] = try self.allocator.dupe(u8, col);
            }
            cloned_partition_by = cols;
        }

        // Clone order_by
        var cloned_order_by: ?[]ast.OrderByClause = null;
        if (spec.order_by) |order_by| {
            var clauses = try self.allocator.alloc(ast.OrderByClause, order_by.len);
            for (order_by, 0..) |clause, i| {
                clauses[i] = ast.OrderByClause{
                    .column = try self.allocator.dupe(u8, clause.column),
                    .direction = clause.direction,
                };
            }
            cloned_order_by = clauses;
        }

        // Clone frame clause (simple copy since it has no dynamic memory)
        const cloned_frame: ?ast.FrameClause = if (spec.frame_clause) |frame|
            frame
        else
            null;

        return ast.WindowSpecification{
            .window_name = cloned_name,
            .partition_by = cloned_partition_by,
            .order_by = cloned_order_by,
            .frame_clause = cloned_frame,
        };
    }

    /// Convert AST default value to storage default value
    fn convertAstDefaultToStorage(self: *Self, default_value: ast.DefaultValue) !storage.Column.DefaultValue {
        return switch (default_value) {
            .Literal => |literal| {
                const storage_value = try self.cloneValue(literal);
                return storage.Column.DefaultValue{ .Literal = storage_value };
            },
            .FunctionCall => |function_call| {
                const storage_func = try self.convertAstFunctionToStorage(function_call);
                return storage.Column.DefaultValue{ .FunctionCall = storage_func };
            },
        };
    }

    /// Convert AST function call to storage function call
    fn convertAstFunctionToStorage(self: *Self, function_call: ast.FunctionCall) !storage.Column.FunctionCall {
        var storage_args = try self.allocator.alloc(storage.Column.FunctionArgument, function_call.arguments.len);
        for (function_call.arguments, 0..) |arg, i| {
            storage_args[i] = try self.convertAstFunctionArgToStorage(arg);
        }

        return storage.Column.FunctionCall{
            .name = try self.allocator.dupe(u8, function_call.name),
            .arguments = storage_args,
        };
    }

    /// Convert AST function argument to storage function argument
    fn convertAstFunctionArgToStorage(self: *Self, arg: ast.FunctionArgument) anyerror!storage.Column.FunctionArgument {
        return switch (arg) {
            .Literal => |literal| {
                const storage_value = try self.cloneValue(literal);
                return storage.Column.FunctionArgument{ .Literal = storage_value };
            },
            .String => |string| {
                // Convert string to Text literal using proper clone
                const text_value = storage.Value{ .Text = string };
                const cloned_value = try text_value.clone(self.allocator);
                return storage.Column.FunctionArgument{ .Literal = cloned_value };
            },
            .Column => |column| {
                return storage.Column.FunctionArgument{ .Column = try self.allocator.dupe(u8, column) };
            },
            .Parameter => |param_index| {
                return storage.Column.FunctionArgument{ .Parameter = param_index };
            },
        };
    }

    /// Clone an AST value (different from storage value)
    fn cloneAstValue(self: *Self, value: ast.Value) anyerror!ast.Value {
        return switch (value) {
            .Integer => |i| ast.Value{ .Integer = i },
            .Text => |t| ast.Value{ .Text = try self.allocator.dupe(u8, t) },
            .Real => |r| ast.Value{ .Real = r },
            .Blob => |b| ast.Value{ .Blob = try self.allocator.dupe(u8, b) },
            .Null => ast.Value.Null,
            .Parameter => |param_index| ast.Value{ .Parameter = param_index },
            .FunctionCall => |function_call| ast.Value{ .FunctionCall = try self.cloneFunctionCall(function_call) },
            .Case => |case_expr| ast.Value{ .Case = try self.cloneCaseExpression(case_expr) },
        };
    }

    /// Clone a CASE expression
    fn cloneCaseExpression(self: *Self, case_expr: ast.CaseExpression) anyerror!ast.CaseExpression {
        var cloned_branches = try self.allocator.alloc(ast.CaseWhenBranch, case_expr.branches.len);
        for (case_expr.branches, 0..) |branch, i| {
            const cloned_condition = try self.allocator.create(ast.Condition);
            cloned_condition.* = try self.cloneCondition(branch.condition);
            cloned_branches[i] = ast.CaseWhenBranch{
                .condition = cloned_condition,
                .result = try self.cloneAstValue(branch.result),
            };
        }

        var cloned_else: ?*ast.Value = null;
        if (case_expr.else_result) |else_val| {
            cloned_else = try self.allocator.create(ast.Value);
            cloned_else.?.* = try self.cloneAstValue(else_val.*);
        }

        var cloned_operand: ?*ast.Value = null;
        if (case_expr.operand) |op| {
            cloned_operand = try self.allocator.create(ast.Value);
            cloned_operand.?.* = try self.cloneAstValue(op.*);
        }

        return ast.CaseExpression{
            .operand = cloned_operand,
            .branches = cloned_branches,
            .else_result = cloned_else,
        };
    }

    /// Plan PRAGMA statement execution
    fn planPragma(self: *Self, pragma: *const ast.PragmaStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        try steps.append(self.allocator, ExecutionStep{
            .Pragma = PragmaStep{
                .name = try self.allocator.dupe(u8, pragma.name),
                .argument = if (pragma.argument) |arg| try self.allocator.dupe(u8, arg) else null,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan ATTACH DATABASE statement
    fn planAttach(self: *Self, attach: *const ast.AttachStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        try steps.append(self.allocator, ExecutionStep{
            .Attach = AttachStep{
                .file_path = try self.allocator.dupe(u8, attach.file_path),
                .schema_name = try self.allocator.dupe(u8, attach.schema_name),
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan DETACH DATABASE statement
    fn planDetach(self: *Self, detach: *const ast.DetachStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        try steps.append(self.allocator, ExecutionStep{
            .Detach = DetachStep{
                .schema_name = try self.allocator.dupe(u8, detach.schema_name),
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan CREATE VIRTUAL TABLE statement (FTS5)
    fn planCreateVirtualTable(self: *Self, create_vt: *const ast.CreateVirtualTableStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        // Duplicate column names
        var columns = try self.allocator.alloc([]const u8, create_vt.columns.len);
        for (create_vt.columns, 0..) |col, i| {
            columns[i] = try self.allocator.dupe(u8, col);
        }

        try steps.append(self.allocator, ExecutionStep{
            .CreateVirtualTable = CreateVirtualTableStep{
                .table_name = try self.allocator.dupe(u8, create_vt.table_name),
                .module_name = try self.allocator.dupe(u8, create_vt.module_name),
                .columns = columns,
                .if_not_exists = create_vt.if_not_exists,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan EXPLAIN / EXPLAIN QUERY PLAN statement
    fn planExplain(self: *Self, explain: *const ast.ExplainStatement) anyerror!ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        // First, plan the inner statement to get its execution steps
        const inner_plan = try self.plan(explain.inner_statement);
        defer {
            // Free the inner plan's step array since we're copying the steps
            self.allocator.free(inner_plan.steps);
        }

        // Copy inner steps for the explain step
        var inner_steps = try self.allocator.alloc(ExecutionStep, inner_plan.steps.len);
        for (inner_plan.steps, 0..) |step, i| {
            inner_steps[i] = step;
        }

        try steps.append(self.allocator, ExecutionStep{
            .Explain = ExplainStep{
                .is_query_plan = explain.is_query_plan,
                .inner_steps = inner_steps,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan Common Table Expression (WITH clause) execution
    /// CTEs are executed first, their results stored, then the main query references them
    fn planWith(self: *Self, with: *const ast.WithStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        // First, plan and create execution steps for each CTE definition
        // CTEs are executed in order and can reference previously defined CTEs
        for (with.cte_definitions) |cte_def| {
            // Plan the CTE's subquery
            const cte_plan = try self.planSelect(&cte_def.query);
            defer {
                // Free the plan's step array but not the steps themselves
                // since we're moving them into the CTE step
                self.allocator.free(cte_plan.steps);
            }

            // Clone column names if provided
            var column_names: ?[][]const u8 = null;
            if (cte_def.column_names) |cols| {
                var cloned_cols: std.ArrayListUnmanaged([]const u8) = .empty;
                for (cols) |col| {
                    try cloned_cols.append(self.allocator, try self.allocator.dupe(u8, col));
                }
                column_names = try cloned_cols.toOwnedSlice(self.allocator);
            }

            // Create the CTE step
            try steps.append(self.allocator, ExecutionStep{
                .CreateCTE = CreateCTEStep{
                    .name = try self.allocator.dupe(u8, cte_def.name),
                    .subquery_steps = try self.allocator.dupe(ExecutionStep, cte_plan.steps),
                    .column_names = column_names,
                    .recursive = with.recursive,
                },
            });
        }

        // Now plan the main query - it can reference the CTEs by name
        const main_plan = try self.planSelect(&with.main_query);

        // Append main query steps
        for (main_plan.steps) |step| {
            try steps.append(self.allocator, step);
        }

        // Don't free main_plan.steps since we've moved them
        self.allocator.free(main_plan.steps);

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Plan compound SELECT (UNION/INTERSECT/EXCEPT)
    fn planCompoundSelect(self: *Self, compound: *const ast.CompoundSelectStatement) !ExecutionPlan {
        var steps: std.ArrayListUnmanaged(ExecutionStep) = .empty;

        // Plan the left SELECT
        const left_plan = try self.planSelect(compound.left);
        defer self.allocator.free(left_plan.steps);

        // Plan the right statement (could be SELECT or another CompoundSelect)
        const right_plan = try self.plan(compound.right);
        defer self.allocator.free(right_plan.steps);

        // Clone order_by if present
        var order_by: ?[]ast.OrderByClause = null;
        if (compound.order_by) |orig_order_by| {
            var cloned_order: std.ArrayListUnmanaged(ast.OrderByClause) = .empty;
            for (orig_order_by) |clause| {
                try cloned_order.append(self.allocator, ast.OrderByClause{
                    .column = try self.allocator.dupe(u8, clause.column),
                    .direction = clause.direction,
                });
            }
            order_by = try cloned_order.toOwnedSlice(self.allocator);
        }

        // Create the SetOperation step
        try steps.append(self.allocator, ExecutionStep{
            .SetOperation = SetOperationStep{
                .operation = compound.operation,
                .left_steps = try self.allocator.dupe(ExecutionStep, left_plan.steps),
                .right_steps = try self.allocator.dupe(ExecutionStep, right_plan.steps),
                .order_by = order_by,
                .limit = compound.limit,
                .offset = compound.offset,
            },
        });

        return ExecutionPlan{
            .steps = try steps.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }
};

/// Execution plan containing steps to execute
pub const ExecutionPlan = struct {
    steps: []ExecutionStep,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExecutionPlan) void {
        for (self.steps) |*step| {
            step.deinit(self.allocator);
        }
        self.allocator.free(self.steps);
    }
};

/// Individual execution steps
pub const ExecutionStep = union(enum) {
    TableScan: TableScanStep,
    IndexScan: IndexScanStep, // Index-based lookup (query optimizer)
    Filter: FilterStep,
    Project: ProjectStep,
    Limit: LimitStep,
    Insert: InsertStep,
    CreateTable: CreateTableStep,
    Update: UpdateStep,
    Delete: DeleteStep,
    NestedLoopJoin: NestedLoopJoinStep,
    HashJoin: HashJoinStep,
    Aggregate: AggregateStep,
    GroupBy: GroupByStep,
    BeginTransaction,
    Commit,
    Rollback,
    CreateIndex: CreateIndexStep,
    DropIndex: DropIndexStep,
    DropTable: DropTableStep,
    CreateCTE: CreateCTEStep, // Common Table Expression support
    Pragma: PragmaStep, // PRAGMA statements for introspection
    Explain: ExplainStep, // EXPLAIN / EXPLAIN QUERY PLAN
    SetOperation: SetOperationStep, // UNION/INTERSECT/EXCEPT
    Window: WindowStep, // Window functions (ROW_NUMBER, RANK, etc.)
    Having: HavingStep, // HAVING clause (filter after GROUP BY)
    Distinct, // SELECT DISTINCT (remove duplicate rows)
    Attach: AttachStep, // ATTACH DATABASE
    Detach: DetachStep, // DETACH DATABASE
    CreateVirtualTable: CreateVirtualTableStep, // CREATE VIRTUAL TABLE (FTS5)

    pub fn deinit(self: *ExecutionStep, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .TableScan => |*step| step.deinit(allocator),
            .IndexScan => |*step| step.deinit(allocator),
            .Filter => |*step| step.deinit(allocator),
            .Project => |*step| step.deinit(allocator),
            .Limit => {},
            .Insert => |*step| step.deinit(allocator),
            .CreateTable => |*step| step.deinit(allocator),
            .Update => |*step| step.deinit(allocator),
            .Delete => |*step| step.deinit(allocator),
            .NestedLoopJoin => |*step| step.deinit(allocator),
            .HashJoin => |*step| step.deinit(allocator),
            .Aggregate => |*step| step.deinit(allocator),
            .GroupBy => |*step| step.deinit(allocator),
            .BeginTransaction => {},
            .Commit => {},
            .Rollback => {},
            .CreateIndex => |*step| step.deinit(allocator),
            .DropIndex => |*step| step.deinit(allocator),
            .DropTable => |*step| step.deinit(allocator),
            .CreateCTE => |*step| step.deinit(allocator),
            .Pragma => |*step| step.deinit(allocator),
            .Explain => |*step| step.deinit(allocator),
            .SetOperation => |*step| step.deinit(allocator),
            .Window => |*step| step.deinit(allocator),
            .Having => |*step| step.deinit(allocator),
            .Distinct => {},
            .Attach => |*step| step.deinit(allocator),
            .Detach => |*step| step.deinit(allocator),
            .CreateVirtualTable => |*step| step.deinit(allocator),
        }
    }
};

/// Table scan step
pub const TableScanStep = struct {
    table_name: []const u8,

    pub fn deinit(self: *TableScanStep, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
    }
};

/// Index scan step (query optimizer - uses index for WHERE clause)
pub const IndexScanStep = struct {
    table_name: []const u8,
    index_name: []const u8,
    column_name: []const u8,
    lookup_value: storage.Value, // The value to look up in the index

    pub fn deinit(self: *IndexScanStep, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        allocator.free(self.index_name);
        allocator.free(self.column_name);
        self.lookup_value.deinit(allocator);
    }
};

/// Filter step (WHERE clause)
pub const FilterStep = struct {
    condition: ast.Condition,

    pub fn deinit(self: *FilterStep, allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
    }
};

/// Having step (HAVING clause - filter after GROUP BY)
pub const HavingStep = struct {
    condition: ast.Condition,

    pub fn deinit(self: *HavingStep, allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
    }
};

/// Projection step (SELECT columns)
pub const ProjectStep = struct {
    columns: [][]const u8,
    expressions: ?[]ast.ColumnExpression, // Optional column expressions (for CASE, etc.)

    pub fn deinit(self: *ProjectStep, allocator: std.mem.Allocator) void {
        for (self.columns) |column| {
            allocator.free(column);
        }
        allocator.free(self.columns);

        if (self.expressions) |exprs| {
            for (exprs) |*expr| {
                @constCast(expr).deinit(allocator);
            }
            allocator.free(exprs);
        }
    }
};

/// Limit step
pub const LimitStep = struct {
    count: u32,
    offset: u32,
};

/// On conflict action for UPSERT
pub const OnConflictAction = union(enum) {
    DoNothing: void,
    DoUpdate: struct {
        assignments: []UpdateAssignment,
        condition: ?ast.Condition,
    },

    pub fn deinit(self: *OnConflictAction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .DoUpdate => |*update| {
                for (update.assignments) |*assignment| {
                    @constCast(assignment).deinit(allocator);
                }
                allocator.free(update.assignments);
                if (update.condition) |*cond| {
                    cond.deinit(allocator);
                }
            },
            .DoNothing => {},
        }
    }
};

/// Insert step
pub const InsertStep = struct {
    table_name: []const u8,
    columns: ?[][]const u8,
    values: [][]storage.Value,
    on_conflict: ?OnConflictAction,
    returning_columns: ?[][]const u8,

    pub fn deinit(self: *InsertStep, allocator: std.mem.Allocator) void {
        // Free table name
        allocator.free(self.table_name);

        // Free columns if they exist
        if (self.columns) |cols| {
            for (cols) |col| {
                allocator.free(col);
            }
            allocator.free(cols);
        }

        // Free values properly
        for (self.values) |row| {
            // Each row is an owned slice of Values
            for (row) |value| {
                value.deinit(allocator);
            }
            // Free the row array itself
            allocator.free(row);
        }
        // Free the values array
        allocator.free(self.values);

        // Free on_conflict
        if (self.on_conflict) |*oc| {
            oc.deinit(allocator);
        }

        // Free returning columns
        if (self.returning_columns) |cols| {
            for (cols) |col| {
                allocator.free(col);
            }
            allocator.free(cols);
        }
    }
};

/// Create table step
pub const CreateTableStep = struct {
    table_name: []const u8,
    columns: []storage.Column,
    if_not_exists: bool,

    pub fn deinit(self: *CreateTableStep, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        for (self.columns) |column| {
            allocator.free(column.name);
            if (column.default_value) |default_value| {
                default_value.deinit(allocator);
            }
        }
        allocator.free(self.columns);
    }
};

/// Update step
pub const UpdateStep = struct {
    table_name: []const u8,
    assignments: []UpdateAssignment,
    condition: ?ast.Condition,
    returning_columns: ?[][]const u8,

    pub fn deinit(self: *UpdateStep, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        for (self.assignments) |*assignment| {
            @constCast(assignment).deinit(allocator);
        }
        allocator.free(self.assignments);
        if (self.condition) |*cond| {
            cond.deinit(allocator);
        }
        if (self.returning_columns) |cols| {
            for (cols) |col| {
                allocator.free(col);
            }
            allocator.free(cols);
        }
    }
};

/// Delete step
pub const DeleteStep = struct {
    table_name: []const u8,
    condition: ?ast.Condition,
    returning_columns: ?[][]const u8,

    pub fn deinit(self: *DeleteStep, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        if (self.condition) |*cond| {
            cond.deinit(allocator);
        }
        if (self.returning_columns) |cols| {
            for (cols) |col| {
                allocator.free(col);
            }
            allocator.free(cols);
        }
    }
};

/// Create index step
pub const CreateIndexStep = struct {
    index_name: []const u8,
    table_name: []const u8,
    columns: [][]const u8,
    unique: bool,
    if_not_exists: bool,

    pub fn deinit(self: *CreateIndexStep, allocator: std.mem.Allocator) void {
        allocator.free(self.index_name);
        allocator.free(self.table_name);
        for (self.columns) |col| {
            allocator.free(col);
        }
        allocator.free(self.columns);
    }
};

/// Drop index step
pub const DropIndexStep = struct {
    index_name: []const u8,
    if_exists: bool,

    pub fn deinit(self: *DropIndexStep, allocator: std.mem.Allocator) void {
        allocator.free(self.index_name);
    }
};

/// Drop table step
pub const DropTableStep = struct {
    table_name: []const u8,
    if_exists: bool,

    pub fn deinit(self: *DropTableStep, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
    }
};

/// Update assignment
pub const UpdateAssignment = struct {
    column: []const u8,
    expr: ast.Expression, // Can be literal, column reference, or arithmetic expression

    pub fn deinit(self: *UpdateAssignment, allocator: std.mem.Allocator) void {
        allocator.free(self.column);
        @constCast(&self.expr).deinit(allocator);
    }
};

/// Nested loop join step (for small tables or when no indexes available)
pub const NestedLoopJoinStep = struct {
    join_type: ast.JoinType,
    left_table: []const u8,
    right_table: []const u8,
    condition: ast.Condition,

    pub fn deinit(self: *NestedLoopJoinStep, allocator: std.mem.Allocator) void {
        allocator.free(self.left_table);
        allocator.free(self.right_table);
        self.condition.deinit(allocator);
    }
};

/// Hash join step (for larger tables with equi-join conditions)
pub const HashJoinStep = struct {
    join_type: ast.JoinType,
    left_table: []const u8,
    right_table: []const u8,
    left_key_column: []const u8,
    right_key_column: []const u8,
    condition: ast.Condition,

    pub fn deinit(self: *HashJoinStep, allocator: std.mem.Allocator) void {
        allocator.free(self.left_table);
        allocator.free(self.right_table);
        allocator.free(self.left_key_column);
        allocator.free(self.right_key_column);
        self.condition.deinit(allocator);
    }
};

/// Aggregate step (for aggregate functions without GROUP BY)
pub const AggregateStep = struct {
    aggregates: []AggregateOperation,

    pub fn deinit(self: *AggregateStep, allocator: std.mem.Allocator) void {
        for (self.aggregates) |*agg| {
            agg.deinit(allocator);
        }
        allocator.free(self.aggregates);
    }
};

/// Group by step (for aggregate functions with GROUP BY)
pub const GroupByStep = struct {
    group_columns: [][]const u8,
    aggregates: []AggregateOperation,

    pub fn deinit(self: *GroupByStep, allocator: std.mem.Allocator) void {
        for (self.group_columns) |col| {
            allocator.free(col);
        }
        allocator.free(self.group_columns);

        for (self.aggregates) |*agg| {
            agg.deinit(allocator);
        }
        allocator.free(self.aggregates);
    }
};

/// Aggregate operation definition
pub const AggregateOperation = struct {
    function_type: ast.AggregateFunctionType,
    column: ?[]const u8, // NULL for COUNT(*)
    alias: ?[]const u8,

    pub fn deinit(self: *AggregateOperation, allocator: std.mem.Allocator) void {
        if (self.column) |col| {
            allocator.free(col);
        }
        if (self.alias) |alias| {
            allocator.free(alias);
        }
    }
};

/// CTE creation step - defines a temporary named result set
pub const CreateCTEStep = struct {
    /// Name of the CTE (used to reference it in the main query)
    name: []const u8,
    /// Execution steps for the CTE's subquery
    subquery_steps: []ExecutionStep,
    /// Optional column names for the CTE result
    column_names: ?[][]const u8,
    /// Whether this is part of a recursive CTE
    recursive: bool,

    pub fn deinit(self: *CreateCTEStep, allocator: std.mem.Allocator) void {
        allocator.free(self.name);

        // Free subquery steps
        for (self.subquery_steps) |*step| {
            step.deinit(allocator);
        }
        allocator.free(self.subquery_steps);

        // Free column names if present
        if (self.column_names) |cols| {
            for (cols) |col| {
                allocator.free(col);
            }
            allocator.free(cols);
        }
    }
};

/// PRAGMA step - executes PRAGMA commands for database introspection
pub const PragmaStep = struct {
    /// PRAGMA name (e.g., "table_info", "database_list")
    name: []const u8,
    /// Optional argument (e.g., table name for table_info)
    argument: ?[]const u8,

    pub fn deinit(self: *PragmaStep, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.argument) |arg| {
            allocator.free(arg);
        }
    }
};

/// EXPLAIN step - returns query plan without executing
pub const ExplainStep = struct {
    /// true for EXPLAIN QUERY PLAN, false for just EXPLAIN
    is_query_plan: bool,
    /// The execution steps that would be executed
    inner_steps: []ExecutionStep,

    pub fn deinit(self: *ExplainStep, allocator: std.mem.Allocator) void {
        for (self.inner_steps) |*step| {
            step.deinit(allocator);
        }
        allocator.free(self.inner_steps);
    }
};

/// ATTACH DATABASE step
pub const AttachStep = struct {
    /// Path to the database file
    file_path: []const u8,
    /// Schema name (alias) for the attached database
    schema_name: []const u8,

    pub fn deinit(self: *AttachStep, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.schema_name);
    }
};

/// DETACH DATABASE step
pub const DetachStep = struct {
    /// Schema name to detach
    schema_name: []const u8,

    pub fn deinit(self: *DetachStep, allocator: std.mem.Allocator) void {
        allocator.free(self.schema_name);
    }
};

/// CREATE VIRTUAL TABLE step (FTS5)
pub const CreateVirtualTableStep = struct {
    /// Table name
    table_name: []const u8,
    /// Module name (e.g., "fts5")
    module_name: []const u8,
    /// Column names to index
    columns: [][]const u8,
    /// IF NOT EXISTS flag
    if_not_exists: bool,

    pub fn deinit(self: *CreateVirtualTableStep, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        allocator.free(self.module_name);
        for (self.columns) |col| {
            allocator.free(col);
        }
        allocator.free(self.columns);
    }
};

/// Set operation step - UNION/INTERSECT/EXCEPT
pub const SetOperationStep = struct {
    /// The set operation type
    operation: ast.SetOperation,
    /// Execution steps for the left side
    left_steps: []ExecutionStep,
    /// Execution steps for the right side
    right_steps: []ExecutionStep,
    /// Optional ORDER BY columns
    order_by: ?[]ast.OrderByClause,
    /// Optional LIMIT
    limit: ?u32,
    /// Optional OFFSET
    offset: ?u32,

    pub fn deinit(self: *SetOperationStep, allocator: std.mem.Allocator) void {
        for (self.left_steps) |*step| {
            step.deinit(allocator);
        }
        allocator.free(self.left_steps);

        for (self.right_steps) |*step| {
            step.deinit(allocator);
        }
        allocator.free(self.right_steps);

        if (self.order_by) |order_by| {
            for (order_by) |clause| {
                allocator.free(clause.column);
            }
            allocator.free(order_by);
        }
    }
};

/// Window function step - applies window functions to result set
pub const WindowStep = struct {
    /// Window functions to apply
    window_functions: []ast.WindowFunction,
    /// Column names for result mapping (window function output names)
    column_names: [][]const u8,
    /// Projected column names (input columns that ORDER BY can reference)
    projected_columns: [][]const u8,

    pub fn deinit(self: *WindowStep, allocator: std.mem.Allocator) void {
        for (self.window_functions) |*wf| {
            wf.deinit(allocator);
        }
        allocator.free(self.window_functions);

        for (self.column_names) |col| {
            allocator.free(col);
        }
        allocator.free(self.column_names);

        for (self.projected_columns) |col| {
            allocator.free(col);
        }
        allocator.free(self.projected_columns);
    }
};

test "planner creation" {
    const allocator = std.testing.allocator;
    const planner = Planner.init(allocator);
    _ = planner; // Suppress unused variable warning
    try std.testing.expect(true);
}
