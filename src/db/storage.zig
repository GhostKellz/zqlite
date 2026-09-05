const std = @import("std");
const btree = @import("btree.zig");
const pager = @import("pager.zig");
const memory_pool = @import("memory_pool.zig");
const ast = @import("../parser/ast.zig");

/// Row identifier type used throughout the database
pub const RowId = u64;

/// Persistent descriptor for one catalog chain slot (one half of the A/B pair).
const SlotDescriptor = struct {
    first_page: u32 = 0,
    page_count: u32 = 0,
    payload_len: u64 = 0,
    checksum: u32 = 0,
    generation: u64 = 0,
};

/// In-memory mirror of the on-disk superblock. The catalog payload is stored in
/// one of two alternating page chains; `active_slot` selects the live one. A
/// rewrite always targets the inactive slot and is only made authoritative by a
/// separate, fsync-ordered superblock update, so a crash mid-rewrite never
/// destroys the last durable catalog.
const CatalogState = struct {
    active_slot: u8 = 0,
    generation: u64 = 0,
    slots: [2]SlotDescriptor = .{ .{}, .{} },
};

/// Storage engine that manages tables and data persistence
pub const StorageEngine = struct {
    allocator: std.mem.Allocator,
    pager: *pager.Pager,
    memory_pool: memory_pool.MemoryPool,
    pooled_allocator: memory_pool.PooledAllocator,
    tables: std.StringHashMap(*Table),
    indexes: std.StringHashMap(*Index),
    fts_indexes: std.StringHashMap(*FTSIndex), // Full-text search indexes
    is_memory: bool,
    read_only: bool,
    catalog: CatalogState,
    user_version: u32,
    schema_version: u32,
    /// True when the database was opened in the legacy single-page catalog
    /// format and has not yet been migrated to the superblock format.
    legacy_format: bool,

    const Self = @This();

    /// Initialize storage engine with file backing
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Self {
        return initWithMode(allocator, path, .read_write);
    }

    /// Initialize storage engine with file backing and explicit access mode.
    pub fn initWithMode(allocator: std.mem.Allocator, path: []const u8, mode: pager.Pager.OpenMode) !*Self {
        var engine = try allocator.create(Self);
        errdefer allocator.destroy(engine);

        engine.allocator = allocator;
        engine.pager = try pager.Pager.initWithMode(allocator, path, mode);
        errdefer engine.pager.deinit();

        engine.memory_pool = memory_pool.MemoryPool.init(allocator);
        engine.pooled_allocator = memory_pool.PooledAllocator.init(&engine.memory_pool);
        engine.tables = std.StringHashMap(*Table).init(allocator);
        engine.indexes = std.StringHashMap(*Index).init(allocator);
        engine.fts_indexes = std.StringHashMap(*FTSIndex).init(allocator);
        engine.is_memory = false;
        engine.read_only = mode == .read_only;
        engine.catalog = .{};
        engine.user_version = 0;
        engine.schema_version = 0;
        engine.legacy_format = false;

        // If opening the catalog fails (I/O error, corruption, or an unsupported
        // format) tear down anything that was partially loaded so the caller is
        // not left owning a half-initialized engine.
        errdefer {
            var t_it = engine.tables.iterator();
            while (t_it.next()) |e| {
                e.value_ptr.*.deinit();
                engine.allocator.free(e.key_ptr.*);
            }
            engine.tables.deinit();
            var i_it = engine.indexes.iterator();
            while (i_it.next()) |e| {
                e.value_ptr.*.deinit(engine.allocator);
                engine.allocator.free(e.key_ptr.*);
            }
            engine.indexes.deinit();
            var f_it = engine.fts_indexes.iterator();
            while (f_it.next()) |e| {
                e.value_ptr.*.deinit(engine.allocator);
                engine.allocator.free(e.key_ptr.*);
            }
            engine.fts_indexes.deinit();
            engine.memory_pool.deinit();
        }

        // Load existing catalog from file
        try engine.loadCatalog();

        return engine;
    }

    /// Initialize in-memory storage engine
    pub fn initMemory(allocator: std.mem.Allocator) !*Self {
        var engine = try allocator.create(Self);
        errdefer allocator.destroy(engine);

        engine.allocator = allocator;
        engine.pager = try pager.Pager.initMemory(allocator);
        errdefer engine.pager.deinit();

        engine.memory_pool = memory_pool.MemoryPool.init(allocator);
        engine.pooled_allocator = memory_pool.PooledAllocator.init(&engine.memory_pool);
        engine.tables = std.StringHashMap(*Table).init(allocator);
        engine.indexes = std.StringHashMap(*Index).init(allocator);
        engine.fts_indexes = std.StringHashMap(*FTSIndex).init(allocator);
        engine.is_memory = true;
        engine.read_only = false;
        engine.catalog = .{};
        engine.user_version = 0;
        engine.schema_version = 0;
        engine.legacy_format = false;

        return engine;
    }

    /// Get the pooled allocator for efficient memory management
    pub fn getPooledAllocator(self: *Self) std.mem.Allocator {
        return self.pooled_allocator.allocator();
    }

    /// Get memory pool statistics
    pub fn getMemoryStats(self: *Self) memory_pool.MemoryPool.GlobalStats {
        return self.memory_pool.getGlobalStats();
    }

    /// Cleanup unused memory pools
    pub fn cleanupMemory(self: *Self) void {
        self.memory_pool.cleanup();
    }

    /// Create a new table
    pub fn createTable(self: *Self, name: []const u8, schema: TableSchema) !void {
        try self.ensureWritable();

        // Check if table already exists
        if (self.tables.contains(name)) {
            return error.TableAlreadyExists;
        }

        const table = try Table.create(self.allocator, self.pager, name, schema);
        errdefer table.deinit();

        const duped_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(duped_name);

        try self.tables.put(duped_name, table);
        self.bumpSchemaVersion();

        // Persist table metadata if not in-memory
        if (self.shouldPersistCatalogNow()) {
            try self.saveTableMetadata(table);
        }
    }

    /// Get a table by name
    pub fn getTable(self: *Self, name: []const u8) ?*Table {
        return self.tables.get(name);
    }

    /// Get all table names in the database (v1.2.2 broad API)
    pub fn getTableNames(self: *Self, allocator: std.mem.Allocator) ![][]const u8 {
        var table_names = try allocator.alloc([]const u8, self.tables.count());
        var iterator = self.tables.iterator();
        var index: usize = 0;

        while (iterator.next()) |entry| {
            table_names[index] = try allocator.dupe(u8, entry.key_ptr.*);
            index += 1;
        }

        return table_names;
    }

    /// Drop a table
    pub fn dropTable(self: *Self, name: []const u8) !void {
        try self.ensureWritable();

        if (self.tables.fetchRemove(name)) |entry| {
            entry.value.deinit();
            self.allocator.free(entry.key);
            self.bumpSchemaVersion();

            // Rewrite metadata page atomically after drop
            if (self.shouldPersistCatalogNow()) {
                try self.rewriteAllMetadata();
            }
        }
    }

    /// Rename an independent table without rewriting row pages. Tables with
    /// indexes, FTS state, or foreign-key dependencies are rejected until those
    /// catalog objects can be migrated as one unit.
    pub fn renameTable(self: *Self, old_name: []const u8, new_name: []const u8) !void {
        try self.ensureWritable();
        const table = self.tables.get(old_name) orelse return error.TableNotFound;
        if (self.tables.contains(new_name)) return error.TableAlreadyExists;
        if (self.fts_indexes.contains(old_name)) return error.UnsupportedAlterTableDependency;
        var index_it = self.indexes.iterator();
        while (index_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.table_name, old_name)) return error.UnsupportedAlterTableDependency;
        }
        var table_it = self.tables.iterator();
        while (table_it.next()) |entry| {
            for (entry.value_ptr.*.schema.foreign_keys) |foreign_key| {
                if (std.mem.eql(u8, entry.value_ptr.*.name, old_name) or
                    std.mem.eql(u8, foreign_key.reference_table, old_name))
                {
                    return error.UnsupportedAlterTableDependency;
                }
            }
        }

        try self.tables.ensureUnusedCapacity(1);
        const new_key = try self.allocator.dupe(u8, new_name);
        errdefer self.allocator.free(new_key);
        const new_table_name = try self.allocator.dupe(u8, new_name);
        errdefer self.allocator.free(new_table_name);
        const old_schema_version = self.schema_version;
        const old_table_name = table.name;
        const entry = self.tables.fetchRemove(old_name).?;
        table.name = new_table_name;
        self.tables.putAssumeCapacity(new_key, table);
        self.bumpSchemaVersion();

        self.rewriteAllMetadata() catch |err| {
            const inserted = self.tables.fetchRemove(new_name).?;
            _ = inserted;
            table.name = old_table_name;
            self.tables.putAssumeCapacity(entry.key, table);
            self.schema_version = old_schema_version;
            return err;
        };
        self.allocator.free(entry.key);
        self.allocator.free(old_table_name);
    }

    /// Rename a column whose name is not referenced by another schema object.
    pub fn renameColumn(self: *Self, table_name: []const u8, old_name: []const u8, new_name: []const u8) !void {
        try self.ensureWritable();
        const table = self.tables.get(table_name) orelse return error.TableNotFound;
        const column_idx = table.getColumnIndex(old_name) orelse return error.ColumnNotFound;
        if (table.getColumnIndex(new_name) != null) return error.ColumnAlreadyExists;
        if (table.schema.check_constraints.len != 0) return error.UnsupportedAlterTableDependency;
        for (table.schema.columns) |column| {
            if (column.generated != null) return error.UnsupportedAlterTableDependency;
        }
        for (table.schema.foreign_keys) |foreign_key| {
            if (foreign_key.columns) |columns| for (columns) |column| {
                if (std.mem.eql(u8, column, old_name)) return error.UnsupportedAlterTableDependency;
            };
            if (foreign_key.reference_columns) |columns| for (columns) |column| {
                if (std.mem.eql(u8, column, old_name)) return error.UnsupportedAlterTableDependency;
            };
            if ((foreign_key.column != null and std.mem.eql(u8, foreign_key.column.?, old_name)) or
                std.mem.eql(u8, foreign_key.reference_column, old_name))
            {
                return error.UnsupportedAlterTableDependency;
            }
        }
        var other_tables = self.tables.iterator();
        while (other_tables.next()) |entry| {
            for (entry.value_ptr.*.schema.foreign_keys) |foreign_key| {
                if (foreign_key.reference_columns) |columns| for (columns) |column| {
                    if (std.mem.eql(u8, foreign_key.reference_table, table_name) and std.mem.eql(u8, column, old_name)) {
                        return error.UnsupportedAlterTableDependency;
                    }
                };
                if (std.mem.eql(u8, foreign_key.reference_table, table_name) and
                    std.mem.eql(u8, foreign_key.reference_column, old_name))
                {
                    return error.UnsupportedAlterTableDependency;
                }
            }
        }
        var index_it = self.indexes.iterator();
        while (index_it.next()) |entry| {
            const index = entry.value_ptr.*;
            if (!std.mem.eql(u8, index.table_name, table_name)) continue;
            for (index.column_names) |column_name| {
                if (std.mem.eql(u8, column_name, old_name)) return error.UnsupportedAlterTableDependency;
            }
        }

        const replacement = try self.allocator.dupe(u8, new_name);
        const old_column_name = table.schema.columns[column_idx].name;
        const old_schema_version = self.schema_version;
        table.schema.columns[column_idx].name = replacement;
        self.bumpSchemaVersion();
        self.rewriteAllMetadata() catch |err| {
            table.schema.columns[column_idx].name = old_column_name;
            self.schema_version = old_schema_version;
            self.allocator.free(replacement);
            return err;
        };
        self.allocator.free(old_column_name);
    }

    /// Rewrite rows into a replacement tree before publishing its root and
    /// schema together. Existing rows retain their keys and storage format.
    pub fn addColumn(self: *Self, table_name: []const u8, column: Column) !void {
        try self.ensureWritable();
        const table = self.tables.get(table_name) orelse return error.TableNotFound;
        if (table.getColumnIndex(column.name) != null) return error.ColumnAlreadyExists;
        if (column.is_primary_key or column.is_unique or column.generated != null) return error.UnsupportedAlterTableColumn;
        var fill: Value = .Null;
        if (table.row_count != 0) {
            if (column.default_value) |default| {
                fill = switch (default) {
                    .Literal => |value| value,
                    .FunctionCall => return error.UnsupportedAlterTableDefault,
                };
            }
            if (!column.is_nullable and fill == .Null) return error.MissingRequiredValue;
        }

        const old_columns = table.schema.columns;
        const expanded = try self.allocator.alloc(Column, old_columns.len + 1);
        errdefer self.allocator.free(expanded);
        @memcpy(expanded[0..old_columns.len], old_columns);
        const new_name = try self.allocator.dupe(u8, column.name);
        errdefer self.allocator.free(new_name);
        const new_default = if (column.default_value) |default_value| try default_value.clone(self.allocator) else null;
        errdefer if (new_default) |default_value| default_value.deinit(self.allocator);
        expanded[old_columns.len] = .{
            .name = new_name,
            .data_type = column.data_type,
            .is_primary_key = false,
            .is_nullable = column.is_nullable,
            .default_value = new_default,
            .generated = null,
            .is_unique = false,
        };

        const old_tree = table.btree;
        const replacement = try btree.BTree.init(self.allocator, self.pager);
        errdefer replacement.deinit();
        const rows = try old_tree.selectAllWithKeys(self.allocator);
        defer {
            for (rows) |item| {
                var row = item.row;
                row.deinit(self.allocator);
            }
            self.allocator.free(rows);
        }
        for (rows) |item| {
            const values = try self.allocator.alloc(Value, expanded.len);
            var initialized: usize = 0;
            errdefer {
                for (values[0..initialized]) |value| value.deinit(self.allocator);
                self.allocator.free(values);
            }
            for (item.row.values, 0..) |value, i| {
                values[i] = try value.clone(self.allocator);
                initialized += 1;
            }
            values[old_columns.len] = try fill.clone(self.allocator);
            initialized += 1;
            try replacement.insert(item.key, .{ .values = values });
        }

        const old_schema_version = self.schema_version;
        table.schema.columns = expanded;
        table.btree = replacement;
        self.bumpSchemaVersion();
        self.rewriteAllMetadata() catch |err| {
            table.schema.columns = old_columns;
            table.btree = old_tree;
            self.schema_version = old_schema_version;
            return err;
        };
        old_tree.deinit();
        self.allocator.free(old_columns);
    }

    /// Atomically rewrite the catalog using the versioned superblock format.
    ///
    /// The full catalog is serialized into a single owned buffer, written to the
    /// inactive A/B chain, and only then made authoritative by a separate,
    /// fsync-ordered superblock update. A crash at any point leaves the previous
    /// durable catalog intact, and the serialized buffer cannot silently truncate
    /// records the way the old single-page writer could.
    fn rewriteAllMetadata(self: *Self) !void {
        if (!self.shouldPersistCatalogNow()) return;
        try self.ensureWritable();

        const payload = try self.serializeCatalog();
        defer self.allocator.free(payload);

        const inactive: usize = if (self.catalog.active_slot == 0) 1 else 0;

        // 1. Write the catalog payload into the inactive slot's page chain.
        var new_slot = try self.writeCatalogPayload(inactive, payload);
        new_slot.generation = self.catalog.generation + 1;

        // Barrier 1: the chain pages must be durable before the superblock can
        // reference them, so a crash mid-rewrite never exposes a torn catalog.
        try self.pager.flush();

        // Build the prospective new superblock state without committing it in
        // memory yet; if writing/flushing the superblock fails, the old active
        // slot remains authoritative both on disk and in memory.
        var new_state = self.catalog;
        new_state.slots[inactive] = new_slot;
        new_state.active_slot = @intCast(inactive);
        new_state.generation = new_slot.generation;

        try self.writeSuperblock(new_state);

        // Barrier 2: the superblock pointer flip is now durable.
        try self.pager.flush();

        // Only now is the new catalog authoritative.
        self.catalog = new_state;
        self.legacy_format = false;
    }

    /// Save metadata for all tables (public wrapper for commits)
    pub fn saveAllMetadata(self: *Self) !void {
        try self.ensureWritable();
        try self.rewriteAllMetadata();
    }

    /// Rebuild the live catalog, tables, and indexes into a fresh database.
    /// Deleted rows and unreachable B-tree/catalog pages are intentionally not
    /// copied, so the destination is a compact logical equivalent.
    pub fn compactTo(self: *Self, dest_path: []const u8) !void {
        const compact = try StorageEngine.init(self.allocator, dest_path);
        errdefer compact.deinit();

        var table_it = self.tables.iterator();
        while (table_it.next()) |entry| {
            const source_table = entry.value_ptr.*;
            try compact.createTable(source_table.name, source_table.schema);
            const dest_table = compact.getTable(source_table.name).?;
            const rows = try source_table.select(self.allocator);
            var transferred: usize = 0;
            errdefer {
                for (rows[transferred..]) |row_value| {
                    var row = row_value;
                    row.deinit(self.allocator);
                }
                self.allocator.free(rows);
            }
            for (rows) |row| {
                _ = try dest_table.insert(self.allocator, row.values);
                transferred += 1;
            }
            self.allocator.free(rows);
        }

        var index_it = self.indexes.iterator();
        while (index_it.next()) |entry| {
            const index = entry.value_ptr.*;
            try compact.createIndexEx(index.name, index.table_name, index.column_names, index.expressions, index.where_clause, index.is_unique);
        }
        var fts_it = self.fts_indexes.iterator();
        while (fts_it.next()) |entry| {
            const fts_index = entry.value_ptr.*;
            try compact.createFTSIndex(fts_index.table_name, fts_index.column_names);
            try compact.rebuildFTSIndex(compact.getFTSIndex(fts_index.table_name).?);
        }

        compact.user_version = self.user_version;
        compact.schema_version = self.schema_version;
        try compact.saveAllMetadata();
        try compact.pager.flush();
        compact.deinit();
    }

    pub fn getUserVersion(self: *const Self) u32 {
        return self.user_version;
    }

    pub fn setUserVersion(self: *Self, version: u32) !void {
        try self.ensureWritable();
        self.user_version = version;
        if (self.shouldPersistCatalogNow()) {
            try self.rewriteAllMetadata();
        }
    }

    pub fn getSchemaVersion(self: *const Self) u32 {
        return self.schema_version;
    }

    fn bumpSchemaVersion(self: *Self) void {
        self.schema_version +%= 1;
        if (self.schema_version == 0) self.schema_version = 1;
    }

    fn ensureWritable(self: *const Self) !void {
        if (self.read_only) return error.ReadOnlyDatabase;
    }

    fn shouldPersistCatalogNow(self: *const Self) bool {
        return !self.is_memory and !self.pager.in_transaction;
    }

    fn appendInt(self: *Self, buf: *std.ArrayListUnmanaged(u8), comptime T: type, value: T) !void {
        var tmp: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &tmp, value, .little);
        try buf.appendSlice(self.allocator, &tmp);
    }

    fn appendMetadataValue(self: *Self, buf: *std.ArrayListUnmanaged(u8), value: Value) !void {
        switch (value) {
            .Null => try buf.append(self.allocator, @backingInt(MetadataValueTag.Null)),
            .Integer => |v| {
                try buf.append(self.allocator, @backingInt(MetadataValueTag.Integer));
                try self.appendInt(buf, i64, v);
            },
            .Text => |t| {
                try buf.append(self.allocator, @backingInt(MetadataValueTag.Text));
                try self.appendInt(buf, u16, @intCast(t.len));
                try buf.appendSlice(self.allocator, t);
            },
            .Real => |r| {
                try buf.append(self.allocator, @backingInt(MetadataValueTag.Real));
                try self.appendInt(buf, u64, @bitCast(r));
            },
            .Boolean => |b| {
                try buf.append(self.allocator, @backingInt(MetadataValueTag.Boolean));
                try buf.append(self.allocator, if (b) @as(u8, 1) else 0);
            },
            .SmallInt => |s| {
                try buf.append(self.allocator, @backingInt(MetadataValueTag.SmallInt));
                try self.appendInt(buf, i16, s);
            },
            .BigInt => |b| {
                try buf.append(self.allocator, @backingInt(MetadataValueTag.BigInt));
                try self.appendInt(buf, i64, b);
            },
            .Blob => |bl| {
                try buf.append(self.allocator, @backingInt(MetadataValueTag.Blob));
                try self.appendInt(buf, u16, @intCast(bl.len));
                try buf.appendSlice(self.allocator, bl);
            },
            else => return error.UnsupportedMetadataValue,
        }
    }

    fn appendFunctionArgument(self: *Self, buf: *std.ArrayListUnmanaged(u8), arg: Column.FunctionArgument) !void {
        switch (arg) {
            .Literal => |lit| {
                try buf.append(self.allocator, @backingInt(MetadataFunctionArgTag.Literal));
                try self.appendMetadataValue(buf, lit);
            },
            .Column => |col| {
                try buf.append(self.allocator, @backingInt(MetadataFunctionArgTag.Column));
                try self.appendInt(buf, u16, @intCast(col.len));
                try buf.appendSlice(self.allocator, col);
            },
            .Parameter => |p| {
                try buf.append(self.allocator, @backingInt(MetadataFunctionArgTag.Parameter));
                try self.appendInt(buf, u32, p);
            },
        }
    }

    fn appendDefaultValue(self: *Self, buf: *std.ArrayListUnmanaged(u8), dv: Column.DefaultValue) !void {
        switch (dv) {
            .Literal => |lit| {
                try buf.append(self.allocator, @backingInt(MetadataDefaultTag.Literal));
                try self.appendMetadataValue(buf, lit);
            },
            .FunctionCall => |fc| {
                try buf.append(self.allocator, @backingInt(MetadataDefaultTag.FunctionCall));
                try self.appendInt(buf, u16, @intCast(fc.name.len));
                try buf.appendSlice(self.allocator, fc.name);
                try self.appendInt(buf, u16, @intCast(fc.arguments.len));
                for (fc.arguments) |a| try self.appendFunctionArgument(buf, a);
            },
        }
    }

    fn appendAstValue(self: *Self, buf: *std.ArrayListUnmanaged(u8), value: ast.Value) !void {
        const storage_value: Value = switch (value) {
            .Integer => |v| .{ .Integer = v },
            .Text => |v| .{ .Text = v },
            .Real => |v| .{ .Real = v },
            .Blob => |v| .{ .Blob = v },
            .Null => .Null,
            .Parameter => return error.UnsupportedCheckConstraint,
            .FunctionCall, .Case => return error.UnsupportedCheckConstraint,
        };
        try self.appendMetadataValue(buf, storage_value);
    }

    fn appendCheckExpression(self: *Self, buf: *std.ArrayListUnmanaged(u8), expr: ast.Expression) !void {
        switch (expr) {
            .Column => |column| {
                try buf.append(self.allocator, 1);
                try self.appendInt(buf, u16, @intCast(column.len));
                try buf.appendSlice(self.allocator, column);
            },
            .Literal => |value| {
                try buf.append(self.allocator, 2);
                try self.appendAstValue(buf, value);
            },
            .Parameter => |param| {
                try buf.append(self.allocator, 3);
                try self.appendInt(buf, u32, param);
            },
            .BinaryOp => |bin| {
                try buf.append(self.allocator, 4);
                try buf.append(self.allocator, @backingInt(bin.op));
                try self.appendCheckExpression(buf, bin.left.*);
                try self.appendCheckExpression(buf, bin.right.*);
            },
            .InList => |list| {
                try buf.append(self.allocator, 5);
                try self.appendInt(buf, u16, @intCast(list.len));
                for (list) |value| try self.appendAstValue(buf, value);
            },
            .Subquery => return error.UnsupportedCheckConstraint,
        }
    }

    fn appendCheckCondition(self: *Self, buf: *std.ArrayListUnmanaged(u8), condition: ast.Condition) !void {
        switch (condition) {
            .Comparison => |comp| {
                try buf.append(self.allocator, 1);
                try buf.append(self.allocator, @backingInt(comp.operator));
                try self.appendCheckExpression(buf, comp.left);
                try self.appendCheckExpression(buf, comp.right);
                if (comp.extra) |extra| {
                    try buf.append(self.allocator, 1);
                    try self.appendCheckExpression(buf, extra);
                } else {
                    try buf.append(self.allocator, 0);
                }
            },
            .Logical => |logical| {
                try buf.append(self.allocator, 2);
                try buf.append(self.allocator, @backingInt(logical.operator));
                try self.appendCheckCondition(buf, logical.left.*);
                try self.appendCheckCondition(buf, logical.right.*);
            },
        }
    }

    fn appendForeignKeyAction(self: *Self, buf: *std.ArrayListUnmanaged(u8), action: ?ast.ForeignKeyAction) !void {
        if (action) |value| {
            try buf.append(self.allocator, 1);
            try buf.append(self.allocator, @backingInt(value));
        } else {
            try buf.append(self.allocator, 0);
        }
    }

    fn appendForeignKey(self: *Self, buf: *std.ArrayListUnmanaged(u8), foreign_key: ast.ForeignKeyConstraint) !void {
        const column = foreign_key.column orelse return error.InvalidForeignKey;
        try self.appendInt(buf, u16, @intCast(column.len));
        try buf.appendSlice(self.allocator, column);
        try self.appendInt(buf, u16, @intCast(foreign_key.reference_table.len));
        try buf.appendSlice(self.allocator, foreign_key.reference_table);
        try self.appendInt(buf, u16, @intCast(foreign_key.reference_column.len));
        try buf.appendSlice(self.allocator, foreign_key.reference_column);
        try self.appendForeignKeyAction(buf, foreign_key.on_delete);
        try self.appendForeignKeyAction(buf, foreign_key.on_update);
    }

    /// Serialize the entire catalog (tables, indexes, column defaults, FTS
    /// indexes) into a single owned buffer. Growing freely means catalog records
    /// are never silently dropped to fit a fixed page.
    fn serializeCatalog(self: *Self) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        // Tables
        try self.appendInt(&buf, u32, @intCast(self.tables.count()));
        var table_it = self.tables.iterator();
        while (table_it.next()) |entry| {
            const table = entry.value_ptr.*;
            try self.appendInt(&buf, u16, @intCast(table.name.len));
            try buf.appendSlice(self.allocator, table.name);
            try self.appendInt(&buf, u32, table.btree.root_page);
            try self.appendInt(&buf, u64, table.row_count);
            try self.appendInt(&buf, u32, @intCast(table.deleted_keys.count()));
            var dk = table.deleted_keys.keyIterator();
            while (dk.next()) |key_ptr| try self.appendInt(&buf, u64, key_ptr.*);
            try self.appendInt(&buf, u16, @intCast(table.schema.columns.len));
            for (table.schema.columns) |column| {
                try self.appendInt(&buf, u16, @intCast(column.name.len));
                try buf.appendSlice(self.allocator, column.name);
                try buf.append(self.allocator, @backingInt(column.data_type));
                var flags: u8 = 0;
                if (column.is_primary_key) flags |= 0x01;
                if (column.is_nullable) flags |= 0x02;
                try buf.append(self.allocator, flags);
            }
        }

        // Indexes
        try self.appendInt(&buf, u32, @intCast(self.indexes.count()));
        var index_it = self.indexes.iterator();
        while (index_it.next()) |entry| {
            const index = entry.value_ptr.*;
            try self.appendInt(&buf, u16, @intCast(index.name.len));
            try buf.appendSlice(self.allocator, index.name);
            try self.appendInt(&buf, u16, @intCast(index.table_name.len));
            try buf.appendSlice(self.allocator, index.table_name);
            var index_flags: u8 = if (index.is_unique) 0x01 else 0x00;
            if (isAdvancedIndexDefinition(index.column_names, index.expressions, index.where_clause)) index_flags |= 0x02;
            try buf.append(self.allocator, index_flags);
            try self.appendInt(&buf, u16, @intCast(index.column_names.len));
            for (index.column_names) |cn| {
                try self.appendInt(&buf, u16, @intCast(cn.len));
                try buf.appendSlice(self.allocator, cn);
            }
        }

        // Table extensions: per-column default values. Only tables with at least
        // one serializable default contribute a record.
        var ext_count: u32 = 0;
        var ext_count_it = self.tables.iterator();
        while (ext_count_it.next()) |entry| {
            const table = entry.value_ptr.*;
            for (table.schema.columns) |column| {
                if (column.default_value) |dv| {
                    if (serializedDefaultValueSize(dv) != null) {
                        ext_count += 1;
                        break;
                    }
                }
            }
        }
        try self.appendInt(&buf, u32, ext_count);

        var ext_it = self.tables.iterator();
        while (ext_it.next()) |entry| {
            const table = entry.value_ptr.*;
            var default_count: u16 = 0;
            for (table.schema.columns) |column| {
                if (column.default_value) |dv| {
                    if (serializedDefaultValueSize(dv) != null) default_count += 1;
                }
            }
            if (default_count == 0) continue;

            try self.appendInt(&buf, u16, @intCast(table.name.len));
            try buf.appendSlice(self.allocator, table.name);
            try self.appendInt(&buf, u16, default_count);
            for (table.schema.columns) |column| {
                const dv = column.default_value orelse continue;
                if (serializedDefaultValueSize(dv) == null) continue;
                try self.appendInt(&buf, u16, @intCast(column.name.len));
                try buf.appendSlice(self.allocator, column.name);
                try self.appendDefaultValue(&buf, dv);
            }
        }

        // FTS indexes
        try self.appendInt(&buf, u32, @intCast(self.fts_indexes.count()));
        var fts_it = self.fts_indexes.iterator();
        while (fts_it.next()) |entry| {
            const fts_index = entry.value_ptr.*;
            try self.appendInt(&buf, u16, @intCast(fts_index.table_name.len));
            try buf.appendSlice(self.allocator, fts_index.table_name);
            try self.appendInt(&buf, u16, @intCast(fts_index.column_names.len));
            for (fts_index.column_names) |cn| {
                try self.appendInt(&buf, u16, @intCast(cn.len));
                try buf.appendSlice(self.allocator, cn);
            }
        }

        // CHECK constraints. This section is appended after the older catalog
        // sections so existing databases without it remain readable.
        var check_ext_count: u32 = 0;
        var check_count_it = self.tables.iterator();
        while (check_count_it.next()) |entry| {
            if (entry.value_ptr.*.schema.check_constraints.len > 0) check_ext_count += 1;
        }
        try self.appendInt(&buf, u32, check_ext_count);

        var check_it = self.tables.iterator();
        while (check_it.next()) |entry| {
            const table = entry.value_ptr.*;
            if (table.schema.check_constraints.len == 0) continue;

            try self.appendInt(&buf, u16, @intCast(table.name.len));
            try buf.appendSlice(self.allocator, table.name);
            try self.appendInt(&buf, u16, @intCast(table.schema.check_constraints.len));
            for (table.schema.check_constraints) |condition| {
                try self.appendCheckCondition(&buf, condition);
            }
        }

        // FOREIGN KEY constraints, appended after CHECK constraints.
        var fk_ext_count: u32 = 0;
        var fk_count_it = self.tables.iterator();
        while (fk_count_it.next()) |entry| {
            for (entry.value_ptr.*.schema.foreign_keys) |foreign_key| {
                if (foreign_key.columns == null and !foreign_key.deferred) {
                    fk_ext_count += 1;
                    break;
                }
            }
        }
        try self.appendInt(&buf, u32, fk_ext_count);

        var fk_it = self.tables.iterator();
        while (fk_it.next()) |entry| {
            const table = entry.value_ptr.*;
            var simple_count: u16 = 0;
            for (table.schema.foreign_keys) |foreign_key| {
                if (foreign_key.columns == null and !foreign_key.deferred) simple_count += 1;
            }
            if (simple_count == 0) continue;

            try self.appendInt(&buf, u16, @intCast(table.name.len));
            try buf.appendSlice(self.allocator, table.name);
            try self.appendInt(&buf, u16, simple_count);
            for (table.schema.foreign_keys) |foreign_key| {
                if (foreign_key.columns == null and !foreign_key.deferred) try self.appendForeignKey(&buf, foreign_key);
            }
        }

        // Database metadata: application/user version and schema version. This
        // optional tail section keeps older catalog payloads readable.
        try self.appendInt(&buf, u32, 1);
        try self.appendInt(&buf, u32, self.user_version);
        try self.appendInt(&buf, u32, self.schema_version);

        // Optional tail extension for partial predicates and expression keys.
        // Keeping the base index records unchanged preserves older catalogs.
        var advanced_index_count: u32 = 0;
        var advanced_count_it = self.indexes.iterator();
        while (advanced_count_it.next()) |entry| {
            const index = entry.value_ptr.*;
            if (isAdvancedIndexDefinition(index.column_names, index.expressions, index.where_clause)) advanced_index_count += 1;
        }
        try self.appendInt(&buf, u32, advanced_index_count);
        var advanced_it = self.indexes.iterator();
        while (advanced_it.next()) |entry| {
            const index = entry.value_ptr.*;
            if (!isAdvancedIndexDefinition(index.column_names, index.expressions, index.where_clause)) continue;
            try self.appendInt(&buf, u16, @intCast(index.name.len));
            try buf.appendSlice(self.allocator, index.name);
            try self.appendInt(&buf, u16, @intCast(index.expressions.len));
            for (index.expressions) |expression| try self.appendCheckExpression(&buf, expression);
            if (index.where_clause) |condition| {
                try buf.append(self.allocator, 1);
                try self.appendCheckCondition(&buf, condition);
            } else {
                try buf.append(self.allocator, 0);
            }
        }

        var advanced_fk_table_count: u32 = 0;
        var advanced_fk_count_it = self.tables.iterator();
        while (advanced_fk_count_it.next()) |entry| {
            for (entry.value_ptr.*.schema.foreign_keys) |foreign_key| {
                if (foreign_key.columns != null or foreign_key.deferred) {
                    advanced_fk_table_count += 1;
                    break;
                }
            }
        }
        try self.appendInt(&buf, u32, advanced_fk_table_count);
        var advanced_fk_it = self.tables.iterator();
        while (advanced_fk_it.next()) |entry| {
            const table = entry.value_ptr.*;
            var constraint_count: u16 = 0;
            for (table.schema.foreign_keys) |foreign_key| {
                if (foreign_key.columns != null or foreign_key.deferred) constraint_count += 1;
            }
            if (constraint_count == 0) continue;
            try self.appendInt(&buf, u16, @intCast(table.name.len));
            try buf.appendSlice(self.allocator, table.name);
            try self.appendInt(&buf, u16, constraint_count);
            for (table.schema.foreign_keys) |foreign_key| {
                if (foreign_key.columns == null and !foreign_key.deferred) continue;
                const child_count: u16 = if (foreign_key.columns) |columns| @intCast(columns.len) else 1;
                try self.appendInt(&buf, u16, child_count);
                if (foreign_key.columns) |columns| {
                    for (columns) |column| {
                        try self.appendInt(&buf, u16, @intCast(column.len));
                        try buf.appendSlice(self.allocator, column);
                    }
                } else {
                    const column = foreign_key.column orelse return error.InvalidForeignKey;
                    try self.appendInt(&buf, u16, @intCast(column.len));
                    try buf.appendSlice(self.allocator, column);
                }
                try self.appendInt(&buf, u16, @intCast(foreign_key.reference_table.len));
                try buf.appendSlice(self.allocator, foreign_key.reference_table);
                const reference_count: u16 = if (foreign_key.reference_columns) |columns| @intCast(columns.len) else 1;
                try self.appendInt(&buf, u16, reference_count);
                if (foreign_key.reference_columns) |columns| {
                    for (columns) |column| {
                        try self.appendInt(&buf, u16, @intCast(column.len));
                        try buf.appendSlice(self.allocator, column);
                    }
                } else {
                    try self.appendInt(&buf, u16, @intCast(foreign_key.reference_column.len));
                    try buf.appendSlice(self.allocator, foreign_key.reference_column);
                }
                try self.appendForeignKeyAction(&buf, foreign_key.on_delete);
                try self.appendForeignKeyAction(&buf, foreign_key.on_update);
                try buf.append(self.allocator, if (foreign_key.deferred) 1 else 0);
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// Write a serialized payload into the page chain backing one A/B slot,
    /// reusing the slot's existing pages and allocating more only when needed.
    /// All pages owned by the slot stay linked so none are leaked across rewrites.
    fn writeCatalogPayload(self: *Self, slot_index: usize, payload: []const u8) !SlotDescriptor {
        const capacity: usize = self.pager.page_size - CATALOG_PAGE_HEADER;
        const needed_pages: usize = if (payload.len == 0)
            1
        else
            (payload.len + capacity - 1) / capacity;

        var pages: std.ArrayListUnmanaged(u32) = .empty;
        defer pages.deinit(self.allocator);

        // Reuse the slot's existing chain pages.
        const existing = self.catalog.slots[slot_index];
        if (existing.first_page != 0 and existing.page_count != 0) {
            var current = existing.first_page;
            var count: u32 = 0;
            while (current != 0 and count < existing.page_count) {
                try pages.append(self.allocator, current);
                const page = try self.pager.getPage(current);
                current = std.mem.readInt(u32, page.data[0..4], .little);
                count += 1;
            }
        }

        // Allocate any additional pages the payload requires.
        while (pages.items.len < needed_pages) {
            const new_id = try self.pager.allocatePage();
            try pages.append(self.allocator, new_id);
        }

        const total_pages = pages.items.len;
        var written: usize = 0;
        for (pages.items, 0..) |page_id, i| {
            const page = try self.pager.getPage(page_id);
            @memset(page.data, 0);
            const next_id: u32 = if (i + 1 < total_pages) pages.items[i + 1] else 0;
            std.mem.writeInt(u32, page.data[0..4], next_id, .little);

            var page_len: usize = 0;
            if (written < payload.len) {
                const remaining = payload.len - written;
                page_len = @min(remaining, capacity);
                @memcpy(page.data[CATALOG_PAGE_HEADER..][0..page_len], payload[written..][0..page_len]);
                written += page_len;
            }
            std.mem.writeInt(u32, page.data[4..8], @intCast(page_len), .little);
            try self.pager.markDirty(page_id);
        }

        return SlotDescriptor{
            .first_page = if (total_pages > 0) pages.items[0] else 0,
            .page_count = @intCast(total_pages),
            .payload_len = payload.len,
            .checksum = std.hash.Crc32.hash(payload),
            .generation = 0,
        };
    }

    fn writeSlotDescriptor(dst: []u8, slot: SlotDescriptor) void {
        std.mem.writeInt(u32, dst[0..4], slot.first_page, .little);
        std.mem.writeInt(u32, dst[4..8], slot.page_count, .little);
        std.mem.writeInt(u64, dst[8..16], slot.payload_len, .little);
        std.mem.writeInt(u32, dst[16..20], slot.checksum, .little);
        std.mem.writeInt(u64, dst[20..28], slot.generation, .little);
    }

    fn readSlotDescriptor(src: []const u8) SlotDescriptor {
        return SlotDescriptor{
            .first_page = std.mem.readInt(u32, src[0..4], .little),
            .page_count = std.mem.readInt(u32, src[4..8], .little),
            .payload_len = std.mem.readInt(u64, src[8..16], .little),
            .checksum = std.mem.readInt(u32, src[16..20], .little),
            .generation = std.mem.readInt(u64, src[20..28], .little),
        };
    }

    /// Write the superblock (page 1) describing the given catalog state. The
    /// header is covered by a CRC32 so a torn or zeroed superblock is detected.
    fn writeSuperblock(self: *Self, state: CatalogState) !void {
        const page = try self.pager.getPage(SUPERBLOCK_PAGE_ID);
        @memset(page.data, 0);
        std.mem.writeInt(u32, page.data[SB_OFF_MAGIC..][0..4], SUPERBLOCK_MAGIC, .little);
        std.mem.writeInt(u16, page.data[SB_OFF_VERSION..][0..2], CATALOG_FORMAT_VERSION, .little);
        std.mem.writeInt(u16, page.data[SB_OFF_FLAGS..][0..2], 0, .little);
        page.data[SB_OFF_ACTIVE] = state.active_slot;
        std.mem.writeInt(u64, page.data[SB_OFF_GENERATION..][0..8], state.generation, .little);
        writeSlotDescriptor(page.data[SB_OFF_SLOT_A..][0..SLOT_DESC_LEN], state.slots[0]);
        writeSlotDescriptor(page.data[SB_OFF_SLOT_B..][0..SLOT_DESC_LEN], state.slots[1]);
        const checksum = std.hash.Crc32.hash(page.data[0..SB_HEADER_LEN]);
        std.mem.writeInt(u32, page.data[SB_OFF_HEADER_CHECKSUM..][0..4], checksum, .little);
        try self.pager.markDirty(SUPERBLOCK_PAGE_ID);
    }

    /// Create an index
    pub fn createIndex(self: *Self, name: []const u8, table_name: []const u8, column_names: [][]const u8, is_unique: bool) !void {
        try self.createIndexEx(name, table_name, column_names, &.{}, null, is_unique);
    }

    pub fn createIndexEx(
        self: *Self,
        name: []const u8,
        table_name: []const u8,
        column_names: [][]const u8,
        expressions: []const ast.Expression,
        where_clause: ?ast.Condition,
        is_unique: bool,
    ) !void {
        try self.ensureWritable();
        const index = try self.registerIndexEx(name, table_name, column_names, expressions, where_clause, is_unique);
        errdefer {
            if (self.indexes.fetchRemove(name)) |entry| {
                entry.value.deinit(self.allocator);
                self.allocator.free(entry.key);
            }
        }

        try self.rebuildIndex(index);
        self.bumpSchemaVersion();

        if (self.shouldPersistCatalogNow()) {
            try self.rewriteAllMetadata();
        }
    }

    fn registerIndex(self: *Self, name: []const u8, table_name: []const u8, column_names: [][]const u8, is_unique: bool) !*Index {
        return self.registerIndexEx(name, table_name, column_names, &.{}, null, is_unique);
    }

    fn isAdvancedIndexDefinition(column_names: []const []const u8, expressions: []const ast.Expression, where_clause: ?ast.Condition) bool {
        if (where_clause != null) return true;
        if (expressions.len == 0) return false;
        if (expressions.len != column_names.len) return true;

        for (expressions, column_names) |expression, column_name| {
            switch (expression) {
                .Column => |name| {
                    if (!std.mem.eql(u8, name, column_name)) return true;
                },
                else => return true,
            }
        }

        return false;
    }

    fn registerIndexEx(
        self: *Self,
        name: []const u8,
        table_name: []const u8,
        column_names: [][]const u8,
        expressions: []const ast.Expression,
        where_clause: ?ast.Condition,
        is_unique: bool,
    ) !*Index {
        // Only index definitions are persisted. Rebuilding derived trees into
        // the database file leaks unreferenced pages and prevents read-only open.
        const index_pager = try pager.Pager.initMemory(self.allocator);
        // Derived pages have no backing file; eviction would discard index data.
        index_pager.setCachePageLimit(std.math.maxInt(u32));
        const index = Index.createEx(self.allocator, index_pager, name, table_name, column_names, expressions, where_clause, is_unique) catch |err| {
            index_pager.deinit();
            return err;
        };
        index.owned_pager = index_pager;
        errdefer index.deinit(self.allocator);

        const duped_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(duped_name);

        try self.indexes.put(duped_name, index);
        return index;
    }

    /// Get an index by name
    pub fn getIndex(self: *Self, name: []const u8) ?*Index {
        return self.indexes.get(name);
    }

    /// Drop an index
    pub fn dropIndex(self: *Self, name: []const u8) !void {
        try self.ensureWritable();

        if (self.indexes.fetchRemove(name)) |entry| {
            entry.value.deinit(self.allocator);
            self.allocator.free(entry.key);
            self.bumpSchemaVersion();

            if (self.shouldPersistCatalogNow()) {
                try self.rewriteAllMetadata();
            }
        }
    }

    pub fn refreshIndexesForTable(self: *Self, table_name: []const u8) !void {
        try self.ensureWritable();

        var index_iter = self.indexes.iterator();
        while (index_iter.next()) |entry| {
            const index = entry.value_ptr.*;
            if (!std.mem.eql(u8, index.table_name, table_name)) {
                continue;
            }

            try self.rebuildIndex(index);
        }

        if (self.shouldPersistCatalogNow()) {
            try self.rewriteAllMetadata();
        }
    }

    /// Create an FTS (Full-Text Search) index for a virtual table
    pub fn createFTSIndex(self: *Self, table_name: []const u8, columns: []const []const u8) !void {
        try self.ensureWritable();

        var fts_index = try FTSIndex.create(self.allocator, table_name, columns);
        errdefer fts_index.deinit(self.allocator);

        const duped_name = try self.allocator.dupe(u8, table_name);
        errdefer self.allocator.free(duped_name);

        try self.fts_indexes.put(duped_name, fts_index);
        self.bumpSchemaVersion();
    }

    /// Get an FTS index by table name
    pub fn getFTSIndex(self: *Self, table_name: []const u8) ?*FTSIndex {
        return self.fts_indexes.get(table_name);
    }

    fn valueEquals(a: Value, b: Value) bool {
        if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) {
            return false;
        }

        return switch (a) {
            .Null => true,
            .Integer => |i| i == b.Integer,
            .Real => |r| r == b.Real,
            .Text => |t| std.mem.eql(u8, t, b.Text),
            .Blob => |blob| std.mem.eql(u8, blob, b.Blob),
            .Boolean => |flag| flag == b.Boolean,
            .SmallInt => |s| s == b.SmallInt,
            .BigInt => |bi| bi == b.BigInt,
            else => false,
        };
    }

    fn rowMatchesUniqueIndex(table: *Table, index: *Index, existing_values: []const Value, candidate_values: []const Value) bool {
        if (!rowMatchesPartialPredicate(table, index, existing_values)) return false;
        if (!rowMatchesPartialPredicate(table, index, candidate_values)) return false;

        for (0..index.keyPartCount()) |part_idx| {
            const existing = evaluateIndexPart(table, index, part_idx, existing_values) orelse return false;
            const candidate = evaluateIndexPart(table, index, part_idx, candidate_values) orelse return false;
            // SQL treats NULLs as distinct for uniqueness: a row with a NULL in any
            // indexed column never conflicts, so multiple NULLs are permitted.
            if (existing == .Null or candidate == .Null) return false;
            if (!valueEquals(existing, candidate)) return false;
        }
        return true;
    }

    pub fn checkUniqueIndexes(self: *Self, table: *Table, candidate_values: []const Value) !void {
        return self.checkUniqueIndexesExcept(table, candidate_values, null);
    }

    pub fn checkUniqueIndexesExcept(self: *Self, table: *Table, candidate_values: []const Value, exclude_row_id: ?i64) !void {
        var index_iter = self.indexes.iterator();
        while (index_iter.next()) |entry| {
            const index = entry.value_ptr.*;
            if (!index.is_unique or !std.mem.eql(u8, index.table_name, table.name)) continue;
            if (!rowMatchesPartialPredicate(table, index, candidate_values)) continue;
            const key = computeIndexKey(table, index, candidate_values) orelse continue;
            var context = UniqueIndexContext{
                .table = table,
                .index = index,
                .candidate = candidate_values,
                .exclude_row_id = exclude_row_id,
            };
            try index.btree.visitEqual(key, &context, UniqueIndexContext.check);
        }
    }

    /// DML updates derived entries after the table mutation has an undo record.
    /// Statement/savepoint rollback rebuilds these trees if any step fails.
    pub fn maintainIndexes(self: *Self, table: *Table, old_row_id: ?i64, new_row_id: ?i64) !void {
        if (self.indexes.count() == 0) return;
        var old_row = if (old_row_id) |id| try table.btree.search(@intCast(id)) else null;
        defer if (old_row) |*row| row.deinit(self.allocator);
        var new_row = if (new_row_id) |id| try table.getRow(id) else null;
        defer if (new_row) |*row| row.deinit(self.allocator);
        var it = self.indexes.iterator();
        while (it.next()) |entry| {
            const index = entry.value_ptr.*;
            if (!std.mem.eql(u8, index.table_name, table.name)) continue;
            if (old_row) |row| {
                if (rowMatchesPartialPredicate(table, index, row.values)) {
                    if (computeIndexKey(table, index, row.values)) |key| {
                        if (!try index.btree.removeIndexEntry(key, old_row_id.?)) return error.CorruptedData;
                    }
                }
            }
            if (new_row) |row| {
                if (rowMatchesPartialPredicate(table, index, row.values)) {
                    if (computeIndexKey(table, index, row.values)) |key| try index.insertEntry(key, @intCast(new_row_id.?));
                }
            }
        }
    }

    /// Check if a table has an FTS index (is a virtual table)
    pub fn isFTSTable(self: *Self, table_name: []const u8) bool {
        return self.fts_indexes.contains(table_name);
    }

    fn rebuildIndex(self: *Self, index: *Index) !void {
        const table = self.getTable(index.table_name) orelse return error.TableNotFound;

        const rebuilt_pager = try pager.Pager.initMemory(self.allocator);
        rebuilt_pager.setCachePageLimit(std.math.maxInt(u32));
        errdefer rebuilt_pager.deinit();
        const rebuilt_tree = try btree.BTree.init(self.allocator, rebuilt_pager);
        errdefer rebuilt_tree.deinit();
        var rebuilt = index.*;
        rebuilt.btree = rebuilt_tree;

        const rows = try table.selectWithKeys(self.allocator);
        defer {
            for (rows) |item| {
                for (item.row.values) |value| {
                    value.deinit(self.allocator);
                }
                self.allocator.free(item.row.values);
            }
            self.allocator.free(rows);
        }

        for (rows) |item| {
            if (!rowMatchesPartialPredicate(table, index, item.row.values)) continue;
            const key = computeIndexKey(table, index, item.row.values) orelse continue;
            if (index.is_unique) {
                var context = UniqueIndexContext{ .table = table, .index = index, .candidate = item.row.values };
                try rebuilt_tree.visitEqual(key, &context, UniqueIndexContext.check);
            }
            try rebuilt.insertEntry(key, @intCast(item.key));
        }
        // Publish only a complete rebuild. A failed unique check or allocation
        // leaves the previous tree available until statement rollback completes.
        index.btree.deinit();
        if (index.owned_pager) |owned| owned.deinit();
        index.btree = rebuilt_tree;
        index.owned_pager = rebuilt_pager;
    }

    const UniqueIndexContext = struct {
        table: *Table,
        index: *Index,
        candidate: []const Value,
        exclude_row_id: ?i64 = null,

        fn check(context: *@This(), entry: Row) anyerror!void {
            if (entry.values.len != 1 or entry.values[0] != .Integer) return error.CorruptedData;
            if (context.exclude_row_id == entry.values[0].Integer) return;
            if (try context.table.getRow(entry.values[0].Integer)) |row| {
                var owned = row;
                defer owned.deinit(context.table.allocator);
                // Hash equality is only a candidate match, including for UNIQUE.
                if (rowMatchesUniqueIndex(context.table, context.index, row.values, context.candidate))
                    return error.UniqueConstraintViolation;
            }
        }
    };

    fn computeIndexKey(table: *Table, index: *Index, values: []const Value) ?u64 {
        const part_count = index.keyPartCount();
        if (part_count == 0) return null;

        if (part_count == 1) {
            const value = evaluateIndexPart(table, index, 0, values) orelse return null;
            // SQL treats NULLs as distinct, so a NULL-bearing row is not indexed and
            // never participates in uniqueness checks. Callers skip a null key.
            if (value == .Null) return null;
            return valueToIndexKey(value);
        }

        var combined: u64 = 0xcbf29ce484222325;
        for (0..part_count) |part_idx| {
            const value = evaluateIndexPart(table, index, part_idx, values) orelse return null;
            if (value == .Null) return null;

            const component = valueToIndexKey(value);
            combined = (combined ^ component) *% 0x100000001b3;
        }

        return combined;
    }

    fn rowMatchesPartialPredicate(table: *Table, index: *Index, values: []const Value) bool {
        const condition = index.where_clause orelse return true;
        return evaluateIndexCondition(table, &condition, values);
    }

    fn evaluateIndexPart(table: *Table, index: *Index, part_idx: usize, values: []const Value) ?Value {
        if (index.expressions.len > part_idx) {
            return evaluateIndexExpression(table, &index.expressions[part_idx], values);
        }
        if (index.column_names.len <= part_idx) return null;
        const column_idx = table.getColumnIndex(index.column_names[part_idx]) orelse return null;
        if (column_idx >= values.len) return null;
        return values[column_idx];
    }

    fn evaluateIndexExpression(table: *Table, expression: *const ast.Expression, values: []const Value) ?Value {
        return switch (expression.*) {
            .Column => |name| blk: {
                const idx = table.getColumnIndex(name) orelse return null;
                if (idx >= values.len) return null;
                break :blk values[idx];
            },
            .Literal => |value| astValueToStorageValue(value),
            .BinaryOp => |bin| blk: {
                const left = evaluateIndexExpression(table, bin.left, values) orelse return null;
                const right = evaluateIndexExpression(table, bin.right, values) orelse return null;
                break :blk evaluateIndexArithmetic(left, bin.op, right);
            },
            else => null,
        };
    }

    fn evaluateIndexCondition(table: *Table, condition: *const ast.Condition, values: []const Value) bool {
        return switch (condition.*) {
            .Comparison => |comparison| evaluateIndexComparison(table, &comparison, values),
            .Logical => |logical| switch (logical.operator) {
                .And => evaluateIndexCondition(table, logical.left, values) and evaluateIndexCondition(table, logical.right, values),
                .Or => evaluateIndexCondition(table, logical.left, values) or evaluateIndexCondition(table, logical.right, values),
            },
        };
    }

    fn evaluateIndexComparison(table: *Table, comparison: *const ast.ComparisonCondition, values: []const Value) bool {
        const left = evaluateIndexExpression(table, &comparison.left, values) orelse Value.Null;
        if (comparison.operator == .IsNull) return left == .Null;
        if (comparison.operator == .IsNotNull) return left != .Null;

        const right = evaluateIndexExpression(table, &comparison.right, values) orelse Value.Null;
        if (left == .Null or right == .Null) return false;

        const order = compareIndexValues(left, right);
        return switch (comparison.operator) {
            .Equal => order == .eq,
            .NotEqual => order != .eq,
            .LessThan => order == .lt,
            .LessThanOrEqual => order == .lt or order == .eq,
            .GreaterThan => order == .gt,
            .GreaterThanOrEqual => order == .gt or order == .eq,
            else => false,
        };
    }

    fn astValueToStorageValue(value: ast.Value) ?Value {
        return switch (value) {
            .Integer => |v| Value{ .Integer = v },
            .Real => |v| Value{ .Real = v },
            .Text => |v| Value{ .Text = v },
            .Blob => |v| Value{ .Blob = v },
            .Null => Value.Null,
            else => null,
        };
    }

    fn evaluateIndexArithmetic(left: Value, op: ast.ArithmeticOp, right: Value) ?Value {
        const left_num: f64 = switch (left) {
            .Integer => |v| @floatFromInt(v),
            .Real => |v| v,
            .SmallInt => |v| @floatFromInt(v),
            .BigInt => |v| @floatFromInt(v),
            else => return null,
        };
        const right_num: f64 = switch (right) {
            .Integer => |v| @floatFromInt(v),
            .Real => |v| v,
            .SmallInt => |v| @floatFromInt(v),
            .BigInt => |v| @floatFromInt(v),
            else => return null,
        };

        const result = switch (op) {
            .Add => left_num + right_num,
            .Subtract => left_num - right_num,
            .Multiply => left_num * right_num,
            .Divide => if (right_num == 0) return null else left_num / right_num,
            .Modulo => if (right_num == 0) return null else @mod(left_num, right_num),
        };
        if (@floor(result) == result) return Value{ .Integer = @intFromFloat(result) };
        return Value{ .Real = result };
    }

    fn compareIndexValues(a: Value, b: Value) std.math.Order {
        return switch (a) {
            .Integer => |x| switch (b) {
                .Integer => |y| std.math.order(x, y),
                .Real => |y| std.math.order(@as(f64, @floatFromInt(x)), y),
                else => .gt,
            },
            .Real => |x| switch (b) {
                .Integer => |y| std.math.order(x, @as(f64, @floatFromInt(y))),
                .Real => |y| std.math.order(x, y),
                else => .gt,
            },
            .Text => |x| switch (b) {
                .Text => |y| std.mem.order(u8, x, y),
                else => .gt,
            },
            else => if (valueEquals(a, b)) .eq else .gt,
        };
    }

    pub fn valueToIndexKey(value: Value) u64 {
        return switch (value) {
            .Integer => |i| @bitCast(i),
            .Text => |t| blk: {
                var hash: u64 = 0;
                for (t) |byte| {
                    hash = hash *% 31 +% byte;
                }
                break :blk hash;
            },
            .Real => |r| if (r == 0) 0 else @bitCast(r),
            .Boolean => |flag| if (flag) 1 else 0,
            .SmallInt => |s| @bitCast(@as(i64, s)),
            .BigInt => |bi| @bitCast(bi),
            else => 0,
        };
    }

    /// Metadata page layout:
    /// - Bytes 0-3: Magic number (0x5A514C54 = "ZQLT")
    /// - Bytes 4-7: Table count
    /// - Bytes 8+: Table entries (variable length)
    /// Each table entry:
    /// - 2 bytes: name length
    /// - N bytes: name
    /// - 2 bytes: column count
    /// - For each column:
    ///   - 2 bytes: name length
    ///   - N bytes: name
    ///   - 1 byte: data type
    ///   - 1 byte: flags (is_primary_key, is_nullable)
    const METADATA_MAGIC: u32 = 0x5A514C54; // "ZQLT" (legacy single-page catalog)
    const METADATA_PAGE_ID: u32 = 1;
    const METADATA_EXT_MAGIC: u32 = 0x5A514558; // "ZQEX" (legacy extension marker)

    // Versioned multi-page catalog format. Page 1 holds a fixed superblock that
    // points at one of two alternating catalog page chains (A/B ping-pong); the
    // catalog payload itself lives in dynamically allocated chained pages.
    const SUPERBLOCK_PAGE_ID: u32 = 1;
    const SUPERBLOCK_MAGIC: u32 = 0x5A444231; // "ZDB1"
    const CATALOG_FORMAT_VERSION: u16 = 1;

    // Superblock field offsets within page 1.
    const SB_OFF_MAGIC: usize = 0; // u32 magic
    const SB_OFF_VERSION: usize = 4; // u16 format version
    const SB_OFF_FLAGS: usize = 6; // u16 reserved flags
    const SB_OFF_ACTIVE: usize = 8; // u8 active slot (0 or 1)
    const SB_OFF_GENERATION: usize = 12; // u64 global generation counter
    const SB_OFF_SLOT_A: usize = 20; // slot A descriptor (SLOT_DESC_LEN bytes)
    const SB_OFF_SLOT_B: usize = 48; // slot B descriptor (SLOT_DESC_LEN bytes)
    const SB_OFF_HEADER_CHECKSUM: usize = 76; // u32 CRC32 over bytes [0..SB_HEADER_LEN)
    const SB_HEADER_LEN: usize = 76; // bytes covered by the header checksum
    const SLOT_DESC_LEN: usize = 28; // first_page,page_count,payload_len,checksum,generation

    // Catalog page header: next_page(u32) + page_payload_len(u32).
    const CATALOG_PAGE_HEADER: usize = 8;

    const MetadataValueTag = enum(u8) {
        Null = 0,
        Integer = 1,
        Text = 2,
        Real = 3,
        Boolean = 4,
        SmallInt = 5,
        BigInt = 6,
        Blob = 7,
    };

    const MetadataDefaultTag = enum(u8) {
        Literal = 0,
        FunctionCall = 1,
    };

    const MetadataFunctionArgTag = enum(u8) {
        Literal = 0,
        Column = 1,
        Parameter = 2,
    };

    fn serializedValueSize(value: Value) ?usize {
        return switch (value) {
            .Null => 1,
            .Integer, .Real, .BigInt => 1 + 8,
            .Boolean => 1 + 1,
            .SmallInt => 1 + 2,
            .Text => |text| 1 + 2 + text.len,
            .Blob => |blob| 1 + 2 + blob.len,
            else => null,
        };
    }

    fn serializedFunctionArgumentSize(arg: Column.FunctionArgument) ?usize {
        return switch (arg) {
            .Literal => |literal| blk: {
                const size = serializedValueSize(literal) orelse return null;
                break :blk 1 + size;
            },
            .Column => |column| 1 + 2 + column.len,
            .Parameter => 1 + 4,
        };
    }

    fn serializedFunctionCallSize(function_call: Column.FunctionCall) ?usize {
        var size: usize = 2 + function_call.name.len + 2;
        for (function_call.arguments) |arg| {
            size += serializedFunctionArgumentSize(arg) orelse return null;
        }
        return size;
    }

    fn serializedDefaultValueSize(default_value: Column.DefaultValue) ?usize {
        return switch (default_value) {
            .Literal => |literal| blk: {
                const size = serializedValueSize(literal) orelse return null;
                break :blk 1 + size;
            },
            .FunctionCall => |function_call| blk: {
                const size = serializedFunctionCallSize(function_call) orelse return null;
                break :blk 1 + size;
            },
        };
    }

    fn readMetadataValue(self: *Self, buffer: []const u8, offset: *usize) !Value {
        if (offset.* >= buffer.len) return error.InvalidMetadata;
        const tag: MetadataValueTag = @fromBackingInt(@intCast(buffer[offset.*]));
        offset.* += 1;

        return switch (tag) {
            .Null => Value.Null,
            .Integer => blk: {
                if (offset.* + 8 > buffer.len) return error.InvalidMetadata;
                const value = std.mem.readInt(i64, buffer[offset.*..][0..8], .little);
                offset.* += 8;
                break :blk Value{ .Integer = value };
            },
            .Text => blk: {
                if (offset.* + 2 > buffer.len) return error.InvalidMetadata;
                const len = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
                offset.* += 2;
                if (offset.* + len > buffer.len) return error.InvalidMetadata;
                const text = try self.allocator.dupe(u8, buffer[offset.*..][0..len]);
                offset.* += len;
                break :blk Value{ .Text = text };
            },
            .Real => blk: {
                if (offset.* + 8 > buffer.len) return error.InvalidMetadata;
                const bits = std.mem.readInt(u64, buffer[offset.*..][0..8], .little);
                offset.* += 8;
                break :blk Value{ .Real = @bitCast(bits) };
            },
            .Boolean => blk: {
                if (offset.* >= buffer.len) return error.InvalidMetadata;
                const flag = buffer[offset.*] != 0;
                offset.* += 1;
                break :blk Value{ .Boolean = flag };
            },
            .SmallInt => blk: {
                if (offset.* + 2 > buffer.len) return error.InvalidMetadata;
                const value = std.mem.readInt(i16, buffer[offset.*..][0..2], .little);
                offset.* += 2;
                break :blk Value{ .SmallInt = value };
            },
            .BigInt => blk: {
                if (offset.* + 8 > buffer.len) return error.InvalidMetadata;
                const value = std.mem.readInt(i64, buffer[offset.*..][0..8], .little);
                offset.* += 8;
                break :blk Value{ .BigInt = value };
            },
            .Blob => blk: {
                if (offset.* + 2 > buffer.len) return error.InvalidMetadata;
                const len = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
                offset.* += 2;
                if (offset.* + len > buffer.len) return error.InvalidMetadata;
                const blob = try self.allocator.dupe(u8, buffer[offset.*..][0..len]);
                offset.* += len;
                break :blk Value{ .Blob = blob };
            },
        };
    }

    fn readFunctionArgument(self: *Self, buffer: []const u8, offset: *usize) !Column.FunctionArgument {
        if (offset.* >= buffer.len) return error.InvalidMetadata;
        const tag: MetadataFunctionArgTag = @fromBackingInt(@intCast(buffer[offset.*]));
        offset.* += 1;

        return switch (tag) {
            .Literal => Column.FunctionArgument{ .Literal = try self.readMetadataValue(buffer, offset) },
            .Column => blk: {
                if (offset.* + 2 > buffer.len) return error.InvalidMetadata;
                const len = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
                offset.* += 2;
                if (offset.* + len > buffer.len) return error.InvalidMetadata;
                const column = try self.allocator.dupe(u8, buffer[offset.*..][0..len]);
                offset.* += len;
                break :blk Column.FunctionArgument{ .Column = column };
            },
            .Parameter => blk: {
                if (offset.* + 4 > buffer.len) return error.InvalidMetadata;
                const param = std.mem.readInt(u32, buffer[offset.*..][0..4], .little);
                offset.* += 4;
                break :blk Column.FunctionArgument{ .Parameter = param };
            },
        };
    }

    fn readDefaultValue(self: *Self, buffer: []const u8, offset: *usize) !Column.DefaultValue {
        if (offset.* >= buffer.len) return error.InvalidMetadata;
        const tag: MetadataDefaultTag = @fromBackingInt(@intCast(buffer[offset.*]));
        offset.* += 1;

        return switch (tag) {
            .Literal => Column.DefaultValue{ .Literal = try self.readMetadataValue(buffer, offset) },
            .FunctionCall => blk: {
                if (offset.* + 2 > buffer.len) return error.InvalidMetadata;
                const name_len = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
                offset.* += 2;
                if (offset.* + name_len + 2 > buffer.len) return error.InvalidMetadata;
                const name = try self.allocator.dupe(u8, buffer[offset.*..][0..name_len]);
                offset.* += name_len;
                errdefer self.allocator.free(name);

                const arg_count = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
                offset.* += 2;
                var args = try self.allocator.alloc(Column.FunctionArgument, arg_count);
                errdefer self.allocator.free(args);

                var args_loaded: usize = 0;
                errdefer {
                    for (args[0..args_loaded]) |arg| {
                        arg.deinit(self.allocator);
                    }
                }

                while (args_loaded < arg_count) : (args_loaded += 1) {
                    args[args_loaded] = try self.readFunctionArgument(buffer, offset);
                }

                break :blk Column.DefaultValue{ .FunctionCall = Column.FunctionCall{
                    .name = name,
                    .arguments = args,
                } };
            },
        };
    }

    fn metadataValueToAst(self: *Self, value: Value) !ast.Value {
        return switch (value) {
            .Integer => |v| ast.Value{ .Integer = v },
            .Text => |v| ast.Value{ .Text = try self.allocator.dupe(u8, v) },
            .Real => |v| ast.Value{ .Real = v },
            .Blob => |v| ast.Value{ .Blob = try self.allocator.dupe(u8, v) },
            .Null => ast.Value.Null,
            else => error.UnsupportedCheckConstraint,
        };
    }

    fn readCheckExpression(self: *Self, buffer: []const u8, offset: *usize) !ast.Expression {
        if (offset.* >= buffer.len) return error.InvalidMetadata;
        const tag = buffer[offset.*];
        offset.* += 1;

        return switch (tag) {
            1 => blk: {
                if (offset.* + 2 > buffer.len) return error.InvalidMetadata;
                const len = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
                offset.* += 2;
                if (offset.* + len > buffer.len) return error.InvalidMetadata;
                const column = try self.allocator.dupe(u8, buffer[offset.*..][0..len]);
                offset.* += len;
                break :blk ast.Expression{ .Column = column };
            },
            2 => blk: {
                const storage_value = try self.readMetadataValue(buffer, offset);
                defer storage_value.deinit(self.allocator);
                break :blk ast.Expression{ .Literal = try self.metadataValueToAst(storage_value) };
            },
            3 => blk: {
                if (offset.* + 4 > buffer.len) return error.InvalidMetadata;
                const param = std.mem.readInt(u32, buffer[offset.*..][0..4], .little);
                offset.* += 4;
                break :blk ast.Expression{ .Parameter = param };
            },
            4 => blk: {
                if (offset.* >= buffer.len) return error.InvalidMetadata;
                const op: ast.ArithmeticOp = @fromBackingInt(@intCast(buffer[offset.*]));
                offset.* += 1;
                const left = try self.allocator.create(ast.Expression);
                errdefer self.allocator.destroy(left);
                left.* = try self.readCheckExpression(buffer, offset);
                errdefer left.deinit(self.allocator);

                const right = try self.allocator.create(ast.Expression);
                errdefer self.allocator.destroy(right);
                right.* = try self.readCheckExpression(buffer, offset);
                errdefer right.deinit(self.allocator);

                break :blk ast.Expression{ .BinaryOp = .{
                    .left = left,
                    .op = op,
                    .right = right,
                } };
            },
            5 => blk: {
                if (offset.* + 2 > buffer.len) return error.InvalidMetadata;
                const count = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
                offset.* += 2;
                var list = try self.allocator.alloc(ast.Value, count);
                var loaded: usize = 0;
                errdefer {
                    for (list[0..loaded]) |*value| value.deinit(self.allocator);
                    self.allocator.free(list);
                }
                while (loaded < count) : (loaded += 1) {
                    const storage_value = try self.readMetadataValue(buffer, offset);
                    defer storage_value.deinit(self.allocator);
                    list[loaded] = try self.metadataValueToAst(storage_value);
                }
                break :blk ast.Expression{ .InList = list };
            },
            else => error.InvalidMetadata,
        };
    }

    fn readCheckCondition(self: *Self, buffer: []const u8, offset: *usize) !ast.Condition {
        if (offset.* >= buffer.len) return error.InvalidMetadata;
        const tag = buffer[offset.*];
        offset.* += 1;

        return switch (tag) {
            1 => blk: {
                if (offset.* >= buffer.len) return error.InvalidMetadata;
                const op: ast.ComparisonOperator = @fromBackingInt(@intCast(buffer[offset.*]));
                offset.* += 1;
                var condition = ast.Condition{ .Comparison = .{
                    .left = try self.readCheckExpression(buffer, offset),
                    .operator = op,
                    .right = try self.readCheckExpression(buffer, offset),
                    .extra = null,
                } };
                errdefer condition.deinit(self.allocator);

                if (offset.* >= buffer.len) return error.InvalidMetadata;
                const has_extra = buffer[offset.*] != 0;
                offset.* += 1;
                if (has_extra) {
                    condition.Comparison.extra = try self.readCheckExpression(buffer, offset);
                }
                break :blk condition;
            },
            2 => blk: {
                if (offset.* >= buffer.len) return error.InvalidMetadata;
                const op: ast.LogicalOperator = @fromBackingInt(@intCast(buffer[offset.*]));
                offset.* += 1;
                const left = try self.allocator.create(ast.Condition);
                errdefer self.allocator.destroy(left);
                left.* = try self.readCheckCondition(buffer, offset);
                errdefer left.deinit(self.allocator);

                const right = try self.allocator.create(ast.Condition);
                errdefer self.allocator.destroy(right);
                right.* = try self.readCheckCondition(buffer, offset);
                errdefer right.deinit(self.allocator);

                break :blk ast.Condition{ .Logical = .{
                    .left = left,
                    .operator = op,
                    .right = right,
                } };
            },
            else => error.InvalidMetadata,
        };
    }

    fn readForeignKeyAction(self: *Self, buffer: []const u8, offset: *usize) !?ast.ForeignKeyAction {
        _ = self;
        if (offset.* >= buffer.len) return error.InvalidMetadata;
        const has_action = buffer[offset.*] != 0;
        offset.* += 1;
        if (!has_action) return null;
        if (offset.* >= buffer.len) return error.InvalidMetadata;
        const action: ast.ForeignKeyAction = @fromBackingInt(@intCast(buffer[offset.*]));
        offset.* += 1;
        return action;
    }

    fn readForeignKey(self: *Self, buffer: []const u8, offset: *usize) !ast.ForeignKeyConstraint {
        if (offset.* + 2 > buffer.len) return error.InvalidMetadata;
        const column_len = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
        offset.* += 2;
        if (offset.* + column_len + 2 > buffer.len) return error.InvalidMetadata;
        const column = try self.allocator.dupe(u8, buffer[offset.*..][0..column_len]);
        offset.* += column_len;
        errdefer self.allocator.free(column);

        const ref_table_len = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
        offset.* += 2;
        if (offset.* + ref_table_len + 2 > buffer.len) return error.InvalidMetadata;
        const ref_table = try self.allocator.dupe(u8, buffer[offset.*..][0..ref_table_len]);
        offset.* += ref_table_len;
        errdefer self.allocator.free(ref_table);

        const ref_column_len = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
        offset.* += 2;
        if (offset.* + ref_column_len > buffer.len) return error.InvalidMetadata;
        const ref_column = try self.allocator.dupe(u8, buffer[offset.*..][0..ref_column_len]);
        offset.* += ref_column_len;
        errdefer self.allocator.free(ref_column);

        return .{
            .column = column,
            .reference_table = ref_table,
            .reference_column = ref_column,
            .on_delete = try self.readForeignKeyAction(buffer, offset),
            .on_update = try self.readForeignKeyAction(buffer, offset),
        };
    }

    fn readCatalogStringList(self: *Self, buffer: []const u8, offset: *usize, count: usize) ![][]const u8 {
        const values = try self.allocator.alloc([]const u8, count);
        var loaded: usize = 0;
        errdefer {
            for (values[0..loaded]) |value| self.allocator.free(value);
            self.allocator.free(values);
        }
        while (loaded < count) : (loaded += 1) {
            if (offset.* + 2 > buffer.len) return error.CorruptCatalog;
            const len = std.mem.readInt(u16, buffer[offset.*..][0..2], .little);
            offset.* += 2;
            if (offset.* + len > buffer.len) return error.CorruptCatalog;
            values[loaded] = try self.allocator.dupe(u8, buffer[offset.*..][0..len]);
            offset.* += len;
        }
        return values;
    }

    fn clearFTSIndex(self: *Self, fts_index: *FTSIndex) void {
        _ = self;
        var iter = fts_index.inverted_index.iterator();
        while (iter.next()) |entry| {
            fts_index.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(fts_index.allocator);
        }
        fts_index.inverted_index.clearRetainingCapacity();
    }

    fn rebuildFTSIndex(self: *Self, fts_index: *FTSIndex) !void {
        self.clearFTSIndex(fts_index);

        const table = self.getTable(fts_index.table_name) orelse return error.TableNotFound;
        const rows = try table.selectWithKeys(self.allocator);
        defer {
            for (rows) |item| {
                for (item.row.values) |value| {
                    value.deinit(self.allocator);
                }
                self.allocator.free(item.row.values);
            }
            self.allocator.free(rows);
        }

        for (rows) |item| {
            const fts_values = if (item.row.values.len > 1) item.row.values[1..] else item.row.values;
            try fts_index.indexDocument(@intCast(item.key), fts_values);
        }
    }

    /// Load existing tables from storage
    /// Open the catalog, dispatching on the page-1 magic. I/O errors propagate
    /// (never silently degrade to "empty database"); an unrecognized magic is a
    /// genuinely new/empty file and leaves the catalog at its defaults.
    fn loadCatalog(self: *Self) !void {
        if (self.is_memory) return;

        const page = try self.pager.getPage(SUPERBLOCK_PAGE_ID);
        if (page.data.len < 8) return;
        const magic = std.mem.readInt(u32, page.data[0..4], .little);

        if (magic == SUPERBLOCK_MAGIC) {
            try self.loadFromSuperblock(page.data);
        } else if (magic == METADATA_MAGIC) {
            // Legacy single-page catalog. Parse it now; it will be transparently
            // migrated to the superblock format on the next metadata rewrite.
            self.legacy_format = true;
            try self.parseLegacyCatalog();
        }
        // else: new/empty database — leave self.catalog at defaults.
    }

    /// Parse the versioned superblock and load the active catalog chain.
    fn loadFromSuperblock(self: *Self, sb: []const u8) !void {
        if (sb.len < SB_OFF_HEADER_CHECKSUM + 4) return error.CorruptCatalog;

        const stored_checksum = std.mem.readInt(u32, sb[SB_OFF_HEADER_CHECKSUM..][0..4], .little);
        if (stored_checksum != std.hash.Crc32.hash(sb[0..SB_HEADER_LEN])) {
            return error.CorruptCatalog;
        }

        const version = std.mem.readInt(u16, sb[SB_OFF_VERSION..][0..2], .little);
        if (version > CATALOG_FORMAT_VERSION) return error.UnsupportedDatabaseFormat;

        var state = CatalogState{};
        state.active_slot = sb[SB_OFF_ACTIVE];
        if (state.active_slot > 1) return error.CorruptCatalog;
        state.generation = std.mem.readInt(u64, sb[SB_OFF_GENERATION..][0..8], .little);
        state.slots[0] = readSlotDescriptor(sb[SB_OFF_SLOT_A..][0..SLOT_DESC_LEN]);
        state.slots[1] = readSlotDescriptor(sb[SB_OFF_SLOT_B..][0..SLOT_DESC_LEN]);

        self.catalog = state;
        self.legacy_format = false;

        const active = state.slots[state.active_slot];
        if (active.first_page == 0 or active.payload_len == 0) return; // empty catalog

        const payload = try self.readCatalogChain(active);
        defer self.allocator.free(payload);

        if (std.hash.Crc32.hash(payload) != active.checksum) return error.CorruptCatalog;
        try self.deserializeCatalog(payload);
    }

    /// Reassemble a slot's payload by walking its page chain.
    fn readCatalogChain(self: *Self, slot: SlotDescriptor) ![]u8 {
        const payload_len: usize = @intCast(slot.payload_len);
        const buf = try self.allocator.alloc(u8, payload_len);
        errdefer self.allocator.free(buf);

        const capacity: usize = self.pager.page_size - CATALOG_PAGE_HEADER;
        var current = slot.first_page;
        var read_total: usize = 0;
        var pages_visited: u32 = 0;
        while (current != 0 and read_total < payload_len) {
            if (pages_visited >= slot.page_count) return error.CorruptCatalog;
            const page = try self.pager.getPage(current);
            if (page.data.len < CATALOG_PAGE_HEADER) return error.CorruptCatalog;
            const next = std.mem.readInt(u32, page.data[0..4], .little);
            const page_len = std.mem.readInt(u32, page.data[4..8], .little);
            if (page_len > capacity) return error.CorruptCatalog;
            if (read_total + page_len > payload_len) return error.CorruptCatalog;
            @memcpy(buf[read_total..][0..page_len], page.data[CATALOG_PAGE_HEADER..][0..page_len]);
            read_total += page_len;
            current = next;
            pages_visited += 1;
        }
        if (read_total != payload_len) return error.CorruptCatalog;
        return buf;
    }

    /// Decode a serialized catalog payload into in-memory tables/indexes/FTS.
    /// Because the payload checksum is verified before this runs, any structural
    /// inconsistency is treated as corruption rather than silently truncated.
    fn deserializeCatalog(self: *Self, payload: []const u8) !void {
        var offset: usize = 0;

        if (offset + 4 > payload.len) return error.CorruptCatalog;
        const table_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;

        var tables_loaded: u32 = 0;
        while (tables_loaded < table_count) : (tables_loaded += 1) {
            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + name_len > payload.len) return error.CorruptCatalog;
            const table_name = try self.allocator.dupe(u8, payload[offset..][0..name_len]);
            offset += name_len;
            errdefer self.allocator.free(table_name);

            if (offset + 16 > payload.len) return error.CorruptCatalog;
            const root_page = std.mem.readInt(u32, payload[offset..][0..4], .little);
            offset += 4;
            const row_count = std.mem.readInt(u64, payload[offset..][0..8], .little);
            offset += 8;
            const deleted_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
            offset += 4;

            var deleted_keys = std.AutoHashMap(u64, void).init(self.allocator);
            errdefer deleted_keys.deinit();
            var dk_idx: u32 = 0;
            while (dk_idx < deleted_count) : (dk_idx += 1) {
                if (offset + 8 > payload.len) return error.CorruptCatalog;
                const key = std.mem.readInt(u64, payload[offset..][0..8], .little);
                offset += 8;
                try deleted_keys.put(key, {});
            }

            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const column_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;

            var columns = try self.allocator.alloc(Column, column_count);
            var col_idx: usize = 0;
            errdefer {
                for (columns[0..col_idx]) |col| self.allocator.free(col.name);
                self.allocator.free(columns);
            }
            while (col_idx < column_count) : (col_idx += 1) {
                if (offset + 2 > payload.len) return error.CorruptCatalog;
                const col_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
                offset += 2;
                if (offset + col_name_len + 2 > payload.len) return error.CorruptCatalog;
                columns[col_idx].name = try self.allocator.dupe(u8, payload[offset..][0..col_name_len]);
                offset += col_name_len;
                columns[col_idx].data_type = @fromBackingInt(@intCast(payload[offset]));
                offset += 1;
                const flags = payload[offset];
                offset += 1;
                columns[col_idx].is_primary_key = (flags & 0x01) != 0;
                columns[col_idx].is_nullable = (flags & 0x02) != 0;
                columns[col_idx].default_value = null;
                columns[col_idx].generated = null;
            }

            const schema = TableSchema{ .columns = columns[0..col_idx] };
            const table = try Table.loadWithDeletedKeys(self.allocator, self.pager, table_name, schema, root_page, row_count, deleted_keys);
            // Ownership of table_name and deleted_keys transferred to the table.
            for (columns[0..col_idx]) |col| self.allocator.free(col.name);
            self.allocator.free(columns);
            try self.tables.put(table_name, table);
        }

        if (offset + 4 > payload.len) return error.CorruptCatalog;
        const index_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;

        var indexes_loaded: u32 = 0;
        while (indexes_loaded < index_count) : (indexes_loaded += 1) {
            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const index_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + index_name_len > payload.len) return error.CorruptCatalog;
            const index_name = payload[offset..][0..index_name_len];
            offset += index_name_len;

            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const table_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + table_name_len > payload.len) return error.CorruptCatalog;
            const table_name = payload[offset..][0..table_name_len];
            offset += table_name_len;

            if (offset + 3 > payload.len) return error.CorruptCatalog;
            const flags = payload[offset];
            offset += 1;
            const is_unique = (flags & 0x01) != 0;
            const has_advanced_definition = (flags & 0x02) != 0;
            const idx_column_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;

            var column_names = try self.allocator.alloc([]const u8, idx_column_count);
            var loaded_columns: usize = 0;
            errdefer {
                for (column_names[0..loaded_columns]) |cn| self.allocator.free(cn);
                self.allocator.free(column_names);
            }
            while (loaded_columns < idx_column_count) : (loaded_columns += 1) {
                if (offset + 2 > payload.len) return error.CorruptCatalog;
                const cn_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
                offset += 2;
                if (offset + cn_len > payload.len) return error.CorruptCatalog;
                column_names[loaded_columns] = try self.allocator.dupe(u8, payload[offset..][0..cn_len]);
                offset += cn_len;
            }

            const index = try self.registerIndex(index_name, table_name, column_names[0..loaded_columns], is_unique);
            if (!has_advanced_definition) try self.rebuildIndex(index);

            for (column_names[0..loaded_columns]) |cn| self.allocator.free(cn);
            self.allocator.free(column_names);
        }

        // Table extensions: per-column default values.
        if (offset + 4 > payload.len) return error.CorruptCatalog;
        const table_extension_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;

        var table_extensions_loaded: u32 = 0;
        while (table_extensions_loaded < table_extension_count) : (table_extensions_loaded += 1) {
            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const table_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + table_name_len + 2 > payload.len) return error.CorruptCatalog;
            const table_name = payload[offset..][0..table_name_len];
            offset += table_name_len;
            const default_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;

            if (self.getTable(table_name)) |table| {
                var defaults_loaded: u16 = 0;
                while (defaults_loaded < default_count) : (defaults_loaded += 1) {
                    if (offset + 2 > payload.len) return error.CorruptCatalog;
                    const column_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
                    offset += 2;
                    if (offset + column_name_len > payload.len) return error.CorruptCatalog;
                    const column_name = payload[offset..][0..column_name_len];
                    offset += column_name_len;

                    const default_value = try self.readDefaultValue(payload, &offset);
                    if (table.getColumnIndex(column_name)) |column_idx| {
                        if (table.schema.columns[column_idx].default_value) |existing| {
                            existing.deinit(self.allocator);
                        }
                        table.schema.columns[column_idx].default_value = default_value;
                    } else {
                        default_value.deinit(self.allocator);
                    }
                }
            } else {
                var defaults_skipped: u16 = 0;
                while (defaults_skipped < default_count) : (defaults_skipped += 1) {
                    if (offset + 2 > payload.len) return error.CorruptCatalog;
                    const column_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
                    offset += 2;
                    if (offset + column_name_len > payload.len) return error.CorruptCatalog;
                    offset += column_name_len;
                    var skipped_default = try self.readDefaultValue(payload, &offset);
                    skipped_default.deinit(self.allocator);
                }
            }
        }

        // FTS indexes
        if (offset + 4 > payload.len) return error.CorruptCatalog;
        const fts_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;

        var fts_loaded: u32 = 0;
        while (fts_loaded < fts_count) : (fts_loaded += 1) {
            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const table_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + table_name_len + 2 > payload.len) return error.CorruptCatalog;
            const table_name = payload[offset..][0..table_name_len];
            offset += table_name_len;
            const fts_column_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;

            var column_names = try self.allocator.alloc([]const u8, fts_column_count);
            var loaded_columns: usize = 0;
            errdefer {
                for (column_names[0..loaded_columns]) |cn| self.allocator.free(cn);
                self.allocator.free(column_names);
            }
            while (loaded_columns < fts_column_count) : (loaded_columns += 1) {
                if (offset + 2 > payload.len) return error.CorruptCatalog;
                const cn_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
                offset += 2;
                if (offset + cn_len > payload.len) return error.CorruptCatalog;
                column_names[loaded_columns] = try self.allocator.dupe(u8, payload[offset..][0..cn_len]);
                offset += cn_len;
            }

            try self.createFTSIndex(table_name, column_names[0..loaded_columns]);
            if (self.getFTSIndex(table_name)) |fts_index| {
                try self.rebuildFTSIndex(fts_index);
            }

            for (column_names[0..loaded_columns]) |cn| self.allocator.free(cn);
            self.allocator.free(column_names);
        }

        // Optional CHECK constraint extension appended after the original
        // catalog sections. Catalogs written before this extension end here.
        if (offset == payload.len) return;
        if (offset + 4 > payload.len) return error.CorruptCatalog;
        const check_extension_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;

        var check_extensions_loaded: u32 = 0;
        while (check_extensions_loaded < check_extension_count) : (check_extensions_loaded += 1) {
            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const table_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + table_name_len + 2 > payload.len) return error.CorruptCatalog;
            const table_name = payload[offset..][0..table_name_len];
            offset += table_name_len;
            const check_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;

            var checks = try self.allocator.alloc(ast.Condition, check_count);
            var checks_loaded: usize = 0;
            errdefer {
                for (checks[0..checks_loaded]) |*condition| condition.deinit(self.allocator);
                self.allocator.free(checks);
            }

            while (checks_loaded < check_count) : (checks_loaded += 1) {
                checks[checks_loaded] = try self.readCheckCondition(payload, &offset);
            }

            if (self.getTable(table_name)) |table| {
                for (table.schema.check_constraints) |*condition| condition.deinit(self.allocator);
                if (table.schema.check_constraints.len > 0) self.allocator.free(table.schema.check_constraints);
                table.schema.check_constraints = checks;
            } else {
                for (checks[0..checks_loaded]) |*condition| condition.deinit(self.allocator);
                self.allocator.free(checks);
            }
        }

        if (offset == payload.len) return;
        if (offset + 4 > payload.len) return error.CorruptCatalog;
        const fk_extension_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;

        var fk_extensions_loaded: u32 = 0;
        while (fk_extensions_loaded < fk_extension_count) : (fk_extensions_loaded += 1) {
            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const table_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + table_name_len + 2 > payload.len) return error.CorruptCatalog;
            const table_name = payload[offset..][0..table_name_len];
            offset += table_name_len;
            const foreign_key_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;

            var foreign_keys = try self.allocator.alloc(ast.ForeignKeyConstraint, foreign_key_count);
            var foreign_keys_loaded: usize = 0;
            errdefer {
                for (foreign_keys[0..foreign_keys_loaded]) |foreign_key| foreign_key.deinit(self.allocator);
                self.allocator.free(foreign_keys);
            }

            while (foreign_keys_loaded < foreign_key_count) : (foreign_keys_loaded += 1) {
                foreign_keys[foreign_keys_loaded] = try self.readForeignKey(payload, &offset);
            }

            if (self.getTable(table_name)) |table| {
                for (table.schema.foreign_keys) |foreign_key| foreign_key.deinit(self.allocator);
                if (table.schema.foreign_keys.len > 0) self.allocator.free(table.schema.foreign_keys);
                table.schema.foreign_keys = foreign_keys;
            } else {
                for (foreign_keys[0..foreign_keys_loaded]) |foreign_key| foreign_key.deinit(self.allocator);
                self.allocator.free(foreign_keys);
            }
        }

        if (offset == payload.len) return;
        if (offset + 4 > payload.len) return error.CorruptCatalog;
        const metadata_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;
        if (metadata_count > 0) {
            if (offset + 8 > payload.len) return error.CorruptCatalog;
            self.user_version = std.mem.readInt(u32, payload[offset..][0..4], .little);
            offset += 4;
            self.schema_version = std.mem.readInt(u32, payload[offset..][0..4], .little);
            offset += 4;
        }

        if (offset == payload.len) return;
        if (offset + 4 > payload.len) return error.CorruptCatalog;
        const advanced_index_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;
        var advanced_loaded: u32 = 0;
        while (advanced_loaded < advanced_index_count) : (advanced_loaded += 1) {
            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + name_len + 2 > payload.len) return error.CorruptCatalog;
            const index_name = payload[offset..][0..name_len];
            offset += name_len;
            const expression_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;

            const expressions = try self.allocator.alloc(ast.Expression, expression_count);
            var expressions_loaded: usize = 0;
            var expressions_owned = true;
            errdefer if (expressions_owned) {
                for (expressions[0..expressions_loaded]) |*expression| expression.deinit(self.allocator);
                self.allocator.free(expressions);
            };
            while (expressions_loaded < expression_count) : (expressions_loaded += 1) {
                expressions[expressions_loaded] = try self.readCheckExpression(payload, &offset);
            }
            if (offset >= payload.len) return error.CorruptCatalog;
            const has_where = payload[offset];
            offset += 1;
            if (has_where > 1) return error.CorruptCatalog;
            var where_clause: ?ast.Condition = if (has_where == 1) try self.readCheckCondition(payload, &offset) else null;
            var where_owned = true;
            errdefer if (where_owned) if (where_clause) |*condition| condition.deinit(self.allocator);

            if (self.getIndex(index_name)) |index| {
                for (index.expressions) |*expression| expression.deinit(self.allocator);
                self.allocator.free(index.expressions);
                if (index.where_clause) |*condition| condition.deinit(self.allocator);
                index.expressions = expressions;
                index.where_clause = where_clause;
                expressions_owned = false;
                where_owned = false;
                where_clause = null;
                try self.rebuildIndex(index);
            } else {
                for (expressions) |*expression| expression.deinit(self.allocator);
                self.allocator.free(expressions);
                expressions_owned = false;
                if (where_clause) |*condition| condition.deinit(self.allocator);
                where_owned = false;
                where_clause = null;
            }
        }
        if (offset == payload.len) return;
        if (offset + 4 > payload.len) return error.CorruptCatalog;
        const advanced_fk_table_count = std.mem.readInt(u32, payload[offset..][0..4], .little);
        offset += 4;
        var advanced_fk_tables_loaded: u32 = 0;
        while (advanced_fk_tables_loaded < advanced_fk_table_count) : (advanced_fk_tables_loaded += 1) {
            if (offset + 2 > payload.len) return error.CorruptCatalog;
            const table_name_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            if (offset + table_name_len + 2 > payload.len) return error.CorruptCatalog;
            const table_name = payload[offset..][0..table_name_len];
            offset += table_name_len;
            const constraint_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
            offset += 2;
            var constraint_idx: u16 = 0;
            while (constraint_idx < constraint_count) : (constraint_idx += 1) {
                if (offset + 2 > payload.len) return error.CorruptCatalog;
                const child_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
                offset += 2;
                if (child_count == 0) return error.CorruptCatalog;
                const child_columns = try self.readCatalogStringList(payload, &offset, child_count);
                var child_owned = true;
                errdefer if (child_owned) {
                    for (child_columns) |column| self.allocator.free(column);
                    self.allocator.free(child_columns);
                };
                if (offset + 2 > payload.len) return error.CorruptCatalog;
                const reference_table_len = std.mem.readInt(u16, payload[offset..][0..2], .little);
                offset += 2;
                if (offset + reference_table_len + 2 > payload.len) return error.CorruptCatalog;
                const reference_table = try self.allocator.dupe(u8, payload[offset..][0..reference_table_len]);
                offset += reference_table_len;
                var reference_table_owned = true;
                errdefer if (reference_table_owned) self.allocator.free(reference_table);
                const reference_count = std.mem.readInt(u16, payload[offset..][0..2], .little);
                offset += 2;
                if (reference_count != child_count) return error.CorruptCatalog;
                const reference_columns = try self.readCatalogStringList(payload, &offset, reference_count);
                var references_owned = true;
                errdefer if (references_owned) {
                    for (reference_columns) |column| self.allocator.free(column);
                    self.allocator.free(reference_columns);
                };
                const on_delete = try self.readForeignKeyAction(payload, &offset);
                const on_update = try self.readForeignKeyAction(payload, &offset);
                if (offset >= payload.len or payload[offset] > 1) return error.CorruptCatalog;
                const deferred = payload[offset] == 1;
                offset += 1;

                var foreign_key: ast.ForeignKeyConstraint = if (child_count == 1) .{
                    .column = child_columns[0],
                    .reference_table = reference_table,
                    .reference_column = reference_columns[0],
                    .on_delete = on_delete,
                    .on_update = on_update,
                    .deferred = deferred,
                } else .{
                    .column = null,
                    .columns = child_columns,
                    .reference_table = reference_table,
                    .reference_column = try self.allocator.dupe(u8, reference_columns[0]),
                    .reference_columns = reference_columns,
                    .on_delete = on_delete,
                    .on_update = on_update,
                    .deferred = deferred,
                };
                if (child_count == 1) {
                    self.allocator.free(child_columns);
                    self.allocator.free(reference_columns);
                }
                child_owned = false;
                references_owned = false;
                reference_table_owned = false;

                if (self.getTable(table_name)) |table| {
                    const previous = table.schema.foreign_keys;
                    const expanded = try self.allocator.alloc(ast.ForeignKeyConstraint, previous.len + 1);
                    @memcpy(expanded[0..previous.len], previous);
                    expanded[previous.len] = foreign_key;
                    if (previous.len > 0) self.allocator.free(previous);
                    table.schema.foreign_keys = expanded;
                } else {
                    foreign_key.deinit(self.allocator);
                }
            }
        }
        if (offset != payload.len) return error.CorruptCatalog;
    }

    /// Parse the legacy single-page (page 1) catalog format. Retained so existing
    /// databases keep opening; they are migrated on the next metadata rewrite.
    fn parseLegacyCatalog(self: *Self) !void {
        if (self.is_memory) return; // No persistence for in-memory databases

        const page = try self.pager.getPage(METADATA_PAGE_ID);

        // Check magic number
        if (page.data.len < 8) return;
        const magic = std.mem.readInt(u32, page.data[0..4], .little);
        if (magic != METADATA_MAGIC) return; // Not a valid ZQLite database or new file

        const table_count = std.mem.readInt(u32, page.data[4..8], .little);
        var offset: usize = 8;

        var tables_loaded: u32 = 0;
        while (tables_loaded < table_count and offset + 4 < page.data.len) {
            // Read table name
            const name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;
            if (offset + name_len > page.data.len) break;

            const table_name = try self.allocator.dupe(u8, page.data[offset..][0..name_len]);
            offset += name_len;

            // Read btree root page (4 bytes)
            if (offset + 4 > page.data.len) {
                self.allocator.free(table_name);
                break;
            }
            const root_page = std.mem.readInt(u32, page.data[offset..][0..4], .little);
            offset += 4;

            // Read row count (8 bytes)
            if (offset + 8 > page.data.len) {
                self.allocator.free(table_name);
                break;
            }
            const row_count = std.mem.readInt(u64, page.data[offset..][0..8], .little);
            offset += 8;

            // Read deleted keys count (4 bytes)
            if (offset + 4 > page.data.len) {
                self.allocator.free(table_name);
                break;
            }
            const deleted_keys_count = std.mem.readInt(u32, page.data[offset..][0..4], .little);
            offset += 4;

            // Read deleted keys (8 bytes each)
            var deleted_keys = std.AutoHashMap(u64, void).init(self.allocator);
            var dk_idx: u32 = 0;
            while (dk_idx < deleted_keys_count and offset + 8 <= page.data.len) {
                const key = std.mem.readInt(u64, page.data[offset..][0..8], .little);
                offset += 8;
                try deleted_keys.put(key, {});
                dk_idx += 1;
            }

            // Read column count
            if (offset + 2 > page.data.len) {
                self.allocator.free(table_name);
                deleted_keys.deinit();
                break;
            }
            const column_count = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;

            // Read columns
            var columns = try self.allocator.alloc(Column, column_count);
            var col_idx: usize = 0;
            while (col_idx < column_count and offset + 4 < page.data.len) {
                const col_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
                offset += 2;
                if (offset + col_name_len + 2 > page.data.len) break;

                columns[col_idx].name = try self.allocator.dupe(u8, page.data[offset..][0..col_name_len]);
                offset += col_name_len;

                columns[col_idx].data_type = @fromBackingInt(@intCast(page.data[offset]));
                offset += 1;

                const flags = page.data[offset];
                offset += 1;
                columns[col_idx].is_primary_key = (flags & 0x01) != 0;
                columns[col_idx].is_nullable = (flags & 0x02) != 0;
                columns[col_idx].default_value = null;
                columns[col_idx].generated = null;

                col_idx += 1;
            }

            // Load the table with existing btree root page
            const schema = TableSchema{ .columns = columns[0..col_idx] };
            const table = try Table.loadWithDeletedKeys(self.allocator, self.pager, table_name, schema, root_page, row_count, deleted_keys);
            try self.tables.put(table_name, table);

            // Free temporary column allocations (Table.load clones them)
            for (columns[0..col_idx]) |col| {
                self.allocator.free(col.name);
            }
            self.allocator.free(columns);

            tables_loaded += 1;
        }

        if (offset + 4 > page.data.len) return;

        const index_count = std.mem.readInt(u32, page.data[offset..][0..4], .little);
        offset += 4;

        var indexes_loaded: u32 = 0;
        while (indexes_loaded < index_count and offset + 7 < page.data.len) {
            const index_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;
            if (offset + index_name_len > page.data.len) break;
            const index_name = page.data[offset..][0..index_name_len];
            offset += index_name_len;

            const table_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;
            if (offset + table_name_len > page.data.len) break;
            const table_name = page.data[offset..][0..table_name_len];
            offset += table_name_len;

            if (offset + 3 > page.data.len) break;
            const flags = page.data[offset];
            offset += 1;
            const is_unique = (flags & 0x01) != 0;

            const column_count = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;

            var column_names = try self.allocator.alloc([]const u8, column_count);
            var loaded_columns: usize = 0;
            errdefer {
                for (column_names[0..loaded_columns]) |column_name| {
                    self.allocator.free(column_name);
                }
                self.allocator.free(column_names);
            }

            while (loaded_columns < column_count and offset + 2 <= page.data.len) {
                const column_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
                offset += 2;
                if (offset + column_name_len > page.data.len) break;

                column_names[loaded_columns] = try self.allocator.dupe(u8, page.data[offset..][0..column_name_len]);
                offset += column_name_len;
                loaded_columns += 1;
            }

            const index = try self.registerIndex(index_name, table_name, column_names[0..loaded_columns], is_unique);
            try self.rebuildIndex(index);

            for (column_names[0..loaded_columns]) |column_name| {
                self.allocator.free(column_name);
            }
            self.allocator.free(column_names);

            indexes_loaded += 1;
        }

        if (page.data.len < 4) return;
        const ext_magic_offset = page.data.len - 4;
        if (offset > ext_magic_offset) return;
        const ext_magic = std.mem.readInt(u32, page.data[ext_magic_offset..][0..4], .little);
        if (ext_magic != METADATA_EXT_MAGIC) return;

        if (offset + 4 > ext_magic_offset) return;
        const table_extension_count = std.mem.readInt(u32, page.data[offset..][0..4], .little);
        offset += 4;

        var table_extensions_loaded: u32 = 0;
        while (table_extensions_loaded < table_extension_count and offset + 4 <= ext_magic_offset) {
            const table_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;
            if (offset + table_name_len + 2 > ext_magic_offset) break;
            const table_name = page.data[offset..][0..table_name_len];
            offset += table_name_len;

            const default_count = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;

            if (self.getTable(table_name)) |table| {
                var defaults_loaded: u16 = 0;
                while (defaults_loaded < default_count and offset + 2 <= ext_magic_offset) : (defaults_loaded += 1) {
                    const column_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
                    offset += 2;
                    if (offset + column_name_len > ext_magic_offset) break;
                    const column_name = page.data[offset..][0..column_name_len];
                    offset += column_name_len;

                    const default_value = try self.readDefaultValue(page.data[0..ext_magic_offset], &offset);
                    errdefer default_value.deinit(self.allocator);

                    if (table.getColumnIndex(column_name)) |column_idx| {
                        if (table.schema.columns[column_idx].default_value) |existing| {
                            existing.deinit(self.allocator);
                        }
                        table.schema.columns[column_idx].default_value = default_value;
                    } else {
                        default_value.deinit(self.allocator);
                    }
                }
            } else {
                var defaults_skipped: u16 = 0;
                while (defaults_skipped < default_count and offset + 2 <= ext_magic_offset) : (defaults_skipped += 1) {
                    const column_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
                    offset += 2;
                    if (offset + column_name_len > ext_magic_offset) break;
                    offset += column_name_len;
                    var skipped_default = try self.readDefaultValue(page.data[0..ext_magic_offset], &offset);
                    skipped_default.deinit(self.allocator);
                }
            }

            table_extensions_loaded += 1;
        }

        if (offset + 4 > ext_magic_offset) return;
        const fts_count = std.mem.readInt(u32, page.data[offset..][0..4], .little);
        offset += 4;

        var fts_loaded: u32 = 0;
        while (fts_loaded < fts_count and offset + 4 <= ext_magic_offset) {
            const table_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;
            if (offset + table_name_len + 2 > ext_magic_offset) break;
            const table_name = page.data[offset..][0..table_name_len];
            offset += table_name_len;

            const column_count = std.mem.readInt(u16, page.data[offset..][0..2], .little);
            offset += 2;

            var column_names = try self.allocator.alloc([]const u8, column_count);
            var loaded_columns: usize = 0;
            errdefer {
                for (column_names[0..loaded_columns]) |column_name| {
                    self.allocator.free(column_name);
                }
                self.allocator.free(column_names);
            }

            while (loaded_columns < column_count and offset + 2 <= ext_magic_offset) {
                const column_name_len = std.mem.readInt(u16, page.data[offset..][0..2], .little);
                offset += 2;
                if (offset + column_name_len > ext_magic_offset) break;
                column_names[loaded_columns] = try self.allocator.dupe(u8, page.data[offset..][0..column_name_len]);
                offset += column_name_len;
                loaded_columns += 1;
            }

            try self.createFTSIndex(table_name, column_names[0..loaded_columns]);
            if (self.getFTSIndex(table_name)) |fts_index| {
                try self.rebuildFTSIndex(fts_index);
            }

            for (column_names[0..loaded_columns]) |column_name| {
                self.allocator.free(column_name);
            }
            self.allocator.free(column_names);

            fts_loaded += 1;
        }
    }

    /// Save table metadata to storage
    /// Uses atomic rewrite to ensure consistency
    fn saveTableMetadata(self: *Self, table: *Table) !void {
        _ = table; // Table is already in self.tables
        if (self.is_memory) return;

        // Rewrite all metadata atomically
        try self.rewriteAllMetadata();
    }

    /// Clean up storage engine
    pub fn deinit(self: *Self) void {
        var table_iterator = self.tables.iterator();
        while (table_iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.tables.deinit();

        var index_iterator = self.indexes.iterator();
        while (index_iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.indexes.deinit();

        // Cleanup FTS indexes
        var fts_iterator = self.fts_indexes.iterator();
        while (fts_iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.fts_indexes.deinit();

        self.pager.deinit();
        self.memory_pool.deinit();
        self.allocator.destroy(self);
    }

    /// Get storage statistics
    pub fn getStats(self: *Self) StorageStats {
        const cache_stats = self.pager.getCacheStats();
        return StorageStats{
            .table_count = @intCast(self.tables.count()),
            .index_count = @intCast(self.indexes.count()),
            .is_memory = self.is_memory,
            .page_count = self.pager.getPageCount(),
            .cache_hit_ratio = cache_stats.hit_ratio,
            .cached_pages = cache_stats.cached_pages,
        };
    }

    pub fn validateIntegrity(self: *Self, allocator: std.mem.Allocator) !IntegrityCheckResult {
        var result = IntegrityCheckResult{};

        var table_iter = self.tables.iterator();
        while (table_iter.next()) |entry| {
            const table_name = entry.key_ptr.*;
            const table = entry.value_ptr.*;
            result.table_count += 1;
            result.deleted_rows += table.deleted_keys.count();

            var deleted_iter = table.deleted_keys.keyIterator();
            while (deleted_iter.next()) |key| {
                if (key.* >= table.row_count) {
                    try result.addIssue(allocator, "deleted row key exceeds table row count");
                }
            }

            const all_rows = table.btree.selectAllWithKeys(allocator) catch |err| {
                try result.addIssue(allocator, "table scan failed during integrity check");
                return err;
            };
            defer {
                for (all_rows) |item| {
                    for (item.row.values) |value| value.deinit(allocator);
                    allocator.free(item.row.values);
                }
                allocator.free(all_rows);
            }

            var live_rows: usize = 0;
            var deleted_existing_rows: usize = 0;
            for (all_rows) |item| {
                if (table.deleted_keys.contains(item.key)) {
                    deleted_existing_rows += 1;
                } else {
                    live_rows += 1;
                }
            }

            result.live_rows += live_rows;
            if (table.deleted_keys.count() != deleted_existing_rows) {
                try result.addIssue(allocator, "deleted row metadata references missing rows");
            }
            const expected_live = all_rows.len - deleted_existing_rows;
            if (live_rows != expected_live) {
                try result.addIssue(allocator, "table live row count does not match catalog metadata");
            }

            for (all_rows) |item| {
                if (!table.deleted_keys.contains(item.key) and item.row.values.len != table.schema.columns.len) {
                    try result.addIssue(allocator, "row column count does not match table schema");
                }
            }

            _ = table_name;
        }

        var index_iter = self.indexes.iterator();
        while (index_iter.next()) |entry| {
            const index = entry.value_ptr.*;
            result.index_count += 1;

            const table = self.getTable(index.table_name) orelse {
                try result.addIssue(allocator, "index references missing table");
                continue;
            };

            for (index.column_names) |column_name| {
                if (table.getColumnIndex(column_name) == null and index.expressions.len == 0) {
                    try result.addIssue(allocator, "index references missing column");
                }
            }

            const index_rows = index.btree.selectAllWithKeys(allocator) catch |err| {
                try result.addIssue(allocator, "index scan failed during integrity check");
                return err;
            };
            defer {
                for (index_rows) |item| {
                    for (item.row.values) |value| value.deinit(allocator);
                    allocator.free(item.row.values);
                }
                allocator.free(index_rows);
            }

            var indexed_row_ids = std.AutoHashMap(i64, void).init(allocator);
            defer indexed_row_ids.deinit();
            for (index_rows) |item| {
                if (item.row.values.len == 0) continue;
                switch (item.row.values[0]) {
                    .Integer => |row_id| try indexed_row_ids.put(row_id, {}),
                    else => {},
                }
            }
            result.index_entries += indexed_row_ids.count();

            const rows = table.selectWithKeys(allocator) catch |err| {
                try result.addIssue(allocator, "table scan for index validation failed");
                return err;
            };
            defer {
                for (rows) |item| {
                    for (item.row.values) |value| value.deinit(allocator);
                    allocator.free(item.row.values);
                }
                allocator.free(rows);
            }

            var expected_indexed_rows: usize = 0;
            for (rows) |item| {
                if (!rowMatchesPartialPredicate(table, index, item.row.values)) continue;
                if (computeIndexKey(table, index, item.row.values) == null) continue;
                expected_indexed_rows += 1;
                if (!indexed_row_ids.contains(item.key)) {
                    try result.addIssue(allocator, "index missing expected table row");
                }
            }

            if (indexed_row_ids.count() != expected_indexed_rows) {
                try result.addIssue(allocator, "index entry count does not match table rows");
            }
        }

        result.ok = result.issue_count == 0;
        return result;
    }
};

/// Table representation
pub const Table = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    schema: TableSchema,
    btree: *btree.BTree,
    row_count: u64,
    deleted_keys: std.AutoHashMap(u64, void), // Keys of logically deleted rows

    const Self = @This();

    /// Create a new table
    pub fn create(allocator: std.mem.Allocator, page_manager: *pager.Pager, name: []const u8, schema: TableSchema) !*Self {
        var table = try allocator.create(Self);
        errdefer allocator.destroy(table);
        table.allocator = allocator;
        table.name = try allocator.dupe(u8, name);
        errdefer allocator.free(table.name);
        // Deep clone schema to ensure ownership with storage engine's allocator
        table.schema = try schema.clone(allocator);
        errdefer table.schema.deinit(allocator);
        table.btree = try btree.BTree.init(allocator, page_manager);
        table.row_count = 0;
        table.deleted_keys = std.AutoHashMap(u64, void).init(allocator);

        return table;
    }

    /// Load an existing table from persisted root page
    pub fn load(allocator: std.mem.Allocator, page_manager: *pager.Pager, name: []const u8, schema: TableSchema, root_page: u32, row_count: u64) !*Self {
        var table = try allocator.create(Self);
        table.allocator = allocator;
        table.name = try allocator.dupe(u8, name);
        table.schema = try schema.clone(allocator);
        table.btree = try btree.BTree.loadFromRootPage(allocator, page_manager, root_page);
        table.row_count = row_count;
        table.deleted_keys = std.AutoHashMap(u64, void).init(allocator);

        return table;
    }

    /// Load an existing table with persisted deleted keys
    pub fn loadWithDeletedKeys(allocator: std.mem.Allocator, page_manager: *pager.Pager, name: []const u8, schema: TableSchema, root_page: u32, row_count: u64, deleted_keys: std.AutoHashMap(u64, void)) !*Self {
        var table = try allocator.create(Self);
        table.allocator = allocator;
        table.name = try allocator.dupe(u8, name);
        table.schema = try schema.clone(allocator);
        table.btree = try btree.BTree.loadFromRootPage(allocator, page_manager, root_page);
        table.row_count = row_count;
        table.deleted_keys = deleted_keys; // Take ownership of the map

        return table;
    }

    /// Insert a row into the table (returns the row_id/key)
    pub fn insert(self: *Self, alloc: std.mem.Allocator, values: []Value) !i64 {
        _ = alloc;
        const row_id = self.row_count;
        try self.btree.insert(row_id, Row{ .values = values });
        self.row_count += 1;
        return @intCast(row_id);
    }

    /// Insert a Row into the table
    pub fn insertRow(self: *Self, row: Row) !void {
        try self.btree.insert(self.row_count, row);
        self.row_count += 1;
    }

    /// Delete a row by its key (logical delete)
    pub fn delete(self: *Self, alloc: std.mem.Allocator, row_id: i64) !void {
        const row = try self.btree.search(@intCast(row_id)) orelse return;
        for (row.values) |value| value.deinit(alloc);
        alloc.free(row.values);
        try self.deleted_keys.put(@intCast(row_id), {});
    }

    /// Undelete a row by its key (for ROLLBACK of DELETE)
    pub fn undelete(self: *Self, row_id: i64) void {
        _ = self.deleted_keys.remove(@intCast(row_id));
    }

    /// Update a row by key
    pub fn updateRow(self: *Self, alloc: std.mem.Allocator, row_id: i64, new_values: []Value) !void {
        // Mark old as deleted
        try self.deleted_keys.put(@intCast(row_id), {});
        // Insert new values with a new key
        const new_row_id = self.row_count;
        try self.btree.insert(new_row_id, Row{ .values = new_values });
        self.row_count += 1;
        _ = alloc;
    }

    /// Select all non-deleted rows
    pub fn select(self: *Self, allocator: std.mem.Allocator) ![]Row {
        const all_rows = try self.btree.selectAllWithKeys(allocator);
        defer allocator.free(all_rows);

        // Filter out deleted rows
        var results: std.ArrayListUnmanaged(Row) = .empty;
        for (all_rows) |item| {
            if (!self.deleted_keys.contains(item.key)) {
                try results.append(allocator, item.row);
            } else {
                // Free the deleted row's values
                for (item.row.values) |value| {
                    value.deinit(allocator);
                }
                allocator.free(item.row.values);
            }
        }
        return results.toOwnedSlice(allocator);
    }

    /// KeyRow pair for returning rows with their keys
    pub const KeyRow = struct {
        key: i64,
        row: Row,
    };

    /// Select all non-deleted rows with their keys (for UPDATE/DELETE with undo logging)
    pub fn selectWithKeys(self: *Self, allocator: std.mem.Allocator) ![]KeyRow {
        const all_rows = try self.btree.selectAllWithKeys(allocator);
        defer allocator.free(all_rows);

        // Filter out deleted rows
        var results: std.ArrayListUnmanaged(KeyRow) = .empty;
        for (all_rows) |item| {
            if (!self.deleted_keys.contains(item.key)) {
                try results.append(allocator, KeyRow{
                    .key = @intCast(item.key),
                    .row = item.row,
                });
            } else {
                // Free the deleted row's values
                for (item.row.values) |value| {
                    value.deinit(allocator);
                }
                allocator.free(item.row.values);
            }
        }
        return results.toOwnedSlice(allocator);
    }

    /// Get a single row by key (returns null if deleted or not found)
    pub fn getRow(self: *Self, row_id: i64) !?Row {
        const key: u64 = @intCast(row_id);
        if (self.deleted_keys.contains(key)) {
            return null;
        }
        return try self.btree.search(key);
    }

    /// Get column index by name
    pub fn getColumnIndex(self: *Self, column_name: []const u8) ?usize {
        for (self.schema.columns, 0..) |col, idx| {
            if (std.mem.eql(u8, col.name, column_name)) {
                return idx;
            }
        }
        return null;
    }

    /// Clean up table
    pub fn deinit(self: *Self) void {
        self.btree.deinit();
        self.deleted_keys.deinit();
        self.allocator.free(self.name);
        self.schema.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Table schema definition
pub const TableSchema = struct {
    columns: []Column,
    check_constraints: []ast.Condition = &.{},
    foreign_keys: []ast.ForeignKeyConstraint = &.{},

    pub fn deinit(self: *TableSchema, allocator: std.mem.Allocator) void {
        // Clean up column names and default values
        for (self.columns) |column| {
            allocator.free(column.name);
            if (column.default_value) |default_value| {
                default_value.deinit(allocator);
            }
            if (column.generated) |generated| {
                generated.deinit(allocator);
            }
        }
        allocator.free(self.columns);
        for (self.check_constraints) |*condition| {
            condition.deinit(allocator);
        }
        if (self.check_constraints.len > 0) allocator.free(self.check_constraints);
        for (self.foreign_keys) |foreign_key| {
            foreign_key.deinit(allocator);
        }
        if (self.foreign_keys.len > 0) allocator.free(self.foreign_keys);
    }

    /// Deep clone schema with a new allocator (for ownership transfer)
    pub fn clone(self: TableSchema, allocator: std.mem.Allocator) CloneValueError!TableSchema {
        var cloned_columns = try allocator.alloc(Column, self.columns.len);

        for (self.columns, 0..) |column, i| {
            cloned_columns[i] = Column{
                .name = try allocator.dupe(u8, column.name),
                .data_type = column.data_type,
                .is_primary_key = column.is_primary_key,
                .is_nullable = column.is_nullable,
                .default_value = if (column.default_value) |default_val|
                    try default_val.clone(allocator)
                else
                    null,
                .generated = if (column.generated) |generated|
                    try generated.clone(allocator)
                else
                    null,
                .is_unique = column.is_unique,
            };
        }

        var cloned_checks = try allocator.alloc(ast.Condition, self.check_constraints.len);
        var checks_cloned: usize = 0;
        errdefer {
            for (cloned_checks[0..checks_cloned]) |*condition| {
                condition.deinit(allocator);
            }
            allocator.free(cloned_checks);
        }

        for (self.check_constraints, 0..) |*condition, i| {
            cloned_checks[i] = try cloneAstCondition(allocator, condition);
            checks_cloned = i + 1;
        }

        var cloned_foreign_keys = try allocator.alloc(ast.ForeignKeyConstraint, self.foreign_keys.len);
        var foreign_keys_cloned: usize = 0;
        errdefer {
            for (cloned_foreign_keys[0..foreign_keys_cloned]) |foreign_key| {
                foreign_key.deinit(allocator);
            }
            allocator.free(cloned_foreign_keys);
        }

        for (self.foreign_keys, 0..) |foreign_key, i| {
            cloned_foreign_keys[i] = try cloneAstForeignKey(allocator, foreign_key);
            foreign_keys_cloned = i + 1;
        }

        return TableSchema{
            .columns = cloned_columns,
            .check_constraints = cloned_checks,
            .foreign_keys = cloned_foreign_keys,
        };
    }
};

fn cloneAstForeignKey(allocator: std.mem.Allocator, foreign_key: ast.ForeignKeyConstraint) CloneValueError!ast.ForeignKeyConstraint {
    const columns = if (foreign_key.columns) |source| blk: {
        const cloned = try allocator.alloc([]const u8, source.len);
        for (source, 0..) |column, i| cloned[i] = try allocator.dupe(u8, column);
        break :blk cloned;
    } else null;
    const reference_columns = if (foreign_key.reference_columns) |source| blk: {
        const cloned = try allocator.alloc([]const u8, source.len);
        for (source, 0..) |column, i| cloned[i] = try allocator.dupe(u8, column);
        break :blk cloned;
    } else null;
    return .{
        .column = if (foreign_key.column) |column| try allocator.dupe(u8, column) else null,
        .columns = columns,
        .reference_table = try allocator.dupe(u8, foreign_key.reference_table),
        .reference_column = try allocator.dupe(u8, foreign_key.reference_column),
        .reference_columns = reference_columns,
        .on_delete = foreign_key.on_delete,
        .on_update = foreign_key.on_update,
        .deferred = foreign_key.deferred,
    };
}

fn cloneAstValue(allocator: std.mem.Allocator, value: ast.Value) CloneValueError!ast.Value {
    return switch (value) {
        .Integer => |v| ast.Value{ .Integer = v },
        .Text => |v| ast.Value{ .Text = try allocator.dupe(u8, v) },
        .Real => |v| ast.Value{ .Real = v },
        .Blob => |v| ast.Value{ .Blob = try allocator.dupe(u8, v) },
        .Null => ast.Value.Null,
        .Parameter => |v| ast.Value{ .Parameter = v },
        .FunctionCall, .Case => error.SyntaxError,
    };
}

fn cloneAstExpression(allocator: std.mem.Allocator, expr: ast.Expression) CloneValueError!ast.Expression {
    return switch (expr) {
        .Column => |column| ast.Expression{ .Column = try allocator.dupe(u8, column) },
        .Literal => |value| ast.Expression{ .Literal = try cloneAstValue(allocator, value) },
        .Parameter => |param| ast.Expression{ .Parameter = param },
        .BinaryOp => |bin| blk: {
            const left = try allocator.create(ast.Expression);
            errdefer allocator.destroy(left);
            left.* = try cloneAstExpression(allocator, bin.left.*);
            errdefer left.deinit(allocator);

            const right = try allocator.create(ast.Expression);
            errdefer allocator.destroy(right);
            right.* = try cloneAstExpression(allocator, bin.right.*);
            errdefer right.deinit(allocator);

            break :blk ast.Expression{ .BinaryOp = .{
                .left = left,
                .op = bin.op,
                .right = right,
            } };
        },
        .InList => |list| blk: {
            var cloned = try allocator.alloc(ast.Value, list.len);
            var cloned_count: usize = 0;
            errdefer {
                for (cloned[0..cloned_count]) |*value| value.deinit(allocator);
                allocator.free(cloned);
            }
            for (list, 0..) |value, i| {
                cloned[i] = try cloneAstValue(allocator, value);
                cloned_count = i + 1;
            }
            break :blk ast.Expression{ .InList = cloned };
        },
        .Subquery => error.SyntaxError,
    };
}

fn cloneAstCondition(allocator: std.mem.Allocator, condition: *const ast.Condition) CloneValueError!ast.Condition {
    return switch (condition.*) {
        .Comparison => |comp| ast.Condition{ .Comparison = .{
            .left = try cloneAstExpression(allocator, comp.left),
            .operator = comp.operator,
            .right = try cloneAstExpression(allocator, comp.right),
            .extra = if (comp.extra) |extra| try cloneAstExpression(allocator, extra) else null,
        } },
        .Logical => |logical| blk: {
            const left = try allocator.create(ast.Condition);
            errdefer allocator.destroy(left);
            left.* = try cloneAstCondition(allocator, logical.left);
            errdefer left.deinit(allocator);

            const right = try allocator.create(ast.Condition);
            errdefer allocator.destroy(right);
            right.* = try cloneAstCondition(allocator, logical.right);
            errdefer right.deinit(allocator);

            break :blk ast.Condition{ .Logical = .{
                .left = left,
                .operator = logical.operator,
                .right = right,
            } };
        },
    };
}

/// Column definition
pub const Column = struct {
    name: []const u8,
    data_type: DataType,
    is_primary_key: bool,
    is_nullable: bool,
    default_value: ?DefaultValue,
    generated: ?GeneratedColumn = null,
    /// Set when the column carries an inline UNIQUE constraint. Enforcement is
    /// implemented by auto-creating a unique index at table creation, so this
    /// flag only needs to survive planning; it is not part of the catalog format.
    is_unique: bool = false,

    pub const GeneratedColumn = struct {
        expression: ast.Expression,
        stored: bool,

        pub fn deinit(self: GeneratedColumn, allocator: std.mem.Allocator) void {
            var expression = self.expression;
            expression.deinit(allocator);
        }

        pub fn clone(self: GeneratedColumn, allocator: std.mem.Allocator) CloneValueError!GeneratedColumn {
            return GeneratedColumn{
                .expression = try cloneAstExpression(allocator, self.expression),
                .stored = self.stored,
            };
        }
    };

    pub const DefaultValue = union(enum) {
        Literal: Value,
        FunctionCall: FunctionCall,

        pub fn deinit(self: DefaultValue, allocator: std.mem.Allocator) void {
            switch (self) {
                .Literal => |value| value.deinit(allocator),
                .FunctionCall => |func| func.deinit(allocator),
            }
        }

        pub fn clone(self: DefaultValue, allocator: std.mem.Allocator) CloneValueError!DefaultValue {
            return switch (self) {
                .Literal => |value| DefaultValue{ .Literal = try value.clone(allocator) },
                .FunctionCall => |func| DefaultValue{ .FunctionCall = try func.clone(allocator) },
            };
        }
    };

    pub const FunctionCall = struct {
        name: []const u8,
        arguments: []FunctionArgument,

        pub fn deinit(self: FunctionCall, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            for (self.arguments) |arg| {
                arg.deinit(allocator);
            }
            allocator.free(self.arguments);
        }

        pub fn clone(self: FunctionCall, allocator: std.mem.Allocator) CloneValueError!FunctionCall {
            const cloned_name = try allocator.dupe(u8, self.name);
            var cloned_args = try allocator.alloc(FunctionArgument, self.arguments.len);

            for (self.arguments, 0..) |arg, i| {
                cloned_args[i] = try arg.clone(allocator);
            }

            return FunctionCall{
                .name = cloned_name,
                .arguments = cloned_args,
            };
        }
    };

    pub const FunctionArgument = union(enum) {
        Literal: Value,
        Column: []const u8,
        Parameter: u32,

        pub fn deinit(self: FunctionArgument, allocator: std.mem.Allocator) void {
            switch (self) {
                .Literal => |value| value.deinit(allocator),
                .Column => |col| allocator.free(col),
                .Parameter => {},
            }
        }

        pub fn clone(self: FunctionArgument, allocator: std.mem.Allocator) CloneValueError!FunctionArgument {
            return switch (self) {
                .Literal => |value| FunctionArgument{ .Literal = try value.clone(allocator) },
                .Column => |col| FunctionArgument{ .Column = try allocator.dupe(u8, col) },
                .Parameter => |param| FunctionArgument{ .Parameter = param },
            };
        }
    };
};

/// Supported data types
pub const DataType = enum {
    Integer,
    Text,
    Real,
    Blob,
    // PostgreSQL compatibility types
    JSON,
    JSONB,
    UUID,
    Array,
    Boolean,
    Timestamp,
    TimestampTZ,
    Date,
    Time,
    Interval,
    Numeric,
    // Extended integer types
    SmallInt,
    BigInt,
    // Extended text types
    Varchar,
    Char,
};

/// Row data
pub const Row = struct {
    values: []Value,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        for (self.values) |value| {
            value.deinit(allocator);
        }
        allocator.free(self.values);
    }
};

/// Value types
pub const Value = union(enum) {
    Integer: i64,
    Text: []const u8,
    Real: f64,
    Blob: []const u8,
    Null,
    Parameter: u32, // Parameter placeholder index
    FunctionCall: Column.FunctionCall, // Function call for evaluation (e.g., in INSERT VALUES)
    // PostgreSQL compatibility values
    JSON: []const u8, // JSON as text
    JSONB: JSONBValue, // Parsed JSON with binary optimization
    UUID: [16]u8, // UUID as 16 bytes
    Array: ArrayValue, // Array of values
    Boolean: bool,
    Timestamp: i64, // Unix timestamp in microseconds
    TimestampTZ: TimestampTZValue, // Timestamp with timezone
    Date: i32, // Days since epoch
    Time: i64, // Microseconds since midnight
    Interval: i64, // Duration in microseconds
    Numeric: NumericValue, // Arbitrary precision decimal
    SmallInt: i16,
    BigInt: i64,

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .Text => |text| allocator.free(text),
            .Blob => |blob| allocator.free(blob),
            .FunctionCall => |func| func.deinit(allocator),
            .JSON => |json| allocator.free(json),
            .JSONB => |jsonb| jsonb.deinit(allocator),
            .Array => |array| array.deinit(allocator),
            .TimestampTZ => |tstz| tstz.deinit(allocator),
            .Numeric => |numeric| numeric.deinit(allocator),
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) CloneValueError!Value {
        return switch (self) {
            .Integer => |i| Value{ .Integer = i },
            .Real => |r| Value{ .Real = r },
            .Null => Value.Null,
            .Parameter => |p| Value{ .Parameter = p },
            .Boolean => |b| Value{ .Boolean = b },
            .Timestamp => |t| Value{ .Timestamp = t },
            .Date => |d| Value{ .Date = d },
            .Time => |t| Value{ .Time = t },
            .Interval => |i| Value{ .Interval = i },
            .SmallInt => |s| Value{ .SmallInt = s },
            .BigInt => |b| Value{ .BigInt = b },
            .UUID => |u| Value{ .UUID = u },
            .Text => |text| Value{ .Text = try allocator.dupe(u8, text) },
            .Blob => |blob| Value{ .Blob = try allocator.dupe(u8, blob) },
            .JSON => |json| Value{ .JSON = try allocator.dupe(u8, json) },
            .FunctionCall => |func| Value{ .FunctionCall = try func.clone(allocator) },
            // For complex types, create proper deep copies
            .JSONB => |jsonb| blk: {
                const json_str = try jsonb.toString(allocator);
                defer allocator.free(json_str);
                break :blk Value{ .JSONB = try JSONBValue.init(allocator, json_str) };
            },
            .Array => |array| Value{ .Array = try array.clone(allocator) },
            .TimestampTZ => |tstz| Value{ .TimestampTZ = TimestampTZValue{
                .timestamp = tstz.timestamp,
                .timezone = try allocator.dupe(u8, tstz.timezone),
            } },
            .Numeric => |numeric| Value{ .Numeric = NumericValue{
                .precision = numeric.precision,
                .scale = numeric.scale,
                .digits = try allocator.dupe(u8, numeric.digits),
                .is_negative = numeric.is_negative,
            } },
        };
    }
};

/// JSONB value with parsed structure
pub const JSONBValue = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn init(allocator: std.mem.Allocator, json_text: []const u8) !JSONBValue {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        return JSONBValue{ .parsed = parsed };
    }

    pub fn deinit(self: JSONBValue, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.parsed.deinit();
    }

    pub fn toString(self: JSONBValue, allocator: std.mem.Allocator) ![]u8 {
        return try self.stringifyJson(allocator);
    }

    /// Convert parsed JSON back to string representation
    pub fn stringifyJson(self: JSONBValue, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.parsed.value) {
            .null => try allocator.dupe(u8, "null"),
            .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
            .integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
            .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .number_string => |s| try allocator.dupe(u8, s),
            .string => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
            .array => |arr| blk: {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                defer result.deinit(allocator);

                try result.append(allocator, '[');
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try result.appendSlice(allocator, ", ");
                    const item_json = JSONBValue{ .parsed = std.json.Parsed(std.json.Value){ .value = item, .arena = undefined } };
                    const item_str = try item_json.stringifyJson(allocator);
                    defer allocator.free(item_str);
                    try result.appendSlice(allocator, item_str);
                }
                try result.append(allocator, ']');
                break :blk try result.toOwnedSlice(allocator);
            },
            .object => |obj| blk: {
                var result: std.ArrayListUnmanaged(u8) = .empty;
                defer result.deinit(allocator);

                try result.append(allocator, '{');
                var first = true;
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    if (!first) try result.appendSlice(allocator, ", ");
                    first = false;
                    try result.appendSlice(allocator, "\"");
                    try result.appendSlice(allocator, entry.key_ptr.*);
                    try result.appendSlice(allocator, "\": ");

                    const value_json = JSONBValue{ .parsed = std.json.Parsed(std.json.Value){ .value = entry.value_ptr.*, .arena = undefined } };
                    const value_str = try value_json.stringifyJson(allocator);
                    defer allocator.free(value_str);
                    try result.appendSlice(allocator, value_str);
                }
                try result.append(allocator, '}');
                break :blk try result.toOwnedSlice(allocator);
            },
        };
    }

    /// Extract a value from JSON using a path (PostgreSQL -> operator)
    pub fn extractPath(self: JSONBValue, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
        const value = self.extractValue(path) orelse return null;
        const json_value = JSONBValue{ .parsed = std.json.Parsed(std.json.Value){ .value = value, .arena = undefined } };
        return try json_value.stringifyJson(allocator);
    }

    /// Extract a text value from JSON (PostgreSQL ->> operator)
    pub fn extractText(self: JSONBValue, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
        const value = self.extractValue(path) orelse return null;
        return switch (value) {
            .string => |s| try allocator.dupe(u8, s),
            .integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
            .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .number_string => |s| try allocator.dupe(u8, s),
            .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
            .null => try allocator.dupe(u8, "null"),
            else => {
                const json_value = JSONBValue{ .parsed = std.json.Parsed(std.json.Value){ .value = value, .arena = undefined } };
                return try json_value.stringifyJson(allocator);
            },
        };
    }

    /// Check if JSON contains a key (PostgreSQL ? operator)
    pub fn hasKey(self: JSONBValue, key: []const u8) bool {
        return switch (self.parsed.value) {
            .object => |obj| obj.contains(key),
            else => false,
        };
    }

    /// Extract raw JSON value for path operations
    fn extractValue(self: JSONBValue, path: []const u8) ?std.json.Value {
        return switch (self.parsed.value) {
            .object => |obj| obj.get(path),
            .array => |arr| blk: {
                const index = std.fmt.parseInt(usize, path, 10) catch return null;
                if (index >= arr.items.len) return null;
                break :blk arr.items[index];
            },
            else => null,
        };
    }
};

