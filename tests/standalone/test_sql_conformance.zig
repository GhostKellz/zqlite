const std = @import("std");
const zqlite = @import("zqlite");

const TestCase = struct {
    name: []const u8,
    setup: []const []const u8,
    statement: []const u8,
    expected: []const u8,
};

const ErrorCase = struct {
    name: []const u8,
    setup: []const []const u8,
    statement: []const u8,
};

const cases = [_]TestCase{
    .{
        .name = "select_where_order",
        .setup = &.{
            "CREATE TABLE users (id INTEGER, name TEXT)",
            "INSERT INTO users VALUES (2, 'Bob')",
            "INSERT INTO users VALUES (1, 'Alice')",
            "INSERT INTO users VALUES (3, 'Carol')",
        },
        .statement = "SELECT id, name FROM users WHERE id > 1 ORDER BY id",
        .expected = "2|Bob\n3|Carol\n",
    },
    .{
        .name = "null_in_logic",
        .setup = &.{
            "CREATE TABLE nullable (id INTEGER, value INTEGER)",
            "INSERT INTO nullable VALUES (1, 1)",
            "INSERT INTO nullable VALUES (2, NULL)",
            "INSERT INTO nullable VALUES (3, 3)",
        },
        .statement = "SELECT id FROM nullable WHERE value IN (NULL, 1) ORDER BY id",
        .expected = "1\n",
    },
    .{
        .name = "null_is_predicates",
        .setup = &.{
            "CREATE TABLE null_pred (id INTEGER, value INTEGER)",
            "INSERT INTO null_pred VALUES (1, NULL)",
            "INSERT INTO null_pred VALUES (2, 0)",
            "INSERT INTO null_pred VALUES (3, 5)",
        },
        .statement = "SELECT id FROM null_pred WHERE value IS NULL OR value IS NOT NULL ORDER BY id",
        .expected = "1\n2\n3\n",
    },
    .{
        .name = "three_valued_and_or",
        .setup = &.{
            "CREATE TABLE logic_test (id INTEGER, lhs INTEGER, rhs INTEGER)",
            "INSERT INTO logic_test VALUES (1, 1, 1)",
            "INSERT INTO logic_test VALUES (2, 1, NULL)",
            "INSERT INTO logic_test VALUES (3, 0, NULL)",
            "INSERT INTO logic_test VALUES (4, NULL, 1)",
        },
        .statement = "SELECT id FROM logic_test WHERE lhs = 1 AND rhs = 1 ORDER BY id",
        .expected = "1\n",
    },
    .{
        .name = "like_text_matching",
        .setup = &.{
            "CREATE TABLE names (id INTEGER, name TEXT)",
            "INSERT INTO names VALUES (1, 'Alice')",
            "INSERT INTO names VALUES (2, 'Bob')",
            "INSERT INTO names VALUES (3, 'Alicia')",
        },
        .statement = "SELECT id FROM names WHERE name LIKE 'Ali%' ORDER BY id",
        .expected = "1\n3\n",
    },
    .{
        .name = "numeric_comparison_order",
        .setup = &.{
            "CREATE TABLE numbers (id INTEGER, value INTEGER)",
            "INSERT INTO numbers VALUES (1, 1)",
            "INSERT INTO numbers VALUES (2, 0)",
            "INSERT INTO numbers VALUES (3, 10)",
            "INSERT INTO numbers VALUES (4, NULL)",
        },
        .statement = "SELECT id FROM numbers WHERE value >= 1 ORDER BY value",
        .expected = "1\n3\n",
    },
    .{
        .name = "grouped_aggregate_ordering",
        .setup = &.{
            "CREATE TABLE grouped_scores (bucket TEXT, score INTEGER)",
            "INSERT INTO grouped_scores VALUES ('b', 2)",
            "INSERT INTO grouped_scores VALUES ('a', 1)",
            "INSERT INTO grouped_scores VALUES ('b', 3)",
            "INSERT INTO grouped_scores VALUES ('a', 4)",
        },
        .statement = "SELECT bucket, COUNT(score), SUM(score) FROM grouped_scores GROUP BY bucket ORDER BY bucket",
        .expected = "a|2|5\nb|2|5\n",
    },
    .{
        .name = "text_affinity_current_order",
        .setup = &.{
            "CREATE TABLE text_values (id INTEGER, value TEXT)",
            "INSERT INTO text_values VALUES (1, '2')",
            "INSERT INTO text_values VALUES (2, '10')",
            "INSERT INTO text_values VALUES (3, 'A')",
            "INSERT INTO text_values VALUES (4, 'a')",
        },
        .statement = "SELECT id, value FROM text_values ORDER BY value",
        .expected = "1|2\n2|10\n3|A\n4|a\n",
    },
    .{
        .name = "insert_default_values",
        .setup = &.{
            "CREATE TABLE defaults_test (id INTEGER DEFAULT 7, name TEXT DEFAULT 'anon', note TEXT)",
            "INSERT INTO defaults_test DEFAULT VALUES",
        },
        .statement = "SELECT id, name, note FROM defaults_test",
        .expected = "7|anon|NULL\n",
    },
    .{
        .name = "check_unknown_allowed",
        .setup = &.{
            "CREATE TABLE products (id INTEGER, price INTEGER CHECK(price > 0))",
            "INSERT INTO products VALUES (1, 10)",
            "INSERT INTO products VALUES (2, NULL)",
        },
        .statement = "SELECT id, price FROM products ORDER BY id",
        .expected = "1|10\n2|NULL\n",
    },
    .{
        .name = "foreign_key_cascade",
        .setup = &.{
            "CREATE TABLE parents (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE children (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parents(id) ON DELETE CASCADE, name TEXT)",
            "INSERT INTO parents VALUES (1, 'parent')",
            "INSERT INTO children VALUES (10, 1, 'child')",
            "DELETE FROM parents WHERE id = 1",
        },
        .statement = "SELECT id, parent_id, name FROM children ORDER BY id",
        .expected = "",
    },
    .{
        .name = "savepoint_rollback_release",
        .setup = &.{
            "CREATE TABLE savepoint_test (id INTEGER, name TEXT)",
            "BEGIN",
            "INSERT INTO savepoint_test VALUES (1, 'outer')",
            "SAVEPOINT sp",
            "INSERT INTO savepoint_test VALUES (2, 'rolled-back')",
            "ROLLBACK TO sp",
            "RELEASE sp",
            "INSERT INTO savepoint_test VALUES (3, 'kept')",
            "COMMIT",
        },
        .statement = "SELECT id, name FROM savepoint_test ORDER BY id",
        .expected = "1|outer\n3|kept\n",
    },
    .{
        .name = "cte_single_step",
        .setup = &.{
            "CREATE TABLE cte_users (id INTEGER, name TEXT, active INTEGER)",
            "INSERT INTO cte_users VALUES (1, 'Alice', 1)",
            "INSERT INTO cte_users VALUES (2, 'Bob', 0)",
            "INSERT INTO cte_users VALUES (3, 'Carol', 1)",
        },
        .statement = "WITH active_users AS (SELECT id, name FROM cte_users WHERE active = 1) SELECT id, name FROM active_users ORDER BY id",
        .expected = "1|Alice\n3|Carol\n",
    },
    .{
        .name = "cte_chained_steps",
        .setup = &.{
            "CREATE TABLE cte_orders (id INTEGER, customer TEXT, amount INTEGER)",
            "INSERT INTO cte_orders VALUES (1, 'alice', 10)",
            "INSERT INTO cte_orders VALUES (2, 'bob', 20)",
            "INSERT INTO cte_orders VALUES (3, 'carol', 30)",
        },
        .statement = "WITH large_orders AS (SELECT id, customer, amount FROM cte_orders WHERE amount >= 20), named_orders AS (SELECT id, customer FROM large_orders WHERE id >= 2) SELECT id, customer FROM named_orders ORDER BY id",
        .expected = "2|bob\n3|carol\n",
    },
    .{
        .name = "cte_explicit_column_aliases",
        .setup = &.{
            "CREATE TABLE cte_alias_source (id INTEGER, name TEXT)",
            "INSERT INTO cte_alias_source VALUES (1, 'Alice')",
            "INSERT INTO cte_alias_source VALUES (2, 'Bob')",
        },
        .statement = "WITH renamed(user_id, label) AS (SELECT id, name FROM cte_alias_source) SELECT user_id, label FROM renamed ORDER BY user_id",
        .expected = "1|Alice\n2|Bob\n",
    },
    .{
        .name = "insert_returning",
        .setup = &.{
            "CREATE TABLE returning_test (id INTEGER PRIMARY KEY, name TEXT)",
        },
        .statement = "INSERT INTO returning_test (id, name) VALUES (1, 'created') RETURNING id, name",
        .expected = "1|created\n",
    },
    .{
        .name = "insert_returning_star_defaults",
        .setup = &.{
            "CREATE TABLE returning_defaults (id INTEGER DEFAULT 7, name TEXT DEFAULT 'anon')",
        },
        .statement = "INSERT INTO returning_defaults DEFAULT VALUES RETURNING *",
        .expected = "7|anon\n",
    },
    .{
        .name = "update_returning",
        .setup = &.{
            "CREATE TABLE update_test (id INTEGER PRIMARY KEY, name TEXT)",
            "INSERT INTO update_test VALUES (1, 'old')",
        },
        .statement = "UPDATE update_test SET name = 'new' WHERE id = 1 RETURNING id, name",
        .expected = "1|new\n",
    },
    .{
        .name = "update_returning_multiple_rows",
        .setup = &.{
            "CREATE TABLE update_many (id INTEGER PRIMARY KEY, name TEXT)",
            "INSERT INTO update_many VALUES (1, 'old')",
            "INSERT INTO update_many VALUES (2, 'stale')",
        },
        .statement = "UPDATE update_many SET name = 'done' WHERE id >= 1 RETURNING id, name",
        .expected = "1|done\n2|done\n",
    },
    .{
        .name = "delete_returning",
        .setup = &.{
            "CREATE TABLE delete_test (id INTEGER PRIMARY KEY, name TEXT)",
            "INSERT INTO delete_test VALUES (1, 'gone')",
        },
        .statement = "DELETE FROM delete_test WHERE id = 1 RETURNING id, name",
        .expected = "1|gone\n",
    },
    .{
        .name = "delete_returning_multiple_rows",
        .setup = &.{
            "CREATE TABLE delete_many (id INTEGER PRIMARY KEY, name TEXT)",
            "INSERT INTO delete_many VALUES (1, 'first')",
            "INSERT INTO delete_many VALUES (2, 'second')",
        },
        .statement = "DELETE FROM delete_many WHERE id >= 1 RETURNING id, name",
        .expected = "1|first\n2|second\n",
    },
    .{
        .name = "upsert_update_returning",
        .setup = &.{
            "CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)",
            "INSERT INTO kv VALUES ('a', 'old')",
        },
        .statement = "INSERT INTO kv (k, v) VALUES ('a', 'new') ON CONFLICT(k) DO UPDATE SET v = 'updated' RETURNING k, v",
        .expected = "a|updated\n",
    },
    .{
        .name = "upsert_do_nothing_insert_returning",
        .setup = &.{
            "CREATE TABLE kv_insert (k TEXT PRIMARY KEY, v TEXT)",
        },
        .statement = "INSERT INTO kv_insert (k, v) VALUES ('a', 'new') ON CONFLICT(k) DO NOTHING RETURNING k, v",
        .expected = "a|new\n",
    },
    .{
        .name = "upsert_do_nothing_conflict_returning",
        .setup = &.{
            "CREATE TABLE kv_ignore (k TEXT PRIMARY KEY, v TEXT)",
            "INSERT INTO kv_ignore VALUES ('a', 'old')",
        },
        .statement = "INSERT INTO kv_ignore (k, v) VALUES ('a', 'new') ON CONFLICT(k) DO NOTHING RETURNING k, v",
        .expected = "",
    },
    .{
        .name = "upsert_excluded_update_returning",
        .setup = &.{
            "CREATE TABLE kv_excluded (k TEXT PRIMARY KEY, v TEXT, status TEXT)",
            "INSERT INTO kv_excluded VALUES ('a', 'old', 'stale')",
        },
        .statement = "INSERT INTO kv_excluded (k, v, status) VALUES ('a', 'new', 'fresh') ON CONFLICT(k) DO UPDATE SET v = excluded.v, status = excluded.status RETURNING k, v, status",
        .expected = "a|new|fresh\n",
    },
    .{
        .name = "collate_nocase_order",
        .setup = &.{
            "CREATE TABLE collated_names (id INTEGER, name TEXT)",
            "INSERT INTO collated_names VALUES (1, 'alice')",
            "INSERT INTO collated_names VALUES (2, 'Bob')",
        },
        .statement = "SELECT id FROM collated_names ORDER BY name COLLATE NOCASE",
        .expected = "1\n2\n",
    },
    .{
        .name = "window_last_value_current_row_frame",
        .setup = &.{
            "CREATE TABLE frame_scores (id INTEGER, score INTEGER)",
            "INSERT INTO frame_scores VALUES (1, 10)",
            "INSERT INTO frame_scores VALUES (2, 20)",
            "INSERT INTO frame_scores VALUES (3, 30)",
        },
        .statement = "SELECT id, LAST_VALUE(score) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM frame_scores ORDER BY id",
        .expected = "1|10\n2|20\n3|30\n",
    },
    .{
        .name = "window_last_value_unbounded_following_frame",
        .setup = &.{
            "CREATE TABLE frame_scores_full (id INTEGER, score INTEGER)",
            "INSERT INTO frame_scores_full VALUES (1, 10)",
            "INSERT INTO frame_scores_full VALUES (2, 20)",
            "INSERT INTO frame_scores_full VALUES (3, 30)",
        },
        .statement = "SELECT id, LAST_VALUE(score) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM frame_scores_full ORDER BY id",
        .expected = "1|30\n2|30\n3|30\n",
    },
    .{
        .name = "window_nth_value_following_frame",
        .setup = &.{
            "CREATE TABLE frame_scores_next (id INTEGER, score INTEGER)",
            "INSERT INTO frame_scores_next VALUES (1, 10)",
            "INSERT INTO frame_scores_next VALUES (2, 20)",
            "INSERT INTO frame_scores_next VALUES (3, 30)",
        },
        .statement = "SELECT id, NTH_VALUE(score, 2) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING) FROM frame_scores_next ORDER BY id",
        .expected = "1|20\n2|30\n3|NULL\n",
    },
    .{
        .name = "generated_column_insert_select",
        .setup = &.{
            "CREATE TABLE generated_items (qty INTEGER, unit_price INTEGER, total INTEGER GENERATED ALWAYS AS (qty * unit_price) STORED)",
            "INSERT INTO generated_items (qty, unit_price) VALUES (3, 7)",
        },
        .statement = "SELECT qty, unit_price, total FROM generated_items",
        .expected = "3|7|21\n",
    },
    .{
        .name = "generated_column_update_recomputes",
        .setup = &.{
            "CREATE TABLE generated_updates (qty INTEGER, unit_price INTEGER, total INTEGER GENERATED ALWAYS AS (qty * unit_price) STORED)",
            "INSERT INTO generated_updates (qty, unit_price) VALUES (2, 5)",
            "UPDATE generated_updates SET qty = 4 WHERE unit_price = 5",
        },
        .statement = "SELECT qty, unit_price, total FROM generated_updates",
        .expected = "4|5|20\n",
    },
    .{
        .name = "generated_column_insert_values_skips_generated",
        .setup = &.{
            "CREATE TABLE generated_values (qty INTEGER, unit_price INTEGER, total INTEGER GENERATED ALWAYS AS (qty * unit_price) STORED)",
            "INSERT INTO generated_values VALUES (6, 8)",
        },
        .statement = "SELECT qty, unit_price, total FROM generated_values",
        .expected = "6|8|48\n",
    },
    .{
        .name = "partial_unique_index_allows_outside_predicate",
        .setup = &.{
            "CREATE TABLE partial_unique_items (sku TEXT, active INTEGER)",
            "CREATE UNIQUE INDEX idx_partial_unique_active ON partial_unique_items (sku) WHERE active = 1",
            "INSERT INTO partial_unique_items VALUES ('A', 1)",
            "INSERT INTO partial_unique_items VALUES ('A', 0)",
        },
        .statement = "SELECT sku, active FROM partial_unique_items",
        .expected = "A|1\nA|0\n",
    },
    .{
        .name = "expression_unique_index_accepts_distinct_expressions",
        .setup = &.{
            "CREATE TABLE expression_unique_items (a INTEGER, b INTEGER)",
            "CREATE UNIQUE INDEX idx_expression_unique_sum ON expression_unique_items ((a + b))",
            "INSERT INTO expression_unique_items VALUES (1, 2)",
            "INSERT INTO expression_unique_items VALUES (1, 3)",
        },
        .statement = "SELECT a, b FROM expression_unique_items ORDER BY b",
        .expected = "1|2\n1|3\n",
    },
    .{
        .name = "json_valid_and_invalid",
        .setup = &.{
            "CREATE TABLE json_seed_valid (id INTEGER)",
            "INSERT INTO json_seed_valid VALUES (1)",
        },
        .statement = "SELECT json_valid('{\"a\":1}'), json_valid('{bad') FROM json_seed_valid",
        .expected = "1|0\n",
    },
    .{
        .name = "json_extract_scalar_and_type",
        .setup = &.{
            "CREATE TABLE json_seed_extract (id INTEGER)",
            "INSERT INTO json_seed_extract VALUES (1)",
        },
        .statement = "SELECT json_extract('{\"name\":\"Ada\",\"count\":3}', '$.name'), json_type('{\"name\":\"Ada\",\"count\":3}', '$.count') FROM json_seed_extract",
        .expected = "Ada|integer\n",
    },
    .{
        .name = "json_extract_array_object_and_length",
        .setup = &.{
            "CREATE TABLE json_seed_array (id INTEGER)",
            "INSERT INTO json_seed_array VALUES (1)",
        },
        .statement = "SELECT json_extract('{\"items\":[1,2,3]}', '$.items[1]'), json_array_length('{\"items\":[1,2,3]}', '$.items') FROM json_seed_array",
        .expected = "2|3\n",
    },
    .{
        .name = "json_column_extract_and_missing_path",
        .setup = &.{
            "CREATE TABLE json_docs (id INTEGER, payload TEXT)",
            "INSERT INTO json_docs VALUES (1, '{\"kind\":\"event\",\"meta\":{\"count\":2}}')",
        },
        .statement = "SELECT json_extract(payload, '$.kind'), json_extract(payload, '$.missing') FROM json_docs",
        .expected = "event|NULL\n",
    },
    .{
        .name = "json_object_constructs_canonical_object",
        .setup = &.{
            "CREATE TABLE json_seed_object (id INTEGER)",
            "INSERT INTO json_seed_object VALUES (1)",
        },
        .statement = "SELECT json_object('id', 7, 'name', 'Ada', 'active', 1) FROM json_seed_object",
        .expected = "{\"id\":7,\"name\":\"Ada\",\"active\":1}\n",
    },
    .{
        .name = "datetime_formats_unixepoch_accurately",
        .setup = &.{
            "CREATE TABLE time_seed_epoch (id INTEGER)",
            "INSERT INTO time_seed_epoch VALUES (1)",
        },
        .statement = "SELECT datetime(0), date(0), time(0) FROM time_seed_epoch",
        .expected = "1970-01-01 00:00:00|1970-01-01|00:00:00\n",
    },
    .{
        .name = "datetime_parses_iso_and_leap_day",
        .setup = &.{
            "CREATE TABLE time_seed_leap (id INTEGER)",
            "INSERT INTO time_seed_leap VALUES (1)",
        },
        .statement = "SELECT unixepoch('2024-02-29 12:34:56'), date('2024-02-29 12:34:56') FROM time_seed_leap",
        .expected = "1709210096|2024-02-29\n",
    },
    .{
        .name = "datetime_applies_day_and_hour_modifiers",
        .setup = &.{
            "CREATE TABLE time_seed_modifiers (id INTEGER)",
            "INSERT INTO time_seed_modifiers VALUES (1)",
        },
        .statement = "SELECT datetime('2024-02-28 23:30:00', '+1 day', '+2 hours') FROM time_seed_modifiers",
        .expected = "2024-03-01 01:30:00\n",
    },
    .{
        .name = "strftime_applies_modifiers",
        .setup = &.{
            "CREATE TABLE time_seed_strftime (id INTEGER)",
            "INSERT INTO time_seed_strftime VALUES (1)",
        },
        .statement = "SELECT strftime('%Y-%m-%d', '2024-01-31 23:59:00', '+1 day') FROM time_seed_strftime",
        .expected = "2024-02-01\n",
    },
    .{
        .name = "time_start_of_day_and_seconds_modifier",
        .setup = &.{
            "CREATE TABLE time_seed_start_day (id INTEGER)",
            "INSERT INTO time_seed_start_day VALUES (1)",
        },
        .statement = "SELECT datetime('2024-06-01 12:34:56', 'start of day', '+90 seconds') FROM time_seed_start_day",
        .expected = "2024-06-01 00:01:30\n",
    },
    .{
        .name = "analyze_populates_planner_stats",
        .setup = &.{
            "CREATE TABLE analyze_stats (sku TEXT, qty INTEGER)",
            "INSERT INTO analyze_stats VALUES ('A', 1)",
            "INSERT INTO analyze_stats VALUES ('A', 2)",
            "INSERT INTO analyze_stats VALUES ('B', 3)",
            "CREATE INDEX idx_analyze_sku ON analyze_stats (sku)",
            "ANALYZE analyze_stats",
        },
        .statement = "PRAGMA planner_stats",
        .expected = "table|analyze_stats||3|3|0|2\nindex|idx_analyze_sku|analyze_stats|3|2|0|sku\n",
    },
    .{
        .name = "planner_uses_analyzed_unique_index_for_equality",
        .setup = &.{
            "CREATE TABLE planner_choice (id INTEGER, name TEXT)",
            "INSERT INTO planner_choice VALUES (1, 'one')",
            "INSERT INTO planner_choice VALUES (2, 'two')",
            "INSERT INTO planner_choice VALUES (3, 'three')",
            "CREATE UNIQUE INDEX idx_planner_choice_id ON planner_choice (id)",
            "ANALYZE planner_choice",
        },
        .statement = "EXPLAIN QUERY PLAN SELECT name FROM planner_choice WHERE id = 3",
        .expected = "0|0|0|INDEX SCAN planner_choice.id USING idx_planner_choice_id rows=1 cost=1\n1|0|0|FILTER\n2|0|0|PROJECT\n",
    },
    .{
        .name = "analyzed_unique_index_lookup_returns_matching_row",
        .setup = &.{
            "CREATE TABLE planner_lookup (id INTEGER, name TEXT)",
            "INSERT INTO planner_lookup VALUES (1, 'one')",
            "INSERT INTO planner_lookup VALUES (2, 'two')",
            "INSERT INTO planner_lookup VALUES (3, 'three')",
            "CREATE UNIQUE INDEX idx_planner_lookup_id ON planner_lookup (id)",
            "ANALYZE planner_lookup",
        },
        .statement = "SELECT name FROM planner_lookup WHERE id = 3",
        .expected = "three\n",
    },
    .{
        .name = "postgres_style_identifier_keyword_column",
        .setup = &.{
            "CREATE TABLE pg_identifiers (id INTEGER, count INTEGER)",
            "INSERT INTO pg_identifiers VALUES (1, 42)",
        },
        .statement = "SELECT count FROM pg_identifiers WHERE id = 1",
        .expected = "42\n",
    },
    .{
        .name = "postgres_style_literals_escape_numeric_null",
        .setup = &.{
            "CREATE TABLE pg_literals (id INTEGER, note TEXT, amount REAL, marker TEXT)",
            "INSERT INTO pg_literals VALUES (1, 'it''s quoted', 3.5, NULL)",
            "INSERT INTO pg_literals VALUES (2, 'other', 4.5, 'x')",
        },
        .statement = "SELECT id, note, amount, marker FROM pg_literals WHERE note = 'it''s quoted' AND amount = 3.5 AND marker IS NULL",
        .expected = "1|it's quoted|3.5|NULL\n",
    },
    .{
        .name = "postgres_style_transaction_commit_rollback",
        .setup = &.{
            "CREATE TABLE pg_transactions (id INTEGER, label TEXT)",
            "BEGIN",
            "INSERT INTO pg_transactions VALUES (1, 'rolled-back')",
            "ROLLBACK",
            "BEGIN",
            "INSERT INTO pg_transactions VALUES (2, 'committed')",
            "COMMIT",
        },
        .statement = "SELECT id, label FROM pg_transactions ORDER BY id",
        .expected = "2|committed\n",
    },
    .{
        .name = "postgres_style_json_expression_predicate",
        .setup = &.{
            "CREATE TABLE pg_json_exprs (id INTEGER, payload TEXT)",
            "INSERT INTO pg_json_exprs VALUES (1, '{\"sku\":\"A1\",\"qty\":2}')",
            "INSERT INTO pg_json_exprs VALUES (2, '{\"sku\":\"B2\",\"qty\":5}')",
        },
        .statement = "SELECT id, json_extract(payload, '$.sku'), json_extract(payload, '$.qty') FROM pg_json_exprs ORDER BY id",
        .expected = "1|A1|2\n2|B2|5\n",
    },
    .{
        .name = "postgres_style_datetime_expression_predicate",
        .setup = &.{
            "CREATE TABLE pg_time_exprs (id INTEGER)",
            "INSERT INTO pg_time_exprs VALUES (1)",
        },
        .statement = "SELECT id, datetime('2024-02-28 23:00:00', '+1 day') FROM pg_time_exprs",
        .expected = "1|2024-02-29 23:00:00\n",
    },
};

