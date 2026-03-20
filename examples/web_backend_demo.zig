const std = @import("std");
const zqlite = @import("zqlite");

/// ZQLite Web Backend Demo
/// Shows how zqlite can be used as a backend database for web applications
/// (This is a simulation - no actual HTTP server, just the database operations)
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🌐 {s} - Web Backend Database Demo\n", .{zqlite.version.FULL_VERSION_STRING});
    std.debug.print("   Simulating a blog/CMS backend with zqlite! 📝\n\n", .{});

    // Open persistent database (in production, this would be a real file)
    var conn = try zqlite.openMemory(allocator); // Using memory for demo
    defer conn.close();

    // Initialize database schema
    try setupBlogSchema(conn);

    // Simulate some API endpoints
    try simulateApiEndpoints(conn, allocator);

    std.debug.print("\n✅ Web backend simulation complete!\n", .{});
    std.debug.print("   ZQLite handles web workloads beautifully! 🚀\n", .{});
}

/// Setup database schema for a simple blog/CMS
fn setupBlogSchema(conn: *zqlite.Connection) !void {
    std.debug.print("🛠️  Setting up blog schema...\n", .{});

    // Users table
    try conn.execute(
        \\CREATE TABLE users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    username TEXT UNIQUE NOT NULL,
        \\    email TEXT UNIQUE NOT NULL,
        \\    password_hash TEXT NOT NULL,
        \\    created_at TEXT DEFAULT 'now',
        \\    is_admin INTEGER DEFAULT 0
        \\)
    );

    // Posts table
    try conn.execute(
        \\CREATE TABLE posts (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    title TEXT NOT NULL,
        \\    content TEXT NOT NULL,
        \\    author_id INTEGER NOT NULL,
        \\    published INTEGER DEFAULT 0,
        \\    created_at TEXT DEFAULT 'now',
        \\    updated_at TEXT DEFAULT 'now'
        \\)
    );

    // Comments table
    try conn.execute(
        \\CREATE TABLE comments (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    post_id INTEGER NOT NULL,
        \\    author_name TEXT NOT NULL,
        \\    author_email TEXT NOT NULL,
        \\    content TEXT NOT NULL,
        \\    approved INTEGER DEFAULT 0,
        \\    created_at TEXT DEFAULT 'now'
        \\)
    );

    // Tags table
    try conn.execute(
        \\CREATE TABLE tags (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT UNIQUE NOT NULL,
        \\    color TEXT DEFAULT '#3B82F6'
        \\)
    );

    // Post tags junction table
    try conn.execute(
        \\CREATE TABLE post_tags (
        \\    post_id INTEGER NOT NULL,
        \\    tag_id INTEGER NOT NULL
        \\)
    );

    std.debug.print("   ✅ Blog schema created successfully!\n", .{});
}