/// Array value containing typed elements
pub const ArrayValue = struct {
    element_type: DataType,
    elements: []Value,

    pub fn deinit(self: ArrayValue, allocator: std.mem.Allocator) void {
        for (self.elements) |element| {
            element.deinit(allocator);
        }
        allocator.free(self.elements);
    }

    /// Create array from values
    pub fn init(allocator: std.mem.Allocator, element_type: DataType, values: []const Value) CloneValueError!ArrayValue {
        var elements = try allocator.alloc(Value, values.len);

        // Clone each value
        for (values, 0..) |value, i| {
            elements[i] = try cloneValue(allocator, value);
        }

        return ArrayValue{
            .element_type = element_type,
            .elements = elements,
        };
    }

    /// Get array length
    pub fn len(self: ArrayValue) usize {
        return self.elements.len;
    }

    /// Get element at index (1-based like PostgreSQL)
    pub fn get(self: ArrayValue, index: usize) ?Value {
        if (index == 0 or index > self.elements.len) return null;
        return self.elements[index - 1];
    }

    /// Convert array to PostgreSQL format string: {elem1,elem2,elem3}
    pub fn toString(self: ArrayValue, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        defer result.deinit(allocator);

        try result.append(allocator, '{');

        for (self.elements, 0..) |element, i| {
            if (i > 0) try result.appendSlice(allocator, ",");

            const elem_str = try valueToString(allocator, element);
            defer allocator.free(elem_str);
            try result.appendSlice(allocator, elem_str);
        }

        try result.append(allocator, '}');
        return try result.toOwnedSlice(allocator);
    }

    /// Check if array contains value (PostgreSQL @> operator)
    pub fn contains(self: ArrayValue, value: Value) bool {
        for (self.elements) |element| {
            if (valuesEqual(element, value)) return true;
        }
        return false;
    }

    /// Array overlap (PostgreSQL && operator)
    pub fn overlaps(self: ArrayValue, other: ArrayValue) bool {
        for (self.elements) |element| {
            if (other.contains(element)) return true;
        }
        return false;
    }

    /// Clone the array
    pub fn clone(self: ArrayValue, allocator: std.mem.Allocator) CloneValueError!ArrayValue {
        return try ArrayValue.init(allocator, self.element_type, self.elements);
    }
};

