const std = @import("std");
const zqlite = @import("zqlite");
const parser = zqlite.parser;
const ast = zqlite.ast;

test "SQL Comments Support" {
    const allocator = std.testing.allocator;

    // Test line comments
    const sql_with_comments =
        \\-- This is a comment
        \\SELECT * FROM users -- another comment
        \\WHERE id = 1; -- final comment
    ;

    var result = parser.parse(allocator, sql_with_comments) catch |err| switch (err) {
        error.UnterminatedComment => return,
        else => return err,
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Select);
}

test "Extended Data Types" {
    const allocator = std.testing.allocator;

    const sql =
        \\CREATE TABLE enhanced_users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name VARCHAR(255) NOT NULL,
        \\    email TEXT UNIQUE,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    birth_date DATE,
        \\    last_login TIMESTAMP,
        \\    is_active BOOLEAN DEFAULT 1,
        \\    balance DECIMAL(10,2),
        \\    score FLOAT
        \\)
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .CreateTable);

    const create_stmt = result.statement.CreateTable;
    try std.testing.expect(create_stmt.columns.len == 9);

    // Verify some specific column types
    const id_col = create_stmt.columns[0];
    try std.testing.expect(id_col.data_type == .Integer);

    const name_col = create_stmt.columns[1];
    try std.testing.expect(name_col.data_type == .Varchar);

    const created_at_col = create_stmt.columns[3];
    try std.testing.expect(created_at_col.data_type == .DateTime);

    const is_active_col = create_stmt.columns[6];
    try std.testing.expect(is_active_col.data_type == .Boolean);
}

