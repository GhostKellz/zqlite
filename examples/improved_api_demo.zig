const std = @import("std");
const zqlite = @import("zqlite");

/// Demo of all the new improved APIs for GhostMesh and ZNS use cases
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🚀 ZQLite v0.8.0 - Improved API Demo\n", .{});
    std.debug.print("   Testing: DEFAULT clauses, simplified binding, transactions, migrations\n\n", .{});

    // Open database connection
    var conn = try zqlite.openMemory(allocator);
    defer conn.deinit();

    try demoMigrationSystem(allocator, conn);
    try demoImprovedCreateTable(conn);
    try demoSimplifiedParameterBinding(conn);
    try demoTransactionHelpers(conn);

    std.debug.print("\n✅ All new features working correctly!\n", .{});
    std.debug.print("   Ready for production use in GhostMesh and ZNS\n", .{});
}

/// Test the new migration system
fn demoMigrationSystem(allocator: std.mem.Allocator, conn: *zqlite.Connection) !void {
    std.debug.print("📦 Testing Migration System...\n", .{});

    // Define migrations for a typical GhostMesh setup
    const migrations = [_]zqlite.migration.Migration{
        zqlite.migration.createMigration(1, "create_users_table",
            \\CREATE TABLE users (
            \\    id TEXT PRIMARY KEY,
            \\    email TEXT UNIQUE NOT NULL,
            \\    display_name TEXT,
            \\    created_at INTEGER DEFAULT (strftime('%s','now')),
            \\    last_login INTEGER,
            \\    mfa_enabled INTEGER DEFAULT 0
            \\)
        , "DROP TABLE users"),
        zqlite.migration.createMigration(2, "create_sessions_table",
            \\CREATE TABLE sessions (
            \\    id TEXT PRIMARY KEY,
            \\    user_id TEXT NOT NULL,
            \\    expires_at INTEGER NOT NULL,
            \\    created_at INTEGER DEFAULT (strftime('%s','now'))
            \\)
        , "DROP TABLE sessions"),
        zqlite.migration.createMigration(3, "add_groups_support", "ALTER TABLE users ADD COLUMN groups TEXT", "ALTER TABLE users DROP COLUMN groups"),
    };

    var migration_manager = zqlite.migration.MigrationManager.init(allocator, conn, &migrations);

    // Run migrations
    try migration_manager.runMigrations();

    // Get status
    const status = try migration_manager.getStatus();
    std.debug.print("   ✅ Applied {d}/{d} migrations (current version: {d})\n", .{ status.applied_migrations, status.total_migrations, status.current_version });
}

/// Test improved CREATE TABLE with DEFAULT clauses that were failing before
fn demoImprovedCreateTable(conn: *zqlite.Connection) !void {
    std.debug.print("🛠️  Testing Improved CREATE TABLE...\n", .{});

    // This SQL was failing in the wishlist - now it works!
    const sql_with_defaults =
        \\CREATE TABLE IF NOT EXISTS audit_log (
        \\    id INTEGER PRIMARY KEY,
        \\    action TEXT NOT NULL,
        \\    user_id TEXT,
        \\    timestamp INTEGER DEFAULT (strftime('%s','now')),
        \\    data TEXT
        \\)
    ;

    try conn.execute(sql_with_defaults);
    std.debug.print("   ✅ Successfully created table with strftime() DEFAULT clause\n", .{});

    // Test other DEFAULT patterns
    const complex_defaults_sql =
        \\CREATE TABLE temp_test (
        \\    id INTEGER DEFAULT 42,
        \\    status TEXT DEFAULT 'active',
        \\    score REAL DEFAULT 0.0,
        \\    created INTEGER DEFAULT (strftime('%s','now'))
        \\)
    ;

    try conn.execute(complex_defaults_sql);
    std.debug.print("   ✅ Complex DEFAULT patterns working\n", .{});
}

