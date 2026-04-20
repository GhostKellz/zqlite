const std = @import("std");

/// ZQLite Production Hardening Utilities
///
/// This module provides security hardening functions for production deployments.
/// Features include:
/// - Secure memory management (zeroing sensitive data)
/// - Input validation and sanitization
/// - Rate limiting for database operations
/// - Audit logging for security-relevant events
/// - Resource limits and quotas
/// Securely zero memory to prevent sensitive data from remaining in memory.
/// Uses volatile operations to prevent compiler optimization.
pub fn secureZero(buffer: []u8) void {
    @memset(buffer, 0);
    // Prevent compiler from optimizing away the memset
    std.mem.doNotOptimizeAway(buffer.ptr);
}

/// Securely zero a fixed-size buffer
pub fn secureZeroFixed(comptime N: usize, buffer: *[N]u8) void {
    @memset(buffer, 0);
    std.mem.doNotOptimizeAway(buffer);
}

/// Constant-time byte comparison to prevent timing attacks
pub fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return std.crypto.timing_safe.eql([*]const u8, a.ptr, b.ptr, a.len);
}

/// Input sanitization for SQL identifiers (table names, column names)
/// Returns error if identifier contains invalid characters
pub fn sanitizeIdentifier(identifier: []const u8) ![]const u8 {
    if (identifier.len == 0) return error.EmptyIdentifier;
    if (identifier.len > 128) return error.IdentifierTooLong;

    // First character must be letter or underscore
    const first = identifier[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') {
        return error.InvalidIdentifierStart;
    }

    // Remaining characters must be alphanumeric or underscore
    for (identifier[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return error.InvalidIdentifierCharacter;
        }
    }

    return identifier;
}

/// Rate limiter for database operations
pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    window_size_ns: u64,
    max_requests: u32,
    requests: std.AutoHashMap(u64, RequestWindow),
    mutex: std.Io.Mutex = .init,

    const RequestWindow = struct {
        count: u32,
        window_start: std.time.Instant,
    };

    const Self = @This();

    /// Initialize rate limiter with window size in seconds and max requests per window
    pub fn init(allocator: std.mem.Allocator, window_size_seconds: u32, max_requests: u32) Self {
        return Self{
            .allocator = allocator,
            .window_size_ns = @as(u64, window_size_seconds) * std.time.ns_per_s,
            .max_requests = max_requests,
            .requests = std.AutoHashMap(u64, RequestWindow).init(allocator),
            .mutex = .{},
        };
    }

    /// Check if a request from the given client ID should be allowed
    pub fn allowRequest(self: *Self, client_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.Instant.now() catch return false;

        if (self.requests.getPtr(client_id)) |window| {
            // Check if we're still in the same window
            if (now.since(window.window_start) < self.window_size_ns) {
                if (window.count >= self.max_requests) {
                    return false; // Rate limited
                }
                window.count += 1;
                return true;
            } else {
                // New window
                window.window_start = now;
                window.count = 1;
                return true;
            }
        } else {
            // First request from this client
            self.requests.put(client_id, RequestWindow{
                .count = 1,
                .window_start = now,
            }) catch return false;
            return true;
        }
    }

    /// Reset rate limit for a specific client
    pub fn resetClient(self: *Self, client_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.requests.remove(client_id);
    }

    /// Clean up expired windows
    pub fn cleanup(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.Instant.now() catch return;
        var to_remove: std.ArrayList(u64) = .empty;
        defer to_remove.deinit(self.allocator);

        var iterator = self.requests.iterator();
        while (iterator.next()) |entry| {
            if (now.since(entry.value_ptr.window_start) > self.window_size_ns * 2) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            _ = self.requests.remove(key);
        }
    }

    pub fn deinit(self: *Self) void {
        self.requests.deinit();
    }
};

/// Audit log entry for security events
pub const AuditEntry = struct {
    timestamp: i64,
    event_type: AuditEventType,
    client_id: ?u64,
    details: []const u8,
    success: bool,
};

pub const AuditEventType = enum {
    ConnectionOpen,
    ConnectionClose,
    AuthenticationAttempt,
    AuthenticationSuccess,
    AuthenticationFailure,
    QueryExecuted,
    TransactionBegin,
    TransactionCommit,
    TransactionRollback,
    SchemaChange,
    PermissionDenied,
    RateLimitExceeded,
    ConfigChange,
};

