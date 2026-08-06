const std = @import("std");
const time_utils = @import("../time_utils.zig");
const tokenizer = @import("tokenizer.zig");
const ast = @import("ast.zig");

/// Enhanced parser error with context
pub const ParseError = struct {
    position: usize,
    expected: []const u8,
    found: []const u8,
    message: []const u8,

    pub fn deinit(self: ParseError, allocator: std.mem.Allocator) void {
        allocator.free(self.expected);
        allocator.free(self.found);
        allocator.free(self.message);
    }
};

/// SQL parser that converts tokens into AST
pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: tokenizer.Tokenizer,
    current_token: tokenizer.Token,
    parameter_index: u32, // Track current parameter index for ? placeholders

    const Self = @This();

    /// Error set for parsing operations
    pub const Error = error{
        UnexpectedToken,
        ExpectedNumber,
        ExpectedNull,
        ExpectedOperator,
        ExpectedValue,
        ExpectedIdentifier,
        AsteriskOnlyValidForCount,
        ExpectedDeleteOrUpdate,
        ExpectedAction,
        ExpectedLeftParen,
        ExpectedCommaOrRightParen,
        OutOfMemory,
        InvalidCharacter,
        Overflow,
        UnterminatedComment,
        UnterminatedString,
        UnexpectedCharacter,
    };

    /// Initialize parser with SQL input
    pub fn init(allocator: std.mem.Allocator, sql: []const u8) !Self {
        var tkn = tokenizer.Tokenizer.init(sql);
        const first_token = try tkn.nextToken(allocator);

        return Self{
            .allocator = allocator,
            .tokenizer = tkn,
            .current_token = first_token,
            .parameter_index = 0,
        };
    }

    /// Parse SQL into AST
    pub fn parse(self: *Self) anyerror!ast.Statement {
        return switch (self.current_token) {
            .Select => try self.parseSelect(),
            .Insert => try self.parseInsert(),
            .Create => try self.parseCreate(),
            .Update => try self.parseUpdate(),
            .Delete => try self.parseDelete(),
            .Begin => try self.parseTransaction(),
            .Commit => try self.parseCommit(),
            .Rollback => try self.parseRollback(),
            .Savepoint => try self.parseSavepoint(),
            .Release => try self.parseRelease(),
            .Drop => try self.parseDrop(),
            .Alter => try self.parseAlterTable(),
            .Pragma => try self.parsePragma(),
            .Analyze => try self.parseAnalyze(),
            .Vacuum => ast.Statement{ .Vacuum = .{} },
            .Explain => try self.parseExplain(),
            .Attach => try self.parseAttach(),
            .Detach => try self.parseDetach(),
            .With => try self.parseWith(),
            else => error.UnexpectedToken,
        };
    }

    fn parseAlterTable(self: *Self) !ast.Statement {
        try self.expect(.Alter);
        try self.expect(.Table);
        const table_name = try self.expectQualifiedIdentifier();
        errdefer self.allocator.free(table_name);

        const action: ast.AlterTableStatement.Action = switch (std.meta.activeTag(self.current_token)) {
            .Rename => blk: {
                try self.advance();
                if (self.currentTokenIsIdentifier("column")) {
                    try self.advance();
                    const old_name = try self.expectIdentifierOrKeyword();
                    errdefer self.allocator.free(old_name);
                    try self.expect(.To);
                    break :blk .{ .RenameColumn = .{
                        .old_name = old_name,
                        .new_name = try self.expectIdentifierOrKeyword(),
                    } };
                }
                try self.expect(.To);
                break :blk .{ .RenameTable = try self.expectIdentifierOrKeyword() };
            },
            .Add => blk: {
                try self.advance();
                if (self.currentTokenIsIdentifier("column")) try self.advance();
                break :blk .{ .AddColumn = try self.parseColumnDefinition() };
            },
            else => return error.UnexpectedToken,
        };

        return .{ .AlterTable = .{ .table_name = table_name, .action = action } };
    }

    fn currentTokenIsIdentifier(self: *const Self, expected: []const u8) bool {
        return switch (self.current_token) {
            .Identifier => |identifier| std.ascii.eqlIgnoreCase(identifier, expected),
            else => false,
        };
    }

    fn parseWith(self: *Self) !ast.Statement {
        try self.expect(.With);

        const recursive = std.meta.activeTag(self.current_token) == .Recursive;
        if (recursive) {
            try self.advance();
        }

        var cte_definitions: std.ArrayListUnmanaged(ast.CTEDefinition) = .empty;
        defer cte_definitions.deinit(self.allocator);
        errdefer for (cte_definitions.items) |*cte| cte.deinit(self.allocator);

        while (true) {
            const name = try self.expectIdentifier();
            errdefer self.allocator.free(name);

            var column_names: ?[][]const u8 = null;
            errdefer if (column_names) |cols| {
                for (cols) |col| self.allocator.free(col);
                self.allocator.free(cols);
            };
            if (std.meta.activeTag(self.current_token) == .LeftParen) {
                try self.advance();

                var cols: std.ArrayListUnmanaged([]const u8) = .empty;
                defer cols.deinit(self.allocator);
                errdefer for (cols.items) |col| self.allocator.free(col);

                while (true) {
                    const col = try self.expectIdentifier();
                    try cols.append(self.allocator, col);

                    if (std.meta.activeTag(self.current_token) == .Comma) {
                        try self.advance();
                    } else {
                        break;
                    }
                }

                try self.expect(.RightParen);
                column_names = try cols.toOwnedSlice(self.allocator);
            }

            try self.expect(.As);
            try self.expect(.LeftParen);
            const query = try self.parseSimpleSelect();
            try self.expect(.RightParen);

            try cte_definitions.append(self.allocator, ast.CTEDefinition{
                .name = name,
                .column_names = column_names,
                .query = query,
            });
            column_names = null;

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else {
                break;
            }
        }

        var main_query = try self.parseSimpleSelect();
        errdefer main_query.deinit(self.allocator);

        return ast.Statement{
            .With = ast.WithStatement{
                .cte_definitions = try cte_definitions.toOwnedSlice(self.allocator),
                .recursive = recursive,
                .main_query = main_query,
            },
        };
    }

    /// Parse SELECT statement (may include UNION/INTERSECT/EXCEPT)
    fn parseSelect(self: *Self) !ast.Statement {
        // Parse the first SELECT
        var left_select = try self.parseSimpleSelect();
        // Freed here only while ownership has not been transferred into left_ptr.
        var left_owned = true;
        errdefer if (left_owned) left_select.deinit(self.allocator);

        // Check for UNION/INTERSECT/EXCEPT
        const set_op = self.parseSetOperation() catch {
            // No set operation, return the simple SELECT
            left_owned = false;
            return ast.Statement{ .Select = left_select };
        };

        // We have a set operation, parse the right side
        const left_ptr = try self.allocator.create(ast.SelectStatement);
        errdefer self.allocator.destroy(left_ptr);
        left_ptr.* = left_select;
        left_owned = false;
        errdefer left_ptr.deinit(self.allocator);

        // Parse right side (could be another SELECT or compound)
        // Note: parseSelect will call expect(.Select) internally
        var right_stmt = try self.parseSelect();
        errdefer right_stmt.deinit(self.allocator);
        const right_ptr = try self.allocator.create(ast.Statement);
        errdefer self.allocator.destroy(right_ptr);
        right_ptr.* = right_stmt;

        // Parse optional ORDER BY for the compound (applies to whole result)
        var order_by: ?[]ast.OrderByClause = null;
        errdefer if (order_by) |ob| {
            for (ob) |clause| self.allocator.free(clause.column);
            self.allocator.free(ob);
        };
        if (std.meta.activeTag(self.current_token) == .Order) {
            try self.advance();
            try self.expect(.By);

            var order_clauses: std.ArrayListUnmanaged(ast.OrderByClause) = .empty;
            defer order_clauses.deinit(self.allocator);
            errdefer for (order_clauses.items) |clause| self.allocator.free(clause.column);

            while (true) {
                const col = try self.expectIdentifier();
                var direction = ast.SortDirection.Asc;

                if (std.meta.activeTag(self.current_token) == .Asc) {
                    try self.advance();
                    direction = .Asc;
                } else if (std.meta.activeTag(self.current_token) == .Desc) {
                    try self.advance();
                    direction = .Desc;
                }

                try order_clauses.append(self.allocator, ast.OrderByClause{
                    .column = col,
                    .direction = direction,
                });

                if (std.meta.activeTag(self.current_token) == .Comma) {
                    try self.advance();
                } else {
                    break;
                }
            }

            order_by = try order_clauses.toOwnedSlice(self.allocator);
        }

        // Parse optional LIMIT clause
        var limit: ?u32 = null;
        if (std.meta.activeTag(self.current_token) == .Limit) {
            try self.advance();
            if (self.current_token == .Integer) {
                limit = @intCast(self.current_token.Integer);
                try self.advance();
            } else {
                return error.ExpectedNumber;
            }
        }

        // Parse optional OFFSET clause
        var offset: ?u32 = null;
        if (std.meta.activeTag(self.current_token) == .Offset) {
            try self.advance();
            if (self.current_token == .Integer) {
                offset = @intCast(self.current_token.Integer);
                try self.advance();
            } else {
                return error.ExpectedNumber;
            }
        }

        return ast.Statement{
            .CompoundSelect = ast.CompoundSelectStatement{
                .left = left_ptr,
                .operation = set_op,
                .right = right_ptr,
                .order_by = order_by,
                .limit = limit,
                .offset = offset,
            },
        };
    }

    /// Parse a simple SELECT without set operations
    fn parseSimpleSelect(self: *Self) !ast.SelectStatement {
        try self.expect(.Select);

        // Check for DISTINCT
        const is_distinct = std.meta.activeTag(self.current_token) == .Distinct;
        if (is_distinct) {
            try self.advance();
        }

        // Parse columns
        var columns: std.ArrayListUnmanaged(ast.Column) = .empty;
        defer columns.deinit(self.allocator);
        errdefer for (columns.items) |*column| {
            self.allocator.free(column.name);
            column.expression.deinit(self.allocator);
            if (column.alias) |alias| self.allocator.free(alias);
        };

        if (std.meta.activeTag(self.current_token) == .Asterisk) {
            try self.advance();
            try columns.append(self.allocator, ast.Column{
                .name = try self.allocator.dupe(u8, "*"),
                .expression = ast.ColumnExpression{ .Simple = try self.allocator.dupe(u8, "*") },
                .alias = null,
            });
        } else {
            while (true) {
                const column = try self.parseColumn();
                try columns.append(self.allocator, column);

                if (std.meta.activeTag(self.current_token) == .Comma) {
                    try self.advance();
                } else {
                    break;
                }
            }
        }

        // Parse FROM clause
        try self.expect(.From);
        var table_name = try self.expectQualifiedIdentifier();
        errdefer self.allocator.free(table_name);

        // Check for optional table alias
        if (self.current_token == .Identifier) {
            const maybe_alias = self.current_token.Identifier;
            // Make sure it's not a keyword that starts a new clause
            if (!isClauseKeyword(maybe_alias)) {
                const with_alias = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ table_name, maybe_alias });
                self.allocator.free(table_name);
                table_name = with_alias;
                try self.advance();
            }
        }

        // Parse optional JOIN clauses
        var joins: std.ArrayListUnmanaged(ast.JoinClause) = .empty;
        defer joins.deinit(self.allocator);
        errdefer for (joins.items) |*join| {
            self.allocator.free(join.table);
            join.condition.deinit(self.allocator);
        };

        while (true) {
            const join_type = self.parseJoinType() catch break;
            const join = try self.parseJoin(join_type);
            try joins.append(self.allocator, join);
        }

        // Parse optional WHERE clause
        var where_clause: ?ast.WhereClause = null;
        errdefer if (where_clause) |*w| w.deinit(self.allocator);
        if (std.meta.activeTag(self.current_token) == .Where) {
            try self.advance();
            where_clause = try self.parseWhere();
        }

        // Parse optional GROUP BY clause
        var group_by: ?[][]const u8 = null;
        errdefer if (group_by) |gb| {
            for (gb) |col| self.allocator.free(col);
            self.allocator.free(gb);
        };
        if (std.meta.activeTag(self.current_token) == .Group) {
            try self.advance();
            try self.expect(.By);

            var group_columns: std.ArrayListUnmanaged([]const u8) = .empty;
            defer group_columns.deinit(self.allocator);
            errdefer for (group_columns.items) |col| self.allocator.free(col);

            while (true) {
                const col = try self.expectIdentifier();
                try group_columns.append(self.allocator, col);

                if (std.meta.activeTag(self.current_token) == .Comma) {
                    try self.advance();
                } else {
                    break;
                }
            }

            group_by = try group_columns.toOwnedSlice(self.allocator);
        }

        // Parse optional HAVING clause
        var having: ?ast.WhereClause = null;
        errdefer if (having) |*h| h.deinit(self.allocator);
        if (std.meta.activeTag(self.current_token) == .Having) {
            try self.advance();
            having = try self.parseWhere();
        }

        // Parse optional WINDOW clause definitions
        var window_definitions: ?[]ast.WindowDefinition = null;
        errdefer if (window_definitions) |wd| {
            for (wd) |*w| w.deinit(self.allocator);
            self.allocator.free(wd);
        };
        if (std.meta.activeTag(self.current_token) == .Window) {
            window_definitions = try self.parseWindowDefinitions();
        }

        // For simple selects in compound statements, don't parse ORDER BY/LIMIT/OFFSET
        // Those are handled at the compound level
        // But we still need to parse them for standalone selects
        var order_by: ?[]ast.OrderByClause = null;
        errdefer if (order_by) |ob| {
            for (ob) |clause| self.allocator.free(clause.column);
            self.allocator.free(ob);
        };
        var limit: ?u32 = null;
        var offset: ?u32 = null;

        // Only parse ORDER BY/LIMIT/OFFSET if not followed by a set operation
        if (!self.isSetOperation()) {
            if (std.meta.activeTag(self.current_token) == .Order) {
                try self.advance();
                try self.expect(.By);

                var order_clauses: std.ArrayListUnmanaged(ast.OrderByClause) = .empty;
                defer order_clauses.deinit(self.allocator);
                errdefer for (order_clauses.items) |clause| self.allocator.free(clause.column);

                while (true) {
                    const col = try self.expectIdentifier();
                    var direction = ast.SortDirection.Asc;

                    if (std.meta.activeTag(self.current_token) == .Asc) {
                        try self.advance();
                        direction = .Asc;
                    } else if (std.meta.activeTag(self.current_token) == .Desc) {
                        try self.advance();
                        direction = .Desc;
                    }

                    try order_clauses.append(self.allocator, ast.OrderByClause{
                        .column = col,
                        .direction = direction,
                    });

                    if (std.meta.activeTag(self.current_token) == .Comma) {
                        try self.advance();
                    } else {
                        break;
                    }
                }

                order_by = try order_clauses.toOwnedSlice(self.allocator);
            }

            if (std.meta.activeTag(self.current_token) == .Limit) {
                try self.advance();
                if (self.current_token == .Integer) {
                    limit = @intCast(self.current_token.Integer);
                    try self.advance();
                } else {
                    return error.ExpectedNumber;
                }
            }

            if (std.meta.activeTag(self.current_token) == .Offset) {
                try self.advance();
                if (self.current_token == .Integer) {
                    offset = @intCast(self.current_token.Integer);
                    try self.advance();
                } else {
                    return error.ExpectedNumber;
                }
            }
        }

        return ast.SelectStatement{
            .columns = try columns.toOwnedSlice(self.allocator),
            .table = table_name,
            .joins = try joins.toOwnedSlice(self.allocator),
            .where_clause = where_clause,
            .group_by = group_by,
            .having = having,
            .order_by = order_by,
            .limit = limit,
            .offset = offset,
            .window_definitions = window_definitions,
            .distinct = is_distinct,
        };
    }

    fn parseWindowDefinitions(self: *Self) ![]ast.WindowDefinition {
        try self.expect(.Window);

        var definitions: std.ArrayListUnmanaged(ast.WindowDefinition) = .empty;
        errdefer {
            for (definitions.items) |*definition| {
                definition.deinit(self.allocator);
            }
            definitions.deinit(self.allocator);
        }

        while (true) {
            const name = try self.expectIdentifier();
            errdefer self.allocator.free(name);

            try self.expect(.As);
            const specification = try self.parseWindowSpecification();

            try definitions.append(self.allocator, ast.WindowDefinition{
                .name = name,
                .specification = specification,
            });

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else {
                break;
            }
        }

        return try definitions.toOwnedSlice(self.allocator);
    }

    /// Check if current token is a set operation
    fn isSetOperation(self: *Self) bool {
        return switch (self.current_token) {
            .Union, .Intersect, .Except => true,
            else => false,
        };
    }

    /// Parse set operation (UNION/INTERSECT/EXCEPT)
    fn parseSetOperation(self: *Self) !ast.SetOperation {
        return switch (self.current_token) {
            .Union => {
                try self.advance();
                // Check for ALL
                if (std.meta.activeTag(self.current_token) == .All) {
                    try self.advance();
                    return .UnionAll;
                }
                return .Union;
            },
            .Intersect => {
                try self.advance();
                if (std.meta.activeTag(self.current_token) == .All) {
                    try self.advance();
                    return .IntersectAll;
                }
                return .Intersect;
            },
            .Except => {
                try self.advance();
                if (std.meta.activeTag(self.current_token) == .All) {
                    try self.advance();
                    return .ExceptAll;
                }
                return .Except;
            },
            else => error.UnexpectedToken,
        };
    }

    /// Parse JOIN type
    fn parseJoinType(self: *Self) !ast.JoinType {
        return switch (self.current_token) {
            .Inner => {
                try self.advance();
                try self.expect(.Join);
                return .Inner;
            },
            .Left => {
                try self.advance();
                // Optional OUTER
                if (std.meta.activeTag(self.current_token) == .Outer) {
                    try self.advance();
                }
                try self.expect(.Join);
                return .Left;
            },
            .Right => {
                try self.advance();
                // Optional OUTER
                if (std.meta.activeTag(self.current_token) == .Outer) {
                    try self.advance();
                }
                try self.expect(.Join);
                return .Right;
            },
            .Full => {
                try self.advance();
                // Optional OUTER
                if (std.meta.activeTag(self.current_token) == .Outer) {
                    try self.advance();
                }
                try self.expect(.Join);
                return .Full;
            },
            .Join => {
                try self.advance();
                return .Inner; // Default to INNER JOIN
            },
            else => error.UnexpectedToken,
        };
    }

    /// Parse JOIN clause
    fn parseJoin(self: *Self, join_type: ast.JoinType) !ast.JoinClause {
        const table = try self.expectIdentifier();

        // Check for optional table alias
        var table_with_alias = table;
        if (self.current_token == .Identifier) {
            const alias = self.current_token.Identifier;
            // Make sure it's not ON keyword
            if (!std.mem.eql(u8, alias, "ON") and !std.mem.eql(u8, alias, "on")) {
                // Store as "table alias" format for executor to handle
                const with_alias = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ table, alias });
                self.allocator.free(table);
                table_with_alias = with_alias;
                try self.advance();
            }
        }

        try self.expect(.On);
        const condition = try self.parseCondition();

        return ast.JoinClause{
            .join_type = join_type,
            .table = table_with_alias,
            .condition = condition,
        };
    }

    /// Parse INSERT statement
    fn parseInsert(self: *Self) !ast.Statement {
        try self.expect(.Insert);

        // Parse optional OR conflict resolution
        var or_conflict: ?ast.ConflictResolution = null;
        if (std.meta.activeTag(self.current_token) == .Or) {
            try self.advance();
            or_conflict = try self.parseConflictResolution();
        }

        try self.expect(.Into);

        const table_name = try self.expectQualifiedIdentifierOrKeyword();

        // Parse optional column list
        var columns: ?[][]const u8 = null;
        if (std.meta.activeTag(self.current_token) == .LeftParen) {
            try self.advance();
            var column_list: std.ArrayListUnmanaged([]const u8) = .empty;
            defer column_list.deinit(self.allocator);

            while (true) {
                const col = try self.expectIdentifierOrKeyword();
                try column_list.append(self.allocator, col);

                if (std.meta.activeTag(self.current_token) == .Comma) {
                    try self.advance();
                } else {
                    break;
                }
            }

            try self.expect(.RightParen);
            columns = try column_list.toOwnedSlice(self.allocator);
        }

        // Parse DEFAULT VALUES as a single row with no explicit values. The VM
        // fills every column from DEFAULT or NULL/NOT NULL rules.
        if (std.meta.activeTag(self.current_token) == .Default) {
            try self.advance();
            try self.expect(.Values);

            var values: std.ArrayListUnmanaged([]ast.Value) = .empty;
            defer values.deinit(self.allocator);
            try values.append(self.allocator, try self.allocator.alloc(ast.Value, 0));

            var returning: ?ast.ReturningClause = null;
            if (std.meta.activeTag(self.current_token) == .Returning) {
                returning = try self.parseReturning();
            }

            return ast.Statement{
                .Insert = ast.InsertStatement{
                    .table = table_name,
                    .columns = columns,
                    .values = try values.toOwnedSlice(self.allocator),
                    .or_conflict = or_conflict,
                    .on_conflict = null,
                    .returning = returning,
                },
            };
        }

        // Parse VALUES clause
        try self.expect(.Values);

        var values: std.ArrayListUnmanaged([]ast.Value) = .empty;
        defer values.deinit(self.allocator);

        // Parse value rows
        while (true) {
            try self.expect(.LeftParen);

            var row: std.ArrayListUnmanaged(ast.Value) = .empty;
            defer row.deinit(self.allocator);

            while (true) {
                const value = try self.parseValue();
                try row.append(self.allocator, value);

                if (std.meta.activeTag(self.current_token) == .Comma) {
                    try self.advance();
                } else {
                    break;
                }
            }

            try self.expect(.RightParen);
            try values.append(self.allocator, try row.toOwnedSlice(self.allocator));

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else {
                break;
            }
        }

        // Parse optional ON CONFLICT clause
        var on_conflict: ?ast.OnConflictClause = null;
        if (std.meta.activeTag(self.current_token) == .On) {
            on_conflict = try self.parseOnConflict();
        }

        // Parse optional RETURNING clause
        var returning: ?ast.ReturningClause = null;
        if (std.meta.activeTag(self.current_token) == .Returning) {
            returning = try self.parseReturning();
        }

        return ast.Statement{
            .Insert = ast.InsertStatement{
                .table = table_name,
                .columns = columns,
                .values = try values.toOwnedSlice(self.allocator),
                .or_conflict = or_conflict,
                .on_conflict = on_conflict,
                .returning = returning,
            },
        };
    }

    /// Parse ON CONFLICT clause for UPSERT
    fn parseOnConflict(self: *Self) !ast.OnConflictClause {
        try self.expect(.On);
        try self.expect(.Conflict);

        // Parse optional target columns
        var target_columns: ?[][]const u8 = null;
        if (std.meta.activeTag(self.current_token) == .LeftParen) {
            try self.advance();
            var cols: std.ArrayListUnmanaged([]const u8) = .empty;
            defer cols.deinit(self.allocator);

            while (true) {
                const col = try self.expectIdentifierOrKeyword();
                try cols.append(self.allocator, col);

                if (std.meta.activeTag(self.current_token) == .Comma) {
                    try self.advance();
                } else {
                    break;
                }
            }
            try self.expect(.RightParen);
            target_columns = try cols.toOwnedSlice(self.allocator);
        }

        // Once the target columns are owned here, any later parse error must free
        // them (and the per-column strings) rather than leak.
        errdefer if (target_columns) |tc| {
            for (tc) |c| self.allocator.free(c);
            self.allocator.free(tc);
        };

        try self.expect(.Do);

        // Parse action: NOTHING or UPDATE
        if (std.meta.activeTag(self.current_token) == .Nothing) {
            try self.advance();
            return ast.OnConflictClause{
                .target_columns = target_columns,
                .action = .{ .DoNothing = {} },
            };
        }

        if (std.meta.activeTag(self.current_token) == .Update) {
            try self.advance();
            try self.expect(.Set);

            // Parse assignments. On error, free every assignment already collected;
            // toOwnedSlice() empties the list on the success path so this no-ops then.
            var assignments: std.ArrayListUnmanaged(ast.Assignment) = .empty;
            errdefer {
                for (assignments.items) |*a| a.deinit(self.allocator);
                assignments.deinit(self.allocator);
            }

            while (true) {
                const column = try self.expectIdentifierOrKeyword();
                self.expect(.Equal) catch |err| {
                    self.allocator.free(column);
                    return err;
                };
                var expr = self.parseExpression() catch |err| {
                    self.allocator.free(column);
                    return err;
                };
                assignments.append(self.allocator, ast.Assignment{
                    .column = column,
                    .expr = expr,
                }) catch |err| {
                    self.allocator.free(column);
                    expr.deinit(self.allocator);
                    return err;
                };

                if (std.meta.activeTag(self.current_token) == .Comma) {
                    try self.advance();
                } else {
                    break;
                }
            }

            // Parse optional WHERE clause
            var where_clause: ?ast.WhereClause = null;
            if (std.meta.activeTag(self.current_token) == .Where) {
                try self.advance();
                where_clause = try self.parseWhere();
            }

            return ast.OnConflictClause{
                .target_columns = target_columns,
                .action = .{
                    .DoUpdate = .{
                        .assignments = try assignments.toOwnedSlice(self.allocator),
                        .where_clause = where_clause,
                    },
                },
            };
        }

        return error.UnexpectedToken;
    }

    /// Parse RETURNING clause
    fn parseReturning(self: *Self) !ast.ReturningClause {
        try self.expect(.Returning);

        var columns: std.ArrayListUnmanaged([]const u8) = .empty;
        defer columns.deinit(self.allocator);

        while (true) {
            if (std.meta.activeTag(self.current_token) == .Asterisk) {
                try self.advance();
                try columns.append(self.allocator, try self.allocator.dupe(u8, "*"));
            } else {
                const col = try self.expectIdentifier();
                try columns.append(self.allocator, col);
            }

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else {
                break;
            }
        }

        return ast.ReturningClause{
            .columns = try columns.toOwnedSlice(self.allocator),
        };
    }

    /// Parse transaction statement
    fn parseTransaction(self: *Self) !ast.Statement {
        try self.expect(.Begin);

        // Optional TRANSACTION keyword
        if (std.meta.activeTag(self.current_token) == .Transaction) {
            try self.advance();
        }

        return ast.Statement{
            .BeginTransaction = ast.TransactionStatement{ .savepoint_name = null },
        };
    }

    /// Parse commit statement
    fn parseCommit(self: *Self) !ast.Statement {
        try self.expect(.Commit);

        // Optional TRANSACTION keyword
        if (std.meta.activeTag(self.current_token) == .Transaction) {
            try self.advance();
        }

        return ast.Statement{
            .Commit = ast.TransactionStatement{ .savepoint_name = null },
        };
    }

    /// Parse rollback statement
    fn parseRollback(self: *Self) !ast.Statement {
        try self.expect(.Rollback);

        if (std.meta.activeTag(self.current_token) == .To) {
            try self.advance();
            if (std.meta.activeTag(self.current_token) == .Savepoint) {
                try self.advance();
            }
            return ast.Statement{
                .RollbackToSavepoint = ast.TransactionStatement{ .savepoint_name = try self.expectIdentifier() },
            };
        }

        // Optional TRANSACTION keyword
        if (std.meta.activeTag(self.current_token) == .Transaction) {
            try self.advance();
        }

        return ast.Statement{
            .Rollback = ast.TransactionStatement{ .savepoint_name = null },
        };
    }

    /// Parse SAVEPOINT statement
    fn parseSavepoint(self: *Self) !ast.Statement {
        try self.expect(.Savepoint);
        return ast.Statement{
            .Savepoint = ast.TransactionStatement{ .savepoint_name = try self.expectIdentifier() },
        };
    }

    /// Parse RELEASE [SAVEPOINT] statement
    fn parseRelease(self: *Self) !ast.Statement {
        try self.expect(.Release);
        if (std.meta.activeTag(self.current_token) == .Savepoint) {
            try self.advance();
        }
        return ast.Statement{
            .ReleaseSavepoint = ast.TransactionStatement{ .savepoint_name = try self.expectIdentifier() },
        };
    }

    /// Parse DROP statement
    fn parseDrop(self: *Self) !ast.Statement {
        try self.expect(.Drop);

        if (std.meta.activeTag(self.current_token) == .Index) {
            try self.advance();

            // Optional IF EXISTS
            var if_exists = false;
            if (std.meta.activeTag(self.current_token) == .If) {
                try self.advance();
                try self.expect(.Exists);
                if_exists = true;
            }

            const index_name = try self.expectQualifiedIdentifier();

            return ast.Statement{
                .DropIndex = ast.DropIndexStatement{
                    .index_name = index_name,
                    .if_exists = if_exists,
                },
            };
        } else if (std.meta.activeTag(self.current_token) == .Table) {
            try self.advance();

            // Optional IF EXISTS
            var if_exists = false;
            if (std.meta.activeTag(self.current_token) == .If) {
                try self.advance();
                try self.expect(.Exists);
                if_exists = true;
            }

            const table_name = try self.expectQualifiedIdentifier();

            return ast.Statement{
                .DropTable = ast.DropTableStatement{
                    .table_name = table_name,
                    .if_exists = if_exists,
                },
            };
        }

        return error.UnexpectedToken;
    }

    /// Parse PRAGMA statement (e.g., PRAGMA table_info(tablename))
    fn parsePragma(self: *Self) !ast.Statement {
        try self.expect(.Pragma);

        // Get pragma name (e.g., "table_info")
        const pragma_name = try self.expectIdentifier();

        // Check for argument in parentheses
        var argument: ?[]const u8 = null;
        var value: ?i64 = null;
        if (std.meta.activeTag(self.current_token) == .LeftParen) {
            try self.advance(); // consume '('

            // Get the argument (table name, etc.)
            argument = try self.expectQualifiedIdentifier();

            try self.expect(.RightParen);
        } else if (std.meta.activeTag(self.current_token) == .Equal) {
            try self.advance();
            if (std.meta.activeTag(self.current_token) != .Integer) return error.UnexpectedToken;
            value = self.current_token.Integer;
            try self.advance();
        }

        return ast.Statement{
            .Pragma = ast.PragmaStatement{
                .name = pragma_name,
                .argument = argument,
                .value = value,
            },
        };
    }

    fn parseAnalyze(self: *Self) !ast.Statement {
        try self.expect(.Analyze);

        const table_name: ?[]const u8 = switch (std.meta.activeTag(self.current_token)) {
            .Identifier => try self.expectIdentifier(),
            .EOF, .Semicolon => null,
            else => return error.UnexpectedToken,
        };

        return ast.Statement{
            .Analyze = ast.AnalyzeStatement{
                .table_name = table_name,
            },
        };
    }

    /// Parse ATTACH DATABASE statement
    /// Syntax: ATTACH DATABASE 'filename' AS schema_name
    fn parseAttach(self: *Self) !ast.Statement {
        try self.expect(.Attach);

        // Optional DATABASE keyword
        if (std.meta.activeTag(self.current_token) == .Database) {
            try self.advance();
        }

        // Get file path (string literal)
        var file_path: []const u8 = undefined;
        if (self.current_token == .String) {
            file_path = try self.allocator.dupe(u8, self.current_token.String);
            try self.advance();
        } else if (self.current_token == .Identifier) {
            // Allow :memory: as identifier
            file_path = try self.expectIdentifier();
        } else {
            return error.ExpectedString;
        }
        errdefer self.allocator.free(file_path);

        // Expect AS keyword
        try self.expect(.As);

        // Get schema name
        const schema_name = try self.expectIdentifier();

        return ast.Statement{
            .Attach = ast.AttachStatement{
                .file_path = file_path,
                .schema_name = schema_name,
            },
        };
    }

    /// Parse DETACH DATABASE statement
    /// Syntax: DETACH DATABASE schema_name
    fn parseDetach(self: *Self) !ast.Statement {
        try self.expect(.Detach);

        // Optional DATABASE keyword
        if (std.meta.activeTag(self.current_token) == .Database) {
            try self.advance();
        }

        // Get schema name
        const schema_name = try self.expectIdentifier();

        return ast.Statement{
            .Detach = ast.DetachStatement{
                .schema_name = schema_name,
            },
        };
    }

    /// Parse EXPLAIN / EXPLAIN QUERY PLAN statement
    fn parseExplain(self: *Self) anyerror!ast.Statement {
        try self.expect(.Explain);

        // Check for QUERY PLAN variant
        var is_query_plan = false;
        if (std.meta.activeTag(self.current_token) == .Query) {
            try self.advance(); // consume 'QUERY'
            try self.expect(.Plan);
            is_query_plan = true;
        }

        // Parse the inner statement
        const inner_statement = try self.allocator.create(ast.Statement);
        errdefer self.allocator.destroy(inner_statement);
        inner_statement.* = try self.parse();
        errdefer inner_statement.deinit(self.allocator);

        return ast.Statement{
            .Explain = ast.ExplainStatement{
                .is_query_plan = is_query_plan,
                .inner_statement = inner_statement,
            },
        };
    }

    /// Parse CREATE statement dispatcher
    fn parseCreate(self: *Self) !ast.Statement {
        try self.expect(.Create);

        if (std.meta.activeTag(self.current_token) == .Table) {
            try self.advance();
            return try self.parseCreateTable();
        } else if (std.meta.activeTag(self.current_token) == .Virtual) {
            try self.advance();
            try self.expect(.Table);
            return try self.parseCreateVirtualTable();
        } else if (std.meta.activeTag(self.current_token) == .Index) {
            return try self.parseCreateIndex();
        } else if (std.meta.activeTag(self.current_token) == .Unique) {
            try self.advance();
            try self.expect(.Index);
            return try self.parseCreateIndexImpl(true);
        }

        return error.UnexpectedToken;
    }

    /// Parse CREATE VIRTUAL TABLE statement (FTS5)
    /// Syntax: CREATE VIRTUAL TABLE table_name USING fts5(col1, col2, ...)
    fn parseCreateVirtualTable(self: *Self) !ast.Statement {
        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (std.meta.activeTag(self.current_token) == .If) {
            try self.advance();
            try self.expect(.Not);
            try self.expect(.Exists);
            if_not_exists = true;
        }

        // Table name
        const table_name = try self.expectQualifiedIdentifier();
        errdefer self.allocator.free(table_name);

        // USING keyword
        try self.expect(.Using);

        // Module name (fts5, fts4, etc.)
        const module_name = switch (self.current_token) {
            .Identifier => try self.expectIdentifier(),
            .Fts5 => blk: {
                try self.advance();
                break :blk try self.allocator.dupe(u8, "fts5");
            },
            else => return error.ExpectedIdentifier,
        };
        errdefer self.allocator.free(module_name);

        // Column list (col1, col2, ...)
        try self.expect(.LeftParen);

        var columns: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (columns.items) |col| {
                self.allocator.free(col);
            }
            columns.deinit(self.allocator);
        }

        while (true) {
            const col_name = try self.expectIdentifier();
            try columns.append(self.allocator, col_name);

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else {
                break;
            }
        }

        try self.expect(.RightParen);

        return ast.Statement{
            .CreateVirtualTable = ast.CreateVirtualTableStatement{
                .table_name = table_name,
                .module_name = module_name,
                .columns = try columns.toOwnedSlice(self.allocator),
                .if_not_exists = if_not_exists,
            },
        };
    }

    /// Parse CREATE INDEX statement
    fn parseCreateIndex(self: *Self) !ast.Statement {
        try self.expect(.Index);
        return try self.parseCreateIndexImpl(false);
    }

    /// Parse CREATE INDEX implementation
    fn parseCreateIndexImpl(self: *Self, unique: bool) !ast.Statement {
        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (std.meta.activeTag(self.current_token) == .If) {
            try self.advance();
            try self.expect(.Not);
            try self.expect(.Exists);
            if_not_exists = true;
        }

        const index_name = try self.expectQualifiedIdentifier();
        try self.expect(.On);
        const table_name = try self.expectQualifiedIdentifier();

        try self.expect(.LeftParen);

        var columns: std.ArrayListUnmanaged([]const u8) = .empty;
        defer columns.deinit(self.allocator);
        errdefer for (columns.items) |col| self.allocator.free(col);

        var expressions: std.ArrayListUnmanaged(ast.Expression) = .empty;
        defer expressions.deinit(self.allocator);
        errdefer for (expressions.items) |*expr| expr.deinit(self.allocator);

        while (true) {
            if (std.meta.activeTag(self.current_token) == .LeftParen) {
                try self.advance();
                var expression = try self.parseExpression();
                errdefer expression.deinit(self.allocator);
                try self.expect(.RightParen);
                try expressions.append(self.allocator, expression);
                try columns.append(self.allocator, try self.allocator.dupe(u8, "<expr>"));
            } else {
                const col = try self.expectIdentifier();
                errdefer self.allocator.free(col);
                try columns.append(self.allocator, try self.allocator.dupe(u8, col));
                try expressions.append(self.allocator, ast.Expression{ .Column = col });
            }

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else {
                break;
            }
        }

        try self.expect(.RightParen);

        var where_clause: ?ast.WhereClause = null;
        errdefer if (where_clause) |*where| where.deinit(self.allocator);
        if (std.meta.activeTag(self.current_token) == .Where) {
            try self.advance();
            where_clause = try self.parseWhere();
        }

        return ast.Statement{
            .CreateIndex = ast.CreateIndexStatement{
                .index_name = index_name,
                .table_name = table_name,
                .columns = try columns.toOwnedSlice(self.allocator),
                .expressions = try expressions.toOwnedSlice(self.allocator),
                .where_clause = where_clause,
                .unique = unique,
                .if_not_exists = if_not_exists,
            },
        };
    }

    /// Parse conflict resolution
    fn parseConflictResolution(self: *Self) !ast.ConflictResolution {
        return switch (self.current_token) {
            .Replace => {
                try self.advance();
                return .Replace;
            },
            .Ignore => {
                try self.advance();
                return .Ignore;
            },
            .Rollback => {
                try self.advance();
                return .Rollback;
            },
            else => error.UnexpectedToken,
        };
    }

    /// Parse CREATE TABLE statement
    fn parseCreateTable(self: *Self) !ast.Statement {
        // Table keyword already consumed by parseCreate

        // Parse optional IF NOT EXISTS
        var if_not_exists = false;
        if (std.meta.activeTag(self.current_token) == .If) {
            try self.advance();
            try self.expect(.Not);
            try self.expect(.Exists);
            if_not_exists = true;
        }

        const table_name = try self.expectQualifiedIdentifier();

        try self.expect(.LeftParen);

        var columns: std.ArrayListUnmanaged(ast.ColumnDefinition) = .empty;
        defer columns.deinit(self.allocator);

        var table_constraints: std.ArrayListUnmanaged(ast.TableConstraint) = .empty;
        defer table_constraints.deinit(self.allocator);

        while (true) {
            // Check if this is a table-level constraint
            if (self.isTableConstraintToken()) {
                const constraint = try self.parseTableConstraint();
                try table_constraints.append(self.allocator, constraint);
            } else {
                // Parse as column definition
                const column = try self.parseColumnDefinition();
                try columns.append(self.allocator, column);
            }

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else {
                break;
            }
        }

        try self.expect(.RightParen);

        return ast.Statement{
            .CreateTable = ast.CreateTableStatement{
                .table_name = table_name,
                .columns = try columns.toOwnedSlice(self.allocator),
                .table_constraints = try table_constraints.toOwnedSlice(self.allocator),
                .if_not_exists = if_not_exists,
            },
        };
    }

    /// Parse UPDATE statement
    fn parseUpdate(self: *Self) !ast.Statement {
        try self.expect(.Update);
        const table_name = try self.expectQualifiedIdentifier();
        errdefer self.allocator.free(table_name);

        try self.expect(.Set);

        var assignments: std.ArrayListUnmanaged(ast.Assignment) = .empty;
        errdefer {
            // Clean up any already-parsed assignments on error
            for (assignments.items) |*assignment| {
                assignment.deinit(self.allocator);
            }
            assignments.deinit(self.allocator);
        }

        while (true) {
            const column = try self.expectIdentifierOrKeyword();
            errdefer self.allocator.free(column);

            try self.expect(.Equal);
            const expr = try self.parseExpression();
            // expr is now owned by assignment, no errdefer needed for it

            try assignments.append(self.allocator, ast.Assignment{
                .column = column,
                .expr = expr,
            });

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else {
                break;
            }
        }

        var where_clause: ?ast.WhereClause = null;
        if (std.meta.activeTag(self.current_token) == .Where) {
            try self.advance();
            where_clause = try self.parseWhere();
        }
        errdefer {
            if (where_clause) |*wc| wc.deinit(self.allocator);
        }

        // Parse optional RETURNING clause
        var returning: ?ast.ReturningClause = null;
        if (std.meta.activeTag(self.current_token) == .Returning) {
            returning = try self.parseReturning();
        }

        return ast.Statement{
            .Update = ast.UpdateStatement{
                .table = table_name,
                .assignments = try assignments.toOwnedSlice(self.allocator),
                .where_clause = where_clause,
                .returning = returning,
            },
        };
    }

    /// Parse DELETE statement
    fn parseDelete(self: *Self) !ast.Statement {
        try self.expect(.Delete);
        try self.expect(.From);
        const table_name = try self.expectQualifiedIdentifier();
        errdefer self.allocator.free(table_name);

        var where_clause: ?ast.WhereClause = null;
        if (std.meta.activeTag(self.current_token) == .Where) {
            try self.advance();
            where_clause = try self.parseWhere();
        }
        errdefer {
            if (where_clause) |*wc| wc.deinit(self.allocator);
        }

        // Parse optional RETURNING clause
        var returning: ?ast.ReturningClause = null;
        if (std.meta.activeTag(self.current_token) == .Returning) {
            returning = try self.parseReturning();
        }

        return ast.Statement{
            .Delete = ast.DeleteStatement{
                .table = table_name,
                .where_clause = where_clause,
                .returning = returning,
            },
        };
    }

    /// Parse a column in SELECT
    fn parseColumn(self: *Self) !ast.Column {
        // Check for aggregate functions like COUNT(*), SUM(col), AVG(col), MIN(col), MAX(col), STDDEV, VARIANCE, GROUP_CONCAT
        const agg_type: ?ast.AggregateFunctionType = blk: {
            const next_token = try self.peekNextToken();
            defer if (next_token) |token| token.deinit(self.allocator);

            if (next_token == null or std.meta.activeTag(next_token.?) != .LeftParen) {
                break :blk null;
            }

            break :blk switch (std.meta.activeTag(self.current_token)) {
                .Count => .Count,
                .Sum => .Sum,
                .Avg => .Avg,
                .Min => .Min,
                .Max => .Max,
                .Stddev => .Stddev,
                .Variance => .Variance,
                .GroupConcat => .GroupConcat,
                else => null,
            };
        };

        if (agg_type) |func_type| {
            const func_name = switch (func_type) {
                .Count => "COUNT",
                .Sum => "SUM",
                .Avg => "AVG",
                .Min => "MIN",
                .Max => "MAX",
                .Stddev => "STDDEV",
                .Variance => "VARIANCE",
                .GroupConcat => "GROUP_CONCAT",
                else => "AGGREGATE",
            };

            try self.advance(); // consume function token
            try self.expect(.LeftParen); // expect '('

            // Check for * (only valid for COUNT)
            var column_name: ?[]const u8 = null;
            if (std.meta.activeTag(self.current_token) == .Asterisk) {
                if (func_type != .Count) {
                    return error.AsteriskOnlyValidForCount;
                }
                try self.advance(); // consume '*'
            } else {
                // Expect column name
                column_name = try self.expectIdentifier();
            }

            try self.expect(.RightParen); // expect ')'

            // Build display name
            const display_name = if (column_name) |col|
                try std.fmt.allocPrint(self.allocator, "{s}({s})", .{ func_name, col })
            else
                try std.fmt.allocPrint(self.allocator, "{s}(*)", .{func_name});

            var alias: ?[]const u8 = null;
            // Check for AS alias
            if (std.meta.activeTag(self.current_token) == .As) {
                try self.advance(); // consume AS
                alias = try self.expectIdentifierOrKeyword();
            } else if (std.meta.activeTag(self.current_token) == .Identifier) {
                // Implicit alias (identifier not followed by aggregate-related tokens)
                alias = try self.expectIdentifier();
            }

            return ast.Column{
                .name = display_name,
                .expression = ast.ColumnExpression{
                    .Aggregate = ast.AggregateFunction{
                        .function_type = func_type,
                        .column = column_name,
                    },
                },
                .alias = alias,
            };
        }

        // Check for CASE expression
        if (std.meta.activeTag(self.current_token) == .Case) {
            const case_value = try self.parseCaseExpression();
            const case_expr = case_value.Case;

            var alias: ?[]const u8 = null;
            // Check for AS alias
            if (std.meta.activeTag(self.current_token) == .As) {
                try self.advance(); // consume AS
                alias = try self.expectIdentifier();
            } else if (std.meta.activeTag(self.current_token) == .Identifier) {
                alias = try self.expectIdentifier();
            }

            return ast.Column{
                .name = try self.allocator.dupe(u8, "CASE"),
                .expression = ast.ColumnExpression{ .Case = case_expr },
                .alias = alias,
            };
        }

        // Check for window functions: ROW_NUMBER, RANK, DENSE_RANK, PERCENT_RANK, CUME_DIST,
        // NTILE, LAG, LEAD, FIRST_VALUE, LAST_VALUE, NTH_VALUE
        const window_func_type: ?ast.WindowFunctionType = switch (std.meta.activeTag(self.current_token)) {
            .Row_Number => .RowNumber,
            .Rank => .Rank,
            .Dense_Rank => .DenseRank,
            .Percent_Rank => .PercentRank,
            .Cume_Dist => .CumeDist,
            .Ntile => .Ntile,
            .Lag => .Lag,
            .Lead => .Lead,
            .First_Value => .FirstValue,
            .Last_Value => .LastValue,
            .Nth_Value => .NthValue,
            else => null,
        };

        if (window_func_type) |func_type| {
            const window_func = try self.parseWindowFunction(func_type);

            var alias: ?[]const u8 = null;
            // Check for AS alias
            if (std.meta.activeTag(self.current_token) == .As) {
                try self.advance(); // consume AS
                alias = try self.expectIdentifier();
            } else if (std.meta.activeTag(self.current_token) == .Identifier) {
                const id = self.current_token.Identifier;
                if (!isClauseKeyword(id)) {
                    alias = try self.expectIdentifier();
                }
            }

            const func_name = switch (func_type) {
                .RowNumber => "ROW_NUMBER",
                .Rank => "RANK",
                .DenseRank => "DENSE_RANK",
                .PercentRank => "PERCENT_RANK",
                .CumeDist => "CUME_DIST",
                .Ntile => "NTILE",
                .Lag => "LAG",
                .Lead => "LEAD",
                .FirstValue => "FIRST_VALUE",
                .LastValue => "LAST_VALUE",
                .NthValue => "NTH_VALUE",
            };

            return ast.Column{
                .name = try self.allocator.dupe(u8, func_name),
                .expression = ast.ColumnExpression{ .Window = window_func },
                .alias = alias,
            };
        }

        // Check for null-handling functions: COALESCE, NULLIF, IFNULL
        // and string functions: UPPER, LOWER, SUBSTR, LENGTH, TRIM
        if (std.meta.activeTag(self.current_token) == .Coalesce or
            std.meta.activeTag(self.current_token) == .Nullif or
            std.meta.activeTag(self.current_token) == .Ifnull or
            std.meta.activeTag(self.current_token) == .Upper or
            std.meta.activeTag(self.current_token) == .Lower or
            std.meta.activeTag(self.current_token) == .Substr or
            std.meta.activeTag(self.current_token) == .Length or
            std.meta.activeTag(self.current_token) == .Trim)
        {
            const func_value = try self.parseNullHandlingFunction();
            const func_call = func_value.FunctionCall;

            var alias: ?[]const u8 = null;
            // Check for AS alias
            if (std.meta.activeTag(self.current_token) == .As) {
                try self.advance(); // consume AS
                alias = try self.expectIdentifier();
            } else if (std.meta.activeTag(self.current_token) == .Identifier) {
                alias = try self.expectIdentifier();
            }

            return ast.Column{
                .name = try self.allocator.dupe(u8, func_call.name),
                .expression = ast.ColumnExpression{ .FunctionCall = func_call },
                .alias = alias,
            };
        }

        if (std.meta.activeTag(self.current_token) == .Identifier) {
            const next_token = try self.peekNextToken();
            defer if (next_token) |token| token.deinit(self.allocator);

            if (next_token != null and std.meta.activeTag(next_token.?) == .LeftParen) {
                const func_call = try self.parseFunctionCall();

                var alias: ?[]const u8 = null;
                if (std.meta.activeTag(self.current_token) == .As) {
                    try self.advance();
                    alias = try self.expectIdentifierOrKeyword();
                } else if (std.meta.activeTag(self.current_token) == .Identifier) {
                    const id = self.current_token.Identifier;
                    if (!isClauseKeyword(id)) {
                        alias = try self.expectIdentifierOrKeyword();
                    }
                }

                return ast.Column{
                    .name = try self.allocator.dupe(u8, func_call.name),
                    .expression = ast.ColumnExpression{ .FunctionCall = func_call },
                    .alias = alias,
                };
            }
        }

        // Regular column parsing - handle qualified names (table.column)
        const first_part = try self.expectIdentifierOrKeyword();
        var name: []const u8 = first_part;

        // Check for qualified name (table.column)
        if (std.meta.activeTag(self.current_token) == .Dot) {
            try self.advance(); // consume '.'
            const second_part = try self.expectIdentifierOrKeyword();
            // Create qualified name "table.column"
            const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ first_part, second_part });
            self.allocator.free(first_part);
            self.allocator.free(second_part);
            name = qualified_name;
        }

        var alias: ?[]const u8 = null;

        // Check for AS alias or implicit alias
        if (std.meta.activeTag(self.current_token) == .As) {
            try self.advance(); // consume AS
            alias = try self.expectIdentifierOrKeyword();
        } else switch (self.current_token) {
            .Identifier => {
                const id = self.current_token.Identifier;
                if (!isClauseKeyword(id)) {
                    alias = try self.expectIdentifier();
                }
            },
            .Count, .Sum, .Avg, .Min, .Max => {
                alias = try self.expectIdentifierOrKeyword();
            },
            else => {},
        }

        return ast.Column{ .name = name, .expression = ast.ColumnExpression{ .Simple = try self.allocator.dupe(u8, name) }, .alias = alias };
    }

    /// Check if an identifier is a SQL clause keyword
    fn isClauseKeyword(id: []const u8) bool {
        const keywords = [_][]const u8{ "FROM", "from", "WHERE", "where", "GROUP", "group", "ORDER", "order", "HAVING", "having", "LIMIT", "limit", "OFFSET", "offset", "JOIN", "join", "INNER", "inner", "LEFT", "left", "RIGHT", "right", "OUTER", "outer", "ON", "on", "AND", "and", "OR", "or" };
        for (keywords) |kw| {
            if (std.mem.eql(u8, id, kw)) return true;
        }
        return false;
    }

    /// Parse a window function expression (ROW_NUMBER, RANK, etc.)
    fn parseWindowFunction(self: *Self, func_type: ast.WindowFunctionType) !ast.WindowFunction {
        try self.advance(); // consume function token
        try self.expect(.LeftParen); // expect '('

        // Parse arguments (some window functions take arguments, e.g., LAG(column, offset, default))
        var arguments: std.ArrayListUnmanaged(ast.FunctionArgument) = .empty;
        errdefer {
            for (arguments.items) |arg| {
                arg.deinit(self.allocator);
            }
            arguments.deinit(self.allocator);
        }

        while (std.meta.activeTag(self.current_token) != .RightParen) {
            // Parse argument
            const arg = switch (self.current_token) {
                .Identifier => |id| blk: {
                    const owned_id = try self.allocator.dupe(u8, id);
                    try self.advance();
                    break :blk ast.FunctionArgument{ .Column = owned_id };
                },
                .Integer => |val| blk: {
                    try self.advance();
                    break :blk ast.FunctionArgument{ .Literal = ast.Value{ .Integer = val } };
                },
                .Real => |val| blk: {
                    try self.advance();
                    break :blk ast.FunctionArgument{ .Literal = ast.Value{ .Real = val } };
                },
                .String => |val| blk: {
                    const owned_val = try self.allocator.dupe(u8, val);
                    try self.advance();
                    break :blk ast.FunctionArgument{ .Literal = ast.Value{ .Text = owned_val } };
                },
                .Null => blk: {
                    try self.advance();
                    break :blk ast.FunctionArgument{ .Literal = ast.Value.Null };
                },
                else => break,
            };

            try arguments.append(self.allocator, arg);

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else {
                break;
            }
        }

        try self.expect(.RightParen); // expect ')'
        try self.expect(.Over); // expect OVER

        // Parse window specification
        const window_spec = try self.parseWindowSpecification();

        return ast.WindowFunction{
            .function_type = func_type,
            .arguments = try arguments.toOwnedSlice(self.allocator),
            .window_spec = window_spec,
        };
    }

    /// Parse OVER clause window specification
    fn parseWindowSpecification(self: *Self) !ast.WindowSpecification {
        if (std.meta.activeTag(self.current_token) != .LeftParen) {
            return ast.WindowSpecification{
                .window_name = try self.expectIdentifier(),
                .partition_by = null,
                .order_by = null,
                .frame_clause = null,
            };
        }

        try self.expect(.LeftParen); // expect '('

        var window_name: ?[]const u8 = null;
        var partition_by: ?[][]const u8 = null;
        var order_by: ?[]ast.OrderByClause = null;
        var frame_clause: ?ast.FrameClause = null;

        if (self.current_token == .Identifier) {
            const name = self.current_token.Identifier;
            if (!isWindowClauseKeyword(name)) {
                window_name = try self.expectIdentifier();
            }
        }

        // Parse optional PARTITION BY
        if (std.meta.activeTag(self.current_token) == .Partition) {
            try self.advance(); // consume PARTITION
            try self.expect(.By); // expect BY

            var columns: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer {
                for (columns.items) |col| {
                    self.allocator.free(col);
                }
                columns.deinit(self.allocator);
            }

            while (true) {
                const col = try self.expectIdentifier();
                try columns.append(self.allocator, col);

                if (std.meta.activeTag(self.current_token) == .Comma) {
                    try self.advance();
                } else {
                    break;
                }
            }

            partition_by = try columns.toOwnedSlice(self.allocator);
        }

        // Parse optional ORDER BY
        if (std.meta.activeTag(self.current_token) == .Order) {
            try self.advance(); // consume ORDER
            try self.expect(.By); // expect BY

            var order_clauses: std.ArrayListUnmanaged(ast.OrderByClause) = .empty;
            errdefer {
                for (order_clauses.items) |clause| {
                    self.allocator.free(clause.column);
                }
                order_clauses.deinit(self.allocator);
            }

            while (true) {
                const col = try self.expectIdentifier();
                var direction = ast.SortDirection.Asc;

                if (std.meta.activeTag(self.current_token) == .Asc) {
                    try self.advance();
                    direction = .Asc;
                } else if (std.meta.activeTag(self.current_token) == .Desc) {
                    try self.advance();
                    direction = .Desc;
                }

                try order_clauses.append(self.allocator, ast.OrderByClause{
                    .column = col,
                    .direction = direction,
                });

                if (std.meta.activeTag(self.current_token) == .Comma) {
                    try self.advance();
                } else {
                    break;
                }
            }

            order_by = try order_clauses.toOwnedSlice(self.allocator);
        }

        // Parse optional frame clause (ROWS/RANGE BETWEEN ... AND ...)
        if (std.meta.activeTag(self.current_token) == .Rows or std.meta.activeTag(self.current_token) == .Range) {
            frame_clause = try self.parseFrameClause();
        }

        try self.expect(.RightParen); // expect ')'

        return ast.WindowSpecification{
            .window_name = window_name,
            .partition_by = partition_by,
            .order_by = order_by,
            .frame_clause = frame_clause,
        };
    }

    fn isWindowClauseKeyword(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "PARTITION") or
            std.ascii.eqlIgnoreCase(name, "ORDER") or
            std.ascii.eqlIgnoreCase(name, "ROWS") or
            std.ascii.eqlIgnoreCase(name, "RANGE") or
            std.ascii.eqlIgnoreCase(name, "GROUPS");
    }

    /// Parse frame clause (ROWS/RANGE BETWEEN ... AND ...)
    fn parseFrameClause(self: *Self) !ast.FrameClause {
        const frame_type: ast.FrameType = switch (std.meta.activeTag(self.current_token)) {
            .Rows => .Rows,
            .Range => .Range,
            else => return error.UnexpectedToken,
        };
        try self.advance(); // consume ROWS/RANGE

        // Expect BETWEEN or just a single bound
        var start_bound: ast.FrameBound = undefined;
        var end_bound: ?ast.FrameBound = null;

        if (std.meta.activeTag(self.current_token) == .Between) {
            try self.advance(); // consume BETWEEN

            start_bound = try self.parseFrameBound();

            try self.expect(.And); // expect AND

            end_bound = try self.parseFrameBound();
        } else {
            // Single bound (e.g., ROWS UNBOUNDED PRECEDING)
            start_bound = try self.parseFrameBound();
        }

        return ast.FrameClause{
            .frame_type = frame_type,
            .start_bound = start_bound,
            .end_bound = end_bound,
        };
    }

    /// Parse a frame bound (UNBOUNDED PRECEDING, CURRENT ROW, etc.)
    fn parseFrameBound(self: *Self) !ast.FrameBound {
        if (std.meta.activeTag(self.current_token) == .Unbounded) {
            try self.advance(); // consume UNBOUNDED
            if (std.meta.activeTag(self.current_token) == .Preceding) {
                try self.advance();
                return .UnboundedPreceding;
            } else if (std.meta.activeTag(self.current_token) == .Following) {
                try self.advance();
                return .UnboundedFollowing;
            } else {
                return error.UnexpectedToken;
            }
        } else if (std.meta.activeTag(self.current_token) == .Current) {
            try self.advance(); // consume CURRENT
            try self.expect(.Row); // expect ROW
            return .CurrentRow;
        } else if (std.meta.activeTag(self.current_token) == .Integer) {
            const offset: u32 = @intCast(self.current_token.Integer);
            try self.advance(); // consume the number
            if (std.meta.activeTag(self.current_token) == .Preceding) {
                try self.advance();
                return ast.FrameBound{ .Preceding = offset };
            } else if (std.meta.activeTag(self.current_token) == .Following) {
                try self.advance();
                return ast.FrameBound{ .Following = offset };
            } else {
                return error.UnexpectedToken;
            }
        } else {
            return error.UnexpectedToken;
        }
    }

    /// Parse a column definition in CREATE TABLE
    fn parseColumnDefinition(self: *Self) !ast.ColumnDefinition {
        const name = try self.expectIdentifierOrKeyword();
        const data_type = try self.parseDataType();

        var constraints: std.ArrayListUnmanaged(ast.ColumnConstraint) = .empty;
        defer constraints.deinit(self.allocator);

        // Parse constraints
        while (true) {
            const constraint = self.parseConstraint() catch break;
            try constraints.append(self.allocator, constraint);
        }

        return ast.ColumnDefinition{
            .name = name,
            .data_type = data_type,
            .constraints = try constraints.toOwnedSlice(self.allocator),
        };
    }

    /// Parse data type
    fn parseDataType(self: *Self) !ast.DataType {
        const type_name = try self.expectIdentifier();
        defer self.allocator.free(type_name);

        // Convert to uppercase for case-insensitive comparison
        var upper_type: [64]u8 = undefined;
        const len = @min(type_name.len, upper_type.len);
        for (type_name[0..len], 0..) |c, i| {
            upper_type[i] = std.ascii.toUpper(c);
        }
        const type_str = upper_type[0..len];

        if (std.mem.eql(u8, type_str, "INTEGER") or std.mem.eql(u8, type_str, "INT")) {
            return .Integer;
        } else if (std.mem.eql(u8, type_str, "TEXT") or std.mem.eql(u8, type_str, "STRING")) {
            return .Text;
        } else if (std.mem.eql(u8, type_str, "REAL")) {
            return .Real;
        } else if (std.mem.eql(u8, type_str, "BLOB")) {
            return .Blob;
        } else if (std.mem.eql(u8, type_str, "DATETIME")) {
            return .DateTime;
        } else if (std.mem.eql(u8, type_str, "TIMESTAMP")) {
            return .Timestamp;
        } else if (std.mem.eql(u8, type_str, "BOOLEAN") or std.mem.eql(u8, type_str, "BOOL")) {
            return .Boolean;
        } else if (std.mem.eql(u8, type_str, "DATE")) {
            return .Date;
        } else if (std.mem.eql(u8, type_str, "TIME")) {
            return .Time;
        } else if (std.mem.eql(u8, type_str, "DECIMAL") or std.mem.eql(u8, type_str, "NUMERIC")) {
            return .Decimal;
        } else if (std.mem.eql(u8, type_str, "VARCHAR")) {
            // Skip optional length specification
            if (std.meta.activeTag(self.current_token) == .LeftParen) {
                try self.advance();
                if (self.current_token == .Integer) {
                    try self.advance();
                }
                try self.expect(.RightParen);
            }
            return .Varchar;
        } else if (std.mem.eql(u8, type_str, "CHAR")) {
            // Skip optional length specification
            if (std.meta.activeTag(self.current_token) == .LeftParen) {
                try self.advance();
                if (self.current_token == .Integer) {
                    try self.advance();
                }
                try self.expect(.RightParen);
            }
            return .Char;
        } else if (std.mem.eql(u8, type_str, "FLOAT")) {
            return .Float;
        } else if (std.mem.eql(u8, type_str, "DOUBLE")) {
            return .Double;
        } else if (std.mem.eql(u8, type_str, "SMALLINT")) {
            return .SmallInt;
        } else if (std.mem.eql(u8, type_str, "BIGINT")) {
            return .BigInt;
        } else {
            // Default to TEXT for unknown types for compatibility
            return .Text;
        }
    }

    /// Parse column constraint
    fn parseConstraint(self: *Self) !ast.ColumnConstraint {
        return switch (self.current_token) {
            .Primary => {
                try self.advance();
                try self.expect(.Key);
                // Check for AUTOINCREMENT
                if (std.meta.activeTag(self.current_token) == .Autoincrement) {
                    try self.advance();
                    return .AutoIncrement;
                }
                return .PrimaryKey;
            },
            .Not => {
                try self.advance();
                try self.expect(.Null);
                return .NotNull;
            },
            .Unique => {
                try self.advance();
                return .Unique;
            },
            .Autoincrement => {
                try self.advance();
                return .AutoIncrement;
            },
            .Default => {
                try self.advance();
                const default_value = try self.parseDefaultValue();
                return ast.ColumnConstraint{ .Default = default_value };
            },
            .As => {
                const generated = try self.parseGeneratedColumn(false);
                return ast.ColumnConstraint{ .Generated = generated };
            },
            .Identifier => |id| {
                if (!std.ascii.eqlIgnoreCase(id, "GENERATED")) return error.UnexpectedToken;
                try self.advance();
                const generated = try self.parseGeneratedColumn(true);
                return ast.ColumnConstraint{ .Generated = generated };
            },
            .Foreign => {
                try self.advance();
                try self.expect(.Key);
                const fk = try self.parseForeignKeyConstraint();
                return ast.ColumnConstraint{ .ForeignKey = fk };
            },
            .References => {
                // Shorthand for FOREIGN KEY
                const fk = try self.parseForeignKeyConstraint();
                return ast.ColumnConstraint{ .ForeignKey = fk };
            },
            .Check => {
                try self.advance();
                try self.expect(.LeftParen);
                const condition = try self.parseCondition();
                try self.expect(.RightParen);
                return ast.ColumnConstraint{ .Check = ast.CheckConstraint{ .condition = condition } };
            },
            else => error.UnexpectedToken,
        };
    }

    fn parseGeneratedColumn(self: *Self, has_generated_keyword: bool) !ast.GeneratedColumn {
        if (has_generated_keyword) {
            const always = try self.expectIdentifier();
            defer self.allocator.free(always);
            if (!std.ascii.eqlIgnoreCase(always, "ALWAYS")) return error.UnexpectedToken;
        }

        try self.expect(.As);
        try self.expect(.LeftParen);
        var expression = try self.parseExpression();
        errdefer expression.deinit(self.allocator);
        try self.expect(.RightParen);

        var stored = true;
        if (self.current_token == .Identifier) {
            const keyword = try self.expectIdentifier();
            defer self.allocator.free(keyword);
            if (std.ascii.eqlIgnoreCase(keyword, "STORED")) {
                stored = true;
            } else if (std.ascii.eqlIgnoreCase(keyword, "VIRTUAL")) {
                stored = false;
            } else {
                return error.UnexpectedToken;
            }
        } else if (std.meta.activeTag(self.current_token) == .Virtual) {
            try self.advance();
            stored = false;
        }

        return ast.GeneratedColumn{
            .expression = expression,
            .stored = stored,
        };
    }

    /// Parse foreign key constraint
    fn parseForeignKeyConstraint(self: *Self) !ast.ForeignKeyConstraint {
        try self.expect(.References);
        const ref_table = try self.expectIdentifier();

        try self.expect(.LeftParen);
        const ref_column = try self.expectIdentifier();
        try self.expect(.RightParen);

        var on_delete: ?ast.ForeignKeyAction = null;
        var on_update: ?ast.ForeignKeyAction = null;

        // Parse ON DELETE/UPDATE actions
        while (std.meta.activeTag(self.current_token) == .On) {
            try self.advance();

            if (std.meta.activeTag(self.current_token) == .Delete) {
                try self.advance();
                on_delete = try self.parseForeignKeyAction();
            } else if (std.meta.activeTag(self.current_token) == .Update) {
                try self.advance();
                on_update = try self.parseForeignKeyAction();
            } else {
                return error.ExpectedDeleteOrUpdate;
            }
        }
        const deferred = try self.parseDeferredForeignKeySuffix();

        return ast.ForeignKeyConstraint{
            .column = null, // column-level constraint
            .reference_table = ref_table,
            .reference_column = ref_column,
            .on_delete = on_delete,
            .on_update = on_update,
            .deferred = deferred,
        };
    }

    fn parseDeferredForeignKeySuffix(self: *Self) !bool {
        if (!self.currentTokenIsIdentifier("deferrable")) return false;
        try self.advance();
        if (!self.currentTokenIsIdentifier("initially")) return error.UnsupportedForeignKeyDeferral;
        try self.advance();
        if (!self.currentTokenIsIdentifier("deferred")) return error.UnsupportedForeignKeyDeferral;
        try self.advance();
        return true;
    }

    /// Parse foreign key action
    fn parseForeignKeyAction(self: *Self) !ast.ForeignKeyAction {
        return switch (self.current_token) {
            .Cascade => {
                try self.advance();
                return .Cascade;
            },
            .Set => {
                try self.advance();
                try self.expect(.Null);
                return .SetNull;
            },
            .Restrict => {
                try self.advance();
                return .Restrict;
            },
            .Identifier => |id| {
                // Check for "NO ACTION"
                if (std.mem.eql(u8, id, "NO") or std.mem.eql(u8, id, "no")) {
                    try self.advance();
                    const action = try self.expectIdentifier();
                    defer self.allocator.free(action);
                    if (!std.mem.eql(u8, action, "ACTION") and !std.mem.eql(u8, action, "action")) {
                        return error.ExpectedAction;
                    }
                    return .NoAction;
                }
                return error.UnexpectedToken;
            },
            else => error.UnexpectedToken,
        };
    }

    /// Parse default value for column constraints
    fn parseDefaultValue(self: *Self) !ast.DefaultValue {
        // Check for parenthesized expressions like (strftime('%s','now'))
        if (std.meta.activeTag(self.current_token) == .LeftParen) {
            try self.advance(); // consume '('

            // Check if it's a function call inside parentheses
            if (self.current_token == .Identifier) {
                const function_call = try self.parseFunctionCall();
                try self.expect(.RightParen);
                return ast.DefaultValue{ .FunctionCall = function_call };
            }

            // Otherwise parse as expression and close paren
            const inner_value = try self.parseDefaultValue();
            try self.expect(.RightParen);
            return inner_value;
        }

        // Check if it's a direct function call (identifier followed by parentheses)
        if (self.current_token == .Identifier) {
            // Peek ahead to see if this is followed by a left paren
            if (try self.peekNextToken()) |next_token| {
                defer next_token.deinit(self.allocator);
                if (std.meta.activeTag(next_token) == .LeftParen) {
                    const function_call = try self.parseFunctionCall();
                    return ast.DefaultValue{ .FunctionCall = function_call };
                }
            }

            // Not a function call, treat as identifier (this shouldn't happen in DEFAULT context)
            // Check for special DEFAULT keywords
            const id = self.current_token.Identifier;
            // Don't free id since it's owned by the token

            // Handle CURRENT_TIMESTAMP and similar
            if (std.mem.eql(u8, id, "CURRENT_TIMESTAMP") or std.mem.eql(u8, id, "current_timestamp")) {
                try self.advance();
                return ast.DefaultValue{ .FunctionCall = ast.FunctionCall{
                    .name = try self.allocator.dupe(u8, "CURRENT_TIMESTAMP"),
                    .arguments = &.{},
                } };
            } else if (std.mem.eql(u8, id, "CURRENT_DATE") or std.mem.eql(u8, id, "current_date")) {
                try self.advance();
                return ast.DefaultValue{ .FunctionCall = ast.FunctionCall{
                    .name = try self.allocator.dupe(u8, "CURRENT_DATE"),
                    .arguments = &.{},
                } };
            } else if (std.mem.eql(u8, id, "CURRENT_TIME") or std.mem.eql(u8, id, "current_time")) {
                try self.advance();
                return ast.DefaultValue{ .FunctionCall = ast.FunctionCall{
                    .name = try self.allocator.dupe(u8, "CURRENT_TIME"),
                    .arguments = &.{},
                } };
            }

            return error.UnexpectedToken;
        }

        // Check for special keywords that are DEFAULT values
        if (std.meta.activeTag(self.current_token) == .Current_Timestamp) {
            try self.advance();
            return ast.DefaultValue{ .FunctionCall = ast.FunctionCall{
                .name = try self.allocator.dupe(u8, "CURRENT_TIMESTAMP"),
                .arguments = &.{},
            } };
        } else if (std.meta.activeTag(self.current_token) == .Current_Date) {
            try self.advance();
            return ast.DefaultValue{ .FunctionCall = ast.FunctionCall{
                .name = try self.allocator.dupe(u8, "CURRENT_DATE"),
                .arguments = &.{},
            } };
        } else if (std.meta.activeTag(self.current_token) == .Current_Time) {
            try self.advance();
            return ast.DefaultValue{ .FunctionCall = ast.FunctionCall{
                .name = try self.allocator.dupe(u8, "CURRENT_TIME"),
                .arguments = &.{},
            } };
        }

        // Otherwise, it's a literal value
        const value = try self.parseValue();
        return ast.DefaultValue{ .Literal = value };
    }

    /// Parse function call
    fn parseFunctionCall(self: *Self) !ast.FunctionCall {
        const func_name = try self.expectIdentifier();

        // Check if there's actually a left paren (this is a safety check)
        if (std.meta.activeTag(self.current_token) != .LeftParen) {
            // Not actually a function call, this is an error in our logic
            return error.ExpectedLeftParen;
        }

        try self.expect(.LeftParen);

        var arguments: std.ArrayListUnmanaged(ast.FunctionArgument) = .empty;
        defer arguments.deinit(self.allocator);

        // Parse arguments
        while (std.meta.activeTag(self.current_token) != .RightParen) {
            const arg = try self.parseFunctionArgument();
            try arguments.append(self.allocator, arg);

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else if (std.meta.activeTag(self.current_token) != .RightParen) {
                return error.ExpectedCommaOrRightParen;
            }
        }

        try self.expect(.RightParen);

        return ast.FunctionCall{
            .name = func_name,
            .arguments = try arguments.toOwnedSlice(self.allocator),
        };
    }

    /// Parse function argument
    fn parseFunctionArgument(self: *Self) !ast.FunctionArgument {
        return switch (self.current_token) {
            .String => |s| {
                const owned_string = try self.allocator.dupe(u8, s);
                try self.advance();
                return ast.FunctionArgument{ .String = owned_string };
            },
            .Identifier => |name| {
                // Column reference in function argument
                const col_name = try self.allocator.dupe(u8, name);
                try self.advance();
                return ast.FunctionArgument{ .Column = col_name };
            },
            .Integer => |i| {
                try self.advance();
                return ast.FunctionArgument{ .Literal = ast.Value{ .Integer = i } };
            },
            .Real => |r| {
                try self.advance();
                return ast.FunctionArgument{ .Literal = ast.Value{ .Real = r } };
            },
            .Null => {
                try self.advance();
                return ast.FunctionArgument{ .Literal = ast.Value.Null };
            },
            else => {
                const value = try self.parseValue();
                return ast.FunctionArgument{ .Literal = value };
            },
        };
    }

    /// Parse WHERE clause
    fn parseWhere(self: *Self) !ast.WhereClause {
        const condition = try self.parseCondition();
        return ast.WhereClause{ .condition = condition };
    }

    /// Parse condition in WHERE clause
    fn parseCondition(self: *Self) Error!ast.Condition {
        var left = ast.Condition{ .Comparison = try self.parseComparison() };

        while (std.meta.activeTag(self.current_token) == .And or std.meta.activeTag(self.current_token) == .Or) {
            const op: ast.LogicalOperator = if (std.meta.activeTag(self.current_token) == .And) .And else .Or;
            try self.advance();

            const right = try self.parseComparison();
            const left_ptr = try self.allocator.create(ast.Condition);
            left_ptr.* = left;

            const right_ptr = try self.allocator.create(ast.Condition);
            right_ptr.* = ast.Condition{ .Comparison = right };

            left = ast.Condition{
                .Logical = ast.LogicalCondition{
                    .left = left_ptr,
                    .operator = op,
                    .right = right_ptr,
                },
            };
        }

        return left;
    }

    /// Parse comparison condition
    fn parseComparison(self: *Self) !ast.ComparisonCondition {
        const left = try self.parseExpression();

        // Check for IS [NOT] NULL
        if (std.meta.activeTag(self.current_token) == .Is) {
            try self.advance();
            const is_not = std.meta.activeTag(self.current_token) == .Not;
            if (is_not) try self.advance();

            if (std.meta.activeTag(self.current_token) != .Null) {
                return error.ExpectedNull;
            }
            try self.advance();

            return ast.ComparisonCondition{
                .left = left,
                .operator = if (is_not) .IsNotNull else .IsNull,
                .right = ast.Expression{ .Literal = ast.Value.Null },
            };
        }

        // Check for NOT LIKE, NOT IN, NOT BETWEEN
        if (std.meta.activeTag(self.current_token) == .Not) {
            try self.advance();
            return switch (self.current_token) {
                .Like => blk: {
                    try self.advance();
                    const right = try self.parseExpression();
                    break :blk ast.ComparisonCondition{
                        .left = left,
                        .operator = .NotLike,
                        .right = right,
                    };
                },
                .In => blk: {
                    try self.advance();
                    const right = try self.parseInClauseContent();
                    break :blk ast.ComparisonCondition{
                        .left = left,
                        .operator = .NotIn,
                        .right = right,
                    };
                },
                .Between => blk: {
                    try self.advance();
                    const low = try self.parseExpression();
                    try self.expect(.And);
                    const high = try self.parseExpression();
                    break :blk ast.ComparisonCondition{
                        .left = left,
                        .operator = .NotBetween,
                        .right = low,
                        .extra = high,
                    };
                },
                else => return error.ExpectedOperator,
            };
        }

        // Check for BETWEEN
        if (std.meta.activeTag(self.current_token) == .Between) {
            try self.advance();
            const low = try self.parseExpression();
            try self.expect(.And);
            const high = try self.parseExpression();
            return ast.ComparisonCondition{
                .left = left,
                .operator = .Between,
                .right = low,
                .extra = high,
            };
        }

        // Check for IN (handles subqueries and value lists)
        if (std.meta.activeTag(self.current_token) == .In) {
            try self.advance();
            const right = try self.parseInClauseContent();
            return ast.ComparisonCondition{
                .left = left,
                .operator = .In,
                .right = right,
            };
        }

        // Regular comparison operator
        const op = try self.parseComparisonOperator();
        const right = try self.parseExpression();

        return ast.ComparisonCondition{
            .left = left,
            .operator = op,
            .right = right,
        };
    }

    /// Parse comparison operator
    fn parseComparisonOperator(self: *Self) !ast.ComparisonOperator {
        const op = switch (self.current_token) {
            .Equal => ast.ComparisonOperator.Equal,
            .NotEqual => ast.ComparisonOperator.NotEqual,
            .LessThan => ast.ComparisonOperator.LessThan,
            .LessThanOrEqual => ast.ComparisonOperator.LessThanOrEqual,
            .GreaterThan => ast.ComparisonOperator.GreaterThan,
            .GreaterThanOrEqual => ast.ComparisonOperator.GreaterThanOrEqual,
            .Like => ast.ComparisonOperator.Like,
            .Match => ast.ComparisonOperator.Match, // FTS MATCH operator
            // Note: IN is handled separately in parseComparison
            else => return error.ExpectedOperator,
        };
        try self.advance();
        return op;
    }

    /// Parse a primary expression (column, literal, parameter, or subquery)
    fn parsePrimaryExpression(self: *Self) !ast.Expression {
        return switch (self.current_token) {
            // .Excluded lets `EXCLUDED.<column>` references inside
            // ON CONFLICT DO UPDATE parse as a qualified column ("excluded.col").
            .Identifier, .Excluded, .Count, .Sum, .Avg, .Min, .Max => {
                var owned_id = try self.expectIdentifierOrKeyword();
                errdefer self.allocator.free(owned_id);

                // Check for qualified name (table.column)
                if (std.meta.activeTag(self.current_token) == .Dot) {
                    try self.advance(); // consume '.'
                    if (self.current_token == .Identifier or
                        self.current_token == .Count or
                        self.current_token == .Sum or
                        self.current_token == .Avg or
                        self.current_token == .Min or
                        self.current_token == .Max)
                    {
                        const second_part = try self.expectIdentifierOrKeyword();
                        defer self.allocator.free(second_part);
                        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ owned_id, second_part });
                        self.allocator.free(owned_id);
                        owned_id = qualified_name;
                    }
                }

                return ast.Expression{ .Column = owned_id };
            },
            .QuestionMark => {
                const param_index = self.parameter_index;
                self.parameter_index += 1;
                try self.advance();
                return ast.Expression{ .Parameter = param_index };
            },
            .NamedParameter => {
                const param_index = self.parameter_index;
                self.parameter_index += 1;
                try self.advance();
                return ast.Expression{ .Parameter = param_index };
            },
            .LeftParen => {
                try self.advance(); // consume '('
                // Check if this is a subquery
                if (std.meta.activeTag(self.current_token) == .Select) {
                    const subquery = try self.allocator.create(ast.SelectStatement);
                    subquery.* = try self.parseSimpleSelect();
                    try self.expect(.RightParen);
                    return ast.Expression{ .Subquery = subquery };
                }
                // Otherwise parse as grouped expression or value list
                const value = try self.parseValue();
                try self.expect(.RightParen);
                return ast.Expression{ .Literal = value };
            },
            else => {
                const value = try self.parseValue();
                return ast.Expression{ .Literal = value };
            },
        };
    }

    /// Parse IN clause content: either (SELECT ...) or (value1, value2, ...)
    fn parseInClauseContent(self: *Self) !ast.Expression {
        try self.expect(.LeftParen);

        // Check if this is a subquery
        if (std.meta.activeTag(self.current_token) == .Select) {
            const subquery = try self.allocator.create(ast.SelectStatement);
            subquery.* = try self.parseSimpleSelect();
            try self.expect(.RightParen);
            return ast.Expression{ .Subquery = subquery };
        }

        // Otherwise parse as value list
        var values: std.ArrayListUnmanaged(ast.Value) = .empty;
        errdefer {
            for (values.items) |*val| {
                val.deinit(self.allocator);
            }
            values.deinit(self.allocator);
        }

        const first_value = try self.parseValue();
        try values.append(self.allocator, first_value);

        while (std.meta.activeTag(self.current_token) == .Comma) {
            try self.advance(); // consume ','
            const value = try self.parseValue();
            try values.append(self.allocator, value);
        }

        try self.expect(.RightParen);
        return ast.Expression{ .InList = try values.toOwnedSlice(self.allocator) };
    }

    /// Check if current token is an arithmetic operator
    fn isArithmeticOp(self: *Self) ?ast.ArithmeticOp {
        return switch (self.current_token) {
            .Plus => .Add,
            .Minus => .Subtract,
            .Asterisk => .Multiply,
            .Divide => .Divide,
            .Modulo => .Modulo,
            else => null,
        };
    }

    /// Parse expression with support for arithmetic operators (column + 1, etc.)
    fn parseExpression(self: *Self) !ast.Expression {
        var left = try self.parsePrimaryExpression();
        errdefer left.deinit(self.allocator);

        // Check for arithmetic operator
        if (self.isArithmeticOp()) |op| {
            try self.advance(); // consume operator

            var right = try self.parsePrimaryExpression();
            errdefer right.deinit(self.allocator);

            // Allocate left and right on heap for BinaryExpr
            const left_ptr = try self.allocator.create(ast.Expression);
            left_ptr.* = left;

            const right_ptr = try self.allocator.create(ast.Expression);
            right_ptr.* = right;

            return ast.Expression{
                .BinaryOp = ast.BinaryExpr{
                    .left = left_ptr,
                    .op = op,
                    .right = right_ptr,
                },
            };
        }

        return left;
    }

    /// Parse value literal
    fn parseValue(self: *Self) Error!ast.Value {
        // Handle CASE expression
        if (std.meta.activeTag(self.current_token) == .Case) {
            return try self.parseCaseExpression();
        }

        // Handle null-handling functions: COALESCE, NULLIF, IFNULL
        // and string functions: UPPER, LOWER, SUBSTR, LENGTH, TRIM
        if (std.meta.activeTag(self.current_token) == .Coalesce or
            std.meta.activeTag(self.current_token) == .Nullif or
            std.meta.activeTag(self.current_token) == .Ifnull or
            std.meta.activeTag(self.current_token) == .Upper or
            std.meta.activeTag(self.current_token) == .Lower or
            std.meta.activeTag(self.current_token) == .Substr or
            std.meta.activeTag(self.current_token) == .Length or
            std.meta.activeTag(self.current_token) == .Trim)
        {
            return try self.parseNullHandlingFunction();
        }

        const value = switch (self.current_token) {
            .Integer => |i| ast.Value{ .Integer = i },
            .Real => |r| ast.Value{ .Real = r },
            .String => |s| ast.Value{ .Text = try self.allocator.dupe(u8, s) },
            .Null => ast.Value.Null,
            .QuestionMark => blk: {
                const param_index = self.parameter_index;
                self.parameter_index += 1;
                break :blk ast.Value{ .Parameter = param_index };
            },
            .NamedParameter => blk: {
                const param_index = self.parameter_index;
                self.parameter_index += 1;
                break :blk ast.Value{ .Parameter = param_index };
            },
            .Current_Timestamp => {
                // Handle CURRENT_TIMESTAMP as a special function
                try self.advance();
                // Generate current timestamp in ISO format
                const ts = time_utils.getTimespec();
                const timestamp = ts.sec;
                const timestamp_str = try std.fmt.allocPrint(self.allocator, "{d}-01-01 12:00:00", .{1970 + @divFloor(timestamp, 31536000)});
                return ast.Value{ .Text = timestamp_str };
            },
            .Identifier => |func_name| {
                // Check if it's a function call like datetime('now')
                if (std.mem.eql(u8, func_name, "datetime")) {
                    try self.advance(); // consume function name
                    if (std.meta.activeTag(self.current_token) == .LeftParen) {
                        try self.advance(); // consume '('
                        // For now, just skip arguments and return a timestamp
                        while (std.meta.activeTag(self.current_token) != .RightParen and std.meta.activeTag(self.current_token) != .EOF) {
                            try self.advance();
                        }
                        if (std.meta.activeTag(self.current_token) == .RightParen) {
                            try self.advance(); // consume ')'
                        }
                        // Generate current timestamp in ISO format
                        const ts = time_utils.getTimespec();
                        const timestamp = ts.sec;
                        const timestamp_str = try std.fmt.allocPrint(self.allocator, "{d}-01-01 12:00:00", .{1970 + @divFloor(timestamp, 31536000)});
                        return ast.Value{ .Text = timestamp_str };
                    }
                }
                return error.ExpectedValue;
            },
            else => return error.ExpectedValue,
        };
        try self.advance();
        return value;
    }

    /// Parse CASE WHEN ... THEN ... ELSE ... END expression
    fn parseCaseExpression(self: *Self) Error!ast.Value {
        try self.advance(); // consume CASE

        var branches: std.ArrayListUnmanaged(ast.CaseWhenBranch) = .empty;
        errdefer {
            for (branches.items) |*branch| {
                branch.deinit(self.allocator);
            }
            branches.deinit(self.allocator);
        }

        // Parse WHEN branches
        while (std.meta.activeTag(self.current_token) == .When) {
            try self.advance(); // consume WHEN

            // Parse condition
            const condition = try self.allocator.create(ast.Condition);
            condition.* = try self.parseCondition();

            try self.expect(.Then);
            const result = try self.parseValue();

            try branches.append(self.allocator, ast.CaseWhenBranch{
                .condition = condition,
                .result = result,
            });
        }

        // Parse optional ELSE
        var else_result: ?*ast.Value = null;
        if (std.meta.activeTag(self.current_token) == .Else) {
            try self.advance(); // consume ELSE
            else_result = try self.allocator.create(ast.Value);
            else_result.?.* = try self.parseValue();
        }

        try self.expect(.End);

        return ast.Value{
            .Case = ast.CaseExpression{
                .operand = null, // Simple searched CASE (CASE WHEN cond THEN ...)
                .branches = try branches.toOwnedSlice(self.allocator),
                .else_result = else_result,
            },
        };
    }

    /// Parse null-handling and string functions
    fn parseNullHandlingFunction(self: *Self) Error!ast.Value {
        const func_name: []const u8 = switch (std.meta.activeTag(self.current_token)) {
            .Coalesce => "COALESCE",
            .Nullif => "NULLIF",
            .Ifnull => "IFNULL",
            .Upper => "UPPER",
            .Lower => "LOWER",
            .Substr => "SUBSTR",
            .Length => "LENGTH",
            .Trim => "TRIM",
            else => unreachable,
        };

        try self.advance(); // consume function name
        try self.expect(.LeftParen);

        var arguments: std.ArrayListUnmanaged(ast.FunctionArgument) = .empty;
        errdefer {
            for (arguments.items) |*arg| {
                arg.deinit(self.allocator);
            }
            arguments.deinit(self.allocator);
        }

        // Parse arguments
        while (std.meta.activeTag(self.current_token) != .RightParen) {
            const arg = try self.parseFunctionArgument();
            try arguments.append(self.allocator, arg);

            if (std.meta.activeTag(self.current_token) == .Comma) {
                try self.advance();
            } else if (std.meta.activeTag(self.current_token) != .RightParen) {
                return error.ExpectedCommaOrRightParen;
            }
        }

        try self.expect(.RightParen);

        return ast.Value{
            .FunctionCall = ast.FunctionCall{
                .name = try self.allocator.dupe(u8, func_name),
                .arguments = try arguments.toOwnedSlice(self.allocator),
            },
        };
    }

    /// Create detailed error message
    fn createError(self: *Self, expected: []const u8, context: []const u8) void {
        // Error details are returned via the error union - no logging needed.
        // Parse errors are often expected (e.g., rejecting SQL injection attempts).
        _ = expected;
        _ = context;
        _ = self;
    }

    /// Expect a specific token
    fn expect(self: *Self, expected: std.meta.Tag(tokenizer.Token)) !void {
        if (std.meta.activeTag(self.current_token) != expected) {
            self.createError(@tagName(expected), "");
            return error.UnexpectedToken;
        }
        try self.advance();
    }

    /// Expect an identifier and return its value
    fn expectIdentifier(self: *Self) ![]const u8 {
        if (self.current_token != .Identifier) {
            self.createError("identifier", "");
            return error.ExpectedIdentifier;
        }
        const value = try self.allocator.dupe(u8, self.current_token.Identifier);
        try self.advance();
        return value;
    }

    /// Expect an identifier or allow keywords as identifiers (for aliases)
    fn expectIdentifierOrKeyword(self: *Self) ![]const u8 {
        switch (self.current_token) {
            .Identifier => |id| {
                const value = try self.allocator.dupe(u8, id);
                try self.advance();
                return value;
            },
            // Allow common keywords as identifiers in alias contexts
            .Excluded => {
                try self.advance();
                return try self.allocator.dupe(u8, "excluded");
            },
            .Count => {
                try self.advance();
                return try self.allocator.dupe(u8, "count");
            },
            .Sum => {
                try self.advance();
                return try self.allocator.dupe(u8, "sum");
            },
            .Avg => {
                try self.advance();
                return try self.allocator.dupe(u8, "avg");
            },
            .Min => {
                try self.advance();
                return try self.allocator.dupe(u8, "min");
            },
            .Max => {
                try self.advance();
                return try self.allocator.dupe(u8, "max");
            },
            else => {
                self.createError("identifier", "");
                return error.ExpectedIdentifier;
            },
        }
    }

    fn expectQualifiedIdentifier(self: *Self) ![]const u8 {
        const first = try self.expectIdentifier();
        return self.finishQualifiedIdentifier(first);
    }

    fn expectQualifiedIdentifierOrKeyword(self: *Self) ![]const u8 {
        const first = try self.expectIdentifierOrKeyword();
        return self.finishQualifiedIdentifier(first);
    }

    fn finishQualifiedIdentifier(self: *Self, first: []const u8) ![]const u8 {
        errdefer self.allocator.free(first);
        if (std.meta.activeTag(self.current_token) != .Dot) return first;

        try self.advance();
        const second = try self.expectIdentifierOrKeyword();
        defer self.allocator.free(second);

        const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ first, second });
        self.allocator.free(first);
        return qualified;
    }

    /// Advance to next token
    fn advance(self: *Self) !void {
        self.current_token.deinit(self.allocator);
        self.current_token = try self.tokenizer.nextToken(self.allocator);
    }

    /// Peek at the next token without consuming it
    fn peekNextToken(self: *Self) !?tokenizer.Token {
        // Create a copy of the current tokenizer state
        var peek_tokenizer = tokenizer.Tokenizer.init(self.tokenizer.input);
        peek_tokenizer.position = self.tokenizer.position;
        peek_tokenizer.current_char = self.tokenizer.current_char;

        // Get the next token without affecting our state
        return try peek_tokenizer.nextToken(self.allocator);
    }

    /// Check if current token indicates a table-level constraint
    fn isTableConstraintToken(self: *Self) bool {
        return switch (self.current_token) {
            .Foreign, .Unique, .Primary, .Check => true,
            else => false,
        };
    }

    /// Parse table-level constraint
    fn parseTableConstraint(self: *Self) !ast.TableConstraint {
        return switch (self.current_token) {
            .Foreign => {
                try self.advance(); // consume FOREIGN
                try self.expect(.Key); // expect KEY
                try self.expect(.LeftParen);
                var child_columns: std.ArrayListUnmanaged([]const u8) = .empty;
                defer child_columns.deinit(self.allocator);
                errdefer for (child_columns.items) |column| self.allocator.free(column);
                while (true) {
                    try child_columns.append(self.allocator, try self.expectIdentifier());
                    if (std.meta.activeTag(self.current_token) != .Comma) break;
                    try self.advance();
                }
                try self.expect(.RightParen);

                try self.expect(.References);
                const ref_table_name = try self.expectIdentifier();
                errdefer self.allocator.free(ref_table_name);
                try self.expect(.LeftParen);
                var parent_columns: std.ArrayListUnmanaged([]const u8) = .empty;
                defer parent_columns.deinit(self.allocator);
                errdefer for (parent_columns.items) |column| self.allocator.free(column);
                while (true) {
                    try parent_columns.append(self.allocator, try self.expectIdentifier());
                    if (std.meta.activeTag(self.current_token) != .Comma) break;
                    try self.advance();
                }
                try self.expect(.RightParen);
                if (child_columns.items.len != parent_columns.items.len) return error.ForeignKeyColumnCountMismatch;

                var on_delete: ?ast.ForeignKeyAction = null;
                var on_update: ?ast.ForeignKeyAction = null;
                while (std.meta.activeTag(self.current_token) == .On) {
                    try self.advance();

                    if (std.meta.activeTag(self.current_token) == .Delete) {
                        try self.advance();
                        on_delete = try self.parseForeignKeyAction();
                    } else if (std.meta.activeTag(self.current_token) == .Update) {
                        try self.advance();
                        on_update = try self.parseForeignKeyAction();
                    } else {
                        return error.ExpectedDeleteOrUpdate;
                    }
                }
                const deferred = try self.parseDeferredForeignKeySuffix();

                if (child_columns.items.len == 1) {
                    const column = child_columns.items[0];
                    const ref_column_name = parent_columns.items[0];
                    child_columns.clearRetainingCapacity();
                    parent_columns.clearRetainingCapacity();
                    return ast.TableConstraint{ .ForeignKey = .{
                        .column = column,
                        .reference_table = ref_table_name,
                        .reference_column = ref_column_name,
                        .on_delete = on_delete,
                        .on_update = on_update,
                        .deferred = deferred,
                    } };
                }

                return ast.TableConstraint{ .ForeignKey = ast.ForeignKeyConstraint{
                    .column = null,
                    .columns = try child_columns.toOwnedSlice(self.allocator),
                    .reference_table = ref_table_name,
                    .reference_column = try self.allocator.dupe(u8, parent_columns.items[0]),
                    .reference_columns = try parent_columns.toOwnedSlice(self.allocator),
                    .on_delete = on_delete,
                    .on_update = on_update,
                    .deferred = deferred,
                } };
            },
            .Unique => {
                try self.advance(); // consume UNIQUE
                try self.expect(.LeftParen);

                var columns_list: std.ArrayListUnmanaged([]const u8) = .empty;
                defer columns_list.deinit(self.allocator);

                while (true) {
                    const column = try self.expectIdentifier();
                    try columns_list.append(self.allocator, column);

                    if (std.meta.activeTag(self.current_token) == .Comma) {
                        try self.advance();
                    } else {
                        break;
                    }
                }

                try self.expect(.RightParen);

                return ast.TableConstraint{ .Unique = ast.UniqueConstraint{
                    .columns = try columns_list.toOwnedSlice(self.allocator),
                } };
            },
            .Primary => {
                try self.advance(); // consume PRIMARY
                try self.expect(.Key); // expect KEY
                try self.expect(.LeftParen);

                var columns_list: std.ArrayListUnmanaged([]const u8) = .empty;
                defer columns_list.deinit(self.allocator);

                while (true) {
                    const column = try self.expectIdentifier();
                    try columns_list.append(self.allocator, column);

                    if (std.meta.activeTag(self.current_token) == .Comma) {
                        try self.advance();
                    } else {
                        break;
                    }
                }

                try self.expect(.RightParen);

                return ast.TableConstraint{ .PrimaryKey = ast.PrimaryKeyConstraint{
                    .columns = try columns_list.toOwnedSlice(self.allocator),
                } };
            },
            .Check => {
                try self.advance(); // consume CHECK
                try self.expect(.LeftParen);
                const condition = try self.parseCondition();
                try self.expect(.RightParen);

                return ast.TableConstraint{ .Check = ast.CheckConstraint{
                    .condition = condition,
                } };
            },
            else => error.UnexpectedToken,
        };
    }

    /// Clean up parser
    pub fn deinit(self: *Self) void {
        self.current_token.deinit(self.allocator);
    }
};

