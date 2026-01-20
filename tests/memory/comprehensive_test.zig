const std = @import("std");
const zqlite = @import("zqlite");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("\n!!! MEMORY LEAK DETECTED !!!\n", .{});
        } else {
            std.debug.print("\n### No memory leaks detected ###\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("=== Comprehensive Memory Test ===\n\n", .{});

    // Test 1: Heavy INSERT/SELECT/DELETE cycles
    std.debug.print("Test 1: Heavy INSERT/SELECT/DELETE cycles...\n", .{});
    {
        var conn = try zqlite.Connection.openMemory(allocator);
        defer conn.close();

        try conn.execute("CREATE TABLE test1 (id INTEGER, name TEXT, value REAL)");

        // Insert 1000 rows
        for (0..1000) |i| {
            const sql = try std.fmt.allocPrint(allocator, "INSERT INTO test1 VALUES ({d}, 'name_{d}', {d}.5)", .{ i, i, i });
            defer allocator.free(sql);
            try conn.execute(sql);
        }

        // Select and iterate through all rows
        var rs = try conn.query("SELECT * FROM test1");
        defer rs.deinit();
        var count: usize = 0;
        while (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            count += 1;
        }
        std.debug.print("  Read {d} rows\n", .{count});

        // Delete half the rows
        try conn.execute("DELETE FROM test1 WHERE id < 500");

        // Select again
        var rs2 = try conn.query("SELECT * FROM test1");
        defer rs2.deinit();
        count = 0;
        while (rs2.next()) |row| {
            var r = row;
            defer r.deinit();
            count += 1;
        }
        std.debug.print("  After DELETE: {d} rows\n", .{count});
    }
    std.debug.print("  PASSED\n\n", .{});

    // Test 2: JOINs with multiple tables
    std.debug.print("Test 2: JOINs with multiple tables...\n", .{});
    {
        var conn = try zqlite.Connection.openMemory(allocator);
        defer conn.close();

        try conn.execute("CREATE TABLE customers (id INTEGER, name TEXT)");
        try conn.execute("CREATE TABLE orders (id INTEGER, customer_id INTEGER, product TEXT)");

        for (0..100) |i| {
            const sql1 = try std.fmt.allocPrint(allocator, "INSERT INTO customers VALUES ({d}, 'Customer_{d}')", .{ i, i });
            defer allocator.free(sql1);
            try conn.execute(sql1);

            // Each customer has 3 orders
            for (0..3) |j| {
                const sql2 = try std.fmt.allocPrint(allocator, "INSERT INTO orders VALUES ({d}, {d}, 'Product_{d}')", .{ i * 3 + j, i, j });
                defer allocator.free(sql2);
                try conn.execute(sql2);
            }
        }

        var rs = try conn.query("SELECT c.name, o.product FROM customers c INNER JOIN orders o ON c.id = o.customer_id");
        defer rs.deinit();
        var count: usize = 0;
        while (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            count += 1;
        }
        std.debug.print("  JOIN result: {d} rows\n", .{count});
    }
    std.debug.print("  PASSED\n\n", .{});

    // Test 3: Transaction ROLLBACK
    std.debug.print("Test 3: Transaction ROLLBACK...\n", .{});
    {
        var conn = try zqlite.Connection.openMemory(allocator);
        defer conn.close();

        try conn.execute("CREATE TABLE txn_test (id INTEGER, value TEXT)");
        try conn.execute("INSERT INTO txn_test VALUES (1, 'initial')");

        // Do 10 transaction cycles
        for (0..10) |i| {
            try conn.begin();

            // Insert some rows
            for (0..100) |j| {
                const sql = try std.fmt.allocPrint(allocator, "INSERT INTO txn_test VALUES ({d}, 'txn_{d}')", .{ i * 100 + j + 2, i });
                defer allocator.free(sql);
                try conn.execute(sql);
            }

            // Rollback
            try conn.rollback();
        }

        var rs = try conn.query("SELECT COUNT(*) FROM txn_test");
        defer rs.deinit();
        if (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            std.debug.print("  After 10 rollbacks, count = {d}\n", .{r.getInt(0).?});
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    // Test 4: UNION/INTERSECT/EXCEPT
    std.debug.print("Test 4: UNION/INTERSECT/EXCEPT...\n", .{});
    {
        var conn = try zqlite.Connection.openMemory(allocator);
        defer conn.close();

        try conn.execute("CREATE TABLE set1 (id INTEGER, name TEXT)");
        try conn.execute("CREATE TABLE set2 (id INTEGER, name TEXT)");

        for (0..50) |i| {
            const sql1 = try std.fmt.allocPrint(allocator, "INSERT INTO set1 VALUES ({d}, 'name_{d}')", .{ i, i });
            defer allocator.free(sql1);
            try conn.execute(sql1);
        }

        for (25..75) |i| {
            const sql2 = try std.fmt.allocPrint(allocator, "INSERT INTO set2 VALUES ({d}, 'name_{d}')", .{ i, i });
            defer allocator.free(sql2);
            try conn.execute(sql2);
        }

        // Test UNION
        var rs1 = try conn.query("SELECT * FROM set1 UNION SELECT * FROM set2");
        defer rs1.deinit();
        var count1: usize = 0;
        while (rs1.next()) |row| {
            var r = row;
            defer r.deinit();
            count1 += 1;
        }
        std.debug.print("  UNION: {d} rows\n", .{count1});

        // Test INTERSECT
        var rs2 = try conn.query("SELECT * FROM set1 INTERSECT SELECT * FROM set2");
        defer rs2.deinit();
        var count2: usize = 0;
        while (rs2.next()) |row| {
            var r = row;
            defer r.deinit();
            count2 += 1;
        }
        std.debug.print("  INTERSECT: {d} rows\n", .{count2});

        // Test EXCEPT
        var rs3 = try conn.query("SELECT * FROM set1 EXCEPT SELECT * FROM set2");
        defer rs3.deinit();
        var count3: usize = 0;
        while (rs3.next()) |row| {
            var r = row;
            defer r.deinit();
            count3 += 1;
        }
        std.debug.print("  EXCEPT: {d} rows\n", .{count3});
    }
    std.debug.print("  PASSED\n\n", .{});

    // Test 5: GROUP BY with aggregates
    std.debug.print("Test 5: GROUP BY with aggregates...\n", .{});
    {
        var conn = try zqlite.Connection.openMemory(allocator);
        defer conn.close();

        try conn.execute("CREATE TABLE sales (dept TEXT, amount INTEGER)");

        const depts = [_][]const u8{ "Sales", "Marketing", "Engineering", "HR" };
        for (0..200) |i| {
            const dept = depts[i % 4];
            const sql = try std.fmt.allocPrint(allocator, "INSERT INTO sales VALUES ('{s}', {d})", .{ dept, (i + 1) * 10 });
            defer allocator.free(sql);
            try conn.execute(sql);
        }

        var rs = try conn.query("SELECT dept, SUM(amount), AVG(amount), COUNT(*) FROM sales GROUP BY dept");
        defer rs.deinit();
        while (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            std.debug.print("  Dept: {s}, Sum: {d}, Avg: {d}, Count: {d}\n", .{
                r.getText(0).?,
                r.getInt(1).?,
                r.getInt(2).?,
                r.getInt(3).?,
            });
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    // Test 6: UPDATE operations
    std.debug.print("Test 6: UPDATE operations...\n", .{});
    {
        var conn = try zqlite.Connection.openMemory(allocator);
        defer conn.close();

        try conn.execute("CREATE TABLE update_test (id INTEGER, value TEXT)");

        for (0..100) |i| {
            const sql = try std.fmt.allocPrint(allocator, "INSERT INTO update_test VALUES ({d}, 'original_{d}')", .{ i, i });
            defer allocator.free(sql);
            try conn.execute(sql);
        }

        // Update half
        try conn.execute("UPDATE update_test SET value = 'updated' WHERE id < 50");

        var rs = try conn.query("SELECT COUNT(*) FROM update_test WHERE value = 'updated'");
        defer rs.deinit();
        if (rs.next()) |row| {
            var r = row;
            defer r.deinit();
            std.debug.print("  Updated rows: {d}\n", .{r.getInt(0).?});
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    // Test 7: Repeated connection open/close
    std.debug.print("Test 7: Repeated connection open/close...\n", .{});
    {
        for (0..50) |_| {
            var conn = try zqlite.Connection.openMemory(allocator);
            try conn.execute("CREATE TABLE temp (id INTEGER)");
            try conn.execute("INSERT INTO temp VALUES (1)");
            var rs = try conn.query("SELECT * FROM temp");
            defer rs.deinit();
            while (rs.next()) |row| {
                var r = row;
                r.deinit();
            }
            conn.close();
        }
    }
    std.debug.print("  50 open/close cycles completed\n", .{});
    std.debug.print("  PASSED\n\n", .{});

    std.debug.print("=== All Memory Tests Completed ===\n", .{});
}
