const std = @import("std");
const zqlite = @import("zqlite");
const parser = @import("zqlite").parser;

/// SQL Parser Fuzzer - Generates random SQL and tests parser robustness
/// This fuzzer helps find:
/// - Parser crashes
/// - Memory leaks
/// - Infinite loops
/// - Assertion failures
/// - Edge cases in SQL syntax handling
const FuzzConfig = struct {
    seed: u64,
    iterations: usize,
    max_sql_length: usize,
    verbose: bool,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("⚠️  Memory leak detected during fuzzing\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const config = FuzzConfig{
        .seed = @intCast(blk: {
            const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
            break :blk ts.sec;
        }),
        .iterations = 10000,
        .max_sql_length = 1000,
        .verbose = false,
    };

    std.debug.print("🎯 SQL Parser Fuzzer\n", .{});
    std.debug.print("   Seed: {}\n", .{config.seed});
    std.debug.print("   Iterations: {}\n", .{config.iterations});
    std.debug.print("   Max SQL length: {}\n\n", .{config.max_sql_length});

    var fuzzer = try SqlFuzzer.init(allocator, config);
    defer fuzzer.deinit();

    try fuzzer.run();

    std.debug.print("\n✅ Fuzzing completed successfully!\n", .{});
    fuzzer.printStats();
}