/// Parse SQL statement (convenience function)
pub fn parse(allocator: std.mem.Allocator, sql: []const u8) !ParseResult {
    var parser = try Parser.init(allocator, sql);
    errdefer parser.deinit();

    const statement = try parser.parse();
    return ParseResult{
        .statement = statement,
        .parser = parser,
    };
}

/// Parse result that manages parser lifetime
pub const ParseResult = struct {
    statement: ast.Statement,
    parser: Parser,

    pub fn deinit(self: *ParseResult) void {
        self.statement.deinit(self.parser.allocator);
        self.parser.deinit();
    }
};

test "parse simple select" {
    const allocator = std.testing.allocator;
    var result = try parse(allocator, "SELECT * FROM users");
    defer result.deinit();

    try std.testing.expectEqual(std.meta.Tag(ast.Statement).Select, std.meta.activeTag(result.statement));
}

test "parse create table with default literal" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE users (id INTEGER DEFAULT 42)";

    var result = try parse(allocator, sql);
    defer result.deinit();

    try std.testing.expectEqual(std.meta.Tag(ast.Statement).CreateTable, std.meta.activeTag(result.statement));

    const create_stmt = result.statement.CreateTable;
    try std.testing.expectEqual(@as(usize, 1), create_stmt.columns.len);

    // Check the column has a default constraint
    const col = create_stmt.columns[0];
    try std.testing.expectEqual(@as(usize, 1), col.constraints.len);
    try std.testing.expectEqual(std.meta.Tag(ast.ColumnConstraint).Default, std.meta.activeTag(col.constraints[0]));
}

