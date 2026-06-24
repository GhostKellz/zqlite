const std = @import("std");
const Connection = @import("connection.zig").Connection;

/// Schema migration definition
pub const Migration = struct {
    version: u32,
    name: []const u8,
    up: []const u8, // SQL to apply migration
    down: []const u8, // SQL to rollback migration

    /// Metadata for tracking migration history
    pub const MetaData = struct {
        version: u32,
        name: []const u8,
        applied_at: i64,
        checksum: []const u8,
    };
};

/// Migration manager for handling schema versions
pub const MigrationManager = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    migrations: []const Migration,

    const Self = @This();

    /// Initialize migration manager
    pub fn init(allocator: std.mem.Allocator, connection: *Connection, migrations: []const Migration) Self {
        return Self{
            .allocator = allocator,
            .connection = connection,
            .migrations = migrations,
        };
    }

    /// Run all pending migrations
    pub fn runMigrations(self: *Self) !void {
        // Get current version
        var current_version = try self.getCurrentVersion();

        // Apply pending migrations
        for (self.migrations) |migration| {
            if (migration.version > current_version) {
                try self.applyMigration(migration);
                current_version = migration.version;
            }
        }
    }

    /// Rollback to a specific version
    pub fn rollbackTo(self: *Self, target_version: u32) !void {
        const current_version = try self.getCurrentVersion();

        if (target_version >= current_version) {
            return; // Nothing to rollback
        }

        // Rollback migrations in reverse order
        var i = self.migrations.len;
        while (i > 0) {
            i -= 1;
            const migration = self.migrations[i];

            if (migration.version > target_version and migration.version <= current_version) {
                try self.rollbackMigration(migration);
            }
        }
        try self.connection.setUserVersion(target_version);
    }

    /// Apply a single migration
    fn applyMigration(self: *Self, migration: Migration) !void {
        std.log.info("Applying migration {d}: {s}", .{ migration.version, migration.name });

        const sql_statements = [_][]const u8{migration.up};
        try self.connection.transactionExec(&sql_statements);
        try self.connection.setUserVersion(migration.version);

        std.log.info("Migration {d} applied successfully", .{migration.version});
    }

    /// Rollback a single migration
    fn rollbackMigration(self: *Self, migration: Migration) !void {
        std.log.info("Rolling back migration {d}: {s}", .{ migration.version, migration.name });

        const sql_statements = [_][]const u8{migration.down};
        try self.connection.transactionExec(&sql_statements);

        std.log.info("Migration {d} rolled back successfully", .{migration.version});
    }

    /// Create migration history table if it doesn't exist
    fn ensureMigrationTable(self: *Self) !void {
        const create_sql =
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\    version INTEGER PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    applied_at INTEGER DEFAULT (strftime('%s','now')),
            \\    checksum TEXT NOT NULL
            \\)
        ;

        try self.connection.execute(create_sql);
    }

    /// Get current schema version
    fn getCurrentVersion(self: *Self) !u32 {
        return self.connection.getUserVersion();
    }

    /// Record a migration in the history table
    fn recordMigration(self: *Self, migration: Migration) !void {
        // Calculate checksum of the migration SQL
        const checksum = try self.calculateChecksum(migration.up);
        defer self.allocator.free(checksum);

        const insert_sql =
            \\INSERT INTO schema_migrations (version, name, checksum)
            \\VALUES (?, ?, ?)
        ;

        var stmt = try self.connection.prepare(insert_sql);
        defer stmt.deinit();

        try stmt.bind(0, @as(i64, @intCast(migration.version)));
        try stmt.bind(1, migration.name);
        try stmt.bind(2, @as([]const u8, checksum));

        var result = try stmt.execute();
        defer result.deinit();
    }

    /// Remove migration record
    fn removeMigrationRecord(self: *Self, version: u32) !void {
        const delete_sql = "DELETE FROM schema_migrations WHERE version = ?";

        var stmt = try self.connection.prepare(delete_sql);
        defer stmt.deinit();

        try stmt.bind(0, @as(i64, @intCast(version)));
        var result = try stmt.execute();
        defer result.deinit();
    }

    /// Calculate checksum for migration verification
    fn calculateChecksum(self: *Self, sql: []const u8) ![]u8 {
        // Simple checksum implementation using CRC32
        const hash = std.hash.Crc32.hash(sql);
        return try std.fmt.allocPrint(self.allocator, "{x}", .{hash});
    }

    /// Validate migration integrity
    pub fn validateMigrations(self: *Self) !bool {
        var previous: u32 = 0;
        for (self.migrations) |migration| {
            if (migration.version == 0 or migration.version <= previous) return false;
            previous = migration.version;
        }
        return true;
    }

    /// Get migration status information
    pub const MigrationStatus = struct {
        total_migrations: u32,
        applied_migrations: u32,
        pending_migrations: u32,
        current_version: u32,
    };

    pub fn getStatus(self: *Self) !MigrationStatus {
        const current_version = try self.getCurrentVersion();
        var applied_count: u32 = 0;

        for (self.migrations) |migration| {
            if (migration.version <= current_version) {
                applied_count += 1;
            }
        }

        return MigrationStatus{
            .total_migrations = @as(u32, @intCast(self.migrations.len)),
            .applied_migrations = applied_count,
            .pending_migrations = @as(u32, @intCast(self.migrations.len)) - applied_count,
            .current_version = current_version,
        };
    }
};

/// Helper function to create a migration
pub fn createMigration(version: u32, name: []const u8, up_sql: []const u8, down_sql: []const u8) Migration {
    return Migration{
        .version = version,
        .name = name,
        .up = up_sql,
        .down = down_sql,
    };
}

// Example usage and tests
test "migration creation" {
    const migration = createMigration(1, "create_users_table", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", "DROP TABLE users");

    try std.testing.expectEqual(@as(u32, 1), migration.version);
    try std.testing.expectEqualStrings("create_users_table", migration.name);
}

test "migration manager initialization" {
    const allocator = std.testing.allocator;

    const migrations = [_]Migration{
        createMigration(1, "test", "CREATE TABLE test (id INTEGER)", "DROP TABLE test"),
    };

    // Note: This test requires a valid connection, which we don't have in unit tests
    // In practice, you'd use a test database connection
    const manager = MigrationManager.init(allocator, undefined, &migrations);
    try std.testing.expectEqual(@as(usize, 1), manager.migrations.len);
}