test "JOIN Operations" {
    const allocator = std.testing.allocator;

    const sql =
        \\SELECT u.name, p.title 
        \\FROM users u
        \\INNER JOIN posts p ON u.id = p.user_id
        \\LEFT JOIN comments c ON p.id = c.post_id
        \\WHERE u.active = 1
        \\ORDER BY u.name ASC
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("JOIN parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Select);

    const select_stmt = result.statement.Select;
    try std.testing.expect(select_stmt.joins.len == 2);
    try std.testing.expect(select_stmt.joins[0].join_type == .Inner);
    try std.testing.expect(select_stmt.joins[1].join_type == .Left);
}

test "Aggregate Functions" {
    const allocator = std.testing.allocator;

    const sql =
        \\SELECT COUNT(*), SUM(amount), AVG(score), MIN(created_at), MAX(updated_at)
        \\FROM transactions
        \\GROUP BY user_id
        \\HAVING COUNT(*) > 5
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("Aggregate parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Select);

    const select_stmt = result.statement.Select;
    try std.testing.expect(select_stmt.columns.len == 5);
    try std.testing.expect(select_stmt.group_by != null);
    try std.testing.expect(select_stmt.having != null);
}

test "Transaction Support" {
    const allocator = std.testing.allocator;

    // Test BEGIN
    var begin_result = parser.parse(allocator, "BEGIN TRANSACTION") catch |err| {
        std.debug.print("BEGIN parse error: {}\n", .{err});
        return err;
    };
    defer begin_result.deinit();
    try std.testing.expect(std.meta.activeTag(begin_result.statement) == .BeginTransaction);

    // Test COMMIT
    var commit_result = parser.parse(allocator, "COMMIT") catch |err| {
        std.debug.print("COMMIT parse error: {}\n", .{err});
        return err;
    };
    defer commit_result.deinit();
    try std.testing.expect(std.meta.activeTag(commit_result.statement) == .Commit);

    // Test ROLLBACK
    var rollback_result = parser.parse(allocator, "ROLLBACK") catch |err| {
        std.debug.print("ROLLBACK parse error: {}\n", .{err});
        return err;
    };
    defer rollback_result.deinit();
    try std.testing.expect(std.meta.activeTag(rollback_result.statement) == .Rollback);
}

test "Index Management" {
    const allocator = std.testing.allocator;

    // Test CREATE INDEX
    const create_idx_sql = "CREATE UNIQUE INDEX idx_user_email ON users (email)";
    var create_result = parser.parse(allocator, create_idx_sql) catch |err| {
        std.debug.print("CREATE INDEX parse error: {}\n", .{err});
        return err;
    };
    defer create_result.deinit();

    try std.testing.expect(std.meta.activeTag(create_result.statement) == .CreateIndex);
    const create_idx = create_result.statement.CreateIndex;
    try std.testing.expect(create_idx.unique == true);
    try std.testing.expect(std.mem.eql(u8, create_idx.index_name, "idx_user_email"));
    try std.testing.expect(std.mem.eql(u8, create_idx.table_name, "users"));

    // Test DROP INDEX
    const drop_idx_sql = "DROP INDEX IF EXISTS idx_user_email";
    var drop_result = parser.parse(allocator, drop_idx_sql) catch |err| {
        std.debug.print("DROP INDEX parse error: {}\n", .{err});
        return err;
    };
    defer drop_result.deinit();

    try std.testing.expect(std.meta.activeTag(drop_result.statement) == .DropIndex);
    const drop_idx = drop_result.statement.DropIndex;
    try std.testing.expect(drop_idx.if_exists == true);
}

test "INSERT Enhancements" {
    const allocator = std.testing.allocator;

    const sql = "INSERT OR IGNORE INTO users (name, email) VALUES ('John', 'john@test.com')";
    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("INSERT OR parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Insert);

    const insert_stmt = result.statement.Insert;
    try std.testing.expect(insert_stmt.or_conflict != null);
    try std.testing.expect(insert_stmt.or_conflict.? == .Ignore);
}

test "Foreign Key Constraints" {
    const allocator = std.testing.allocator;

    const sql =
        \\CREATE TABLE posts (
        \\    id INTEGER PRIMARY KEY,
        \\    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        \\    title TEXT NOT NULL,
        \\    content TEXT
        \\)
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("FK parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .CreateTable);

    const create_stmt = result.statement.CreateTable;
    const user_id_col = create_stmt.columns[1];

    // Check for foreign key constraint
    var has_fk = false;
    for (user_id_col.constraints) |constraint| {
        if (constraint == .ForeignKey) {
            has_fk = true;
            const fk = constraint.ForeignKey;
            try std.testing.expect(std.mem.eql(u8, fk.reference_table, "users"));
            try std.testing.expect(std.mem.eql(u8, fk.reference_column, "id"));
            try std.testing.expect(fk.on_delete == .Cascade);
            break;
        }
    }
    try std.testing.expect(has_fk);
}

test "RETURNING Clause - INSERT" {
    const allocator = std.testing.allocator;

    const sql =
        \\INSERT INTO users (name, email) VALUES ('John', 'john@example.com') RETURNING id, name
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("RETURNING INSERT parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Insert);
    const insert_stmt = result.statement.Insert;
    try std.testing.expect(insert_stmt.returning != null);
    try std.testing.expect(insert_stmt.returning.?.columns.len == 2);
    try std.testing.expect(std.mem.eql(u8, insert_stmt.returning.?.columns[0], "id"));
    try std.testing.expect(std.mem.eql(u8, insert_stmt.returning.?.columns[1], "name"));
}

test "RETURNING Clause - UPDATE" {
    const allocator = std.testing.allocator;

    const sql =
        \\UPDATE users SET name = 'Jane' WHERE id = 1 RETURNING *
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("RETURNING UPDATE parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Update);
    const update_stmt = result.statement.Update;
    try std.testing.expect(update_stmt.returning != null);
    try std.testing.expect(update_stmt.returning.?.columns.len == 1);
    try std.testing.expect(std.mem.eql(u8, update_stmt.returning.?.columns[0], "*"));
}

test "RETURNING Clause - DELETE" {
    const allocator = std.testing.allocator;

    const sql =
        \\DELETE FROM users WHERE active = 0 RETURNING id, name, email
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("RETURNING DELETE parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Delete);
    const delete_stmt = result.statement.Delete;
    try std.testing.expect(delete_stmt.returning != null);
    try std.testing.expect(delete_stmt.returning.?.columns.len == 3);
}

test "ON CONFLICT DO NOTHING - UPSERT" {
    const allocator = std.testing.allocator;

    const sql =
        \\INSERT INTO users (id, name) VALUES (1, 'John') ON CONFLICT DO NOTHING
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("UPSERT DO NOTHING parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Insert);
    const insert_stmt = result.statement.Insert;
    try std.testing.expect(insert_stmt.on_conflict != null);
    try std.testing.expect(insert_stmt.on_conflict.?.action == .DoNothing);
}

test "ON CONFLICT DO UPDATE - UPSERT" {
    const allocator = std.testing.allocator;

    const sql =
        \\INSERT INTO users (id, name, email) VALUES (1, 'John', 'john@example.com')
        \\ON CONFLICT (id) DO UPDATE SET name = 'Jane', email = 'jane@example.com'
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("UPSERT DO UPDATE parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Insert);
    const insert_stmt = result.statement.Insert;
    try std.testing.expect(insert_stmt.on_conflict != null);
    try std.testing.expect(insert_stmt.on_conflict.?.target_columns != null);
    try std.testing.expect(insert_stmt.on_conflict.?.target_columns.?[0].len == 1); // "id"
    try std.testing.expect(insert_stmt.on_conflict.?.action == .DoUpdate);

    // Verify assignments
    const action = insert_stmt.on_conflict.?.action;
    switch (action) {
        .DoUpdate => |update| {
            try std.testing.expect(update.assignments.len == 2);
        },
        else => return error.UnexpectedAction,
    }
}

test "ON CONFLICT with WHERE clause" {
    const allocator = std.testing.allocator;

    const sql =
        \\INSERT INTO users (id, name) VALUES (1, 'John')
        \\ON CONFLICT (id) DO UPDATE SET name = 'Updated' WHERE active = 1
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("UPSERT with WHERE parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Insert);
    const insert_stmt = result.statement.Insert;
    try std.testing.expect(insert_stmt.on_conflict != null);

    const action = insert_stmt.on_conflict.?.action;
    switch (action) {
        .DoUpdate => |update| {
            try std.testing.expect(update.where_clause != null);
        },
        else => return error.UnexpectedAction,
    }
}

test "UPSERT with RETURNING" {
    const allocator = std.testing.allocator;

    const sql =
        \\INSERT INTO users (id, name) VALUES (1, 'John')
        \\ON CONFLICT (id) DO UPDATE SET name = 'Jane'
        \\RETURNING id, name
    ;

    var result = parser.parse(allocator, sql) catch |err| {
        std.debug.print("UPSERT with RETURNING parse error: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    try std.testing.expect(std.meta.activeTag(result.statement) == .Insert);
    const insert_stmt = result.statement.Insert;
    try std.testing.expect(insert_stmt.on_conflict != null);
    try std.testing.expect(insert_stmt.returning != null);
    try std.testing.expect(insert_stmt.returning.?.columns.len == 2);
}
