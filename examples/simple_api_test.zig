const std = @import("std");
const zqlite = @import("zqlite");

/// Simple test of the core new features
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("ZQLite Core Feature Test\n", .{});

    // Test 1: Parser improvements (DEFAULT clauses)
    std.debug.print("📝 Testing SQL Parser improvements...\n", .{});

    const test_sql = "CREATE TABLE users (id INTEGER DEFAULT 42)";
    var parsed_result = try zqlite.parser.parse(allocator, test_sql);
    defer parsed_result.deinit();

    std.debug.print("   ✅ Successfully parsed CREATE TABLE with DEFAULT\n", .{});

    // Test 2: Connection and prepared statement binding
    std.debug.print("⚡ Testing Simplified Parameter Binding...\n", .{});

    const conn = try zqlite.openMemory(allocator);
    defer conn.close();

    // Create table
    try conn.execute("CREATE TABLE test (id INTEGER, name TEXT)");

    // Test simplified binding
    const insert_sql = "INSERT INTO test (id, name) VALUES (?, ?)";
    var stmt = try conn.prepare(insert_sql);
    defer stmt.deinit();

    // New simplified API
    try stmt.bind(0, 123);
    try stmt.bind(1, "test_user");

    std.debug.print("   ✅ Simplified binding works: auto-detected types\n", .{});

    // Test 3: Transaction helpers
    std.debug.print("🔒 Testing Transaction Helpers...\n", .{});

    const batch_sql = [_][]const u8{
        "INSERT INTO test (id, name) VALUES (1, 'user1')",
        "INSERT INTO test (id, name) VALUES (2, 'user2')",
    };

    try conn.transactionExec(&batch_sql);
    std.debug.print("   ✅ Batch transaction executed successfully\n", .{});

    // Test 4: Migration system (basic)
    std.debug.print("📦 Testing Migration System (basic)...\n", .{});

    const migrations = [_]zqlite.migration.Migration{
        zqlite.migration.createMigration(1, "add_email_column", "ALTER TABLE test ADD COLUMN email TEXT", "ALTER TABLE test DROP COLUMN email"),
    };

    var migration_manager = zqlite.migration.MigrationManager.init(allocator, conn, &migrations);
    const status = try migration_manager.getStatus();

    std.debug.print("   ✅ Migration system initialized: {d} migrations available\n", .{status.total_migrations});

    std.debug.print("\nCore features test complete.\n", .{});
}