/// Helper function to clone a value
const CloneValueError = error{
    OutOfMemory,
    Overflow,
    InvalidCharacter,
    UnexpectedToken,
    InvalidNumber,
    InvalidEnumTag,
    DuplicateField,
    UnknownField,
    MissingField,
    LengthMismatch,
    SyntaxError,
    UnexpectedEndOfInput,
    BufferUnderrun,
    ValueTooLong,
};

fn cloneValue(allocator: std.mem.Allocator, value: Value) CloneValueError!Value {
    return switch (value) {
        .Integer => |i| Value{ .Integer = i },
        .Real => |r| Value{ .Real = r },
        .Text => |t| Value{ .Text = try allocator.dupe(u8, t) },
        .Blob => |b| Value{ .Blob = try allocator.dupe(u8, b) },
        .Null => Value.Null,
        .JSON => |j| Value{ .JSON = try allocator.dupe(u8, j) },
        .JSONB => |jsonb| Value{ .JSONB = try JSONBValue.init(allocator, try jsonb.toString(allocator)) },
        .UUID => |uuid| Value{ .UUID = uuid },
        .Array => |array| Value{ .Array = try ArrayValue.init(allocator, array.element_type, array.elements) },
        .Boolean => |b| Value{ .Boolean = b },
        .SmallInt => |s| Value{ .SmallInt = s },
        .BigInt => |b| Value{ .BigInt = b },
        else => value, // For simple types that don't need cloning
    };
}

