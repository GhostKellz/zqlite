const std = @import("std");
const zqlite = @import("../zqlite.zig");
const version = @import("../version.zig");
const storage = @import("../db/storage.zig");

/// Interactive CLI shell for zqlite
pub const Shell = struct {
    allocator: std.mem.Allocator,
    connection: ?*zqlite.Connection,
    running: bool,
    database_path: ?[]const u8,

    const Self = @This();

    /// Initialize shell
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .connection = null,
            .running = true,
            .database_path = null,
        };
    }

    /// Start the interactive shell
    pub fn run(self: *Self) !void {
        // Write banner
        try writeAll(version.FULL_VERSION_WITH_BUILD);
        try writeAll(" - Interactive Shell\n");
        try writeAll("High-performance embedded database with post-quantum crypto\n");
        try writeAll("Type .help for usage hints, .open <file> to open a database\n\n");

        // Create in-memory connection by default
        self.connection = try zqlite.openMemory(self.allocator);
        try writeAll("Connected to :memory:\n");

        var line_buffer: [4096]u8 = undefined;
        var statement_buffer: [16384]u8 = undefined;
        var statement_len: usize = 0;
        var in_multiline = false;

        while (self.running) {
            // Show appropriate prompt
            if (in_multiline) {
                try writeAll("   ...> ");
            } else {
                try writeAll("zqlite> ");
            }

            const line = readLine(&line_buffer) catch |err| switch (err) {
                error.EndOfStream => {
                    try writeAll("\n");
                    break;
                },
                else => return err,
            };

            if (line.len == 0) {
                if (in_multiline) {
                    // Empty line in multiline mode - execute what we have
                    if (statement_len > 0) {
                        self.processCommand(statement_buffer[0..statement_len]) catch |err| {
                            try writeAll("Error: ");
                            try writeAll(@errorName(err));
                            try writeAll("\n");
                        };
                        statement_len = 0;
                        in_multiline = false;
                    }
                }
                continue;
            }

            // Dot commands are always single-line
            if (!in_multiline and std.mem.startsWith(u8, line, ".")) {
                self.processCommand(line) catch |err| {
                    try writeAll("Error: ");
                    try writeAll(@errorName(err));
                    try writeAll("\n");
                };
                continue;
            }

            // Append to statement buffer
            if (statement_len + line.len + 1 < statement_buffer.len) {
                if (statement_len > 0) {
                    statement_buffer[statement_len] = ' ';
                    statement_len += 1;
                }
                @memcpy(statement_buffer[statement_len..][0..line.len], line);
                statement_len += line.len;
            }

            // Check if statement is complete (ends with semicolon)
            const trimmed = std.mem.trimEnd(u8, statement_buffer[0..statement_len], " \t");
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ';') {
                // Statement complete - execute it
                self.processCommand(statement_buffer[0..statement_len]) catch |err| {
                    try writeAll("Error: ");
                    try writeAll(@errorName(err));
                    try writeAll("\n");
                };
                statement_len = 0;
                in_multiline = false;
            } else {
                // Statement incomplete - continue reading
                in_multiline = true;
            }
        }
    }

    /// Process shell command
    fn processCommand(self: *Self, command: []const u8) !void {
        if (std.mem.startsWith(u8, command, ".")) {
            try self.processDotCommand(command);
        } else {
            try self.executeSQL(command);
        }
    }

    /// Process dot commands (.help, .quit, etc.)
    fn processDotCommand(self: *Self, command: []const u8) !void {
        if (std.mem.eql(u8, command, ".quit") or std.mem.eql(u8, command, ".exit")) {
            self.running = false;
            try writeAll("Goodbye!\n");
        } else if (std.mem.eql(u8, command, ".help")) {
            try self.printHelp();
        } else if (std.mem.eql(u8, command, ".version")) {
            try writeAll("ZQLite ");
            try writeAll(version.VERSION_STRING);
            try writeAll("\n");
        } else if (std.mem.startsWith(u8, command, ".open ")) {
            const path = std.mem.trim(u8, command[6..], " \t");
            try self.openDatabase(path);
        } else if (std.mem.eql(u8, command, ".tables")) {
            try self.listTables();
        } else if (std.mem.startsWith(u8, command, ".schema")) {
            const table_name = std.mem.trim(u8, command[7..], " \t");
            try self.showSchema(if (table_name.len > 0) table_name else null);
        } else if (std.mem.eql(u8, command, ".databases")) {
            try self.showDatabases();
        } else {
            try writeAll("Unknown command: ");
            try writeAll(command);
            try writeAll("\n");
            try self.printHelp();
        }
    }

    /// Open a database file
    fn openDatabase(self: *Self, path: []const u8) !void {
        // Close existing connection
        if (self.connection) |conn| {
            conn.close();
        }

        if (std.mem.eql(u8, path, ":memory:")) {
            self.connection = try zqlite.openMemory(self.allocator);
            self.database_path = null;
            try writeAll("Connected to :memory:\n");
        } else {
            self.connection = try zqlite.open(self.allocator, path);
            self.database_path = path;
            try writeAll("Connected to ");
            try writeAll(path);
            try writeAll("\n");
        }
    }

    /// List all tables
    fn listTables(self: *Self) !void {
        const conn = self.connection orelse {
            try writeAll("No database connected\n");
            return;
        };

        const table_names = try conn.getTableNames();
        defer {
            for (table_names) |name| {
                self.allocator.free(name);
            }
            self.allocator.free(table_names);
        }

        if (table_names.len == 0) {
            try writeAll("(no tables)\n");
        } else {
            for (table_names) |name| {
                try writeAll(name);
                try writeAll("\n");
            }
        }
    }

    /// Show schema for a table or all tables
    fn showSchema(self: *Self, table_name: ?[]const u8) !void {
        const conn = self.connection orelse {
            try writeAll("No database connected\n");
            return;
        };

        if (table_name) |name| {
            var schema = conn.getTableSchema(name) catch {
                try writeAll("Error getting schema\n");
                return;
            } orelse {
                try writeAll("Table not found: ");
                try writeAll(name);
                try writeAll("\n");
                return;
            };
            defer schema.deinit();

            try writeAll("CREATE TABLE ");
            try writeAll(name);
            try writeAll(" (\n");
            for (schema.columns, 0..) |col, i| {
                try writeAll("  ");
                try writeAll(col.name);
                try writeAll(" ");
                try writeAll(@tagName(col.data_type));
                if (col.is_primary_key) try writeAll(" PRIMARY KEY");
                if (!col.is_nullable) try writeAll(" NOT NULL");
                if (i < schema.columns.len - 1) try writeAll(",");
                try writeAll("\n");
            }
            try writeAll(");\n");
        } else {
            // Show all tables
            const table_names = try conn.getTableNames();
            defer {
                for (table_names) |t_name| {
                    self.allocator.free(t_name);
                }
                self.allocator.free(table_names);
            }

            for (table_names) |t_name| {
                try self.showSchema(t_name);
                try writeAll("\n");
            }
        }
    }

    /// Show connected databases
    fn showDatabases(self: *Self) !void {
        const conn = self.connection orelse {
            try writeAll("No database connected\n");
            return;
        };

        const info = conn.info();
        if (info.is_memory) {
            try writeAll("main: :memory:\n");
        } else if (info.path) |path| {
            try writeAll("main: ");
            try writeAll(path);
            try writeAll("\n");
        }
    }

    /// Execute SQL command
    fn executeSQL(self: *Self, sql: []const u8) !void {
        const conn = self.connection orelse {
            try writeAll("No database connected\n");
            return;
        };

        // Determine if this is a query (SELECT) or a statement
        const upper_sql = blk: {
            var buf: [64]u8 = undefined;
            const len = @min(sql.len, buf.len);
            for (sql[0..len], 0..) |c, i| {
                buf[i] = std.ascii.toUpper(c);
            }
            break :blk buf[0..len];
        };

        const trimmed_upper = std.mem.trimStart(u8, upper_sql, " \t");

        if (std.mem.startsWith(u8, trimmed_upper, "SELECT") or
            std.mem.startsWith(u8, trimmed_upper, "PRAGMA"))
        {
            // Execute as query and display results
            var result_set = conn.query(sql) catch |err| {
                try writeAll("Error: ");
                try writeAll(@errorName(err));
                try writeAll("\n");
                return;
            };
            defer result_set.deinit();

            // Print column headers
            if (result_set.column_names.len > 0) {
                for (result_set.column_names, 0..) |name, i| {
                    if (i > 0) try writeAll("|");
                    try writeAll(name);
                }
                try writeAll("\n");

                // Print separator
                for (result_set.column_names, 0..) |name, i| {
                    if (i > 0) try writeAll("+");
                    for (0..name.len) |_| {
                        try writeAll("-");
                    }
                }
                try writeAll("\n");
            }

            // Print rows
            var row_count: usize = 0;
            while (result_set.next()) |row_data| {
                var row = row_data;
                defer row.deinit();

                for (row.values, 0..) |value, i| {
                    if (i > 0) try writeAll("|");
                    try printValue(value);
                }
                try writeAll("\n");
                row_count += 1;
            }

            try writeAll("(");
            try writeInt(row_count);
            try writeAll(" row");
            if (row_count != 1) try writeAll("s");
            try writeAll(")\n");
        } else {
            // Execute as statement
            const affected = conn.exec(sql) catch |err| {
                try writeAll("Error: ");
                try writeAll(@errorName(err));
                try writeAll("\n");
                return;
            };

            if (std.mem.startsWith(u8, trimmed_upper, "INSERT")) {
                try writeAll("Inserted ");
                try writeInt(affected);
                try writeAll(" row");
                if (affected != 1) try writeAll("s");
                try writeAll("\n");
            } else if (std.mem.startsWith(u8, trimmed_upper, "UPDATE")) {
                try writeAll("Updated ");
                try writeInt(affected);
                try writeAll(" row");
                if (affected != 1) try writeAll("s");
                try writeAll("\n");
            } else if (std.mem.startsWith(u8, trimmed_upper, "DELETE")) {
                try writeAll("Deleted ");
                try writeInt(affected);
                try writeAll(" row");
                if (affected != 1) try writeAll("s");
                try writeAll("\n");
            } else if (std.mem.startsWith(u8, trimmed_upper, "CREATE")) {
                try writeAll("OK\n");
            } else if (std.mem.startsWith(u8, trimmed_upper, "DROP")) {
                try writeAll("OK\n");
            } else {
                try writeAll("OK (");
                try writeInt(affected);
                try writeAll(" rows affected)\n");
            }
        }
    }

    /// Print help information
    fn printHelp(self: *Self) !void {
        _ = self;
        try writeAll(
            \\Available commands:
            \\  .help                 Show this help message
            \\  .open <file>          Open database file (use :memory: for in-memory)
            \\  .tables               List all tables
            \\  .schema [table]       Show CREATE statements
            \\  .databases            Show connected databases
            \\  .version              Show version information
            \\  .quit, .exit          Exit the shell
            \\  <SQL>                 Execute SQL statement
            \\
        );
    }

    /// Cleanup
    pub fn deinit(self: *Self) void {
        if (self.connection) |conn| {
            conn.close();
        }
    }
};

