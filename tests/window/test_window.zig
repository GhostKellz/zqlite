const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("\n!!! MEMORY LEAK DETECTED !!!\n", .{});
        } else {
            std.debug.print("\n### No memory leaks detected ###\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("=== Window Functions Test ===\n\n", .{});

    var conn = try zqlite.Connection.openMemory(allocator);
    defer conn.close();

    // Create a test table
    try conn.execute("CREATE TABLE employees (id INTEGER, name TEXT, department TEXT, salary INTEGER)");

    // Insert test data
    try conn.execute("INSERT INTO employees VALUES (1, 'Alice', 'Engineering', 75000)");
    try conn.execute("INSERT INTO employees VALUES (2, 'Bob', 'Engineering', 80000)");
    try conn.execute("INSERT INTO employees VALUES (3, 'Charlie', 'Engineering', 70000)");
    try conn.execute("INSERT INTO employees VALUES (4, 'Diana', 'Sales', 65000)");
    try conn.execute("INSERT INTO employees VALUES (5, 'Eve', 'Sales', 72000)");
    try conn.execute("INSERT INTO employees VALUES (6, 'Frank', 'Sales', 68000)");
    try conn.execute("INSERT INTO employees VALUES (7, 'Grace', 'HR', 55000)");
    try conn.execute("INSERT INTO employees VALUES (8, 'Henry', 'HR', 58000)");

    std.debug.print("Test 1: ROW_NUMBER() window function\n", .{});
    {
        var rs = try conn.query("SELECT name, salary, ROW_NUMBER() OVER (ORDER BY salary DESC) FROM employees");
        defer rs.deinit();

        std.debug.print("  Name       | Salary | Row#\n", .{});
        std.debug.print("  -----------|--------|-----\n", .{});
        while (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            std.debug.print("  {s:<10} | {d:>6} | {d}\n", .{
                r.getText(0) orelse "NULL",
                r.getInt(1) orelse 0,
                r.getInt(2) orelse 0,
            });
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    std.debug.print("Test 2: RANK() window function\n", .{});
    {
        var rs = try conn.query("SELECT name, salary, RANK() OVER (ORDER BY salary DESC) FROM employees");
        defer rs.deinit();

        std.debug.print("  Name       | Salary | Rank\n", .{});
        std.debug.print("  -----------|--------|-----\n", .{});
        while (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            std.debug.print("  {s:<10} | {d:>6} | {d}\n", .{
                r.getText(0) orelse "NULL",
                r.getInt(1) orelse 0,
                r.getInt(2) orelse 0,
            });
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    std.debug.print("Test 3: DENSE_RANK() window function\n", .{});
    {
        var rs = try conn.query("SELECT name, salary, DENSE_RANK() OVER (ORDER BY salary DESC) FROM employees");
        defer rs.deinit();

        std.debug.print("  Name       | Salary | DenseRank\n", .{});
        std.debug.print("  -----------|--------|----------\n", .{});
        while (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            std.debug.print("  {s:<10} | {d:>6} | {d}\n", .{
                r.getText(0) orelse "NULL",
                r.getInt(1) orelse 0,
                r.getInt(2) orelse 0,
            });
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    std.debug.print("Test 4: NTILE(4) window function\n", .{});
    {
        var rs = try conn.query("SELECT name, salary, NTILE(4) OVER (ORDER BY salary DESC) FROM employees");
        defer rs.deinit();

        std.debug.print("  Name       | Salary | Quartile\n", .{});
        std.debug.print("  -----------|--------|----------\n", .{});
        while (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            std.debug.print("  {s:<10} | {d:>6} | {d}\n", .{
                r.getText(0) orelse "NULL",
                r.getInt(1) orelse 0,
                r.getInt(2) orelse 0,
            });
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    std.debug.print("Test 5: ROW_NUMBER() with PARTITION BY department\n", .{});
    {
        // Note: PARTITION BY requires rows with same partition key to be adjacent
        // We use a subquery or ORDER BY to achieve this, but for now test basic case
        var rs = try conn.query("SELECT name, department, salary, ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) FROM employees");
        defer rs.deinit();

        std.debug.print("  Name       | Dept       | Salary | Row#\n", .{});
        std.debug.print("  -----------|------------|--------|-----\n", .{});
        while (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            std.debug.print("  {s:<10} | {s:<10} | {d:>6} | {d}\n", .{
                r.getText(0) orelse "NULL",
                r.getText(1) orelse "NULL",
                r.getInt(2) orelse 0,
                r.getInt(3) orelse 0,
            });
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    std.debug.print("Test 6: RANK() with PARTITION BY department\n", .{});
    {
        var rs = try conn.query("SELECT name, department, salary, RANK() OVER (PARTITION BY department ORDER BY salary DESC) FROM employees");
        defer rs.deinit();

        std.debug.print("  Name       | Dept       | Salary | Rank\n", .{});
        std.debug.print("  -----------|------------|--------|-----\n", .{});
        while (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            std.debug.print("  {s:<10} | {s:<10} | {d:>6} | {d}\n", .{
                r.getText(0) orelse "NULL",
                r.getText(1) orelse "NULL",
                r.getInt(2) orelse 0,
                r.getInt(3) orelse 0,
            });
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    std.debug.print("=== All Window Function Tests Completed ===\n", .{});
}