const error_cases = [_]ErrorCase{
    .{
        .name = "cte_nested_unsupported",
        .setup = &.{
            "CREATE TABLE cte_seed (id INTEGER)",
            "INSERT INTO cte_seed VALUES (1)",
        },
        .statement = "WITH outer_cte AS (WITH inner_cte AS (SELECT id FROM cte_seed) SELECT id FROM inner_cte) SELECT id FROM outer_cte",
    },
    .{
        .name = "cte_recursive_self_reference_unsupported",
        .setup = &.{},
        .statement = "WITH RECURSIVE nums AS (SELECT id FROM nums) SELECT id FROM nums",
    },
    .{
        .name = "generated_column_direct_insert_rejected",
        .setup = &.{
            "CREATE TABLE generated_reject_insert (qty INTEGER, unit_price INTEGER, total INTEGER GENERATED ALWAYS AS (qty * unit_price) STORED)",
        },
        .statement = "INSERT INTO generated_reject_insert (qty, unit_price, total) VALUES (1, 2, 99)",
    },
    .{
        .name = "generated_column_direct_update_rejected",
        .setup = &.{
            "CREATE TABLE generated_reject_update (qty INTEGER, unit_price INTEGER, total INTEGER GENERATED ALWAYS AS (qty * unit_price) STORED)",
            "INSERT INTO generated_reject_update (qty, unit_price) VALUES (1, 2)",
        },
        .statement = "UPDATE generated_reject_update SET total = 99",
    },
    .{
        .name = "partial_unique_index_rejects_inside_predicate_duplicate",
        .setup = &.{
            "CREATE TABLE partial_unique_reject (sku TEXT, active INTEGER)",
            "CREATE UNIQUE INDEX idx_partial_unique_reject_active ON partial_unique_reject (sku) WHERE active = 1",
            "INSERT INTO partial_unique_reject VALUES ('A', 1)",
        },
        .statement = "INSERT INTO partial_unique_reject VALUES ('A', 1)",
    },
    .{
        .name = "expression_unique_index_rejects_duplicate_expression",
        .setup = &.{
            "CREATE TABLE expression_unique_reject (a INTEGER, b INTEGER)",
            "CREATE UNIQUE INDEX idx_expression_unique_reject_sum ON expression_unique_reject ((a + b))",
            "INSERT INTO expression_unique_reject VALUES (1, 2)",
        },
        .statement = "INSERT INTO expression_unique_reject VALUES (2, 1)",
    },
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== SQL Statement Conformance Tests ===", .{});
    for (cases) |case| {
        const output = try runCase(allocator, case);
        defer allocator.free(output);
        try std.testing.expectEqualStrings(case.expected, output);
        std.log.info("[PASS] {s}", .{case.name});
    }
    for (error_cases) |case| {
        try runErrorCase(allocator, case);
        std.log.info("[PASS] {s}", .{case.name});
    }
    try runScalarUdfCase(allocator);
    std.log.info("[PASS] user_defined_scalar_function", .{});
    try runAggregateUdfCase(allocator);
    std.log.info("[PASS] user_defined_aggregate_function", .{});
    try runPostgresStyleParameterCase(allocator);
    std.log.info("[PASS] postgres_style_parameter_binding", .{});
    try runPostgresStyleErrorCategoryCase();
    std.log.info("[PASS] postgres_style_error_categories", .{});
    try runResourceLimitCases(allocator);
    std.log.info("[PASS] resource_limits_and_progress_callbacks", .{});
    try runSchemaQualifiedAttachCase(allocator);
    std.log.info("[PASS] schema_qualified_attached_database_ddl_dml", .{});
    try runSchemaVersionAndMigrationCase(allocator);
    std.log.info("[PASS] schema_versions_and_migration_api", .{});
    std.log.info("=== ALL SQL STATEMENT CONFORMANCE TESTS PASSED ===", .{});
}