/// Helper function to convert value to string
fn valueToString(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return switch (value) {
        .Integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
        .Real => |r| try std.fmt.allocPrint(allocator, "{d}", .{r}),
        .Text => |t| try std.fmt.allocPrint(allocator, "\"{s}\"", .{t}),
        .Boolean => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .Null => try allocator.dupe(u8, "NULL"),
        else => try allocator.dupe(u8, "?"), // Placeholder for complex types
    };
}

/// Helper function to compare values
fn valuesEqual(a: Value, b: Value) bool {
    return switch (a) {
        .Integer => |ai| switch (b) {
            .Integer => |bi| ai == bi,
            else => false,
        },
        .Real => |ar| switch (b) {
            .Real => |br| ar == br,
            else => false,
        },
        .Text => |at| switch (b) {
            .Text => |bt| std.mem.eql(u8, at, bt),
            else => false,
        },
        .Boolean => |ab| switch (b) {
            .Boolean => |bb| ab == bb,
            else => false,
        },
        .Null => switch (b) {
            .Null => true,
            else => false,
        },
        else => false, // Complex comparison would need more implementation
    };
}

/// Timestamp with timezone
pub const TimestampTZValue = struct {
    timestamp: i64, // Unix timestamp in microseconds
    timezone: []const u8, // Timezone name (e.g., "UTC", "America/New_York")

    pub fn deinit(self: TimestampTZValue, allocator: std.mem.Allocator) void {
        allocator.free(self.timezone);
    }
};