// Low-level I/O helper functions

fn writeAll(str: []const u8) !void {
    std.debug.print("{s}", .{str});
}

fn writeInt(value: anytype) !void {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    try writeAll(str);
}

fn writeInt64(value: i64) !void {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    try writeAll(str);
}

fn writeFloat(value: f64) !void {
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d:.6}", .{value}) catch return;
    try writeAll(str);
}

fn printValue(value: storage.Value) !void {
    switch (value) {
        .Integer => |i| try writeInt64(i),
        .Real => |r| try writeFloat(r),
        .Text => |t| try writeAll(t),
        .Blob => |b| {
            try writeAll("<blob:");
            try writeInt(b.len);
            try writeAll(">");
        },
        .Null => try writeAll("NULL"),
        .Boolean => |b| try writeAll(if (b) "true" else "false"),
        .JSON => |j| try writeAll(j),
        .UUID => |u| {
            var buf: [36]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
                u[0], u[1], u[2],  u[3],  u[4],  u[5],  u[6],  u[7],
                u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15],
            }) catch {};
            try writeAll(&buf);
        },
        .Timestamp => |ts| try writeInt64(ts),
        .Date => |d| try writeInt(d),
        .Time => |t| try writeInt64(t),
        else => try writeAll("?"),
    }
}

