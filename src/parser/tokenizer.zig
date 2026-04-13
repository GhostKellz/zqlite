const std = @import("std");

/// SQL tokenizer for lexical analysis
pub const Tokenizer = struct {
    input: []const u8,
    position: usize,
    current_char: ?u8,

    const Self = @This();

    /// Initialize tokenizer with SQL input
    pub fn init(input: []const u8) Self {
        return Self{
            .input = input,
            .position = 0,
            .current_char = if (input.len > 0) input[0] else null,
        };
    }

    /// Get the next token
    pub fn nextToken(self: *Self, allocator: std.mem.Allocator) !Token {
        while (self.current_char != null) {
            // Skip whitespace
            if (std.ascii.isWhitespace(self.current_char.?)) {
                self.skipWhitespace();
                continue;
            }

            // Skip SQL comments
            if (self.current_char.? == '-') {
                const next_pos = self.position + 1;
                if (next_pos < self.input.len and self.input[next_pos] == '-') {
                    self.skipLineComment();
                    continue;
                }
            }

            // Skip multi-line comments
            if (self.current_char.? == '/') {
                const next_pos = self.position + 1;
                if (next_pos < self.input.len and self.input[next_pos] == '*') {
                    try self.skipBlockComment();
                    continue;
                }
            }

            // Numbers
            if (std.ascii.isDigit(self.current_char.?)) {
                return try self.readNumber(allocator);
            }

            // Identifiers and keywords
            if (std.ascii.isAlphabetic(self.current_char.?) or self.current_char.? == '_') {
                return try self.readIdentifier(allocator);
            }

            // String literals
            if (self.current_char.? == '\'' or self.current_char.? == '"') {
                return try self.readString(allocator);
            }

            // Operators and punctuation
            switch (self.current_char.?) {
                '=' => {
                    self.advance();
                    return Token{ .Equal = {} };
                },
                '!' => {
                    self.advance();
                    if (self.current_char == '=') {
                        self.advance();
                        return Token{ .NotEqual = {} };
                    }
                    return error.UnexpectedCharacter;
                },
                '<' => {
                    self.advance();
                    if (self.current_char == '=') {
                        self.advance();
                        return Token{ .LessThanOrEqual = {} };
                    }
                    return Token{ .LessThan = {} };
                },
                '>' => {
                    self.advance();
                    if (self.current_char == '=') {
                        self.advance();
                        return Token{ .GreaterThanOrEqual = {} };
                    }
                    return Token{ .GreaterThan = {} };
                },
                '(' => {
                    self.advance();
                    return Token{ .LeftParen = {} };
                },
                ')' => {
                    self.advance();
                    return Token{ .RightParen = {} };
                },
                ',' => {
                    self.advance();
                    return Token{ .Comma = {} };
                },
                ';' => {
                    self.advance();
                    return Token{ .Semicolon = {} };
                },
                '*' => {
                    self.advance();
                    return Token{ .Asterisk = {} };
                },
                '+' => {
                    self.advance();
                    return Token{ .Plus = {} };
                },
                '-' => {
                    self.advance();
                    return Token{ .Minus = {} };
                },
                '/' => {
                    self.advance();
                    return Token{ .Divide = {} };
                },
                '%' => {
                    self.advance();
                    return Token{ .Modulo = {} };
                },
                '.' => {
                    self.advance();
                    return Token{ .Dot = {} };
                },
                '?' => {
                    self.advance();
                    return Token{ .QuestionMark = {} };
                },
                else => {
                    return error.UnexpectedCharacter;
                },
            }
        }

        return Token{ .EOF = {} };
    }

    /// Advance to next character
    fn advance(self: *Self) void {
        self.position += 1;
        if (self.position >= self.input.len) {
            self.current_char = null;
        } else {
            self.current_char = self.input[self.position];
        }
    }

    /// Skip whitespace characters
    fn skipWhitespace(self: *Self) void {
        while (self.current_char != null and std.ascii.isWhitespace(self.current_char.?)) {
            self.advance();
        }
    }

    /// Skip line comment (-- comment)
    fn skipLineComment(self: *Self) void {
        // Skip the '--'
        self.advance();
        self.advance();

        // Skip until end of line or end of input
        while (self.current_char != null and self.current_char.? != '\n') {
            self.advance();
        }

        // Skip the newline if present
        if (self.current_char == '\n') {
            self.advance();
        }
    }

    /// Skip block comment (/* comment */)
    fn skipBlockComment(self: *Self) !void {
        // Skip the '/*'
        self.advance();
        self.advance();

        // Skip until we find '*/'
        while (self.current_char != null) {
            if (self.current_char.? == '*') {
                self.advance();
                if (self.current_char != null and self.current_char.? == '/') {
                    self.advance();
                    return;
                }
            } else {
                self.advance();
            }
        }

        // If we reach here, the comment was not closed
        return error.UnterminatedComment;
    }

    /// Read a number token
    fn readNumber(self: *Self, allocator: std.mem.Allocator) !Token {
        _ = allocator; // Not needed for number parsing
        const start = self.position;
        var has_dot = false;

        while (self.current_char != null and (std.ascii.isDigit(self.current_char.?) or self.current_char.? == '.')) {
            if (self.current_char.? == '.') {
                if (has_dot) break; // Second dot, stop parsing
                has_dot = true;
            }
            self.advance();
        }

        const number_str = self.input[start..self.position];

        if (has_dot) {
            const value = try std.fmt.parseFloat(f64, number_str);
            return Token{ .Real = value };
        } else {
            const value = try std.fmt.parseInt(i64, number_str, 10);
            return Token{ .Integer = value };
        }
    }

    /// Read an identifier or keyword
    fn readIdentifier(self: *Self, allocator: std.mem.Allocator) !Token {
        const start = self.position;

        while (self.current_char != null and
            (std.ascii.isAlphanumeric(self.current_char.?) or self.current_char.? == '_'))
        {
            self.advance();
        }

        const identifier = self.input[start..self.position];

        // Check if it's a keyword
        if (getKeyword(identifier)) |keyword| {
            return keyword;
        }

        // It's an identifier
        const owned_identifier = try allocator.dupe(u8, identifier);
        return Token{ .Identifier = owned_identifier };
    }

    /// Read a string literal
    fn readString(self: *Self, allocator: std.mem.Allocator) !Token {
        const quote_char = self.current_char.?;
        self.advance(); // Skip opening quote

        const start = self.position;

        while (self.current_char != null and self.current_char.? != quote_char) {
            self.advance();
        }

        if (self.current_char == null) {
            return error.UnterminatedString;
        }

        const string_content = self.input[start..self.position];
        self.advance(); // Skip closing quote

        const owned_string = try allocator.dupe(u8, string_content);
        return Token{ .String = owned_string };
    }
};