/// Simulate various API endpoints that a web backend might handle
fn simulateApiEndpoints(conn: *zqlite.Connection, allocator: std.mem.Allocator) !void {
    std.debug.print("\n🔄 Simulating API endpoints...\n", .{});

    // Endpoint 1: POST /api/users (Create user)
    std.debug.print("\n📝 POST /api/users - Creating users...\n", .{});

    try conn.execute("INSERT INTO users (username, email, password_hash, is_admin) VALUES ('john_doe', 'john@example.com', 'hashed_password_123', 1)");
    try conn.execute("INSERT INTO users (username, email, password_hash, is_admin) VALUES ('jane_smith', 'jane@example.com', 'hashed_password_456', 0)");
    try conn.execute("INSERT INTO users (username, email, password_hash, is_admin) VALUES ('bob_wilson', 'bob@example.com', 'hashed_password_789', 0)");

    std.debug.print("   ✅ Created 3 users (1 admin + 2 regular)\n", .{});

    // Endpoint 2: GET /api/users (List users)
    std.debug.print("\n👥 GET /api/users - Listing users...\n", .{});

    var users_result = try conn.query("SELECT id, username, email, is_admin FROM users ORDER BY created_at");
    defer users_result.deinit();

    std.debug.print("   📋 Found {d} users:\n", .{users_result.count()});
    while (users_result.next()) |user| {
        const id = user.getIntByName("id") orelse 0;
        const username = user.getTextByName("username") orelse "unknown";
        const email = user.getTextByName("email") orelse "no-email";
        const is_admin = user.getIntByName("is_admin") orelse 0;
        const role = if (is_admin == 1) "Admin" else "User";

        std.debug.print("   │ #{d}: {s} ({s}) - {s}\n", .{ id, username, email, role });
    }

    // Endpoint 3: POST /api/posts (Create posts)
    std.debug.print("\n📄 POST /api/posts - Creating blog posts...\n", .{});

    // Note: Using AUTOINCREMENT, john_doe gets ID 1, jane_smith gets ID 2, bob_wilson gets ID 3
    try conn.execute("INSERT INTO posts (title, content, author_id, published) VALUES ('Welcome to ZQLite!', 'This is our first post about the amazing ZQLite database...', 1, 1)");
    try conn.execute("INSERT INTO posts (title, content, author_id, published) VALUES ('ZQLite vs SQLite', 'A comprehensive comparison between ZQLite and SQLite...', 1, 1)");
    try conn.execute("INSERT INTO posts (title, content, author_id) VALUES ('Draft Post', 'This is still a draft...', 2)");

    // Create some tags
    try conn.execute("INSERT INTO tags (name, color) VALUES ('Database', '#EF4444')");
    try conn.execute("INSERT INTO tags (name, color) VALUES ('Zig', '#F59E0B')");
    try conn.execute("INSERT INTO tags (name, color) VALUES ('Performance', '#10B981')");

    // Tag the posts (post IDs 1,2 and tag IDs 1,2,3 from AUTOINCREMENT)
    try conn.execute("INSERT INTO post_tags (post_id, tag_id) VALUES (1, 1), (1, 2)");
    try conn.execute("INSERT INTO post_tags (post_id, tag_id) VALUES (2, 1), (2, 3)");

    std.debug.print("   ✅ Created blog posts and tags\n", .{});

    // Endpoint 4: GET /api/posts (List published posts with authors)
    std.debug.print("\n📚 GET /api/posts - Listing published posts...\n", .{});

    var posts_result = try conn.query(
        \\SELECT p.id, p.title, u.username as author, p.created_at
        \\FROM posts p 
        \\JOIN users u ON p.author_id = u.id 
        \\WHERE p.published = 1 
        \\ORDER BY p.created_at DESC
    );
    defer posts_result.deinit();

    std.debug.print("   📋 Published posts ({d}):\n", .{posts_result.count()});
    while (posts_result.next()) |post| {
        const id = post.getIntByName("id") orelse 0;
        const title = post.getTextByName("title") orelse "Untitled";
        const author = post.getTextByName("author") orelse "Unknown";

        std.debug.print("   │ #{d}: \"{s}\" by {s}\n", .{ id, title, author });
    }

    // Endpoint 5: POST /api/comments (Add comments)
    std.debug.print("\n💬 POST /api/comments - Adding comments...\n", .{});

    try conn.execute("INSERT INTO comments (post_id, author_name, author_email, content, approved) VALUES (1, 'Alice Reader', 'alice@reader.com', 'Great introduction to ZQLite!', 1)");
    try conn.execute("INSERT INTO comments (post_id, author_name, author_email, content) VALUES (1, 'Spam Bot', 'spam@bot.com', 'Buy cheap products now!')");
    try conn.execute("INSERT INTO comments (post_id, author_name, author_email, content, approved) VALUES (2, 'DB Expert', 'expert@db.com', 'Interesting comparison. I love the type safety!', 1)");

    std.debug.print("   ✅ Added comments (some pending approval)\n", .{});

    // Endpoint 6: GET /api/posts/:id/comments (Get approved comments for a post)
    std.debug.print("\n💭 GET /api/posts/1/comments - Getting approved comments...\n", .{});

    var comments_result = try conn.query("SELECT author_name, content, created_at FROM comments WHERE post_id = 1 AND approved = 1 ORDER BY created_at");
    defer comments_result.deinit();

    while (comments_result.next()) |comment| {
        const author = comment.getTextByName("author_name") orelse "Anonymous";
        const content = comment.getTextByName("content") orelse "";

        std.debug.print("   💬 {s}: \"{s}\"\n", .{ author, content });
    }

    // Endpoint 7: Dashboard analytics (complex queries)
    std.debug.print("\n📊 GET /api/admin/dashboard - Analytics...\n", .{});

    // Count posts by author
    var author_stats = try conn.query(
        \\SELECT u.username, 
        \\       COUNT(p.id) as post_count,
        \\       SUM(CASE WHEN p.published = 1 THEN 1 ELSE 0 END) as published_count
        \\FROM users u 
        \\LEFT JOIN posts p ON u.id = p.author_id 
        \\GROUP BY u.id, u.username
    );
    defer author_stats.deinit();

    std.debug.print("   📈 Author Statistics:\n", .{});
    while (author_stats.next()) |stat| {
        const username = stat.getTextByName("username") orelse "Unknown";
        const post_count = stat.getIntByName("post_count") orelse 0;
        const published_count = stat.getIntByName("published_count") orelse 0;

        std.debug.print("   │ {s}: {d} posts ({d} published)\n", .{ username, post_count, published_count });
    }

    // Comments moderation queue
    if (try conn.queryRow("SELECT COUNT(*) as pending_count FROM comments WHERE approved = 0")) |row| {
        const pending = row.getIntByName("pending_count") orelse 0;
        std.debug.print("   ⏳ Pending comments for moderation: {d}\n", .{pending});
    }

    // Database introspection for admin
    std.debug.print("\n🔧 Database Schema (for admin panel):\n", .{});
    const tables = try conn.getTableNames();
    defer {
        for (tables) |name| {
            allocator.free(name);
        }
        allocator.free(tables);
    }

    for (tables) |table_name| {
        if (try conn.getTableSchema(table_name)) |schema| {
            var mutable_schema = schema;
            defer mutable_schema.deinit();
            std.debug.print("   📋 {s}: {d} columns\n", .{ table_name, schema.columnCount() });
        }
    }
}