fn runScalarUdfCase(allocator: std.mem.Allocator) !void {
    var conn = try zqlite.openMemory(allocator);
    defer conn.close();

    try conn.registerScalarFunction("twice", twice);
    try conn.execute("CREATE TABLE udf_scalar_values (id INTEGER, value INTEGER)");
    try conn.execute("INSERT INTO udf_scalar_values VALUES (1, 7)");
    try conn.execute("INSERT INTO udf_scalar_values VALUES (2, 11)");

    var result = try conn.query("SELECT id, twice(value) FROM udf_scalar_values ORDER BY id");
    defer result.deinit();

    const output = try executionResultToString(allocator, &result);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("1|14\n2|22\n", output);
}

fn runAggregateUdfCase(allocator: std.mem.Allocator) !void {
    var conn = try zqlite.openMemory(allocator);
    defer conn.close();

    try conn.registerAggregateFunction("range_width", rangeWidth);
    try conn.execute("CREATE TABLE udf_aggregate_values (bucket TEXT, value INTEGER)");
    try conn.execute("INSERT INTO udf_aggregate_values VALUES ('a', 3)");
    try conn.execute("INSERT INTO udf_aggregate_values VALUES ('a', 10)");
    try conn.execute("INSERT INTO udf_aggregate_values VALUES ('b', 8)");
    try conn.execute("INSERT INTO udf_aggregate_values VALUES ('b', 9)");

    var result = try conn.query("SELECT bucket, range_width(value) FROM udf_aggregate_values GROUP BY bucket ORDER BY bucket");
    defer result.deinit();

    const output = try executionResultToString(allocator, &result);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("a|7\nb|1\n", output);
}

