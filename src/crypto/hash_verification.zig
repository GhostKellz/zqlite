const std = @import("std");
const crypto_interface = @import("interface.zig");

/// Hash Verification System for ZQLite v0.8.0
/// Provides dependency hash validation and stability features
pub const HashVerifier = struct {
    crypto: crypto_interface.CryptoInterface,
    allocator: std.mem.Allocator,
    known_hashes: std.HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage),

    const Self = @This();

    const StringContext = struct {
        pub fn hash(self: @This(), s: []const u8) u64 {
            _ = self;
            return std.hash_map.hashString(s);
        }
        pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
            _ = self;
            return std.mem.eql(u8, a, b);
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: crypto_interface.CryptoConfig) Self {
        const crypto = crypto_interface.CryptoInterface.init(config);
        const known_hashes = std.HashMap([]const u8, []const u8, StringContext, std.hash_map.default_max_load_percentage).init(allocator);

        return Self{
            .crypto = crypto,
            .allocator = allocator,
            .known_hashes = known_hashes,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all stored strings
        var iterator = self.known_hashes.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.known_hashes.deinit();
    }

    /// Register a known good hash for a dependency
    pub fn registerKnownHash(self: *Self, name: []const u8, hash: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const hash_copy = try self.allocator.dupe(u8, hash);
        try self.known_hashes.put(name_copy, hash_copy);
    }

    /// Verify a dependency hash against known good hashes
    pub fn verifyDependencyHash(self: Self, name: []const u8, provided_hash: []const u8) bool {
        if (self.known_hashes.get(name)) |known_hash| {
            return std.mem.eql(u8, known_hash, provided_hash);
        }
        return false; // Unknown dependency, reject by default
    }

    /// Calculate file hash for verification
    pub fn calculateFileHash(self: Self, file_path: []const u8) ![]u8 {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);

        var hash: [32]u8 = undefined;
        try self.crypto.hash(buffer, &hash);

        // Convert to hex string
        const hex_chars = "0123456789abcdef";
        const hex_hash = try self.allocator.alloc(u8, 64);
        for (hash, 0..) |byte, i| {
            hex_hash[i * 2] = hex_chars[byte >> 4];
            hex_hash[i * 2 + 1] = hex_chars[byte & 0xF];
        }

        return hex_hash;
    }

    /// Initialize with default ZQLite dependency hashes
    pub fn initWithDefaults(allocator: std.mem.Allocator, config: crypto_interface.CryptoConfig) !Self {
        var verifier = Self.init(allocator, config);

        // Register known good hashes for ZQLite dependencies
        try verifier.registerKnownHash("tokioz", "TokioZ-0.0.0-DgtPReljAgAuGaoLtQCm_E-UA_7j_TAGQ8kkV-mtjz4V");
        try verifier.registerKnownHash("zcrypto", "122070b3c10a2bd82405cf1bef779789685bce2cb71dd95bfbc540b92d23f57bfd7b");

        return verifier;
    }

    /// Verify all dependencies in build.zig.zon
    pub fn verifyBuildDependencies(self: Self, build_zon_path: []const u8) !VerificationResult {
        const file = try std.fs.cwd().openFile(build_zon_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const content = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(content);

        _ = try file.readAll(content);

        var result = VerificationResult{
            .all_verified = true,
            .failed_deps = .{},
        };

        // Simple parsing to find .hash = lines
        var lines = std.mem.split(u8, content, "\n");
        var current_dep: ?[]const u8 = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");

            // Look for dependency names
            if (std.mem.indexOf(u8, trimmed, ".") == 0 and std.mem.indexOf(u8, trimmed, " = .{") != null) {
                const dot_pos = std.mem.indexOf(u8, trimmed, ".").?;
                const eq_pos = std.mem.indexOf(u8, trimmed, " = .{").?;
                current_dep = trimmed[dot_pos + 1 .. eq_pos];
            }

            // Look for hash lines
            if (std.mem.indexOf(u8, trimmed, ".hash = \"") != null) {
                const start_quote = std.mem.indexOf(u8, trimmed, "\"").? + 1;
                const end_quote = std.mem.lastIndexOf(u8, trimmed, "\"").?;
                const hash_value = trimmed[start_quote..end_quote];

                if (current_dep) |dep_name| {
                    if (!self.verifyDependencyHash(dep_name, hash_value)) {
                        result.all_verified = false;
                        try result.failed_deps.append(self.allocator, try self.allocator.dupe(u8, dep_name));
                    }
                }
            }
        }

        return result;
    }

    pub const VerificationResult = struct {
        all_verified: bool,
        failed_deps: std.ArrayListUnmanaged([]const u8),

        pub fn deinit(self: *VerificationResult, allocator: std.mem.Allocator) void {
            for (self.failed_deps.items) |dep| {
                allocator.free(dep);
            }
            self.failed_deps.deinit(allocator);
        }
    };
};

