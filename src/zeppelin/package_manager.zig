const std = @import("std");
const storage = @import("../db/storage.zig");
const connection = @import("../db/connection.zig");
const zqlite = @import("../zqlite.zig");
const crypto = zqlite.crypto;

/// Get current time in milliseconds using compat clock
fn getMilliTimestamp() i64 {
    const ts = zqlite.time_utils.getTimespec();
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Zeppelin Package Manager integration for zqlite v1.2.5
/// Provides package dependency tracking, version management, and integrity verification
pub const ZeppelinPackageManager = struct {
    allocator: std.mem.Allocator,
    connection: *connection.Connection,
    crypto_engine: ?*crypto.CryptoEngine,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, conn: *connection.Connection) !Self {
        var self = Self{
            .allocator = allocator,
            .connection = conn,
            .crypto_engine = null,
        };

        // Initialize crypto engine if available
        if (@hasDecl(@import("root"), "zqlite_enable_crypto")) {
            self.crypto_engine = try crypto.CryptoEngine.init(allocator);
        }

        // Create package management tables
        try self.initializeTables();

        return self;
    }

    /// Initialize package management database tables
    fn initializeTables(self: *Self) !void {
        const create_packages_table =
            \\CREATE TABLE IF NOT EXISTS zeppelin_packages (
            \\    package_id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    version TEXT NOT NULL,
            \\    description TEXT,
            \\    author TEXT,
            \\    repository_url TEXT,
            \\    license TEXT,
            \\    created_at INTEGER NOT NULL,
            \\    updated_at INTEGER NOT NULL,
            \\    file_hash BLOB,
            \\    signature BLOB,
            \\    metadata_json TEXT
            \\)
        ;

        const create_dependencies_table =
            \\CREATE TABLE IF NOT EXISTS zeppelin_dependencies (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    package_id TEXT NOT NULL,
            \\    dependency_package_id TEXT NOT NULL,
            \\    version_constraint TEXT NOT NULL,
            \\    dependency_type TEXT NOT NULL, -- 'runtime', 'build', 'dev', 'optional'
            \\    created_at INTEGER NOT NULL,
            \\    FOREIGN KEY (package_id) REFERENCES zeppelin_packages(package_id),
            \\    FOREIGN KEY (dependency_package_id) REFERENCES zeppelin_packages(package_id)
            \\)
        ;

        const create_versions_table =
            \\CREATE TABLE IF NOT EXISTS zeppelin_package_versions (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    package_id TEXT NOT NULL,
            \\    version TEXT NOT NULL,
            \\    release_date INTEGER NOT NULL,
            \\    is_prerelease BOOLEAN DEFAULT FALSE,
            \\    is_deprecated BOOLEAN DEFAULT FALSE,
            \\    download_count INTEGER DEFAULT 0,
            \\    file_size INTEGER,
            \\    checksum TEXT,
            \\    release_notes TEXT,
            \\    UNIQUE(package_id, version),
            \\    FOREIGN KEY (package_id) REFERENCES zeppelin_packages(package_id)
            \\)
        ;

        const create_registry_table =
            \\CREATE TABLE IF NOT EXISTS zeppelin_registry_mirrors (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    name TEXT NOT NULL UNIQUE,
            \\    base_url TEXT NOT NULL,
            \\    priority INTEGER DEFAULT 100,
            \\    is_active BOOLEAN DEFAULT TRUE,
            \\    last_sync_at INTEGER,
            \\    public_key BLOB,
            \\    created_at INTEGER NOT NULL
            \\)
        ;

        const create_installed_packages_table =
            \\CREATE TABLE IF NOT EXISTS zeppelin_installed_packages (
            \\    package_id TEXT PRIMARY KEY,
            \\    installed_version TEXT NOT NULL,
            \\    install_path TEXT NOT NULL,
            \\    installed_at INTEGER NOT NULL,
            \\    installed_by TEXT,
            \\    is_dev_dependency BOOLEAN DEFAULT FALSE,
            \\    FOREIGN KEY (package_id) REFERENCES zeppelin_packages(package_id)
            \\)
        ;

        // Execute table creation
        _ = try self.connection.execute(create_packages_table);
        _ = try self.connection.execute(create_dependencies_table);
        _ = try self.connection.execute(create_versions_table);
        _ = try self.connection.execute(create_registry_table);
        _ = try self.connection.execute(create_installed_packages_table);

        // Create indexes for performance
        _ = try self.connection.execute("CREATE INDEX IF NOT EXISTS idx_packages_name ON zeppelin_packages(name)");
        _ = try self.connection.execute("CREATE INDEX IF NOT EXISTS idx_dependencies_package ON zeppelin_dependencies(package_id)");
        _ = try self.connection.execute("CREATE INDEX IF NOT EXISTS idx_dependencies_dep_package ON zeppelin_dependencies(dependency_package_id)");
        _ = try self.connection.execute("CREATE INDEX IF NOT EXISTS idx_versions_package ON zeppelin_package_versions(package_id)");
        _ = try self.connection.execute("CREATE INDEX IF NOT EXISTS idx_versions_release_date ON zeppelin_package_versions(release_date DESC)");
    }

    /// Register a new package
    pub fn registerPackage(self: *Self, package: PackageInfo) !void {
        const current_time = getMilliTimestamp();

        // Serialize metadata to JSON
        const metadata_json = try self.serializePackageMetadata(package.metadata);
        defer self.allocator.free(metadata_json);

        // Calculate file hash if crypto is available
        var file_hash: ?[]const u8 = null;
        var signature: ?[]const u8 = null;

        if (self.crypto_engine) |crypto_eng| {
            if (package.file_content) |content| {
                file_hash = try crypto_eng.hash(content);
                signature = try crypto_eng.sign(content);
            }
        }

        // Using direct SQL formatting instead of prepared statements for simplicity

        // Execute insert (simplified - in production, use prepared statements)
        const full_sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO zeppelin_packages " ++
            "(package_id, name, version, description, author, repository_url, license, " ++
            "created_at, updated_at, file_hash, signature, metadata_json) " ++
            "VALUES ('{}', '{}', '{}', '{}', '{}', '{}', '{}', {}, {}, {}, {}, '{}')", .{
            package.package_id,
            package.name,
            package.version,
            package.description orelse "",
            package.author orelse "",
            package.repository_url orelse "",
            package.license orelse "",
            current_time,
            current_time,
            if (file_hash) |h| std.fmt.fmtSliceHexLower(h) else "NULL",
            if (signature) |s| std.fmt.fmtSliceHexLower(s) else "NULL",
            metadata_json,
        });
        defer self.allocator.free(full_sql);

        _ = try self.connection.execute(full_sql);

        // Register version
        try self.addPackageVersion(package.package_id, package.version, PackageVersion{
            .version = package.version,
            .release_date = current_time,
            .is_prerelease = package.metadata.is_prerelease,
            .file_size = if (package.file_content) |content| content.len else 0,
            .release_notes = package.metadata.release_notes,
        });

        // Add dependencies
        if (package.dependencies) |deps| {
            for (deps) |dep| {
                try self.addDependency(package.package_id, dep);
            }
        }
    }

    /// Add a package version
    pub fn addPackageVersion(self: *Self, package_id: []const u8, version: []const u8, version_info: PackageVersion) !void {
        const insert_sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO zeppelin_package_versions " ++
            "(package_id, version, release_date, is_prerelease, is_deprecated, " ++
            "file_size, release_notes) " ++
            "VALUES ('{}', '{}', {}, {}, {}, {}, '{}')", .{
            package_id,
            version,
            version_info.release_date,
            if (version_info.is_prerelease) 1 else 0,
            if (version_info.is_deprecated) 1 else 0,
            version_info.file_size,
            version_info.release_notes orelse "",
        });
        defer self.allocator.free(insert_sql);

        _ = try self.connection.execute(insert_sql);
    }

    /// Add a dependency
    pub fn addDependency(self: *Self, package_id: []const u8, dependency: Dependency) !void {
        const current_time = getMilliTimestamp();

        const insert_sql = try std.fmt.allocPrint(self.allocator, "INSERT INTO zeppelin_dependencies " ++
            "(package_id, dependency_package_id, version_constraint, dependency_type, created_at) " ++
            "VALUES ('{}', '{}', '{}', '{}', {})", .{
            package_id,
            dependency.package_id,
            dependency.version_constraint,
            @tagName(dependency.dependency_type),
            current_time,
        });
        defer self.allocator.free(insert_sql);

        _ = try self.connection.execute(insert_sql);
    }

    /// Get package dependency graph
    pub fn getDependencyGraph(self: *Self, package_id: []const u8) !DependencyGraph {
        var graph = DependencyGraph.init(self.allocator);
        var visited = std.hash_map.HashMap([]const u8, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer visited.deinit();

        try self.buildDependencyGraph(package_id, &graph, &visited, 0);

        return graph;
    }

    /// Resolve dependencies using topological sort
    pub fn resolveDependencies(self: *Self, root_packages: [][]const u8) ![][]const u8 {
        var all_dependencies = std.hash_map.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer {
            var iterator = all_dependencies.iterator();
            while (iterator.next()) |entry| {
                entry.value_ptr.deinit();
            }
            all_dependencies.deinit();
        }

        // Collect all dependencies
        for (root_packages) |package_id| {
            try self.collectAllDependencies(package_id, &all_dependencies);
        }

        // Perform topological sort
        return try self.topologicalSort(&all_dependencies);
    }

    /// Verify package integrity using cryptographic signatures
    pub fn verifyPackageIntegrity(self: *Self, package_id: []const u8, file_content: []const u8) !bool {
        if (self.crypto_engine) |crypto_eng| {
            // Get stored hash and signature
            const query_sql = try std.fmt.allocPrint(self.allocator, "SELECT file_hash, signature FROM zeppelin_packages WHERE package_id = '{}'", .{package_id});
            defer self.allocator.free(query_sql);

            const result = try self.connection.execute(query_sql);
            defer result.deinit(self.allocator);

            if (result.rows.len == 0) {
                return false; // Package not found
            }

            const stored_hash = switch (result.rows[0].values[0]) {
                .Text => |t| t,
                .Blob => |b| b,
                else => return false,
            };

            const stored_signature = switch (result.rows[0].values[1]) {
                .Text => |t| t,
                .Blob => |b| b,
                else => return false,
            };

            // Verify hash
            const computed_hash = try crypto_eng.hash(file_content);
            defer self.allocator.free(computed_hash);

            if (!std.mem.eql(u8, stored_hash, std.fmt.fmtSliceHexLower(computed_hash))) {
                return false;
            }

            // Verify signature
            return crypto_eng.verify(file_content, stored_signature);
        }

        // If no crypto engine, just return true (no verification)
        return true;
    }

    /// Search packages by name pattern
    pub fn searchPackages(self: *Self, pattern: []const u8) ![]PackageInfo {
        const search_sql = try std.fmt.allocPrint(self.allocator, "SELECT package_id, name, version, description, author, repository_url, license, metadata_json " ++
            "FROM zeppelin_packages WHERE name LIKE '%{}%' OR description LIKE '%{}%' " ++
            "ORDER BY name", .{ pattern, pattern });
        defer self.allocator.free(search_sql);

        const result = try self.connection.execute(search_sql);
        defer result.deinit(self.allocator);

        var packages = std.ArrayList(PackageInfo).init(self.allocator);

        for (result.rows) |row| {
            const package_info = PackageInfo{
                .package_id = switch (row.values[0]) {
                    .Text => |t| try self.allocator.dupe(u8, t),
                    else => continue,
                },
                .name = switch (row.values[1]) {
                    .Text => |t| try self.allocator.dupe(u8, t),
                    else => continue,
                },
                .version = switch (row.values[2]) {
                    .Text => |t| try self.allocator.dupe(u8, t),
                    else => continue,
                },
                .description = switch (row.values[3]) {
                    .Text => |t| try self.allocator.dupe(u8, t),
                    .Null => null,
                    else => continue,
                },
                .author = switch (row.values[4]) {
                    .Text => |t| try self.allocator.dupe(u8, t),
                    .Null => null,
                    else => continue,
                },
                .repository_url = switch (row.values[5]) {
                    .Text => |t| try self.allocator.dupe(u8, t),
                    .Null => null,
                    else => continue,
                },
                .license = switch (row.values[6]) {
                    .Text => |t| try self.allocator.dupe(u8, t),
                    .Null => null,
                    else => continue,
                },
                .metadata = try self.deserializePackageMetadata(switch (row.values[7]) {
                    .Text => |t| t,
                    else => "{}",
                }),
                .dependencies = null,
                .file_content = null,
            };

            try packages.append(package_info);
        }

        return try packages.toOwnedSlice();
    }

    /// Get package statistics
    pub fn getPackageStats(self: *Self) !PackageStats {
        const stats_sql =
            \\SELECT 
            \\    (SELECT COUNT(*) FROM zeppelin_packages) as total_packages,
            \\    (SELECT COUNT(*) FROM zeppelin_package_versions) as total_versions,
            \\    (SELECT COUNT(*) FROM zeppelin_dependencies) as total_dependencies,
            \\    (SELECT COUNT(*) FROM zeppelin_installed_packages) as installed_packages,
            \\    (SELECT AVG(download_count) FROM zeppelin_package_versions) as avg_downloads
        ;

        const result = try self.connection.execute(stats_sql);
        defer result.deinit(self.allocator);

        if (result.rows.len == 0) {
            return PackageStats{};
        }

        const row = result.rows[0];
        return PackageStats{
            .total_packages = switch (row.values[0]) {
                .Integer => |i| @intCast(i),
                else => 0,
            },
            .total_versions = switch (row.values[1]) {
                .Integer => |i| @intCast(i),
                else => 0,
            },
            .total_dependencies = switch (row.values[2]) {
                .Integer => |i| @intCast(i),
                else => 0,
            },
            .installed_packages = switch (row.values[3]) {
                .Integer => |i| @intCast(i),
                else => 0,
            },
            .avg_download_count = switch (row.values[4]) {
                .Real => |r| r,
                .Integer => |i| @floatFromInt(i),
                else => 0.0,
            },
        };
    }

    // Helper functions
    fn buildDependencyGraph(self: *Self, package_id: []const u8, graph: *DependencyGraph, visited: *std.hash_map.HashMap([]const u8, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage), depth: u32) !void {
        if (visited.contains(package_id) or depth > 100) { // Prevent infinite recursion
            return;
        }

        try visited.put(try self.allocator.dupe(u8, package_id), {});

        const deps_sql = try std.fmt.allocPrint(self.allocator, "SELECT dependency_package_id, version_constraint, dependency_type " ++
            "FROM zeppelin_dependencies WHERE package_id = '{}'", .{package_id});
        defer self.allocator.free(deps_sql);

        const result = try self.connection.execute(deps_sql);
        defer result.deinit(self.allocator);

        for (result.rows) |row| {
            const dep_package_id = switch (row.values[0]) {
                .Text => |t| t,
                else => continue,
            };
            const version_constraint = switch (row.values[1]) {
                .Text => |t| t,
                else => continue,
            };
            const dependency_type = switch (row.values[2]) {
                .Text => |t| t,
                else => continue,
            };

            const dep = Dependency{
                .package_id = try self.allocator.dupe(u8, dep_package_id),
                .version_constraint = try self.allocator.dupe(u8, version_constraint),
                .dependency_type = std.meta.stringToEnum(DependencyType, dependency_type) orelse .runtime,
            };

            try graph.addDependency(try self.allocator.dupe(u8, package_id), dep);

            // Recursively build graph for dependencies
            try self.buildDependencyGraph(dep_package_id, graph, visited, depth + 1);
        }
    }

    fn collectAllDependencies(self: *Self, package_id: []const u8, all_deps: *std.hash_map.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage)) !void {
        if (all_deps.contains(package_id)) {
            return; // Already processed
        }

        var package_deps = std.ArrayList([]const u8).init(self.allocator);

        const deps_sql = try std.fmt.allocPrint(self.allocator, "SELECT dependency_package_id FROM zeppelin_dependencies WHERE package_id = '{}'", .{package_id});
        defer self.allocator.free(deps_sql);

        const result = try self.connection.execute(deps_sql);
        defer result.deinit(self.allocator);

        for (result.rows) |row| {
            const dep_package_id = switch (row.values[0]) {
                .Text => |t| t,
                else => continue,
            };
            try package_deps.append(try self.allocator.dupe(u8, dep_package_id));

            // Recursively collect dependencies
            try self.collectAllDependencies(dep_package_id, all_deps);
        }

        try all_deps.put(try self.allocator.dupe(u8, package_id), package_deps);
    }

    fn topologicalSort(self: *Self, graph: *std.hash_map.HashMap([]const u8, std.ArrayList([]const u8), std.hash_map.StringContext, std.hash_map.default_max_load_percentage)) ![][]const u8 {
        var in_degree = std.hash_map.HashMap([]const u8, u32, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer in_degree.deinit();

        var queue = std.ArrayList([]const u8).init(self.allocator);
        defer queue.deinit();

        var result = std.ArrayList([]const u8).init(self.allocator);

        // Calculate in-degrees
        var graph_iterator = graph.iterator();
        while (graph_iterator.next()) |entry| {
            const package_id = entry.key_ptr.*;
            try in_degree.put(package_id, 0);

            for (entry.value_ptr.items) |dep| {
                const current_degree = in_degree.get(dep) orelse 0;
                try in_degree.put(dep, current_degree + 1);
            }
        }

        // Find nodes with no incoming edges
        var in_degree_iterator = in_degree.iterator();
        while (in_degree_iterator.next()) |entry| {
            if (entry.value_ptr.* == 0) {
                try queue.append(entry.key_ptr.*);
            }
        }

        // Process queue
        while (queue.items.len > 0) {
            const current = queue.swapRemove(0);
            try result.append(current);

            if (graph.get(current)) |neighbors| {
                for (neighbors.items) |neighbor| {
                    if (in_degree.getPtr(neighbor)) |degree_ptr| {
                        degree_ptr.* -= 1;
                        if (degree_ptr.* == 0) {
                            try queue.append(neighbor);
                        }
                    }
                }
            }
        }

        return try result.toOwnedSlice();
    }

    fn serializePackageMetadata(self: *Self, metadata: PackageMetadata) ![]u8 {
        // Simple JSON serialization - in production, use a proper JSON library
        return try std.fmt.allocPrint(self.allocator, "{{\"is_prerelease\":{},\"release_notes\":\"{}\",\"build_hash\":\"{}\",\"keywords\":[]}}", .{
            if (metadata.is_prerelease) "true" else "false",
            metadata.release_notes orelse "",
            metadata.build_hash orelse "",
        });
    }

    fn deserializePackageMetadata(self: *Self, json_str: []const u8) !PackageMetadata {
        _ = self; // Remove unused variable warning
        _ = json_str; // Remove unused variable warning

        // Simple deserialization - in production, use a proper JSON parser
        return PackageMetadata{
            .is_prerelease = false,
            .release_notes = null,
            .build_hash = null,
            .keywords = &[_][]const u8{},
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.crypto_engine) |crypto_eng| {
            crypto_eng.deinit();
        }
    }
};

