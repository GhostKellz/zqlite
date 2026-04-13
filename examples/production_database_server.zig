const std = @import("std");
const zqlite = @import("zqlite");

/// Database Server Example
/// Demonstrates connection pooling, backup, and monitoring patterns.
///
/// ⚠️  WARNING ⚠️
/// This is a DEMONSTRATION EXAMPLE showing design patterns.
/// It is NOT production-ready code. Before any real use:
///   1. Set ZQLITE_MASTER_KEY environment variable with a secure 32+ char key
///   2. Implement real user authentication in verifyUserCredentials()
///   3. Configure TLS/SSL for network connections
///   4. Set up proper access control and audit logging
///   5. Review and customize all security-related code paths
const ServerError = error{
    ConnectionLimitReached,
    AuthenticationFailed,
    DatabaseLocked,
    ReplicationFailed,
    BackupFailed,
    InvalidQuery,
    MasterKeyNotConfigured,
    MasterKeyTooShort,
};

/// Client connection information
pub const ClientConnection = struct {
    connection_id: u64,
    client_address: []const u8,
    connected_at: i64,
    last_activity: i64,
    authenticated: bool,
    username: []const u8,
    database: []const u8,
    queries_executed: u64,
    bytes_transferred: u64,

    /// Check if connection is still active
    pub fn isActive(self: *const ClientConnection) bool {
        const ts_now = zqlite.time_utils.getTimespec();
        const now = ts_now.sec;
        return (now - self.last_activity) < 1800; // 30 minutes timeout
    }

    /// Update activity timestamp
    pub fn updateActivity(self: *ClientConnection) void {
        const ts = zqlite.time_utils.getTimespec();

        self.last_activity = ts.sec;
    }
};

/// Database instance configuration
pub const DatabaseConfig = struct {
    name: []const u8,
    file_path: []const u8,
    max_connections: u32,
    backup_enabled: bool,
    replication_enabled: bool,
    encryption_enabled: bool,
    wal_mode: bool,
    cache_size: usize,

    /// Create full-featured configuration
    pub fn fullFeatured(name: []const u8, file_path: []const u8) DatabaseConfig {
        return DatabaseConfig{
            .name = name,
            .file_path = file_path,
            .max_connections = 1000,
            .backup_enabled = true,
            .replication_enabled = true,
            .encryption_enabled = true,
            .wal_mode = true,
            .cache_size = 256 * 1024 * 1024, // 256MB cache
        };
    }
};