/// SQL tokens
pub const Token = union(enum) {
    // Literals
    Integer: i64,
    Real: f64,
    String: []const u8,
    Identifier: []const u8,

    // Keywords
    Select,
    From,
    Where,
    Insert,
    Into,
    Values,
    Update,
    Set,
    Delete,
    Create,
    Table,
    And,
    Or,
    Like,
    In,
    Null,
    Not,
    Primary,
    Key,
    Unique,
    Begin,
    Commit,
    Rollback,
    If,
    Exists,
    Limit,
    Offset,
    Default,
    Foreign,
    References,
    On,
    Cascade,
    Restrict,
    Index,
    Drop,
    Inner,
    Left,
    Right,
    Full,
    Outer,
    Join,
    Group,
    By,
    Having,
    Order,
    Asc,
    Desc,
    Count,
    Sum,
    Avg,
    Min,
    Max,
    Stddev,
    Variance,
    GroupConcat,
    Distinct,
    As,
    Transaction,
    Autoincrement,
    Check,
    Replace,
    Ignore,
    Current_Timestamp,
    Current_Date,
    Current_Time,
    Is,
    Between,
    Case,
    When,
    Then,
    Else,
    End,
    Union,
    Intersect,
    Except,
    All,
    Coalesce,
    Nullif,
    Ifnull,
    Upper,
    Lower,
    Substr,
    Length,
    Trim,
    Ltrim,
    Rtrim,
    Explain,
    Query,
    Plan,
    Pragma,
    // Window function tokens
    Window,
    Over,
    Partition,
    Row_Number,
    Rank,
    Dense_Rank,
    Percent_Rank,
    Cume_Dist,
    Ntile,
    Lead,
    Lag,
    First_Value,
    Last_Value,
    Nth_Value,
    Rows,
    Range,
    Unbounded,
    Preceding,
    Following,
    Current,
    Row,
    // Database management
    Attach,
    Detach,
    Database,
    Schema, // For schema-qualified names
    Virtual,
    Using,
    Match, // For FTS MATCH operator
    Fts5, // Full-text search
    // RETURNING and UPSERT support
    Returning,
    Conflict,
    Do,
    Nothing,
    Excluded, // For referencing excluded row in ON CONFLICT

    // Operators
    Equal,
    NotEqual,
    LessThan,
    LessThanOrEqual,
    GreaterThan,
    GreaterThanOrEqual,

    // Punctuation
    LeftParen,
    RightParen,
    Comma,
    Semicolon,
    Asterisk,
    QuestionMark,
    Plus,
    Minus,
    Divide,
    Modulo,
    Dot,

    // Special
    EOF,

    pub fn deinit(self: Token, allocator: std.mem.Allocator) void {
        switch (self) {
            .String => |str| allocator.free(str),
            .Identifier => |id| allocator.free(id),
            else => {},
        }
    }
};