fn twice(_: std.mem.Allocator, arguments: []const Value) anyerror!Value {
    if (arguments.len != 1) return error.InvalidArgumentCount;
    return switch (arguments[0]) {
        .Integer => |value| Value{ .Integer = value * 2 },
        .Null => Value.Null,
        else => error.InvalidArgumentType,
    };
}

fn rangeWidth(_: std.mem.Allocator, values: []const Value) anyerror!Value {
    var min_value: ?i64 = null;
    var max_value: ?i64 = null;

    for (values) |value| {
        if (value != .Integer) continue;
        const current = value.Integer;
        if (min_value == null or current < min_value.?) min_value = current;
        if (max_value == null or current > max_value.?) max_value = current;
    }

    if (min_value == null or max_value == null) return Value.Null;
    return Value{ .Integer = max_value.? - min_value.? };
}

fn runPostgresStyleParameterCase(allocator: std.mem.Allocator) !void {
    var conn = try zqlite.openMemory(allocator);
    defer conn.close();

    try conn.execute("CREATE TABLE pg_params (id INTEGER, name TEXT, tag TEXT)");

    var insert = try conn.prepare("INSERT INTO pg_params VALUES (:id, @name, $tag)");
    defer insert.deinit();
    try insert.bindNamed(":id", @as(i64, 7));
    try insert.bindNamed("name", "Ada");
    try insert.bindNamed("$tag", "engineer");
    var insert_result = try insert.execute();
    defer insert_result.deinit();

    var repeated = try conn.prepare("SELECT id, name, tag FROM pg_params WHERE id = :id OR id = :id");
    defer repeated.deinit();
    try repeated.bindNamed("id", @as(i64, 7));
    var result = try repeated.execute();
    defer result.deinit();

    const output = try executionResultToString(allocator, &result);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("7|Ada|engineer\n", output);
}

