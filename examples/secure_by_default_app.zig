const std = @import("std");
const zqlite = @import("zqlite");

const ProgressState = struct {
    calls: u32 = 0,
};

fn progressHandler(context: ?*anyopaque, event: zqlite.ProgressEvent) bool {
    const state: *ProgressState = @ptrCast(@alignCast(context.?));
    state.calls += 1;
    return event.work_units < 50_000;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var progress_state = ProgressState{};
    var conn = try zqlite.openMemoryWithOptions(allocator, .{
        .secure_mode = true,
        .resource_limits = .{
            .max_scanned_rows = 10_000,
            .max_result_rows = 1_000,
            .max_affected_rows = 100,
            .progress_interval_ops = 1,
        },
        .progress_callback = progressHandler,
        .progress_context = &progress_state,
    });
    defer conn.close();

    try conn.execute(
        \\CREATE TABLE accounts (
        \\    id INTEGER PRIMARY KEY,
        \\    email TEXT UNIQUE NOT NULL,
        \\    role TEXT NOT NULL
        \\)
    );

    var insert = try conn.prepare("INSERT INTO accounts (id, email, role) VALUES (:id, :email, :role)");
    defer insert.deinit();

    try insert.bindNamed("id", 1);
    try insert.bindNamed("email", "ada@example.com");
    try insert.bindNamed("role", "admin");
    var insert_result = try insert.execute();
    insert_result.deinit();

    insert.reset();
    try insert.bindNamed("id", 2);
    try insert.bindNamed("email", "linus@example.com");
    try insert.bindNamed("role", "user");
    insert_result = try insert.execute();
    insert_result.deinit();

    var lookup = try conn.prepare("SELECT email, role FROM accounts WHERE id = :id");
    defer lookup.deinit();

    try lookup.bindNamed("id", 1);
    var lookup_result = try lookup.execute();
    defer lookup_result.deinit();
    if (lookup_result.rows.items.len != 1) return error.ExpectedOneAccount;

    conn.execute("ATTACH DATABASE 'relative.db' AS blocked") catch |err| switch (err) {
        error.RelativePathNotAllowed => {},
        else => return err,
    };

    try conn.execute("ATTACH DATABASE ':memory:' AS scratch");
    try conn.execute("CREATE TABLE scratch.audit (event TEXT)");
    try conn.execute("INSERT INTO scratch.audit VALUES ('login')");
    try conn.execute("DETACH DATABASE scratch");

    try conn.transactionExec(&.{
        "INSERT INTO accounts (id, email, role) VALUES (3, 'grace@example.com', 'auditor')",
        "UPDATE accounts SET role = 'maintainer' WHERE id = 2",
    });

    try conn.flush();

    const progress = conn.currentProgressEvent();
    if (progress.work_units == 0 or progress_state.calls == 0) return error.ExpectedProgressEvents;

    std.debug.print("secure-by-default example completed: rows={d}, progress_calls={d}\n", .{
        lookup_result.rows.items.len,
        progress_state.calls,
    });
}