/// Arbitrary precision numeric value
pub const NumericValue = struct {
    precision: u16, // Total digits
    scale: u16, // Digits after decimal point
    digits: []u8, // BCD encoded digits
    is_negative: bool,

    pub fn deinit(self: NumericValue, allocator: std.mem.Allocator) void {
        allocator.free(self.digits);
    }
};

/// Storage statistics
pub const StorageStats = struct {
    table_count: u32,
    index_count: u32,
    is_memory: bool,
    page_count: u32,
    cache_hit_ratio: f64,
    cached_pages: u32,
};

pub const IntegrityCheckResult = struct {
    ok: bool = true,
    table_count: usize = 0,
    index_count: usize = 0,
    live_rows: usize = 0,
    deleted_rows: usize = 0,
    index_entries: usize = 0,
    issue_count: usize = 0,
    first_issue: ?[]const u8 = null,

    pub fn deinit(self: *IntegrityCheckResult, allocator: std.mem.Allocator) void {
        if (self.first_issue) |issue| allocator.free(issue);
        self.first_issue = null;
    }

    fn addIssue(self: *IntegrityCheckResult, allocator: std.mem.Allocator, message: []const u8) !void {
        self.ok = false;
        self.issue_count += 1;
        if (self.first_issue == null) {
            self.first_issue = try allocator.dupe(u8, message);
        }
    }
};

