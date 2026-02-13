const std = @import("std");
const build_options = @import("build_options");

// Version information
pub const version = @import("version.zig");

// Build profile and feature flags
pub const profile = build_options.profile;
pub const features = struct {
    pub const crypto = build_options.enable_crypto;
    pub const transport = build_options.enable_transport;
    pub const json = build_options.enable_json;
    pub const performance = build_options.enable_performance;
    pub const concurrent = build_options.enable_concurrent;
    pub const ffi = build_options.enable_ffi;
};

// Open options
pub const OpenOptions = struct {
    enable_async: bool = false,
    connection_pool_size: u32 = 4,
    enable_cache: bool = false,
    btree_cache_size: usize = 1000,
    plan_cache_size: usize = 100,
    enable_sqlite_compat: bool = false,
    enable_package_manager: bool = false,
    enable_error_reporting: bool = false,
    error_history_size: usize = 1000,
};

// Core database modules
pub const db = @import("db/connection.zig");
pub const Connection = db.Connection; // Export for convenience
pub const storage = @import("db/storage.zig");
pub const btree = @import("db/btree.zig");
pub const wal = @import("db/wal.zig");
pub const pager = @import("db/pager.zig");
pub const encryption = @import("db/encryption.zig");
pub const connection_pool = @import("db/connection_pool.zig");

// SQL parsing modules
pub const tokenizer = @import("parser/tokenizer.zig");
pub const ast = @import("parser/ast.zig");
pub const parser = @import("parser/parser.zig");

// Query execution modules
pub const planner = @import("executor/planner.zig");
pub const vm = @import("executor/vm.zig");
pub const prepared_statements = @import("executor/prepared_statements.zig");
pub const window_functions = @import("executor/window_functions.zig");
pub const executor = struct {
    pub const PreparedStatement = prepared_statements.PreparedStatement;
};

// CLI shell
pub const cli = @import("shell/cli.zig");

// Structured logging
pub const logging = @import("logging/logger.zig");

// Post-quantum cryptography (profile: full, or -Dcrypto=true)
pub const crypto = if (build_options.enable_crypto)
    struct {
        pub const CryptoEngine = @import("crypto/secure_storage.zig").CryptoEngine;
        pub const CryptoTransactionLog = @import("crypto/secure_storage.zig").CryptoTransactionLog;
        pub const interface = @import("crypto/interface.zig");
        pub const hash_verification = @import("crypto/hash_verification.zig");
        pub const zns_adapter = @import("crypto/zns_adapter.zig");
    }
else
    struct {
        pub const CryptoEngine = void;
        pub const CryptoTransactionLog = void;
    };

// Async operations (profile: advanced+, or -Dconcurrent=true)
pub const async_ops = if (build_options.enable_concurrent)
    @import("concurrent/async_operations.zig")
else
    struct {};

// SQLite compatibility layer
pub const sqlite_compat = @import("sqlite_compat/sqlite_compatibility.zig");

// Performance optimizations (profile: advanced+, or -Dperformance=true)
pub const performance = if (build_options.enable_performance)
    @import("performance/cache_manager.zig")
else
    struct {};

pub const query_cache = if (build_options.enable_performance)
    @import("performance/query_cache.zig")
else
    struct {};

// Error handling
pub const error_handling = @import("error_handling/enhanced_errors.zig");
pub const database_errors = @import("error_handling/database_errors.zig");

// Time utilities (safe timestamp functions)
pub const time_utils = @import("time_utils.zig");

// Compatibility shims for Zig 0.16 (mutex/condition/clock_gettime/Instant)
pub const compat = @import("zsync/compat/thread.zig");

// PQ-QUIC transport (profile: full, or -Dtransport=true)
pub const transport = if (build_options.enable_transport)
    struct {
        pub const Transport = @import("transport/transport.zig").Transport;
        pub const PQQuicTransport = @import("transport/pq_quic.zig").PQQuicTransport;
        pub const PQDatabaseTransport = @import("transport/pq_quic.zig").PQDatabaseTransport;
    }
else
    struct {
        pub const Transport = void;
        pub const PQQuicTransport = void;
        pub const PQDatabaseTransport = void;
    };

// Advanced indexing
pub const advanced_indexes = @import("indexing/advanced_indexes.zig");

// Version and metadata
pub const build_info = version.FULL_VERSION_STRING ++ " [" ++ build_options.profile ++ "]";

// Main API functions
pub fn open(allocator: std.mem.Allocator, path: []const u8) !*db.Connection {
    // Handle special :memory: path for in-memory databases
    if (std.mem.eql(u8, path, ":memory:")) {
        return db.Connection.openMemory(allocator);
    }
    return db.Connection.open(allocator, path);
}

pub fn openMemory(allocator: std.mem.Allocator) !*db.Connection {
    return db.Connection.openMemory(allocator);
}

/// Create connection pool for high-concurrency applications
pub fn createConnectionPool(allocator: std.mem.Allocator, database_path: ?[]const u8, min_connections: u32, max_connections: u32) !*connection_pool.ConnectionPool {
    return connection_pool.ConnectionPool.init(allocator, database_path, min_connections, max_connections);
}

/// Create query cache (requires performance feature)
pub fn createQueryCache(allocator: std.mem.Allocator, max_entries: usize, max_memory_bytes: usize) !*query_cache.QueryCache {
    if (!build_options.enable_performance) {
        @compileError("Query cache requires -Dperformance=true or profile=advanced/full");
    }
    return query_cache.QueryCache.init(allocator, max_entries, max_memory_bytes);
}

/// Query hasher for cache key generation (requires performance feature)
pub const QueryHasher = if (build_options.enable_performance)
    query_cache.QueryHasher
else
    @compileError("QueryHasher requires -Dperformance=true or profile=advanced/full");

/// Generate UUID v4
pub fn generateUUID(random: std.Random) [16]u8 {
    return ast.UUIDUtils.generateV4(random);
}

/// Parse UUID from string
pub fn parseUUID(uuid_str: []const u8) ![16]u8 {
    return ast.UUIDUtils.parseFromString(uuid_str);
}

/// Convert UUID to string
pub fn uuidToString(uuid: [16]u8, allocator: std.mem.Allocator) ![]u8 {
    return ast.UUIDUtils.toString(uuid, allocator);
}

/// Print build info for demos
pub fn printBuildInfo() void {
    std.debug.print("ZQLite {s}\n", .{version.VERSION_STRING});
    std.debug.print("  Profile: {s}\n", .{build_options.profile});
    std.debug.print("  Features:\n", .{});
    if (build_options.enable_crypto) std.debug.print("    - Post-quantum crypto\n", .{});
    if (build_options.enable_transport) std.debug.print("    - PQ-QUIC transport\n", .{});
    if (build_options.enable_json) std.debug.print("    - JSON support\n", .{});
    if (build_options.enable_performance) std.debug.print("    - Query cache & connection pool\n", .{});
    if (build_options.enable_concurrent) std.debug.print("    - Async operations\n", .{});
    if (build_options.enable_ffi) std.debug.print("    - C API (FFI)\n", .{});
}

// Tests
test "zqlite version info" {
    try std.testing.expect(std.mem.eql(u8, version.VERSION_STRING, "1.5.3"));
}

test "build info contains version" {
    try std.testing.expect(std.mem.indexOf(u8, version.FULL_VERSION_STRING, "ZQLite") != null);
}

test "features reflect build options" {
    if (features.crypto) {
        _ = crypto.CryptoEngine;
    }
    if (features.transport) {
        _ = transport.Transport;
    }
}