fn runPostgresStyleErrorCategoryCase() !void {
    try std.testing.expectEqual(zqlite.ErrorCategory.sql, zqlite.categorizeError(error.TableNotFound));
    try std.testing.expectEqual(zqlite.ErrorCategory.constraint, zqlite.categorizeError(error.UniqueConstraintViolation));
    try std.testing.expectEqual(zqlite.ErrorCategory.misuse, zqlite.categorizeError(error.NamedParameterNotFound));
    try std.testing.expectEqual(zqlite.ErrorCategory.format, zqlite.categorizeError(error.CorruptData));
    try std.testing.expectEqual(zqlite.ErrorCategory.format, zqlite.categorizeError(error.CorruptCatalog));
    try std.testing.expectEqual(zqlite.ErrorCategory.format, zqlite.categorizeError(error.UnsupportedDatabaseFormat));
    try std.testing.expectEqual(zqlite.ErrorCategory.io, zqlite.categorizeError(error.ReadOnlyDatabase));
    try std.testing.expectEqual(zqlite.ErrorCategory.authorization, zqlite.categorizeError(error.PathNotInAllowedRoots));
}

const ProgressContext = struct {
    calls: u32 = 0,
};

fn cancelAfterFirstProgress(context: ?*anyopaque, event: zqlite.ProgressEvent) bool {
    const ctx: *ProgressContext = @ptrCast(@alignCast(context.?));
    ctx.calls += 1;
    _ = event;
    return false;
}