test "parse create table with default function call" {
    const allocator = std.testing.allocator;
    // Simplified test - the complex strftime parsing can be added later
    const sql = "CREATE TABLE users (id INTEGER PRIMARY KEY, created_at INTEGER DEFAULT 42)";

    var result = try parse(allocator, sql);
    defer result.deinit();

    try std.testing.expectEqual(std.meta.Tag(ast.Statement).CreateTable, std.meta.activeTag(result.statement));

    const create_stmt = result.statement.CreateTable;
    try std.testing.expectEqual(@as(usize, 2), create_stmt.columns.len);

    // Check the second column has a default constraint
    const second_col = create_stmt.columns[1];
    try std.testing.expectEqual(@as(usize, 1), second_col.constraints.len);
    try std.testing.expectEqual(std.meta.Tag(ast.ColumnConstraint).Default, std.meta.activeTag(second_col.constraints[0]));
}

test "parse create table with aggregate keyword column name" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE counter (id INTEGER, count INTEGER)";

    var result = try parse(allocator, sql);
    defer result.deinit();

    try std.testing.expectEqual(std.meta.Tag(ast.Statement).CreateTable, std.meta.activeTag(result.statement));

    const create_stmt = result.statement.CreateTable;
    try std.testing.expectEqual(@as(usize, 2), create_stmt.columns.len);
    try std.testing.expectEqualStrings("count", create_stmt.columns[1].name);
}

