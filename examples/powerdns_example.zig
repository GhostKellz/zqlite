const std = @import("std");
const zqlite = @import("zqlite");

/// Example PowerDNS-like server using zqlite as backend
const PowerDNSServer = struct {
    allocator: std.mem.Allocator,
    db: *zqlite.db.Connection,

    const Self = @This();

    /// Initialize the DNS server with zqlite backend
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !Self {
        // Open or create the database
        const db = if (std.mem.eql(u8, db_path, ":memory:"))
            try zqlite.openMemory(allocator)
        else
            try zqlite.open(allocator, db_path);

        var server = Self{
            .allocator = allocator,
            .db = db,
        };

        // Initialize DNS schema
        try server.initSchema();
        return server;
    }

    /// Initialize the DNS records schema
    fn initSchema(self: *Self) !void {
        // Create DNS records table
        const create_records_sql =
            \\CREATE TABLE dns_records (
            \\  id INTEGER,
            \\  domain TEXT,
            \\  type TEXT,
            \\  value TEXT,
            \\  ttl INTEGER,
            \\  priority INTEGER
            \\)
        ;

        // Create DNS zones table
        const create_zones_sql =
            \\CREATE TABLE dns_zones (
            \\  id INTEGER,
            \\  name TEXT,
            \\  type TEXT,
            \\  master TEXT,
            \\  last_check INTEGER,
            \\  notified_serial INTEGER
            \\)
        ;

        self.db.execute(create_records_sql) catch |err| switch (err) {
            else => return err,
        };

        self.db.execute(create_zones_sql) catch |err| switch (err) {
            else => return err,
        };
    }

    /// Add a DNS record
    pub fn addRecord(self: *Self, domain: []const u8, record_type: []const u8, value: []const u8, ttl: u32, priority: u32) !void {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "INSERT INTO dns_records (domain, type, value, ttl, priority) VALUES ('{s}', '{s}', '{s}', {d}, {d})", .{ domain, record_type, value, ttl, priority });

        try self.db.execute(sql);
        std.debug.print("Added DNS record: {s} {s} {s} (TTL: {d})\n", .{ domain, record_type, value, ttl });
    }

    /// Look up DNS records for a domain
    pub fn lookupRecords(self: *Self, domain: []const u8, record_type: ?[]const u8) !void {
        var buf: [512]u8 = undefined;
        const sql = if (record_type) |rtype|
            try std.fmt.bufPrint(buf[0..], "SELECT domain, type, value, ttl, priority FROM dns_records WHERE domain = '{s}' AND type = '{s}'", .{ domain, rtype })
        else
            try std.fmt.bufPrint(buf[0..], "SELECT domain, type, value, ttl, priority FROM dns_records WHERE domain = '{s}'", .{domain});

        std.debug.print("Looking up DNS records for {s}:\n", .{domain});
        try self.db.execute(sql);
    }

    /// Add a DNS zone
    pub fn addZone(self: *Self, zone_name: []const u8, zone_type: []const u8) !void {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "INSERT INTO dns_zones (name, type) VALUES ('{s}', '{s}')", .{ zone_name, zone_type });

        try self.db.execute(sql);
        std.debug.print("Added DNS zone: {s} ({s})\n", .{ zone_name, zone_type });
    }

    /// List all zones
    pub fn listZones(self: *Self) !void {
        const sql = "SELECT name, type FROM dns_zones";
        std.debug.print("DNS Zones:\n", .{});
        try self.db.execute(sql);
    }

    /// Update a DNS record
    pub fn updateRecord(self: *Self, domain: []const u8, record_type: []const u8, new_value: []const u8, new_ttl: u32) !void {
        var buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrint(buf[0..], "UPDATE dns_records SET value = '{s}', ttl = {d} WHERE domain = '{s}' AND type = '{s}'", .{ new_value, new_ttl, domain, record_type });

        try self.db.execute(sql);
        std.debug.print("Updated DNS record: {s} {s} -> {s} (TTL: {d})\n", .{ domain, record_type, new_value, new_ttl });
    }

    /// Delete DNS records
    pub fn deleteRecord(self: *Self, domain: []const u8, record_type: ?[]const u8) !void {
        var buf: [512]u8 = undefined;
        const sql = if (record_type) |rtype|
            try std.fmt.bufPrint(buf[0..], "DELETE FROM dns_records WHERE domain = '{s}' AND type = '{s}'", .{ domain, rtype })
        else
            try std.fmt.bufPrint(buf[0..], "DELETE FROM dns_records WHERE domain = '{s}'", .{domain});

        try self.db.execute(sql);
        std.debug.print("Deleted DNS records for {s}\n", .{domain});
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.db.close();
    }
};

/// Demo function showing PowerDNS-like operations
pub fn runDemo() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🟦 PowerDNS Example with zqlite Backend\n", .{});
    std.debug.print("=====================================\n\n", .{});

    // Initialize the DNS server with in-memory database
    var dns_server = try PowerDNSServer.init(allocator, ":memory:");
    defer dns_server.deinit();

    // Add some zones
    try dns_server.addZone("example.com", "NATIVE");
    try dns_server.addZone("test.org", "NATIVE");
    std.debug.print("\n", .{});

    // Add DNS records
    try dns_server.addRecord("example.com", "A", "192.168.1.10", 300, 0);
    try dns_server.addRecord("example.com", "MX", "mail.example.com", 300, 10);
    try dns_server.addRecord("www.example.com", "A", "192.168.1.10", 300, 0);
    try dns_server.addRecord("mail.example.com", "A", "192.168.1.20", 300, 0);
    try dns_server.addRecord("test.org", "A", "10.0.0.5", 600, 0);
    std.debug.print("\n", .{});

    // Look up records
    try dns_server.lookupRecords("example.com", null);
    std.debug.print("\n", .{});
    try dns_server.lookupRecords("example.com", "A");
    std.debug.print("\n", .{});

    // Update a record
    try dns_server.updateRecord("example.com", "A", "192.168.1.100", 600);
    std.debug.print("\n", .{});

    // Look up again to see the change
    try dns_server.lookupRecords("example.com", "A");
    std.debug.print("\n", .{});

    // List all zones
    try dns_server.listZones();
    std.debug.print("\n", .{});

    // Delete a record
    try dns_server.deleteRecord("www.example.com", "A");
    std.debug.print("\n", .{});

    // Final lookup
    try dns_server.lookupRecords("example.com", null);

    std.debug.print("\n🎉 PowerDNS example completed successfully!\n", .{});
    std.debug.print("This demonstrates how easy it is to use zqlite as a backend for DNS services.\n", .{});
}

pub fn main() !void {
    try runDemo();
}