fn runResourceLimitCases(allocator: std.mem.Allocator) !void {
    {
        var conn = try zqlite.openMemoryWithOptions(allocator, .{
            .resource_limits = .{ .max_result_rows = 2 },
        });
        defer conn.close();

        try conn.execute("CREATE TABLE limit_rows (id INTEGER)");
        try conn.execute("INSERT INTO limit_rows VALUES (1)");
        try conn.execute("INSERT INTO limit_rows VALUES (2)");
        try conn.execute("INSERT INTO limit_rows VALUES (3)");
        try std.testing.expectError(error.ResourceLimitExceeded, conn.query("SELECT id FROM limit_rows ORDER BY id"));
    }

    {
        var conn = try zqlite.openMemoryWithOptions(allocator, .{
            .resource_limits = .{ .max_scanned_rows = 2 },
        });
        defer conn.close();

        try conn.execute("CREATE TABLE scan_limit (id INTEGER)");
        try conn.execute("INSERT INTO scan_limit VALUES (1)");
        try conn.execute("INSERT INTO scan_limit VALUES (2)");
        try conn.execute("INSERT INTO scan_limit VALUES (3)");
        try std.testing.expectError(error.ResourceLimitExceeded, conn.query("SELECT id FROM scan_limit WHERE id > 0"));
    }

    {
        var conn = try zqlite.openMemoryWithOptions(allocator, .{
            .resource_limits = .{ .max_affected_rows = 1 },
        });
        defer conn.close();

        try conn.execute("CREATE TABLE affected_limit (id INTEGER)");
        try conn.execute("INSERT INTO affected_limit VALUES (1)");
        try std.testing.expectError(error.ResourceLimitExceeded, conn.execute("INSERT INTO affected_limit VALUES (2), (3)"));
    }

    {
        var conn = try zqlite.openMemoryWithOptions(allocator, .{
            .resource_limits = .{ .max_statement_bytes = 12 },
        });
        defer conn.close();

        try std.testing.expectError(error.ResourceLimitExceeded, conn.execute("CREATE TABLE statement_limit (id INTEGER)"));
    }

    {
        var conn = try zqlite.openMemoryWithOptions(allocator, .{
            .resource_limits = .{ .max_vm_steps = 1 },
        });
        defer conn.close();

        try conn.execute("CREATE TABLE vm_step_limit (id INTEGER)");
        try std.testing.expectError(error.ResourceLimitExceeded, conn.query("SELECT id FROM vm_step_limit"));
    }

    {
        var conn = try zqlite.openMemoryWithOptions(allocator, .{
            .resource_limits = .{ .max_memory_bytes = 1 },
        });
        defer conn.close();

        try conn.execute("CREATE TABLE memory_limit (id INTEGER)");
        try conn.execute("INSERT INTO memory_limit VALUES (1)");
        try std.testing.expectError(error.ResourceLimitExceeded, conn.query("SELECT id FROM memory_limit"));
    }

    {
        var conn = try zqlite.openMemoryWithOptions(allocator, .{
            .resource_limits = .{ .max_page_count = 1 },
        });
        defer conn.close();

        try conn.execute("CREATE TABLE page_limit_one (id INTEGER)");
        try std.testing.expectError(error.ResourceLimitExceeded, conn.execute("CREATE TABLE page_limit_two (id INTEGER)"));
    }

    {
        var conn = try zqlite.openMemory(allocator);
        defer conn.close();

        try conn.execute("CREATE TABLE runtime_limit (id INTEGER)");
        try std.testing.expectError(error.ResourceLimitExceeded, conn.configureResourceLimits(.{ .max_page_count = 0 }));
        try conn.configureResourceLimits(.{ .max_cache_pages = 1 });
        try std.testing.expectEqual(@as(?u32, 1), conn.getResourceLimits().max_cache_pages);
    }

    {
        var ctx = ProgressContext{};
        var conn = try zqlite.openMemoryWithOptions(allocator, .{
            .resource_limits = .{ .progress_interval_ops = 1 },
            .progress_callback = cancelAfterFirstProgress,
            .progress_context = &ctx,
        });
        defer conn.close();

        try std.testing.expectError(error.Interrupted, conn.execute("CREATE TABLE progress_cancel (id INTEGER)"));
        try std.testing.expect(ctx.calls > 0);
    }
}