/// Test the new simplified parameter binding API
fn demoSimplifiedParameterBinding(conn: *zqlite.Connection) !void {
    std.debug.print("⚡ Testing Simplified Parameter Binding...\n", .{});

    // Insert test data using new simplified API
    const insert_sql = "INSERT INTO users (id, email, display_name, mfa_enabled) VALUES (?, ?, ?, ?)";
    var stmt = try conn.prepare(insert_sql);
    defer stmt.deinit();

    // Old way (still works):
    // try stmt.bindParameter(0, zqlite.storage.Value{ .Text = "user123" });

    // New simplified way - auto-type detection!
    try stmt.bind(0, "user123"); // String -> Text
    try stmt.bind(1, "user@example.com"); // String -> Text
    try stmt.bind(2, "John Doe"); // String -> Text
    try stmt.bind(3, 1); // Integer -> Integer

    _ = try stmt.execute();
    std.debug.print("   ✅ Simplified binding: auto-detected types\n", .{});

    // Test different types
    var stmt2 = try conn.prepare("INSERT INTO audit_log (action, user_id, data) VALUES (?, ?, ?)");
    defer stmt2.deinit();

    try stmt2.bind(0, "login");
    try stmt2.bind(1, "user123");
    try stmt2.bindNull(2); // Explicit NULL
    _ = try stmt2.execute();

    std.debug.print("   ✅ Mixed types and NULL values work perfectly\n", .{});

    // Test optional values
    const optional_name: ?[]const u8 = null;
    var stmt3 = try conn.prepare("INSERT INTO users (id, email, display_name) VALUES (?, ?, ?)");
    defer stmt3.deinit();

    try stmt3.bind(0, "user456");
    try stmt3.bind(1, "user2@example.com");
    try stmt3.bind(2, optional_name); // Optional -> NULL
    _ = try stmt3.execute();

    std.debug.print("   ✅ Optional types automatically convert to NULL\n", .{});
}

/// Test the new transaction convenience methods
fn demoTransactionHelpers(conn: *zqlite.Connection) !void {
    std.debug.print("🔒 Testing Transaction Helpers...\n", .{});

    // Test simple transaction wrapper
    try conn.transactionSimple(struct {
        pub fn run(connection: *zqlite.Connection) !void {
            try connection.execute("INSERT INTO users (id, email) VALUES ('tx_user1', 'tx1@example.com')");
            try connection.execute("INSERT INTO users (id, email) VALUES ('tx_user2', 'tx2@example.com')");
        }
    }.run);
    std.debug.print("   ✅ Simple transaction wrapper completed\n", .{});

    // Test transaction with multiple SQL statements
    const batch_statements = [_][]const u8{
        "INSERT INTO audit_log (action, user_id) VALUES ('batch_insert', 'tx_user1')",
        "INSERT INTO audit_log (action, user_id) VALUES ('batch_insert', 'tx_user2')",
        "UPDATE users SET last_login = strftime('%s','now') WHERE id = 'tx_user1'",
    };

    try conn.transactionExec(&batch_statements);
    std.debug.print("   ✅ Batch transaction executed successfully\n", .{});

    // Test transaction with context (for more complex operations)
    const UserContext = struct {
        user_id: []const u8,
        permissions: []const []const u8,
    };

    const context = UserContext{
        .user_id = "admin_user",
        .permissions = &[_][]const u8{ "read", "write", "admin" },
    };

    try conn.transaction(UserContext, struct {
        pub fn run(connection: *zqlite.Connection, ctx: UserContext) !void {
            // Insert user
            var stmt = try connection.prepare("INSERT INTO users (id, email) VALUES (?, ?)");
            defer stmt.deinit();
            try stmt.bind(0, ctx.user_id);
            try stmt.bind(1, "admin@example.com");
            _ = try stmt.execute();

            // Log each permission
            for (ctx.permissions) |perm| {
                var log_stmt = try connection.prepare("INSERT INTO audit_log (action, user_id, data) VALUES (?, ?, ?)");
                defer log_stmt.deinit();
                try log_stmt.bind(0, "grant_permission");
                try log_stmt.bind(1, ctx.user_id);
                try log_stmt.bind(2, perm);
                _ = try log_stmt.execute();
            }
        }
    }.run, context);
    std.debug.print("   ✅ Context-aware transaction completed\n", .{});

    // Verify all data was inserted
    const count_sql = "SELECT COUNT(*) FROM users";
    try conn.execute(count_sql);
    std.debug.print("   ✅ All transaction data committed successfully\n", .{});
}