/// Index definition
pub const Index = struct {
    name: []const u8,
    table_name: []const u8,
    column_names: [][]const u8,
    expressions: []ast.Expression,
    where_clause: ?ast.Condition,
    btree: *btree.BTree,
    is_unique: bool,
    owned_pager: ?*pager.Pager = null,

    const Self = @This();

    /// Create a new index
    pub fn create(allocator: std.mem.Allocator, page_manager: *pager.Pager, name: []const u8, table_name: []const u8, column_names: [][]const u8, is_unique: bool) !*Self {
        return createEx(allocator, page_manager, name, table_name, column_names, &.{}, null, is_unique);
    }

    pub fn createEx(
        allocator: std.mem.Allocator,
        page_manager: *pager.Pager,
        name: []const u8,
        table_name: []const u8,
        column_names: [][]const u8,
        expressions: []const ast.Expression,
        where_clause: ?ast.Condition,
        is_unique: bool,
    ) !*Self {
        var index = try allocator.create(Self);
        errdefer allocator.destroy(index);
        index.owned_pager = null;
        index.name = try allocator.dupe(u8, name);
        errdefer allocator.free(index.name);
        index.table_name = try allocator.dupe(u8, table_name);
        errdefer allocator.free(index.table_name);

        // Clone column names
        index.column_names = try allocator.alloc([]const u8, column_names.len);
        var columns_initialized: usize = 0;
        errdefer {
            for (index.column_names[0..columns_initialized]) |column| allocator.free(column);
            allocator.free(index.column_names);
        }
        for (column_names, 0..) |col_name, i| {
            index.column_names[i] = try allocator.dupe(u8, col_name);
            columns_initialized += 1;
        }

        index.expressions = try allocator.alloc(ast.Expression, expressions.len);
        var expressions_initialized: usize = 0;
        errdefer {
            for (index.expressions[0..expressions_initialized]) |*expression| expression.deinit(allocator);
            allocator.free(index.expressions);
        }
        for (expressions, 0..) |expression, i| {
            index.expressions[i] = try cloneAstExpression(allocator, expression);
            expressions_initialized += 1;
        }

        index.where_clause = if (where_clause) |condition| try cloneAstCondition(allocator, &condition) else null;
        errdefer if (index.where_clause) |*condition| condition.deinit(allocator);
        index.btree = try btree.BTree.init(allocator, page_manager);
        index.is_unique = is_unique;

        return index;
    }

    pub fn keyPartCount(self: *const Self) usize {
        return if (self.expressions.len > 0) self.expressions.len else self.column_names.len;
    }

    /// Insert a key into the index
    pub fn insert(self: *Self, key: u64, row_id: u64) !void {
        if (self.is_unique) {
            // Check if key already exists
            if (try self.btree.search(key)) |existing| {
                var owned = existing;
                owned.deinit(self.btree.allocator);
                return error.UniqueConstraintViolation;
            }
        }

        try self.insertEntry(key, row_id);
    }

    fn insertEntry(self: *Self, key: u64, row_id: u64) !void {
        // Create a row with just the row ID
        var index_row = Row{
            .values = try self.btree.allocator.alloc(Value, 1),
        };
        index_row.values[0] = Value{ .Integer = @intCast(row_id) };
        errdefer index_row.deinit(self.btree.allocator);

        try self.btree.insert(key, index_row);
    }

    /// Search for a key in the index
    pub fn search(self: *Self, key: u64) !?u64 {
        if (try self.btree.search(key)) |row| {
            defer {
                for (row.values) |value| {
                    value.deinit(self.btree.allocator);
                }
                self.btree.allocator.free(row.values);
            }
            if (row.values.len > 0) {
                switch (row.values[0]) {
                    .Integer => |row_id| return @intCast(row_id),
                    else => return null,
                }
            }
        }
        return null;
    }

    /// Clean up index
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.table_name);
        for (self.column_names) |col_name| {
            allocator.free(col_name);
        }
        allocator.free(self.column_names);
        for (self.expressions) |*expression| {
            expression.deinit(allocator);
        }
        allocator.free(self.expressions);
        if (self.where_clause) |*condition| {
            condition.deinit(allocator);
        }
        self.btree.deinit();
        if (self.owned_pager) |owned| owned.deinit();
        allocator.destroy(self);
    }
};