/// Audit logger for security-relevant events
/// SECURITY: Automatically redacts sensitive data from log entries
pub const AuditLogger = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(AuditEntry),
    max_entries: usize,
    mutex: std.Io.Mutex = .init,
    file: ?std.fs.File,
    enable_redaction: bool,

    const Self = @This();

    /// Sensitive patterns to redact from audit logs
    const SENSITIVE_PATTERNS = [_][]const u8{
        "password",
        "passwd",
        "pwd",
        "secret",
        "token",
        "api_key",
        "apikey",
        "bearer",
        "credential",
        "private_key",
        "authorization",
        "master_key",
        "encryption_key",
    };

    /// Initialize audit logger with optional file output
    /// Redaction is enabled by default for security
    pub fn init(allocator: std.mem.Allocator, max_entries: usize, log_path: ?[]const u8) !Self {
        return initWithOptions(allocator, max_entries, log_path, true);
    }

    /// Initialize with explicit redaction control
    /// WARNING: Disabling redaction may expose sensitive data in logs
    pub fn initWithOptions(allocator: std.mem.Allocator, max_entries: usize, log_path: ?[]const u8, enable_redaction: bool) !Self {
        var file: ?std.fs.File = null;
        if (log_path) |path| {
            file = try std.fs.cwd().createFile(path, .{ .truncate = false });
            try file.?.seekFromEnd(0);
        }

        if (!enable_redaction) {
            std.log.warn("SECURITY: Audit log redaction disabled - sensitive data may be logged", .{});
        }

        return Self{
            .allocator = allocator,
            .entries = .empty,
            .max_entries = max_entries,
            .mutex = .{},
            .file = file,
            .enable_redaction = enable_redaction,
        };
    }

    /// Log an audit event with automatic redaction of sensitive data
    pub fn log(self: *Self, event_type: AuditEventType, client_id: ?u64, details: []const u8, success: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ts = std.time.timestamp();

        // Redact sensitive data from details
        const safe_details = if (self.enable_redaction)
            try self.redactSensitiveData(details)
        else
            try self.allocator.dupe(u8, details);

        const entry = AuditEntry{
            .timestamp = ts,
            .event_type = event_type,
            .client_id = client_id,
            .details = safe_details,
            .success = success,
        };

        // Write to file if configured
        if (self.file) |file| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{d}|{s}|{?d}|{s}|{s}\n", .{
                entry.timestamp,
                @tagName(entry.event_type),
                entry.client_id,
                entry.details,
                if (entry.success) "OK" else "FAIL",
            }) catch &buf;
            file.writeAll(line) catch {};
        }

        // Maintain in-memory log with rotation
        if (self.entries.items.len >= self.max_entries) {
            // Remove oldest entry
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old.details);
        }

        try self.entries.append(self.allocator, entry);
    }

    /// Log an audit event with pre-redacted safe details
    /// Use this when you've already ensured the details are safe
    pub fn logSafe(self: *Self, event_type: AuditEventType, client_id: ?u64, safe_details: []const u8, success: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ts = std.time.timestamp();

        const entry = AuditEntry{
            .timestamp = ts,
            .event_type = event_type,
            .client_id = client_id,
            .details = try self.allocator.dupe(u8, safe_details),
            .success = success,
        };

        if (self.file) |file| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{d}|{s}|{?d}|{s}|{s}\n", .{
                entry.timestamp,
                @tagName(entry.event_type),
                entry.client_id,
                entry.details,
                if (entry.success) "OK" else "FAIL",
            }) catch &buf;
            file.writeAll(line) catch {};
        }

        if (self.entries.items.len >= self.max_entries) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old.details);
        }

        try self.entries.append(self.allocator, entry);
    }

    /// Redact sensitive patterns from detail string
    fn redactSensitiveData(self: *Self, input: []const u8) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            const remaining = input[i..];
            var found_sensitive = false;

            for (SENSITIVE_PATTERNS) |pattern| {
                if (startsWithIgnoreCase(remaining, pattern)) {
                    const pattern_end = i + pattern.len;
                    if (pattern_end < input.len) {
                        const next_char = input[pattern_end];
                        if (next_char == '=' or next_char == ':' or next_char == '"') {
                            // Append the key and delimiter
                            try result.appendSlice(self.allocator, input[i..pattern_end]);
                            try result.append(self.allocator, next_char);

                            // Skip whitespace and quotes
                            var value_start = pattern_end + 1;
                            while (value_start < input.len and (input[value_start] == ' ' or input[value_start] == '"' or input[value_start] == '\'')) {
                                try result.append(self.allocator, input[value_start]);
                                value_start += 1;
                            }

                            // Find value end
                            var value_end = value_start;
                            while (value_end < input.len) {
                                const c = input[value_end];
                                if (c == ' ' or c == ',' or c == '\n' or c == '\r' or c == '"' or c == '\'' or c == '}' or c == '&' or c == '|') {
                                    break;
                                }
                                value_end += 1;
                            }

                            // Replace value with redaction placeholder
                            try result.appendSlice(self.allocator, "[REDACTED]");
                            i = value_end;
                            found_sensitive = true;
                            break;
                        }
                    }
                }
            }

            if (!found_sensitive) {
                try result.append(self.allocator, input[i]);
                i += 1;
            }
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        for (haystack[0..needle.len], needle) |h, n| {
            if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
        }
        return true;
    }

    /// Get recent audit entries
    pub fn getRecent(self: *Self, count: usize) []const AuditEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const start = if (self.entries.items.len > count) self.entries.items.len - count else 0;
        return self.entries.items[start..];
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.details);
        }
        self.entries.deinit(self.allocator);
        if (self.file) |file| {
            file.close();
        }
    }
};