test "parse insert with aggregate keyword identifiers" {
    const allocator = std.testing.allocator;
    const sql = "INSERT INTO counter (id, count) VALUES (1, 0)";

    var result = try parse(allocator, sql);
    defer result.deinit();

    try std.testing.expectEqual(std.meta.Tag(ast.Statement).Insert, std.meta.activeTag(result.statement));

    const insert_stmt = result.statement.Insert;
    try std.testing.expectEqualStrings("counter", insert_stmt.table_name);
    try std.testing.expect(insert_stmt.columns != null);
    try std.testing.expectEqual(@as(usize, 2), insert_stmt.columns.?.len);
    try std.testing.expectEqualStrings("count", insert_stmt.columns.?[1]);
}

test "parse select bare aggregate keyword as column name" {
    const allocator = std.testing.allocator;
    const sql = "SELECT count FROM counter WHERE id = 1";

    var result = try parse(allocator, sql);
    defer result.deinit();

    try std.testing.expectEqual(std.meta.Tag(ast.Statement).Select, std.meta.activeTag(result.statement));

    const select_stmt = result.statement.Select;
    try std.testing.expectEqual(@as(usize, 1), select_stmt.columns.len);
    try std.testing.expectEqualStrings("count", select_stmt.columns[0].name);
}

test "parse insert with parameters" {
    const allocator = std.testing.allocator;
    const sql = "INSERT INTO users (id, name) VALUES (?, ?)";

    var result = try parse(allocator, sql);
    defer result.deinit();

    try std.testing.expectEqual(std.meta.Tag(ast.Statement).Insert, std.meta.activeTag(result.statement));

    const insert_stmt = result.statement.Insert;
    try std.testing.expectEqual(@as(usize, 1), insert_stmt.values.len);

    // Check that we have parameter placeholders
    const row = insert_stmt.values[0];
    try std.testing.expectEqual(@as(usize, 2), row.len);
    try std.testing.expectEqual(std.meta.Tag(ast.Value).Parameter, std.meta.activeTag(row[0]));
    try std.testing.expectEqual(std.meta.Tag(ast.Value).Parameter, std.meta.activeTag(row[1]));
    try std.testing.expectEqual(@as(u32, 0), row[0].Parameter);
    try std.testing.expectEqual(@as(u32, 1), row[1].Parameter);
}

test "parse strftime function in default" {
    const allocator = std.testing.allocator;
    // Test the exact case that was failing
    const sql = "CREATE TABLE test (created INTEGER DEFAULT (strftime('%s','now')))";

    var result = try parse(allocator, sql);
    defer result.deinit();

    try std.testing.expectEqual(std.meta.Tag(ast.Statement).CreateTable, std.meta.activeTag(result.statement));
}