/// Full-Text Search Index for virtual tables (FTS5)
pub const FTSIndex = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    column_names: [][]const u8,
    /// Inverted index: term -> list of (rowid, column_index, position)
    inverted_index: std.StringHashMap(std.ArrayListUnmanaged(TermOccurrence)),

    const Self = @This();

    /// Term occurrence in a document
    const TermOccurrence = struct {
        rowid: u64,
        column_index: u32,
        position: u32,
    };

    /// Create a new FTS index
    pub fn create(allocator: std.mem.Allocator, table_name: []const u8, columns: []const []const u8) !*Self {
        var fts = try allocator.create(Self);
        errdefer allocator.destroy(fts);

        fts.allocator = allocator;
        fts.table_name = try allocator.dupe(u8, table_name);
        errdefer allocator.free(fts.table_name);

        // Copy column names
        fts.column_names = try allocator.alloc([]const u8, columns.len);
        errdefer allocator.free(fts.column_names);

        var cols_allocated: usize = 0;
        errdefer {
            for (fts.column_names[0..cols_allocated]) |col| {
                allocator.free(col);
            }
        }

        for (columns, 0..) |col, i| {
            fts.column_names[i] = try allocator.dupe(u8, col);
            cols_allocated = i + 1;
        }

        fts.inverted_index = std.StringHashMap(std.ArrayListUnmanaged(TermOccurrence)).init(allocator);

        return fts;
    }

    /// Index a document (row)
    pub fn indexDocument(self: *Self, rowid: u64, values: []const Value) !void {
        for (values, 0..) |value, col_idx| {
            if (col_idx >= self.column_names.len) continue;

            // Only index text values
            const text = switch (value) {
                .Text => |t| t,
                else => continue,
            };

            // Tokenize and index
            var pos: u32 = 0;
            var iter = std.mem.tokenizeAny(u8, text, " \t\n\r.,;:!?()[]{}\"'");
            while (iter.next()) |token| {
                // Normalize to lowercase
                var lower_buf: [256]u8 = undefined;
                const lower_token = if (token.len <= 256) blk: {
                    for (token, 0..) |c, i| {
                        lower_buf[i] = std.ascii.toLower(c);
                    }
                    break :blk lower_buf[0..token.len];
                } else token;

                // Get or create term entry
                var entry = self.inverted_index.getPtr(lower_token);
                if (entry == null) {
                    const term_copy = try self.allocator.dupe(u8, lower_token);
                    const new_list: std.ArrayListUnmanaged(TermOccurrence) = .empty;
                    try self.inverted_index.put(term_copy, new_list);
                    entry = self.inverted_index.getPtr(term_copy);
                }

                try entry.?.append(self.allocator, TermOccurrence{
                    .rowid = rowid,
                    .column_index = @intCast(col_idx),
                    .position = pos,
                });

                pos += 1;
            }
        }
    }

    /// Search the FTS index for a query
    pub fn search(self: *Self, query: []const u8) ![]u64 {
        var results = std.AutoHashMap(u64, void).init(self.allocator);
        defer results.deinit();

        // Tokenize query
        var first_term = true;
        var iter = std.mem.tokenizeAny(u8, query, " \t\n\r.,;:!?()[]{}\"'");
        while (iter.next()) |token| {
            // Normalize to lowercase
            var lower_buf: [256]u8 = undefined;
            const lower_token = if (token.len <= 256) blk: {
                for (token, 0..) |c, i| {
                    lower_buf[i] = std.ascii.toLower(c);
                }
                break :blk lower_buf[0..token.len];
            } else token;

            if (self.inverted_index.get(lower_token)) |occurrences| {
                if (first_term) {
                    // First term: add all matching rowids
                    for (occurrences.items) |occ| {
                        try results.put(occ.rowid, {});
                    }
                    first_term = false;
                } else {
                    // Subsequent terms: intersect with existing results
                    var term_rowids = std.AutoHashMap(u64, void).init(self.allocator);
                    defer term_rowids.deinit();

                    for (occurrences.items) |occ| {
                        try term_rowids.put(occ.rowid, {});
                    }

                    // Remove rowids not in this term's results
                    var to_remove: std.ArrayListUnmanaged(u64) = .empty;
                    defer to_remove.deinit(self.allocator);

                    var result_iter = results.iterator();
                    while (result_iter.next()) |entry| {
                        if (!term_rowids.contains(entry.key_ptr.*)) {
                            try to_remove.append(self.allocator, entry.key_ptr.*);
                        }
                    }

                    for (to_remove.items) |rowid| {
                        _ = results.remove(rowid);
                    }
                }
            } else if (!first_term) {
                // Term not found in subsequent terms: empty results
                results.clearRetainingCapacity();
            }
        }

        // Convert to array
        var result_array = try self.allocator.alloc(u64, results.count());
        var i: usize = 0;
        var result_iter = results.iterator();
        while (result_iter.next()) |entry| {
            result_array[i] = entry.key_ptr.*;
            i += 1;
        }

        return result_array;
    }

    /// Clean up FTS index
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.table_name);
        for (self.column_names) |col| {
            allocator.free(col);
        }
        allocator.free(self.column_names);

        // Free inverted index
        var iter = self.inverted_index.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.inverted_index.deinit();

        allocator.destroy(self);
    }
};

test "storage engine creation" {
    try std.testing.expect(true); // Placeholder
}

test "table operations" {
    try std.testing.expect(true); // Placeholder
}