fn runSchemaQualifiedAttachCase(allocator: std.mem.Allocator) !void {
    var conn = try zqlite.openMemoryWithOptions(allocator, .{ .secure_mode = true });
    defer conn.close();

    try conn.execute("ATTACH DATABASE ':memory:' AS scratch");
    try conn.execute("CREATE TABLE scratch.audit (id INTEGER, event TEXT UNIQUE)");
    try conn.execute("CREATE INDEX scratch.idx_scratch_audit_event ON scratch.audit (event)");
    try conn.execute("INSERT INTO scratch.audit VALUES (1, 'login')");

    {
        var result = try conn.query("SELECT event FROM scratch.audit WHERE id = 1");
        defer result.deinit();

        const output = try executionResultToString(allocator, &result);
        defer allocator.free(output);
        try std.testing.expectEqualStrings("login\n", output);
    }

    try conn.execute("UPDATE scratch.audit SET event = 'logout' WHERE id = 1");

    {
        var result = try conn.query("SELECT event FROM scratch.audit WHERE id = 1");
        defer result.deinit();

        const output = try executionResultToString(allocator, &result);
        defer allocator.free(output);
        try std.testing.expectEqualStrings("logout\n", output);
    }

    try conn.execute("DELETE FROM scratch.audit WHERE id = 1");

    {
        var result = try conn.query("SELECT id FROM scratch.audit");
        defer result.deinit();

        const output = try executionResultToString(allocator, &result);
        defer allocator.free(output);
        try std.testing.expectEqualStrings("", output);
    }

    try conn.execute("DROP INDEX scratch.idx_scratch_audit_event");
    try std.testing.expectError(error.IndexNotFound, conn.execute("DROP INDEX scratch.idx_scratch_audit_event"));
    try conn.execute("DROP TABLE scratch.audit");
    try std.testing.expectError(error.TableNotFound, conn.query("SELECT * FROM scratch.audit"));
    try std.testing.expectError(error.SchemaNotFound, conn.execute("CREATE TABLE missing_schema.t (id INTEGER)"));
}

