const std = @import("std");
const zqlite = @import("zqlite");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("zqlite UUID Demo\n\n", .{});

    // Initialize PRNG for UUID generation using Io random
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        init.io.random(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    // Generate multiple UUIDs
    for (0..5) |i| {
        const uuid = zqlite.generateUUID(random);
        const uuid_str = try zqlite.uuidToString(uuid, allocator);
        defer allocator.free(uuid_str);

        std.debug.print("UUID {}: {s}\n", .{ i + 1, uuid_str });

        // Test round-trip: string -> UUID -> string
        const parsed_uuid = try zqlite.parseUUID(uuid_str);
        const reparsed_str = try zqlite.uuidToString(parsed_uuid, allocator);
        defer allocator.free(reparsed_str);

        // Verify they match
        if (std.mem.eql(u8, uuid_str, reparsed_str)) {
            std.debug.print("  Round-trip successful\n", .{});
        } else {
            std.debug.print("  Round-trip failed!\n", .{});
        }

        // Test UUID in database
        var conn = try zqlite.openMemory(allocator);
        defer conn.close();

        try conn.execute("CREATE TABLE users (id UUID PRIMARY KEY, name TEXT);");

        // Insert with UUID
        var stmt = try conn.prepare("INSERT INTO users (id, name) VALUES (?, ?);");
        defer stmt.deinit();

        try stmt.bindParameter(0, zqlite.storage.Value{ .UUID = uuid });
        const user_name = try allocator.dupe(u8, "Test User");
        defer allocator.free(user_name);
        try stmt.bindParameter(1, zqlite.storage.Value{ .Text = user_name });

        var result = try stmt.execute();
        defer result.deinit();

        std.debug.print("  UUID stored in database\n\n", .{});
    }

    // Test UUID NIL value
    const nil_uuid = std.mem.zeroes([16]u8);
    const nil_str = try zqlite.uuidToString(nil_uuid, allocator);
    defer allocator.free(nil_str);
    std.debug.print("NIL UUID: {s}\n", .{nil_str});

    // Test specific UUID formats
    const test_uuid = "550e8400-e29b-41d4-a716-446655440000";
    const parsed = try zqlite.parseUUID(test_uuid);
    const reformatted = try zqlite.uuidToString(parsed, allocator);
    defer allocator.free(reformatted);
    std.debug.print("Test UUID: {s} -> {s}\n", .{ test_uuid, reformatted });

    std.debug.print("\nUUID functionality is working!\n", .{});
}