/// Check if identifier is a keyword
fn getKeyword(identifier: []const u8) ?Token {
    const keyword_map = std.StaticStringMap(Token).initComptime(.{
        .{ "SELECT", .Select },
        .{ "select", .Select },
        .{ "FROM", .From },
        .{ "from", .From },
        .{ "WHERE", .Where },
        .{ "where", .Where },
        .{ "INSERT", .Insert },
        .{ "insert", .Insert },
        .{ "INTO", .Into },
        .{ "into", .Into },
        .{ "VALUES", .Values },
        .{ "values", .Values },
        .{ "UPDATE", .Update },
        .{ "update", .Update },
        .{ "SET", .Set },
        .{ "set", .Set },
        .{ "DELETE", .Delete },
        .{ "delete", .Delete },
        .{ "CREATE", .Create },
        .{ "create", .Create },
        .{ "TABLE", .Table },
        .{ "table", .Table },
        .{ "AND", .And },
        .{ "and", .And },
        .{ "OR", .Or },
        .{ "or", .Or },
        .{ "LIKE", .Like },
        .{ "like", .Like },
        .{ "IN", .In },
        .{ "in", .In },
        .{ "NULL", .Null },
        .{ "null", .Null },
        .{ "NOT", .Not },
        .{ "not", .Not },
        .{ "PRIMARY", .Primary },
        .{ "primary", .Primary },
        .{ "KEY", .Key },
        .{ "key", .Key },
        .{ "UNIQUE", .Unique },
        .{ "unique", .Unique },
        .{ "BEGIN", .Begin },
        .{ "begin", .Begin },
        .{ "COMMIT", .Commit },
        .{ "commit", .Commit },
        .{ "ROLLBACK", .Rollback },
        .{ "rollback", .Rollback },
        .{ "IF", .If },
        .{ "if", .If },
        .{ "EXISTS", .Exists },
        .{ "exists", .Exists },
        .{ "LIMIT", .Limit },
        .{ "limit", .Limit },
        .{ "OFFSET", .Offset },
        .{ "offset", .Offset },
        .{ "DEFAULT", .Default },
        .{ "default", .Default },
        .{ "FOREIGN", .Foreign },
        .{ "foreign", .Foreign },
        .{ "REFERENCES", .References },
        .{ "references", .References },
        .{ "ON", .On },
        .{ "on", .On },
        .{ "CASCADE", .Cascade },
        .{ "cascade", .Cascade },
        .{ "RESTRICT", .Restrict },
        .{ "restrict", .Restrict },
        .{ "INDEX", .Index },
        .{ "index", .Index },
        .{ "DROP", .Drop },
        .{ "drop", .Drop },
        .{ "INNER", .Inner },
        .{ "inner", .Inner },
        .{ "LEFT", .Left },
        .{ "left", .Left },
        .{ "RIGHT", .Right },
        .{ "right", .Right },
        .{ "FULL", .Full },
        .{ "full", .Full },
        .{ "OUTER", .Outer },
        .{ "outer", .Outer },
        .{ "JOIN", .Join },
        .{ "join", .Join },
        .{ "GROUP", .Group },
        .{ "group", .Group },
        .{ "BY", .By },
        .{ "by", .By },
        .{ "HAVING", .Having },
        .{ "having", .Having },
        .{ "ORDER", .Order },
        .{ "order", .Order },
        .{ "ASC", .Asc },
        .{ "asc", .Asc },
        .{ "DESC", .Desc },
        .{ "desc", .Desc },
        .{ "COUNT", .Count },
        .{ "count", .Count },
        .{ "SUM", .Sum },
        .{ "sum", .Sum },
        .{ "AVG", .Avg },
        .{ "avg", .Avg },
        .{ "MIN", .Min },
        .{ "min", .Min },
        .{ "MAX", .Max },
        .{ "max", .Max },
        .{ "STDDEV", .Stddev },
        .{ "stddev", .Stddev },
        .{ "STDDEV_POP", .Stddev },
        .{ "stddev_pop", .Stddev },
        .{ "STDEV", .Stddev },
        .{ "stdev", .Stddev },
        .{ "VARIANCE", .Variance },
        .{ "variance", .Variance },
        .{ "VAR_POP", .Variance },
        .{ "var_pop", .Variance },
        .{ "GROUP_CONCAT", .GroupConcat },
        .{ "group_concat", .GroupConcat },
        .{ "DISTINCT", .Distinct },
        .{ "distinct", .Distinct },
        .{ "AS", .As },
        .{ "as", .As },
        .{ "TRANSACTION", .Transaction },
        .{ "transaction", .Transaction },
        .{ "AUTOINCREMENT", .Autoincrement },
        .{ "autoincrement", .Autoincrement },
        .{ "CHECK", .Check },
        .{ "check", .Check },
        .{ "REPLACE", .Replace },
        .{ "replace", .Replace },
        .{ "IGNORE", .Ignore },
        .{ "ignore", .Ignore },
        .{ "CURRENT_TIMESTAMP", .Current_Timestamp },
        .{ "current_timestamp", .Current_Timestamp },
        .{ "CURRENT_DATE", .Current_Date },
        .{ "current_date", .Current_Date },
        .{ "CURRENT_TIME", .Current_Time },
        .{ "current_time", .Current_Time },
        .{ "IS", .Is },
        .{ "is", .Is },
        .{ "BETWEEN", .Between },
        .{ "between", .Between },
        .{ "CASE", .Case },
        .{ "case", .Case },
        .{ "WHEN", .When },
        .{ "when", .When },
        .{ "THEN", .Then },
        .{ "then", .Then },
        .{ "ELSE", .Else },
        .{ "else", .Else },
        .{ "END", .End },
        .{ "end", .End },
        .{ "UNION", .Union },
        .{ "union", .Union },
        .{ "INTERSECT", .Intersect },
        .{ "intersect", .Intersect },
        .{ "EXCEPT", .Except },
        .{ "except", .Except },
        .{ "ALL", .All },
        .{ "all", .All },
        .{ "COALESCE", .Coalesce },
        .{ "coalesce", .Coalesce },
        .{ "NULLIF", .Nullif },
        .{ "nullif", .Nullif },
        .{ "IFNULL", .Ifnull },
        .{ "ifnull", .Ifnull },
        .{ "UPPER", .Upper },
        .{ "upper", .Upper },
        .{ "LOWER", .Lower },
        .{ "lower", .Lower },
        .{ "SUBSTR", .Substr },
        .{ "substr", .Substr },
        .{ "SUBSTRING", .Substr },
        .{ "substring", .Substr },
        .{ "LENGTH", .Length },
        .{ "length", .Length },
        .{ "TRIM", .Trim },
        .{ "trim", .Trim },
        .{ "LTRIM", .Ltrim },
        .{ "ltrim", .Ltrim },
        .{ "RTRIM", .Rtrim },
        .{ "rtrim", .Rtrim },
        .{ "EXPLAIN", .Explain },
        .{ "explain", .Explain },
        .{ "QUERY", .Query },
        .{ "query", .Query },
        .{ "PLAN", .Plan },
        .{ "plan", .Plan },
        .{ "PRAGMA", .Pragma },
        .{ "pragma", .Pragma },
        .{ "WINDOW", .Window },
        .{ "window", .Window },
        .{ "ATTACH", .Attach },
        .{ "attach", .Attach },
        .{ "DETACH", .Detach },
        .{ "detach", .Detach },
        .{ "DATABASE", .Database },
        .{ "database", .Database },
        .{ "SCHEMA", .Schema },
        .{ "schema", .Schema },
        .{ "VIRTUAL", .Virtual },
        .{ "virtual", .Virtual },
        .{ "USING", .Using },
        .{ "using", .Using },
        .{ "MATCH", .Match },
        .{ "match", .Match },
        .{ "FTS5", .Fts5 },
        .{ "fts5", .Fts5 },
        .{ "FTS4", .Fts5 }, // Map FTS4 to FTS5 for compatibility
        .{ "fts4", .Fts5 },
        // RETURNING and UPSERT keywords
        .{ "RETURNING", .Returning },
        .{ "returning", .Returning },
        .{ "CONFLICT", .Conflict },
        .{ "conflict", .Conflict },
        .{ "DO", .Do },
        .{ "do", .Do },
        .{ "NOTHING", .Nothing },
        .{ "nothing", .Nothing },
        .{ "EXCLUDED", .Excluded },
        .{ "excluded", .Excluded },
        // Window function keywords
        .{ "OVER", .Over },
        .{ "over", .Over },
        .{ "PARTITION", .Partition },
        .{ "partition", .Partition },
        .{ "ROW_NUMBER", .Row_Number },
        .{ "row_number", .Row_Number },
        .{ "RANK", .Rank },
        .{ "rank", .Rank },
        .{ "DENSE_RANK", .Dense_Rank },
        .{ "dense_rank", .Dense_Rank },
        .{ "PERCENT_RANK", .Percent_Rank },
        .{ "percent_rank", .Percent_Rank },
        .{ "CUME_DIST", .Cume_Dist },
        .{ "cume_dist", .Cume_Dist },
        .{ "NTILE", .Ntile },
        .{ "ntile", .Ntile },
        .{ "LEAD", .Lead },
        .{ "lead", .Lead },
        .{ "LAG", .Lag },
        .{ "lag", .Lag },
        .{ "FIRST_VALUE", .First_Value },
        .{ "first_value", .First_Value },
        .{ "LAST_VALUE", .Last_Value },
        .{ "last_value", .Last_Value },
        .{ "NTH_VALUE", .Nth_Value },
        .{ "nth_value", .Nth_Value },
        .{ "ROWS", .Rows },
        .{ "rows", .Rows },
        .{ "RANGE", .Range },
        .{ "range", .Range },
        .{ "UNBOUNDED", .Unbounded },
        .{ "unbounded", .Unbounded },
        .{ "PRECEDING", .Preceding },
        .{ "preceding", .Preceding },
        .{ "FOLLOWING", .Following },
        .{ "following", .Following },
        .{ "CURRENT", .Current },
        .{ "current", .Current },
        .{ "ROW", .Row },
        .{ "row", .Row },
    });

    return keyword_map.get(identifier);
}

test "tokenizer basic" {
    const allocator = std.testing.allocator;
    var tokenizer = Tokenizer.init("SELECT * FROM users");

    const token1 = try tokenizer.nextToken(allocator);
    defer token1.deinit(allocator);
    try std.testing.expectEqual(Token.Select, token1);

    const token2 = try tokenizer.nextToken(allocator);
    defer token2.deinit(allocator);
    try std.testing.expectEqual(Token.Asterisk, token2);

    const token3 = try tokenizer.nextToken(allocator);
    defer token3.deinit(allocator);
    try std.testing.expectEqual(Token.From, token3);
}

test "tokenizer numbers" {
    const allocator = std.testing.allocator;
    var tokenizer = Tokenizer.init("42 3.14");

    const token1 = try tokenizer.nextToken(allocator);
    defer token1.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 42), token1.Integer);

    const token2 = try tokenizer.nextToken(allocator);
    defer token2.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 3.14), token2.Real);
}