/// ZQLite Database Server Example
pub const ZQLiteServer = struct {
    allocator: std.mem.Allocator,
    config: DatabaseConfig,
    crypto_engine: *zqlite.crypto.CryptoEngine,
    connections: std.HashMap(u64, ClientConnection, std.HashMap.Sha256Context, std.hash_map.default_max_load_percentage),
    connection_counter: u64,
    server_started: i64,
    total_queries: u64,

    const Self = @This();

    /// Initialize database server
    pub fn init(allocator: std.mem.Allocator, config: DatabaseConfig) !Self {
        const version = zqlite.version;
        std.debug.print("🚀 Initializing {s} - Database Server Example\n", .{version.FULL_VERSION_STRING});
        std.debug.print("Database: {s}\n", .{config.name});
        std.debug.print("File: {s}\n", .{config.file_path});

        const crypto_engine = try allocator.create(zqlite.crypto.CryptoEngine);
        // SECURITY: Master key MUST be provided externally, never hardcoded!
        // In production, load from:
        //   - Environment variable: std.posix.getenv("ZQLITE_MASTER_KEY")
        //   - Hardware security module (HSM)
        //   - Secure key management service (KMS)
        const master_key = std.posix.getenv("ZQLITE_MASTER_KEY") orelse {
            std.log.err("SECURITY ERROR: ZQLITE_MASTER_KEY environment variable not set!", .{});
            std.log.err("Set a cryptographically secure master key before starting the server.", .{});
            return error.MasterKeyNotConfigured;
        };
        if (master_key.len < 32) {
            std.log.err("SECURITY ERROR: Master key must be at least 32 characters!", .{});
            return error.MasterKeyTooShort;
        }
        crypto_engine.* = try zqlite.crypto.CryptoEngine.initWithMasterKey(allocator, master_key);

        var self = Self{
            .allocator = allocator,
            .config = config,
            .crypto_engine = crypto_engine,
            .connections = std.HashMap(u64, ClientConnection, std.HashMap.Sha256Context, std.hash_map.default_max_load_percentage).init(allocator),
            .connection_counter = 0,
            .server_started = blk: {
                const ts = zqlite.time_utils.getTimespec();
                break :blk ts.sec;
            },
            .total_queries = 0,
        };

        try self.initializeDatabase();
        try self.startBackgroundTasks();

        std.debug.print("✅ ZQLite Server initialized successfully\n", .{});
        return self;
    }

    /// Cleanup and shutdown server
    pub fn deinit(self: *Self) void {
        std.debug.print("🛑 Shutting down ZQLite Server...\n", .{});

        // Close all client connections
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            self.disconnectClient(entry.key_ptr.*) catch {};
        }

        self.connections.deinit();
        self.crypto_engine.deinit();
        self.allocator.destroy(self.crypto_engine);

        std.debug.print("✅ Server shutdown complete\n", .{});
    }

    /// Initialize database with production settings
    fn initializeDatabase(self: *Self) !void {
        std.debug.print("🗄️  Configuring database for production...\n", .{});

        // TODO: Initialize ZQLite database with:
        // - WAL mode for better concurrency
        // - Appropriate cache size
        // - Foreign key constraints
        // - Secure temp directory
        // - Performance pragmas

        if (self.config.encryption_enabled) {
            std.debug.print("🔐 Database encryption enabled\n", .{});
        }

        if (self.config.wal_mode) {
            std.debug.print("📝 WAL mode enabled for better concurrency\n", .{});
        }

        std.debug.print("💾 Cache size: {} MB\n", .{self.config.cache_size / (1024 * 1024)});
        std.debug.print("🔗 Max connections: {}\n", .{self.config.max_connections});
    }

    /// Start background maintenance tasks
    fn startBackgroundTasks(self: *Self) !void {
        _ = self;
        std.debug.print("⚙️  Starting background tasks...\n", .{});

        // TODO: Start background threads for:
        // - Connection cleanup
        // - Database maintenance (VACUUM, ANALYZE)
        // - Backup scheduling
        // - Replication synchronization
        // - Performance monitoring

        std.debug.print("✅ Background tasks started\n", .{});
    }

    /// Accept new client connection
    pub fn acceptConnection(self: *Self, client_address: []const u8) !u64 {
        if (self.connections.count() >= self.config.max_connections) {
            return ServerError.ConnectionLimitReached;
        }

        self.connection_counter += 1;
        const connection_id = self.connection_counter;

        const connection = ClientConnection{
            .connection_id = connection_id,
            .client_address = client_address,
            .connected_at = blk: {
                const ts = zqlite.time_utils.getTimespec();
                break :blk ts.sec;
            },
            .last_activity = blk: {
                const ts = zqlite.time_utils.getTimespec();
                break :blk ts.sec;
            },
            .authenticated = false,
            .username = "",
            .database = self.config.name,
            .queries_executed = 0,
            .bytes_transferred = 0,
        };

        try self.connections.put(connection_id, connection);

        std.debug.print("🤝 Client connected: {} from {s}\n", .{ connection_id, client_address });
        return connection_id;
    }

    /// Authenticate client connection
    pub fn authenticateClient(self: *Self, connection_id: u64, username: []const u8, password: []const u8) !bool {
        const connection = self.connections.getPtr(connection_id) orelse return ServerError.AuthenticationFailed;

        std.debug.print("🔐 Authenticating user: {s}\n", .{username});

        // Hash password and verify against stored hash
        const password_hash = try self.crypto_engine.hashPassword(password);
        defer self.allocator.free(password_hash);

        // TODO: Check against user database
        const is_valid = self.verifyUserCredentials(username, password_hash);

        if (is_valid) {
            connection.authenticated = true;
            connection.username = username;
            connection.updateActivity();
            std.debug.print("✅ Authentication successful for {s}\n", .{username});
        } else {
            std.debug.print("❌ Authentication failed for {s}\n", .{username});
        }

        return is_valid;
    }

    /// Execute SQL query for authenticated client
    pub fn executeQuery(self: *Self, connection_id: u64, query: []const u8) !QueryResult {
        const connection = self.connections.getPtr(connection_id) orelse return ServerError.InvalidQuery;

        if (!connection.authenticated) {
            return ServerError.AuthenticationFailed;
        }

        // SECURITY: Don't log full query content - may contain sensitive data (passwords, PII, etc.)
        // Log only query type/prefix for audit purposes
        const query_preview = if (query.len > 20) query[0..20] else query;
        std.debug.print("🔍 Executing query for {s}: {s}...\n", .{ connection.username, query_preview });

        connection.updateActivity();
        connection.queries_executed += 1;
        self.total_queries += 1;

        // TODO: Parse and execute SQL query using ZQLite engine
        // TODO: Apply security checks and permissions
        // TODO: Return structured results

        const result = QueryResult{
            .success = true,
            .rows_affected = 42,
            .execution_time_ms = 15,
            .result_data = "Sample result data",
        };

        std.debug.print("✅ Query executed successfully\n", .{});
        return result;
    }

    /// Disconnect client
    pub fn disconnectClient(self: *Self, connection_id: u64) !void {
        if (self.connections.get(connection_id)) |connection| {
            std.debug.print("👋 Disconnecting client {} ({s})\n", .{ connection_id, connection.username });
            _ = self.connections.remove(connection_id);
        }
    }

    /// Create database backup
    pub fn createBackup(self: *Self, backup_path: []const u8) !void {
        if (!self.config.backup_enabled) {
            std.debug.print("⚠️  Backup is disabled\n", .{});
            return;
        }

        std.debug.print("💾 Creating database backup: {s}\n", .{backup_path});

        // TODO: Create encrypted database backup
        // TODO: Verify backup integrity
        // TODO: Update backup metadata

        std.debug.print("✅ Backup created successfully\n", .{});
    }

    /// Get server statistics
    pub fn getServerStats(self: *Self) ServerStats {
        const ts_now = zqlite.time_utils.getTimespec();
        const uptime = ts_now.sec - self.server_started;

        return ServerStats{
            .uptime_seconds = uptime,
            .total_connections = self.connection_counter,
            .active_connections = @intCast(self.connections.count()),
            .total_queries = self.total_queries,
            .database_size_bytes = self.getDatabaseSize(),
        };
    }

    /// Verify user credentials
    /// SECURITY: This is a reference implementation - customize for your auth system
    fn verifyUserCredentials(self: *Self, username: []const u8, password_hash: []const u8) bool {
        _ = self;

        // SECURITY: NEVER accept all credentials in production!
        // This example shows the pattern - you MUST implement real verification.
        //
        // Production implementations should:
        // 1. Query user table: SELECT password_hash, salt FROM users WHERE username = ?
        // 2. Use constant-time comparison for password hashes
        // 3. Implement rate limiting and account lockout
        // 4. Log failed authentication attempts
        // 5. Consider multi-factor authentication

        // Example: Reject all logins until properly configured
        // This prevents accidental deployment with auth bypass
        if (std.posix.getenv("ZQLITE_ALLOW_DEMO_AUTH")) |_| {
            // Only allow demo auth if explicitly enabled (for development only!)
            std.log.warn("WARNING: Demo authentication enabled - DO NOT USE IN PRODUCTION!", .{});
            return std.mem.eql(u8, username, "demo") and password_hash.len > 0;
        }

        // Default: Reject all authentication until real implementation is added
        std.log.err("Authentication not configured. Implement verifyUserCredentials().", .{});
        _ = password_hash;
        return false;
    }

    /// Get database file size
    fn getDatabaseSize(self: *Self) u64 {
        _ = self;
        // TODO: Get actual database file size
        return 1024 * 1024 * 50; // 50MB placeholder
    }
};