fn readLine(buffer: []u8) ![]const u8 {
    const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;
    var pos: usize = 0;

    while (pos < buffer.len) {
        var byte: [1]u8 = undefined;
        const n = std.posix.read(stdin_fd, &byte) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };

        if (n == 0) {
            if (pos == 0) return error.EndOfStream;
            break;
        }

        if (byte[0] == '\n') break;
        buffer[pos] = byte[0];
        pos += 1;
    }

    return std.mem.trim(u8, buffer[0..pos], " \t\r\n");
}

/// Shell runner function
pub fn runShell() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var shell = Shell.init(allocator);
    defer shell.deinit();
    try shell.run();
}

/// Execute command line arguments
pub fn executeCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var database_path: ?[]const u8 = null;
    var sql_command: ?[]const u8 = null;
    var show_version = false;
    var show_help = false;

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--sql") or std.mem.eql(u8, arg, "-c")) {
            if (i + 1 < args.len) {
                i += 1;
                sql_command = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--db") or std.mem.eql(u8, arg, "-d")) {
            if (i + 1 < args.len) {
                i += 1;
                database_path = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-") and database_path == null) {
            database_path = arg;
        }
    }

    if (show_version) {
        try writeAll("ZQLite ");
        try writeAll(version.FULL_VERSION_STRING);
        try writeAll("\n");
        return;
    }

    if (show_help) {
        try writeAll(
            \\ZQLite - High-performance embedded database with post-quantum crypto
            \\
            \\Usage: zqlite [options] [database]
            \\
            \\Options:
            \\  -h, --help          Show this help message
            \\  -v, --version       Show version information
            \\  -d, --db <file>     Database file to open
            \\  -c, --sql <sql>     Execute SQL command and exit
            \\
            \\Examples:
            \\  zqlite                          Start interactive shell with :memory:
            \\  zqlite mydb.db                  Open database file
            \\  zqlite -c "SELECT 1+1"          Execute SQL on :memory:
            \\  zqlite mydb.db -c "SELECT *"    Execute SQL on database file
            \\
        );
        return;
    }

    // Open database
    const conn = if (database_path) |path|
        try zqlite.open(allocator, path)
    else
        try zqlite.openMemory(allocator);
    defer conn.close();

    if (sql_command) |sql| {
        // Execute single command
        var shell = Shell.init(allocator);
        shell.connection = conn;
        try shell.executeSQL(sql);
    } else {
        // Start interactive shell
        var shell = Shell.init(allocator);
        shell.connection = conn;
        shell.database_path = database_path;

        try writeAll(version.FULL_VERSION_WITH_BUILD);
        try writeAll(" - Interactive Shell\n");
        try writeAll("High-performance embedded database with post-quantum crypto\n");
        if (database_path) |path| {
            try writeAll("Connected to ");
            try writeAll(path);
            try writeAll("\n");
        } else {
            try writeAll("Connected to :memory:\n");
        }
        try writeAll("Type .help for usage hints\n\n");

        var line_buffer: [4096]u8 = undefined;

        while (shell.running) {
            try writeAll("zqlite> ");

            const line = readLine(&line_buffer) catch |err| switch (err) {
                error.EndOfStream => {
                    try writeAll("\n");
                    break;
                },
                else => return err,
            };

            if (line.len == 0) continue;

            shell.processCommand(line) catch |err| {
                try writeAll("Error: ");
                try writeAll(@errorName(err));
                try writeAll("\n");
            };
        }
    }
}
