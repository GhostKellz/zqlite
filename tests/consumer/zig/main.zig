const std = @import("std");
const zqlite = @import("zqlite");

test "release package Zig consumer" {
    const pq = zqlite.getPQCapability();
    try std.testing.expect(!pq.isAvailable());
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.none, pq.backend);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.stdlib, pq.provider);
    try std.testing.expectEqual(zqlite.pqc_backend.LibOQSProviderStatus.not_configured, pq.liboqs_status);
    const pq_json = try zqlite.pqDiagnosticsJson(std.testing.allocator, pq);
    defer std.testing.allocator.free(pq_json);
    try std.testing.expect(std.mem.indexOf(u8, pq_json, "\"available\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, pq_json, "\"provider\":\"stdlib\"") != null);

    const conn = try zqlite.openMemory(std.testing.allocator);
    defer conn.close();

    try conn.execute("CREATE TABLE smoke (id INTEGER, name TEXT)");
    try conn.execute("INSERT INTO smoke VALUES (1, 'package-ok')");

    var result = try conn.query("SELECT name FROM smoke WHERE id = 1");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.count());
}