/// Stability monitoring for crypto operations
pub const StabilityMonitor = struct {
    crypto: crypto_interface.CryptoInterface,
    allocator: std.mem.Allocator,
    operation_counts: std.HashMap([]const u8, u64, StringContext, std.hash_map.default_max_load_percentage),
    error_counts: std.HashMap([]const u8, u64, StringContext, std.hash_map.default_max_load_percentage),

    const Self = @This();

    const StringContext = struct {
        pub fn hash(self: @This(), s: []const u8) u64 {
            _ = self;
            return std.hash_map.hashString(s);
        }
        pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
            _ = self;
            return std.mem.eql(u8, a, b);
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: crypto_interface.CryptoConfig) Self {
        const crypto = crypto_interface.CryptoInterface.init(config);
        const operation_counts = std.HashMap([]const u8, u64, StringContext, std.hash_map.default_max_load_percentage).init(allocator);
        const error_counts = std.HashMap([]const u8, u64, StringContext, std.hash_map.default_max_load_percentage).init(allocator);

        return Self{
            .crypto = crypto,
            .allocator = allocator,
            .operation_counts = operation_counts,
            .error_counts = error_counts,
        };
    }

    pub fn deinit(self: *Self) void {
        // Free all stored strings
        var op_iterator = self.operation_counts.iterator();
        while (op_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.operation_counts.deinit();

        var err_iterator = self.error_counts.iterator();
        while (err_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.error_counts.deinit();
    }

    /// Record a successful operation
    pub fn recordOperation(self: *Self, operation: []const u8) !void {
        const key = try self.allocator.dupe(u8, operation);
        const result = try self.operation_counts.getOrPut(key);
        if (result.found_existing) {
            self.allocator.free(key); // Don't need the duplicate
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 1;
        }
    }

    /// Record an error
    pub fn recordError(self: *Self, operation: []const u8) !void {
        const key = try self.allocator.dupe(u8, operation);
        const result = try self.error_counts.getOrPut(key);
        if (result.found_existing) {
            self.allocator.free(key); // Don't need the duplicate
            result.value_ptr.* += 1;
        } else {
            result.value_ptr.* = 1;
        }
    }

    /// Get error rate for an operation
    pub fn getErrorRate(self: Self, operation: []const u8) f64 {
        const op_count = self.operation_counts.get(operation) orelse 0;
        const err_count = self.error_counts.get(operation) orelse 0;

        if (op_count == 0) return 0.0;
        return @as(f64, @floatFromInt(err_count)) / @as(f64, @floatFromInt(op_count));
    }

    /// Check if system is stable (error rate < 1%)
    pub fn isStable(self: Self) bool {
        var op_iterator = self.operation_counts.iterator();
        while (op_iterator.next()) |entry| {
            const error_rate = self.getErrorRate(entry.key_ptr.*);
            if (error_rate > 0.01) return false; // 1% error rate threshold
        }
        return true;
    }

    /// Generate stability report
    pub fn generateReport(self: Self) ![]u8 {
        var report: std.ArrayListUnmanaged(u8) = .empty;
        const writer = report.writer(self.allocator);

        try writer.writeAll("=== ZQLite v0.8.0 Stability Report ===\n");
        try writer.print("System Stable: {}\n", .{self.isStable()});
        try writer.writeAll("\nOperation Statistics:\n");

        var op_iterator = self.operation_counts.iterator();
        while (op_iterator.next()) |entry| {
            const op_name = entry.key_ptr.*;
            const op_count = entry.value_ptr.*;
            const err_count = self.error_counts.get(op_name) orelse 0;
            const error_rate = self.getErrorRate(op_name);

            try writer.print("  {s}: {} ops, {} errors, {d:.2}% error rate\n", .{ op_name, op_count, err_count, error_rate * 100.0 });
        }

        return report.toOwnedSlice(self.allocator);
    }
};