/// SQL query execution result
pub const QueryResult = struct {
    success: bool,
    rows_affected: u64,
    execution_time_ms: u64,
    result_data: []const u8,

    pub fn print(self: *const QueryResult) void {
        if (self.success) {
            std.debug.print("✅ Query result: {} rows affected in {}ms\n", .{ self.rows_affected, self.execution_time_ms });
        } else {
            std.debug.print("❌ Query failed\n", .{});
        }
    }
};

/// Server performance statistics
pub const ServerStats = struct {
    uptime_seconds: i64,
    total_connections: u64,
    active_connections: u32,
    total_queries: u64,
    database_size_bytes: u64,

    pub fn print(self: *const ServerStats) void {
        std.debug.print("\n📊 ZQLite Server Statistics:\n", .{});
        std.debug.print("   Uptime: {} seconds\n", .{self.uptime_seconds});
        std.debug.print("   Total Connections: {}\n", .{self.total_connections});
        std.debug.print("   Active Connections: {}\n", .{self.active_connections});
        std.debug.print("   Total Queries: {}\n", .{self.total_queries});
        std.debug.print("   Database Size: {} MB\n", .{self.database_size_bytes / (1024 * 1024)});
    }
};

/// Demo production database server
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🏦 ZQLite Database Server Demo\n", .{});
    std.debug.print("==============================\n\n", .{});

    // Create full-featured configuration
    const config = DatabaseConfig.fullFeatured("demo_db", "/tmp/zqlite_demo.db");

    // Initialize server
    var server = try ZQLiteServer.init(allocator, config);
    defer server.deinit();

    // Simulate client connections
    const client1 = try server.acceptConnection("192.168.1.100:45678");
    const client2 = try server.acceptConnection("10.0.0.50:33456");
    const client3 = try server.acceptConnection("203.0.113.25:12345");

    // Authenticate clients
    _ = try server.authenticateClient(client1, "alice", "secure_password123");
    _ = try server.authenticateClient(client2, "bob", "another_password456");
    _ = try server.authenticateClient(client3, "admin", "admin_super_secure789");

    // Execute some queries
    var result1 = try server.executeQuery(client1, "SELECT * FROM users WHERE active = 1");
    result1.print();

    var result2 = try server.executeQuery(client2, "INSERT INTO orders (user_id, amount) VALUES (1, 99.99)");
    result2.print();

    var result3 = try server.executeQuery(client3, "UPDATE users SET last_login = NOW() WHERE id = 1");
    result3.print();

    // Create backup
    try server.createBackup("/backups/production_backup_2024.db.enc");

    // Show server statistics
    const stats = server.getServerStats();
    stats.print();

    // Disconnect clients
    try server.disconnectClient(client1);
    try server.disconnectClient(client2);
    try server.disconnectClient(client3);

    std.debug.print("\n✅ Database Server Demo completed!\n", .{});
    std.debug.print("This example demonstrates connection pooling, backup, and monitoring patterns.\n", .{});
}