fn runSchemaVersionAndMigrationCase(allocator: std.mem.Allocator) !void {
    var conn = try zqlite.openMemoryWithOptions(allocator, .{ .plan_cache_entries = 0 });
    defer conn.close();

    try std.testing.expectEqual(@as(u32, 0), conn.getUserVersion());
    try std.testing.expectEqual(@as(u32, 0), conn.getSchemaVersion());

    try conn.setUserVersion(3);
    try std.testing.expectEqual(@as(u32, 3), conn.getUserVersion());

    {
        var result = try conn.query("PRAGMA user_version");
        defer result.deinit();
        try std.testing.expectEqual(@as(i64, 3), result.rows.items[0].values[0].Integer);
    }

    {
        var result = try conn.query("PRAGMA user_version = 4");
        defer result.deinit();
        try std.testing.expectEqual(@as(i64, 4), result.rows.items[0].values[0].Integer);
    }

    try conn.execute("CREATE TABLE versioned (id INTEGER)");
    const schema_after_create = conn.getSchemaVersion();
    try std.testing.expect(schema_after_create > 0);

    {
        var result = try conn.query("PRAGMA schema_version");
        defer result.deinit();
        try std.testing.expectEqual(@as(i64, @intCast(schema_after_create)), result.rows.items[0].values[0].Integer);
    }

    const migrations = [_]zqlite.migration.Migration{
        zqlite.migration.createMigration(5, "add_accounts", "CREATE TABLE migration_accounts (id INTEGER)", "DROP TABLE migration_accounts"),
        zqlite.migration.createMigration(6, "bad_followup", "INSERT INTO missing_migration_table VALUES (1)", ""),
    };
    var manager = zqlite.migration.MigrationManager.init(allocator, conn, &migrations);
    try std.testing.expect(try manager.validateMigrations());
    try std.testing.expectError(error.TableNotFound, manager.runMigrations());
    try std.testing.expectEqual(@as(u32, 5), conn.getUserVersion());

    try manager.rollbackTo(4);
    try std.testing.expectEqual(@as(u32, 4), conn.getUserVersion());
    try std.testing.expectError(error.TableNotFound, conn.query("SELECT * FROM migration_accounts"));
}

fn runCase(allocator: std.mem.Allocator, case: TestCase) ![]u8 {
    var conn = try zqlite.openMemory(allocator);
    defer conn.close();

    for (case.setup) |stmt| try conn.execute(stmt);

    var result = try conn.query(case.statement);
    defer result.deinit();

    return executionResultToString(allocator, &result);
}

fn executionResultToString(allocator: std.mem.Allocator, result: anytype) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    for (result.rows.items) |row| {
        for (row.values, 0..) |value, i| {
            if (i > 0) try output.append(allocator, '|');
            try appendValue(allocator, &output, value);
        }
        try output.append(allocator, '\n');
    }

    return output.toOwnedSlice(allocator);
}

fn runErrorCase(allocator: std.mem.Allocator, case: ErrorCase) !void {
    var conn = try zqlite.openMemory(allocator);
    defer conn.close();

    for (case.setup) |stmt| try conn.execute(stmt);

    if (conn.query(case.statement)) |result| {
        var mutable_result = result;
        mutable_result.deinit();
        return error.ExpectedStatementFailure;
    } else |_| {}
}

fn appendValue(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), value: Value) !void {
    switch (value) {
        .Null => try output.appendSlice(allocator, "NULL"),
        .Integer => |v| try appendFmt(allocator, output, "{d}", .{v}),
        .Real => |v| try appendFmt(allocator, output, "{d}", .{v}),
        .Text => |v| try output.appendSlice(allocator, v),
        .Blob => |v| try appendFmt(allocator, output, "{x}", .{v}),
        .Boolean => |v| try appendFmt(allocator, output, "{d}", .{if (v) @as(u8, 1) else 0}),
        .SmallInt => |v| try appendFmt(allocator, output, "{d}", .{v}),
        .BigInt => |v| try appendFmt(allocator, output, "{d}", .{v}),
        else => try output.appendSlice(allocator, "NULL"),
    }
}

const Value = zqlite.storage.Value;

fn appendFmt(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try output.appendSlice(allocator, formatted);
}