// Data structures
pub const PackageInfo = struct {
    package_id: []const u8,
    name: []const u8,
    version: []const u8,
    description: ?[]const u8,
    author: ?[]const u8,
    repository_url: ?[]const u8,
    license: ?[]const u8,
    metadata: PackageMetadata,
    dependencies: ?[]Dependency,
    file_content: ?[]const u8, // For integrity checking
};

pub const PackageMetadata = struct {
    is_prerelease: bool,
    release_notes: ?[]const u8,
    build_hash: ?[]const u8,
    keywords: [][]const u8,
};

pub const PackageVersion = struct {
    version: []const u8,
    release_date: i64,
    is_prerelease: bool = false,
    is_deprecated: bool = false,
    file_size: usize,
    release_notes: ?[]const u8,
};

pub const Dependency = struct {
    package_id: []const u8,
    version_constraint: []const u8, // e.g., ">=1.0.0", "~1.2.0", "^2.0.0"
    dependency_type: DependencyType,
};

pub const DependencyType = enum {
    runtime,
    build,
    dev,
    optional,
};

pub const DependencyGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.hash_map.HashMap([]const u8, std.ArrayList(Dependency), std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: std.mem.Allocator) DependencyGraph {
        return DependencyGraph{
            .allocator = allocator,
            .nodes = std.hash_map.HashMap([]const u8, std.ArrayList(Dependency), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn addDependency(self: *DependencyGraph, package_id: []const u8, dependency: Dependency) !void {
        var deps = self.nodes.get(package_id) orelse std.ArrayList(Dependency).init(self.allocator);
        try deps.append(dependency);
        try self.nodes.put(package_id, deps);
    }

    pub fn deinit(self: *DependencyGraph) void {
        var iterator = self.nodes.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.nodes.deinit();
    }
};

pub const PackageStats = struct {
    total_packages: u32 = 0,
    total_versions: u32 = 0,
    total_dependencies: u32 = 0,
    installed_packages: u32 = 0,
    avg_download_count: f64 = 0.0,
};