/// Resource limits for database operations
pub const ResourceLimits = struct {
    max_query_size: usize = 1024 * 1024, // 1MB
    max_result_rows: usize = 100_000,
    max_connections: u32 = 100,
    max_transaction_duration_seconds: u32 = 300, // 5 minutes
    max_memory_per_query: usize = 64 * 1024 * 1024, // 64MB
    max_concurrent_transactions: u32 = 50,

    const Self = @This();

    pub fn validateQuerySize(self: Self, size: usize) !void {
        if (size > self.max_query_size) {
            return error.QueryTooLarge;
        }
    }

    pub fn validateResultCount(self: Self, count: usize) !void {
        if (count > self.max_result_rows) {
            return error.TooManyResults;
        }
    }
};

/// Connection validator for security checks
pub const ConnectionValidator = struct {
    allowed_hosts: std.ArrayList([]const u8),
    blocked_hosts: std.ArrayList([]const u8),
    require_tls: bool,
    min_tls_version: TLSVersion,
    allocator: std.mem.Allocator,

    pub const TLSVersion = enum {
        TLS12,
        TLS13,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allowed_hosts = .empty,
            .blocked_hosts = .empty,
            .require_tls = true,
            .min_tls_version = .TLS13,
            .allocator = allocator,
        };
    }

    pub fn allowHost(self: *Self, host: []const u8) !void {
        try self.allowed_hosts.append(self.allocator, try self.allocator.dupe(u8, host));
    }

    pub fn blockHost(self: *Self, host: []const u8) !void {
        try self.blocked_hosts.append(self.allocator, try self.allocator.dupe(u8, host));
    }

    pub fn isHostAllowed(self: *Self, host: []const u8) bool {
        // Check blocklist first
        for (self.blocked_hosts.items) |blocked| {
            if (std.mem.eql(u8, blocked, host)) {
                return false;
            }
        }

        // If allowlist is empty, allow all non-blocked hosts
        if (self.allowed_hosts.items.len == 0) {
            return true;
        }

        // Check allowlist
        for (self.allowed_hosts.items) |allowed| {
            if (std.mem.eql(u8, allowed, host)) {
                return true;
            }
        }

        return false;
    }

    pub fn deinit(self: *Self) void {
        for (self.allowed_hosts.items) |host| {
            self.allocator.free(host);
        }
        self.allowed_hosts.deinit(self.allocator);

        for (self.blocked_hosts.items) |host| {
            self.allocator.free(host);
        }
        self.blocked_hosts.deinit(self.allocator);
    }
};

/// Production configuration validation
pub const ConfigValidator = struct {
    /// Validate database configuration for production use
    pub fn validateProductionConfig(config: anytype) !void {
        // Check for insecure defaults
        if (@hasField(@TypeOf(config), "encryption_enabled")) {
            if (!config.encryption_enabled) {
                return error.EncryptionRequired;
            }
        }

        if (@hasField(@TypeOf(config), "password")) {
            if (config.password.len < 12) {
                return error.PasswordTooWeak;
            }
        }

        if (@hasField(@TypeOf(config), "max_connections")) {
            if (config.max_connections > 10000) {
                return error.TooManyConnections;
            }
        }
    }

    /// Check if running in debug mode (should warn in production)
    pub fn isDebugMode() bool {
        return @import("builtin").mode == .Debug;
    }

    /// Get recommended production settings
    pub fn getRecommendedSettings() ResourceLimits {
        return ResourceLimits{
            .max_query_size = 512 * 1024, // 512KB
            .max_result_rows = 10_000,
            .max_connections = 50,
            .max_transaction_duration_seconds = 60,
            .max_memory_per_query = 32 * 1024 * 1024, // 32MB
            .max_concurrent_transactions = 25,
        };
    }
};

// Tests
test "secure zero" {
    var buffer: [32]u8 = undefined;
    @memset(&buffer, 0xAA);
    secureZero(&buffer);

    for (buffer) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "sanitize identifier" {
    // Valid identifiers
    _ = try sanitizeIdentifier("users");
    _ = try sanitizeIdentifier("_private");
    _ = try sanitizeIdentifier("User123");

    // Invalid identifiers
    try std.testing.expectError(error.EmptyIdentifier, sanitizeIdentifier(""));
    try std.testing.expectError(error.InvalidIdentifierStart, sanitizeIdentifier("123abc"));
    try std.testing.expectError(error.InvalidIdentifierCharacter, sanitizeIdentifier("user-name"));
}

test "rate limiter" {
    var limiter = RateLimiter.init(std.testing.allocator, 1, 3);
    defer limiter.deinit();

    const client_id: u64 = 12345;

    // First 3 requests should be allowed
    try std.testing.expect(limiter.allowRequest(client_id));
    try std.testing.expect(limiter.allowRequest(client_id));
    try std.testing.expect(limiter.allowRequest(client_id));

    // 4th request should be denied
    try std.testing.expect(!limiter.allowRequest(client_id));
}

test "resource limits" {
    const limits = ResourceLimits{};

    try limits.validateQuerySize(1000);
    try std.testing.expectError(error.QueryTooLarge, limits.validateQuerySize(2 * 1024 * 1024));
}