const SqlFuzzer = struct {
    allocator: std.mem.Allocator,
    config: FuzzConfig,
    rng: std.Random.DefaultPrng,
    stats: FuzzStats,

    const FuzzStats = struct {
        total_tests: usize = 0,
        successful_parses: usize = 0,
        parse_errors: usize = 0,
        crashes: usize = 0,
        unique_errors: std.StringHashMap(usize),
    };

    fn init(allocator: std.mem.Allocator, config: FuzzConfig) !SqlFuzzer {
        return SqlFuzzer{
            .allocator = allocator,
            .config = config,
            .rng = std.Random.DefaultPrng.init(config.seed),
            .stats = FuzzStats{
                .unique_errors = std.StringHashMap(usize).init(allocator),
            },
        };
    }

    fn deinit(self: *SqlFuzzer) void {
        var it = self.stats.unique_errors.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.stats.unique_errors.deinit();
    }

    fn run(self: *SqlFuzzer) !void {
        var i: usize = 0;
        while (i < self.config.iterations) : (i += 1) {
            if (i % 1000 == 0) {
                std.debug.print("\rProgress: {}/{} ({d:.1}%)", .{
                    i,
                    self.config.iterations,
                    @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(self.config.iterations)) * 100.0,
                });
            }

            // Generate random SQL
            const sql = try self.generateRandomSql();
            defer self.allocator.free(sql);

            // Test parser
            try self.testParseSql(sql);

            self.stats.total_tests += 1;
        }
        std.debug.print("\rProgress: {}/{} (100.0%)  \n", .{ self.config.iterations, self.config.iterations });
    }

    fn generateRandomSql(self: *SqlFuzzer) ![]const u8 {
        const strategy = self.rng.random().intRangeAtMost(u8, 0, 9);

        return switch (strategy) {
            0 => try self.generateSelect(),
            1 => try self.generateInsert(),
            2 => try self.generateUpdate(),
            3 => try self.generateDelete(),
            4 => try self.generateCreateTable(),
            5 => try self.generateMalformed(),
            6 => try self.generateLongInput(),
            7 => try self.generateSpecialChars(),
            8 => try self.generateNestedQuery(),
            9 => try self.generateTransaction(),
            else => unreachable,
        };
    }

    fn generateSelect(self: *SqlFuzzer) ![]const u8 {
        const choice = self.rng.random().intRangeAtMost(u8, 0, 5);
        const table = self.randomIdentifier();
        const col1 = self.randomIdentifier();
        const col2 = self.randomIdentifier();
        const val1 = self.rng.random().intRangeAtMost(i32, 0, 1000);
        const val2 = self.rng.random().intRangeAtMost(i32, 0, 1000);

        return switch (choice) {
            0 => std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table}),
            1 => std.fmt.allocPrint(self.allocator, "SELECT {s}, {s} FROM {s}", .{ col1, col2, table }),
            2 => std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} = {d}", .{ table, col1, val1 }),
            3 => std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM {s}", .{table}),
            4 => std.fmt.allocPrint(self.allocator, "SELECT {s} FROM {s} LIMIT {d}", .{ col1, table, val1 }),
            5 => std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} > {d} AND {s} < {d}", .{ table, col1, val1, col2, val2 }),
            else => unreachable,
        };
    }

    fn generateInsert(self: *SqlFuzzer) ![]const u8 {
        const table = self.randomIdentifier();
        const col = self.randomIdentifier();
        const val = self.rng.random().intRangeAtMost(i32, 0, 1000);

        return std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO {s} ({s}) VALUES ({d})",
            .{ table, col, val },
        );
    }

    fn generateUpdate(self: *SqlFuzzer) ![]const u8 {
        const table = self.randomIdentifier();
        const col = self.randomIdentifier();
        const val = self.rng.random().intRangeAtMost(i32, 0, 1000);

        return std.fmt.allocPrint(
            self.allocator,
            "UPDATE {s} SET {s} = {d}",
            .{ table, col, val },
        );
    }

    fn generateDelete(self: *SqlFuzzer) ![]const u8 {
        const table = self.randomIdentifier();
        const col = self.randomIdentifier();
        const val = self.rng.random().intRangeAtMost(i32, 0, 1000);

        return std.fmt.allocPrint(
            self.allocator,
            "DELETE FROM {s} WHERE {s} = {d}",
            .{ table, col, val },
        );
    }

    fn generateCreateTable(self: *SqlFuzzer) ![]const u8 {
        const choice = self.rng.random().intRangeAtMost(u8, 0, 3);
        const table = self.randomIdentifier();
        const col1 = self.randomIdentifier();
        const col2 = self.randomIdentifier();

        return switch (choice) {
            0 => std.fmt.allocPrint(self.allocator, "CREATE TABLE {s} ({s} INTEGER, {s} TEXT)", .{ table, col1, col2 }),
            1 => std.fmt.allocPrint(self.allocator, "CREATE TABLE {s} ({s} INTEGER PRIMARY KEY, {s} TEXT DEFAULT 'test')", .{ table, col1, col2 }),
            2 => std.fmt.allocPrint(self.allocator, "CREATE TABLE {s} ({s} INTEGER, {s} TEXT NOT NULL)", .{ table, col1, col2 }),
            3 => std.fmt.allocPrint(self.allocator, "CREATE TABLE IF NOT EXISTS {s} ({s} INTEGER)", .{ table, col1 }),
            else => unreachable,
        };
    }

    fn generateMalformed(self: *SqlFuzzer) ![]const u8 {
        const malformed = [_][]const u8{
            "SELECT * FROM",
            "INSERT INTO",
            "UPDATE SET",
            "DELETE WHERE",
            "CREATE TABLE",
            "SELECT * FROM WHERE",
            "INSERT INTO () VALUES ()",
            "UPDATE SET = ",
            ";;;",
            "SELECT SELECT SELECT",
            "FROM WHERE JOIN",
        };

        const idx = self.rng.random().intRangeAtMost(usize, 0, malformed.len - 1);
        return self.allocator.dupe(u8, malformed[idx]);
    }

    fn generateLongInput(self: *SqlFuzzer) ![]const u8 {
        const table = self.randomIdentifier();
        const col1 = self.randomIdentifier();
        const col2 = self.randomIdentifier();
        const col3 = self.randomIdentifier();

        // Create a long SELECT with many columns (simplified)
        return std.fmt.allocPrint(
            self.allocator,
            "SELECT {s}, {s}, {s}, {s}, {s}, {s}, {s}, {s}, {s}, {s} FROM {s}",
            .{ col1, col2, col3, col1, col2, col3, col1, col2, col3, col1, table },
        );
    }

    fn generateSpecialChars(self: *SqlFuzzer) ![]const u8 {
        const special_chars = [_][]const u8{
            "SELECT * FROM table WHERE name = 'O''Reilly'",
            "SELECT * FROM table WHERE data = '\\'escape\\''",
            "SELECT * FROM `weird``table`",
            "SELECT * FROM \"table\" WHERE \"column\" = 1",
            "SELECT /* comment */ * FROM table",
            "SELECT -- comment\n* FROM table",
        };

        const idx = self.rng.random().intRangeAtMost(usize, 0, special_chars.len - 1);
        return self.allocator.dupe(u8, special_chars[idx]);
    }

    fn generateNestedQuery(self: *SqlFuzzer) ![]const u8 {
        const table1 = self.randomIdentifier();
        const table2 = self.randomIdentifier();
        const col = self.randomIdentifier();

        return std.fmt.allocPrint(
            self.allocator,
            "SELECT * FROM {s} WHERE {s} IN (SELECT {s} FROM {s})",
            .{ table1, col, col, table2 },
        );
    }

    fn generateTransaction(self: *SqlFuzzer) ![]const u8 {
        const cmds = [_][]const u8{
            "BEGIN TRANSACTION",
            "COMMIT",
            "ROLLBACK",
            "BEGIN",
        };

        const idx = self.rng.random().intRangeAtMost(usize, 0, cmds.len - 1);
        return self.allocator.dupe(u8, cmds[idx]);
    }

    fn randomIdentifier(self: *SqlFuzzer) []const u8 {
        const identifiers = [_][]const u8{
            "users",
            "products",
            "orders",
            "id",
            "name",
            "value",
            "data",
            "created_at",
        };

        return identifiers[self.rng.random().intRangeAtMost(usize, 0, identifiers.len - 1)];
    }

    fn testParseSql(self: *SqlFuzzer, sql: []const u8) !void {
        if (self.config.verbose) {
            std.debug.print("Testing: {s}\n", .{sql});
        }

        // Try to parse the SQL
        var parsed = parser.parse(self.allocator, sql) catch |err| {
            self.stats.parse_errors += 1;

            // Track unique error types
            const error_name = @errorName(err);
            const gop = try self.stats.unique_errors.getOrPut(error_name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, error_name);
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;

            return;
        };
        defer parsed.deinit();

        self.stats.successful_parses += 1;
    }

    fn printStats(self: *SqlFuzzer) void {
        std.debug.print("\n📊 Fuzzing Statistics:\n", .{});
        std.debug.print("   Total tests: {}\n", .{self.stats.total_tests});
        std.debug.print("   Successful parses: {} ({d:.1}%)\n", .{
            self.stats.successful_parses,
            @as(f64, @floatFromInt(self.stats.successful_parses)) / @as(f64, @floatFromInt(self.stats.total_tests)) * 100.0,
        });
        std.debug.print("   Parse errors: {} ({d:.1}%)\n", .{
            self.stats.parse_errors,
            @as(f64, @floatFromInt(self.stats.parse_errors)) / @as(f64, @floatFromInt(self.stats.total_tests)) * 100.0,
        });
        std.debug.print("   Crashes: {}\n", .{self.stats.crashes});

        std.debug.print("\n📝 Unique Error Types:\n", .{});
        var it = self.stats.unique_errors.iterator();
        while (it.next()) |entry| {
            std.debug.print("   {s}: {} occurrences\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
};
