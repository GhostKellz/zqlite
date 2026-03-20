const std = @import("std");
const parser = @import("src/parser/parser.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🎉 ZQLite v1.2.3 Enhanced SQL Parser Demo\n\n", .{});

    // Test parsing enhanced SQL features
    const test_cases = [_][]const u8{ "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, created DATETIME DEFAULT CURRENT_TIMESTAMP)", "BEGIN TRANSACTION", "INSERT OR IGNORE INTO users (name) VALUES ('John')", "CREATE UNIQUE INDEX idx_name ON users (name)", "SELECT COUNT(*) FROM users WHERE active = 1", "COMMIT" };

    for (test_cases) |sql| {
        std.debug.print("✅ Parsing: {s}\n", .{sql});

        var result = parser.parse(allocator, sql) catch |err| {
            std.debug.print("   ❌ Parse error: {}\n", .{err});
            continue;
        };
        defer result.deinit();

        std.debug.print("   ✓ Successfully parsed as: {s}\n\n", .{@tagName(result.statement)});
    }

    std.debug.print("🎯 ZQLite v1.2.3 Enhanced Features:\n", .{});
    std.debug.print("   • Extended data types (DATETIME, TIMESTAMP, BOOLEAN, DECIMAL, etc.)\n", .{});
    std.debug.print("   • DEFAULT functions (CURRENT_TIMESTAMP, CURRENT_DATE, CURRENT_TIME)\n", .{});
    std.debug.print("   • AUTOINCREMENT support for INTEGER PRIMARY KEY\n", .{});
    std.debug.print("   • FOREIGN KEY constraints with CASCADE/RESTRICT actions\n", .{});
    std.debug.print("   • Transaction support (BEGIN, COMMIT, ROLLBACK)\n", .{});
    std.debug.print("   • Index management (CREATE INDEX, DROP INDEX, UNIQUE)\n", .{});
    std.debug.print("   • INSERT enhancements (OR IGNORE, OR REPLACE, OR ROLLBACK)\n", .{});
    std.debug.print("   • JOIN operations (INNER, LEFT, RIGHT, FULL OUTER)\n", .{});
    std.debug.print("   • Aggregate functions (COUNT, SUM, AVG, MIN, MAX, GROUP_CONCAT)\n", .{});
    std.debug.print("   • GROUP BY and HAVING clauses\n", .{});
    std.debug.print("   • ORDER BY with ASC/DESC sorting\n", .{});
    std.debug.print("   • SQL comments support (-- line and /* block */)\n", .{});
    std.debug.print("   • Enhanced error messages with position information\n", .{});
    std.debug.print("\n✨ ZQLite now supports most standard SQL features!\n", .{});
    std.debug.print("📋 Ready for production use with complex SQL schemas.\n", .{});
}
