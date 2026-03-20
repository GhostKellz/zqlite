const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // Build Profiles
    // ============================================================
    // core     = SQLite-like minimal (db, parser, executor)
    // advanced = PostgreSQL features (core + json, performance, concurrent)
    // full     = Everything (advanced + crypto, transport, cluster, ffi)
    const profile = b.option([]const u8, "profile", "Build profile: core, advanced, full (default: full)") orelse "full";

    // Individual feature flags (can override profile defaults)
    const enable_crypto = b.option(bool, "crypto", "Enable post-quantum crypto") orelse
        std.mem.eql(u8, profile, "full");
    const enable_transport = b.option(bool, "transport", "Enable PQ-QUIC transport") orelse
        std.mem.eql(u8, profile, "full");
    const enable_json = b.option(bool, "json", "Enable JSON support") orelse
        (std.mem.eql(u8, profile, "advanced") or std.mem.eql(u8, profile, "full"));
    const enable_performance = b.option(bool, "performance", "Enable query cache/connection pool") orelse
        (std.mem.eql(u8, profile, "advanced") or std.mem.eql(u8, profile, "full"));
    const enable_concurrent = b.option(bool, "concurrent", "Enable async operations") orelse
        (std.mem.eql(u8, profile, "advanced") or std.mem.eql(u8, profile, "full"));
    const enable_ffi = b.option(bool, "ffi", "Enable C API") orelse
        std.mem.eql(u8, profile, "full");

    // Build metadata options
    const build_options = b.addOptions();

    // Add feature flags to build options
    build_options.addOption([]const u8, "profile", profile);
    build_options.addOption(bool, "enable_crypto", enable_crypto);
    build_options.addOption(bool, "enable_transport", enable_transport);
    build_options.addOption(bool, "enable_json", enable_json);
    build_options.addOption(bool, "enable_performance", enable_performance);
    build_options.addOption(bool, "enable_concurrent", enable_concurrent);
    build_options.addOption(bool, "enable_ffi", enable_ffi);

    // Get Git commit hash (simplified for Zig 0.16 compatibility)
    const git_commit = "dev";

    // Get build date (simplified for Zig 0.16 compatibility)
    const build_date = "2026-01-14";

    // Build mode string
    const build_mode = switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe => "release-safe",
        .ReleaseFast => "release-fast",
        .ReleaseSmall => "release-small",
    };

    build_options.addOption([]const u8, "git_commit", git_commit);
    build_options.addOption([]const u8, "build_date", build_date);
    build_options.addOption([]const u8, "build_mode", build_mode);
    
    // Add zsync dependency for async operations
    const zsync = b.dependency("zsync", .{
        .target = target,
        .optimize = optimize,
    });
    
    // Create the zqlite library - now with only zsync dependency!
    const lib = b.addLibrary(.{
        .name = "zqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zqlite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add zsync dependency to library
    lib.root_module.addImport("zsync", zsync.module("zsync"));
    lib.root_module.addOptions("build_options", build_options);

    // Install the library
    b.installArtifact(lib);

    // Create C library for FFI (only if enabled)
    if (enable_ffi) {
        const c_lib = b.addLibrary(.{
            .name = "zqlite_c",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ffi/c_api.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        // Link the main library to the C FFI
        c_lib.root_module.addImport("zqlite", lib.root_module);
        c_lib.root_module.addImport("zsync", zsync.module("zsync"));

        // Install the C library
        b.installArtifact(c_lib);
    }

    // Export the zqlite module for use by other packages
    const zqlite_module = b.addModule("zqlite", .{
        .root_source_file = b.path("src/zqlite.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add dependencies to exported module
    zqlite_module.addImport("zsync", zsync.module("zsync"));
    zqlite_module.addOptions("build_options", build_options);

    // Create the zqlite executable
    const exe = b.addExecutable(.{
        .name = "zqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link the library to the executable
    exe.root_module.addImport("zqlite", lib.root_module);
    exe.root_module.addImport("zsync", zsync.module("zsync"));
    exe.root_module.addOptions("build_options", build_options);

    // Install the executable
    b.installArtifact(exe);

    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Create test step
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zqlite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add dependencies to tests
    lib_unit_tests.root_module.addImport("zsync", zsync.module("zsync"));
    lib_unit_tests.root_module.addOptions("build_options", build_options);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe_unit_tests.root_module.addImport("zqlite", lib.root_module);
    exe_unit_tests.root_module.addImport("zsync", zsync.module("zsync"));
    exe_unit_tests.root_module.addOptions("build_options", build_options);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Add comprehensive test runner
    const test_runner = b.addExecutable(.{
        .name = "test_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    test_runner.root_module.addImport("zqlite", lib.root_module);
    test_runner.root_module.addImport("zsync", zsync.module("zsync"));
    test_runner.root_module.addOptions("build_options", build_options);

    const run_test_runner = b.addRunArtifact(test_runner);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    const comprehensive_test_step = b.step("test-comprehensive", "Run comprehensive test suite");
    comprehensive_test_step.dependOn(&run_test_runner.step);

    // Add quick validation test
    const validation_test = b.addExecutable(.{
        .name = "test_validation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_validation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    validation_test.root_module.addImport("zqlite", lib.root_module);
    validation_test.root_module.addImport("zsync", zsync.module("zsync"));
    validation_test.root_module.addOptions("build_options", build_options);

    const run_validation_test = b.addRunArtifact(validation_test);

    const validation_step = b.step("test-quick", "Run quick validation test");
    validation_step.dependOn(&run_validation_test.step);

    // Add intensive memory test
    const memory_test = b.addExecutable(.{
        .name = "intensive_memory_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/memory/intensive_memory_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    memory_test.root_module.addImport("zqlite", lib.root_module);
    memory_test.root_module.addImport("zsync", zsync.module("zsync"));
    memory_test.root_module.addOptions("build_options", build_options);

    const run_memory_test = b.addRunArtifact(memory_test);

    const memory_test_step = b.step("test-memory", "Run intensive memory leak detection tests");
    memory_test_step.dependOn(&run_memory_test.step);

    // Add advanced tests (stress, security, edge cases)
    const advanced_tests = b.addTest(.{
        .name = "advanced_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/advanced_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    advanced_tests.root_module.addImport("zqlite", lib.root_module);
    advanced_tests.root_module.addImport("zsync", zsync.module("zsync"));
    advanced_tests.root_module.addOptions("build_options", build_options);

    const run_advanced_tests = b.addRunArtifact(advanced_tests);

    const advanced_test_step = b.step("test-advanced", "Run advanced tests (stress, security, edge cases)");
    advanced_test_step.dependOn(&run_advanced_tests.step);

    // Add simple memory test (avoiding btree bug)
    const simple_memory_test = b.addExecutable(.{
        .name = "simple_memory_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/memory/simple_memory_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    simple_memory_test.root_module.addImport("zqlite", lib.root_module);
    simple_memory_test.root_module.addImport("zsync", zsync.module("zsync"));
    simple_memory_test.root_module.addOptions("build_options", build_options);

    const run_simple_memory_test = b.addRunArtifact(simple_memory_test);

    const simple_memory_test_step = b.step("test-memory-safe", "Run safe memory tests (avoiding btree bug)");
    simple_memory_test_step.dependOn(&run_simple_memory_test.step);

    // Add comprehensive leak detection test
    const leak_detection_test = b.addExecutable(.{
        .name = "leak_detection_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/memory/leak_detection_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    leak_detection_test.root_module.addImport("zqlite", lib.root_module);
    leak_detection_test.root_module.addImport("zsync", zsync.module("zsync"));
    leak_detection_test.root_module.addOptions("build_options", build_options);

    const run_leak_detection_test = b.addRunArtifact(leak_detection_test);

    const leak_detection_step = b.step("test-leak-detection", "Run comprehensive memory leak detection");
    leak_detection_step.dependOn(&run_leak_detection_test.step);

    // Add CREATE TABLE specific leak test (validates DEFAULT constraint fixes)
    const create_table_leak_test = b.addExecutable(.{
        .name = "create_table_leak_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/memory/create_table_leak_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    create_table_leak_test.root_module.addImport("zqlite", lib.root_module);
    create_table_leak_test.root_module.addImport("zsync", zsync.module("zsync"));
    create_table_leak_test.root_module.addOptions("build_options", build_options);

    const run_create_table_leak_test = b.addRunArtifact(create_table_leak_test);

    const create_table_leak_step = b.step("test-create-table-leaks", "Test CREATE TABLE DEFAULT constraint memory fixes");
    create_table_leak_step.dependOn(&run_create_table_leak_test.step);

    // Add dedicated memory leak detection script
    const memory_leak_test = b.addExecutable(.{
        .name = "memory_leak_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/memory/memory_leak_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    memory_leak_test.root_module.addImport("zqlite", lib.root_module);
    memory_leak_test.root_module.addImport("zsync", zsync.module("zsync"));
    memory_leak_test.root_module.addOptions("build_options", build_options);

    const run_memory_leak_test = b.addRunArtifact(memory_leak_test);

    const memory_leak_step = b.step("test-memory-leaks", "Run dedicated memory leak detection");
    memory_leak_step.dependOn(&run_memory_leak_test.step);

    // Add window function test
    const window_test = b.addExecutable(.{
        .name = "window_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/window/test_window.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    window_test.root_module.addImport("zqlite", lib.root_module);
    window_test.root_module.addImport("zsync", zsync.module("zsync"));
    window_test.root_module.addOptions("build_options", build_options);

    const run_window_test = b.addRunArtifact(window_test);

    const window_test_step = b.step("test-window", "Run window function tests");
    window_test_step.dependOn(&run_window_test.step);

    // Add comprehensive memory test (INSERT/SELECT/DELETE, JOINs, transactions, etc.)
    const comprehensive_memory_test = b.addExecutable(.{
        .name = "comprehensive_memory_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/memory/comprehensive_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    comprehensive_memory_test.root_module.addImport("zqlite", lib.root_module);
    comprehensive_memory_test.root_module.addImport("zsync", zsync.module("zsync"));
    comprehensive_memory_test.root_module.addOptions("build_options", build_options);

    const run_comprehensive_memory_test = b.addRunArtifact(comprehensive_memory_test);

    const comprehensive_memory_test_step = b.step("test-comprehensive-memory", "Run comprehensive memory tests");
    comprehensive_memory_test_step.dependOn(&run_comprehensive_memory_test.step);

    // Add SQL parser fuzzer
    const sql_parser_fuzzer = b.addExecutable(.{
        .name = "sql_parser_fuzzer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/sql_parser_fuzzer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    sql_parser_fuzzer.root_module.addImport("zqlite", lib.root_module);
    sql_parser_fuzzer.root_module.addImport("zsync", zsync.module("zsync"));
    sql_parser_fuzzer.root_module.addOptions("build_options", build_options);

    const run_sql_parser_fuzzer = b.addRunArtifact(sql_parser_fuzzer);

    const fuzz_parser_step = b.step("fuzz-parser", "Run SQL parser fuzzer");
    fuzz_parser_step.dependOn(&run_sql_parser_fuzzer.step);

    // Add fuzz example test (separate from main tests to avoid harness protocol issues)
    const fuzz_example = b.addTest(.{
        .name = "fuzz_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz/fuzz_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_fuzz_example = b.addRunArtifact(fuzz_example);

    const fuzz_example_step = b.step("fuzz-example", "Run fuzz example test");
    fuzz_example_step.dependOn(&run_fuzz_example.step);

    // Add logging test
    const logger_test = b.addExecutable(.{
        .name = "logger_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/logging/logger_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    logger_test.root_module.addImport("zqlite", lib.root_module);
    logger_test.root_module.addImport("zsync", zsync.module("zsync"));

    const run_logger_test = b.addRunArtifact(logger_test);

    const logger_test_step = b.step("test-logging", "Test structured logging system");
    logger_test_step.dependOn(&run_logger_test.step);

    // Add security test suite (SQL injection, WAL limits, integrity verification)
    const security_test = b.addExecutable(.{
        .name = "security_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_security.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    security_test.root_module.addImport("zqlite", lib.root_module);
    security_test.root_module.addImport("zsync", zsync.module("zsync"));
    security_test.root_module.addOptions("build_options", build_options);

    const run_security_test = b.addRunArtifact(security_test);

    const security_test_step = b.step("test-security", "Run security tests (SQL injection, integrity verification, WAL limits)");
    security_test_step.dependOn(&run_security_test.step);

    // Add simple benchmark suite (avoids B-tree OrderMismatch bug)
    const benchmark_suite = b.addExecutable(.{
        .name = "benchmark_suite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench/simple_benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Benchmarks need optimizations
        }),
    });

    benchmark_suite.root_module.addImport("zqlite", lib.root_module);
    benchmark_suite.root_module.addImport("zsync", zsync.module("zsync"));

    const run_benchmark_suite = b.addRunArtifact(benchmark_suite);

    const benchmark_step = b.step("bench", "Run simple performance benchmark");
    benchmark_step.dependOn(&run_benchmark_suite.step);

    // Add benchmark validator for CI regression detection
    const benchmark_validator = b.addExecutable(.{
        .name = "benchmark_validator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench/benchmark_validator.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    benchmark_validator.root_module.addImport("zqlite", lib.root_module);
    benchmark_validator.root_module.addImport("zsync", zsync.module("zsync"));

    const run_benchmark_validator = b.addRunArtifact(benchmark_validator);

    const validate_bench_step = b.step("bench-validate", "Validate benchmarks against baseline (CI)");
    validate_bench_step.dependOn(&run_benchmark_validator.step);

    // Add minimal benchmark for debugging
    const minimal_bench = b.addExecutable(.{
        .name = "minimal_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench/minimal_bench.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });

    minimal_bench.root_module.addImport("zqlite", lib.root_module);
    minimal_bench.root_module.addImport("zsync", zsync.module("zsync"));

    const run_minimal_bench = b.addRunArtifact(minimal_bench);

    const minimal_bench_step = b.step("bench-minimal", "Run minimal benchmark (debug)");
    minimal_bench_step.dependOn(&run_minimal_bench.step);

    // Basic examples that work without external dependencies
    createBasicExample(b, "powerdns_example", lib, target, optimize, zsync, build_options);
    createBasicExample(b, "cipher_dns", lib, target, optimize, zsync, build_options);

    // v1.2.2 Universal API examples
    createBasicExample(b, "universal_api_demo", lib, target, optimize, zsync, build_options);
    createBasicExample(b, "web_backend_demo", lib, target, optimize, zsync, build_options);

    // v1.3.0 PostgreSQL compatibility demos
    createDemo(b, "uuid_demo", lib, target, optimize, zsync, build_options);
    createDemo(b, "json_demo", lib, target, optimize, zsync, build_options);
    createDemo(b, "connection_pool_demo", lib, target, optimize, zsync, build_options);
    createDemo(b, "window_functions_demo", lib, target, optimize, zsync, build_options);
    createDemo(b, "query_cache_demo", lib, target, optimize, zsync, build_options);
    createDemo(b, "array_operations_demo", lib, target, optimize, zsync, build_options);

    // Ghostwire integration demo
    createBasicExample(b, "ghostwire_integration_demo", lib, target, optimize, zsync, build_options);
}

fn createBasicExample(b: *std.Build, name: []const u8, lib: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zsync: *std.Build.Dependency, build_options: *std.Build.Step.Options) void {
    const example = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        }),
    });

    example.root_module.addImport("zqlite", lib.root_module);
    example.root_module.addImport("zsync", zsync.module("zsync"));
    example.root_module.addOptions("build_options", build_options);
    b.installArtifact(example);
}

fn createDemo(b: *std.Build, name: []const u8, lib: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, zsync: *std.Build.Dependency, build_options: *std.Build.Step.Options) void {
    const demo = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        }),
    });

    demo.root_module.addImport("zqlite", lib.root_module);
    demo.root_module.addImport("zsync", zsync.module("zsync"));
    demo.root_module.addOptions("build_options", build_options);
    b.installArtifact(demo);
}