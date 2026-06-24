const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // Build Profiles
    // ============================================================
    // core         = stable embedded database core
    // advanced     = stable default (core + json, performance, concurrent, ffi)
    // experimental = advanced + crypto and simulated transport scaffolding
    // full         = compatibility alias for experimental
    const Profile = enum { core, advanced, experimental, full };
    const requested_profile = b.option(Profile, "profile", "Build profile: core, advanced, experimental (full is an alias)") orelse .advanced;
    const is_advanced = requested_profile == .advanced;
    const is_experimental = requested_profile == .experimental or requested_profile == .full;
    const profile = if (is_experimental) "experimental" else @tagName(requested_profile);

    // Individual feature flags (can override profile defaults)
    const enable_crypto = b.option(bool, "crypto", "Enable post-quantum crypto") orelse
        is_experimental;
    const enable_liboqs = b.option(bool, "liboqs", "Enable experimental liboqs PQC backend placeholder") orelse
        false;
    const liboqs_include_path = b.option([]const u8, "liboqs-include-path", "Diagnostic-only liboqs include path; does not link liboqs yet") orelse
        "";
    const liboqs_library_path = b.option([]const u8, "liboqs-library-path", "Diagnostic-only liboqs library path; does not link liboqs yet") orelse
        "";
    const enable_transport = b.option(bool, "transport", "Enable PQ-QUIC transport") orelse
        is_experimental;
    const enable_json = b.option(bool, "json", "Enable JSON support") orelse
        (is_advanced or is_experimental);
    const enable_performance = b.option(bool, "performance", "Enable query cache/connection pool") orelse
        (is_advanced or is_experimental);
    const enable_concurrent = b.option(bool, "concurrent", "Enable async operations") orelse
        (is_advanced or is_experimental);
    const enable_ffi = b.option(bool, "ffi", "Enable C API") orelse
        (is_advanced or is_experimental);

    // Build metadata options
    const build_options = b.addOptions();

    // Add feature flags to build options
    build_options.addOption([]const u8, "profile", profile);
    build_options.addOption(bool, "enable_crypto", enable_crypto);
    build_options.addOption(bool, "enable_liboqs", enable_liboqs);
    build_options.addOption([]const u8, "liboqs_include_path", liboqs_include_path);
    build_options.addOption([]const u8, "liboqs_library_path", liboqs_library_path);
    build_options.addOption(bool, "enable_transport", enable_transport);
    build_options.addOption(bool, "enable_json", enable_json);
    build_options.addOption(bool, "enable_performance", enable_performance);
    build_options.addOption(bool, "enable_concurrent", enable_concurrent);
    build_options.addOption(bool, "enable_ffi", enable_ffi);

    // Build metadata - static values for reproducible builds from source archives
    // These are intentionally not dynamic to ensure tarball builds work without git/shell
    const git_commit = "release";
    const build_date = "2026-05-05";

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
    const build_zon = @import("build.zig.zon");
    build_options.addOption([]const u8, "version", build_zon.version);

    // Create the zqlite library
    const lib = b.addLibrary(.{
        .name = "zqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zqlite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.root_module.addOptions("build_options", build_options);

    // Install the library
    b.installArtifact(lib);

    // Create static and shared C ABI libraries when FFI is enabled.
    if (enable_ffi) {
        const c_lib_static = b.addLibrary(.{
            .name = "zqlite_c",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ffi/c_api.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        c_lib_static.root_module.addImport("zqlite", lib.root_module);
        b.installArtifact(c_lib_static);

        const c_lib_shared = b.addLibrary(.{
            .name = "zqlite_c",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ffi/c_api.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        c_lib_shared.root_module.addImport("zqlite", lib.root_module);
        b.installArtifact(c_lib_shared);
    }

    // The installed C header is part of the supported C ABI contract.
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/zqlite.h"), "zqlite.h").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path("include/zqlite_c.symbols"), .header, "zqlite_c.symbols").step);

    // Export the zqlite module for use by other packages
    const zqlite_module = b.addModule("zqlite", .{
        .root_source_file = b.path("src/zqlite.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    exe.root_module.addOptions("build_options", build_options);

    // Install the executable
    b.installArtifact(exe);

    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

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
    test_runner.root_module.addOptions("build_options", build_options);

    const run_test_runner = b.addRunArtifact(test_runner);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    const comprehensive_test_step = b.step("test-comprehensive", "Run comprehensive test suite");
    comprehensive_test_step.dependOn(&run_test_runner.step);

    const sql_conformance_test = b.addExecutable(.{
        .name = "test_sql_conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_sql_conformance.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sql_conformance_test.root_module.addImport("zqlite", lib.root_module);
    sql_conformance_test.root_module.addOptions("build_options", build_options);
    const run_sql_conformance_test = b.addRunArtifact(sql_conformance_test);
    const sql_conformance_step = b.step("test-sql-conformance", "Run statement-level SQL conformance tests");
    sql_conformance_step.dependOn(&run_sql_conformance_test.step);
    comprehensive_test_step.dependOn(&run_sql_conformance_test.step);

    // Add quick validation test
    const validation_test = b.addExecutable(.{
        .name = "test_validation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_validation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    validation_test.root_module.addImport("zqlite", lib.root_module);
    validation_test.root_module.addOptions("build_options", build_options);

    const run_validation_test = b.addRunArtifact(validation_test);

    const validation_step = b.step("test-quick", "Run quick validation test");
    validation_step.dependOn(&run_validation_test.step);

    const feature_availability_test = b.addExecutable(.{
        .name = "test_feature_availability",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_feature_availability.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    feature_availability_test.root_module.addImport("zqlite", lib.root_module);
    feature_availability_test.root_module.addOptions("build_options", build_options);
    const run_feature_availability_test = b.addRunArtifact(feature_availability_test);
    const feature_availability_step = b.step("test-feature-availability", "Run feature availability contract tests");
    feature_availability_step.dependOn(&run_feature_availability_test.step);
    validation_step.dependOn(&run_feature_availability_test.step);

    const pqc_capability_test = b.addExecutable(.{
        .name = "test_pqc_capability",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_pqc_capability.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    pqc_capability_test.root_module.addImport("zqlite", lib.root_module);
    const pqc_c_api_module = b.createModule(.{
        .root_source_file = b.path("src/ffi/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    pqc_c_api_module.addImport("zqlite", lib.root_module);
    pqc_capability_test.root_module.addImport("c_api", pqc_c_api_module);
    pqc_capability_test.root_module.addOptions("build_options", build_options);
    const run_pqc_capability_test = b.addRunArtifact(pqc_capability_test);
    const pqc_test_step = b.step("test-pqc", "Run deterministic PQC capability, fallback, and negative-path tests");
    pqc_test_step.dependOn(&run_pqc_capability_test.step);

    const pqc_kat_generator = b.addExecutable(.{
        .name = "generate_pqc_regression_kats",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate-pqc-regression-kats.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    pqc_kat_generator.root_module.addImport("zqlite", lib.root_module);
    pqc_kat_generator.root_module.addOptions("build_options", build_options);
    const run_pqc_kat_generator = b.addRunArtifact(pqc_kat_generator);
    const generate_pqc_kats_step = b.step("generate-pqc-regression-kats", "Generate deterministic ZQLite PQC regression KAT fixtures");
    generate_pqc_kats_step.dependOn(&run_pqc_kat_generator.step);

    const pqc_generated_kats_test = b.addExecutable(.{
        .name = "test_pqc_generated_kats",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_pqc_generated_kats.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    pqc_generated_kats_test.root_module.addImport("zqlite", lib.root_module);
    pqc_generated_kats_test.root_module.addOptions("build_options", build_options);
    const run_pqc_generated_kats_test = b.addRunArtifact(pqc_generated_kats_test);
    const pqc_generated_kats_step = b.step("test-pqc-generated-kats", "Run generated ZQLite stdlib PQC regression KAT fixtures");
    pqc_generated_kats_step.dependOn(&run_pqc_generated_kats_test.step);

    const validate_pqc_fixtures = b.addSystemCommand(&.{"./scripts/validate-pqc-fixtures.sh"});
    const validate_pqc_fixtures_step = b.step("validate-pqc-fixtures", "Validate PQC fixture fields and classifications");
    validate_pqc_fixtures_step.dependOn(&validate_pqc_fixtures.step);

    const liboqs_kat_converter = b.addExecutable(.{
        .name = "convert_liboqs_kat_output",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/convert-liboqs-kat-output.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_liboqs_kat_converter = b.addInstallArtifact(liboqs_kat_converter, .{});
    const liboqs_kat_converter_step = b.step("build-liboqs-kat-converter", "Compile the liboqs KAT output converter");
    liboqs_kat_converter_step.dependOn(&install_liboqs_kat_converter.step);

    const pqc_official_kats_test = b.addExecutable(.{
        .name = "test_pqc_official_kats",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_pqc_official_kats.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    pqc_official_kats_test.root_module.addImport("zqlite", lib.root_module);
    pqc_official_kats_test.root_module.addOptions("build_options", build_options);
    const run_pqc_official_kats_test = b.addRunArtifact(pqc_official_kats_test);
    const pqc_official_kats_step = b.step("test-pqc-official-kats", "Run imported official ML-KEM/ML-DSA KAT vectors when present");
    pqc_official_kats_step.dependOn(&run_pqc_official_kats_test.step);

    const memory_test_step = b.step("test-memory", "Run primary memory leak detection suite");

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
    advanced_tests.root_module.addOptions("build_options", build_options);

    const run_advanced_tests = b.addRunArtifact(advanced_tests);

    const advanced_test_step = b.step("test-advanced", "Run advanced tests (stress, security, edge cases)");
    advanced_test_step.dependOn(&run_advanced_tests.step);

    const simple_memory_test_step = b.step("test-memory-safe", "Run focused CREATE TABLE/default memory regression");

    const leak_detection_step = b.step("test-leak-detection", "Run compatibility alias for primary memory leak suite");

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
    memory_leak_test.root_module.addOptions("build_options", build_options);

    const run_memory_leak_test = b.addRunArtifact(memory_leak_test);

    const memory_leak_step = b.step("test-memory-leaks", "Run dedicated memory leak detection");
    memory_leak_step.dependOn(&run_memory_leak_test.step);
    memory_test_step.dependOn(&run_memory_leak_test.step);
    leak_detection_step.dependOn(&run_memory_leak_test.step);

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
    window_test.root_module.addOptions("build_options", build_options);

    const run_window_test = b.addRunArtifact(window_test);

    const window_test_step = b.step("test-window", "Run window function tests");
    window_test_step.dependOn(&run_window_test.step);

    const comprehensive_memory_test_step = b.step("test-comprehensive-memory", "Run compatibility alias for primary memory leak suite and focused regression");
    comprehensive_memory_test_step.dependOn(&run_memory_leak_test.step);
    simple_memory_test_step.dependOn(&run_create_table_leak_test.step);
    comprehensive_memory_test_step.dependOn(&run_create_table_leak_test.step);

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
    security_test.root_module.addOptions("build_options", build_options);

    const run_security_test = b.addRunArtifact(security_test);

    const security_test_step = b.step("test-security", "Run security tests (SQL injection, integrity verification, WAL limits)");
    security_test_step.dependOn(&run_security_test.step);

    // File-backed storage tests (persistence across connections)
    const file_backed_test = b.addExecutable(.{
        .name = "test_file_backed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_file_backed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    file_backed_test.root_module.addImport("zqlite", lib.root_module);
    file_backed_test.root_module.addOptions("build_options", build_options);

    const run_file_backed_test = b.addRunArtifact(file_backed_test);

    const file_backed_step = b.step("test-file-backed", "Run file-backed storage persistence tests");
    file_backed_step.dependOn(&run_file_backed_test.step);

    // Transaction atomicity tests (COMMIT/ROLLBACK persistence)
    const transaction_test = b.addExecutable(.{
        .name = "test_transaction_atomicity",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_transaction_atomicity.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    transaction_test.root_module.addImport("zqlite", lib.root_module);
    transaction_test.root_module.addOptions("build_options", build_options);

    const run_transaction_test = b.addRunArtifact(transaction_test);

    const transaction_step = b.step("test-transaction", "Run transaction atomicity tests (COMMIT/ROLLBACK persistence)");
    transaction_step.dependOn(&run_transaction_test.step);

    // Combined storage tests (both run in parallel since each has own cleanup)
    const storage_step = b.step("test-storage", "Run all storage tests (file-backed + transaction atomicity)");
    storage_step.dependOn(&run_file_backed_test.step);
    storage_step.dependOn(&run_transaction_test.step);

    const durability_error_test = b.addExecutable(.{
        .name = "test_durability_errors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_durability_errors.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    durability_error_test.root_module.addImport("zqlite", lib.root_module);
    durability_error_test.root_module.addOptions("build_options", build_options);
    const run_durability_error_test = b.addRunArtifact(durability_error_test);
    const durability_error_step = b.step("test-durability-errors", "Run injected persistence failure tests");
    durability_error_step.dependOn(&run_durability_error_test.step);
    storage_step.dependOn(&run_durability_error_test.step);

    const storage_property_test = b.addExecutable(.{
        .name = "test_storage_properties",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_storage_properties.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    storage_property_test.root_module.addImport("zqlite", lib.root_module);
    storage_property_test.root_module.addOptions("build_options", build_options);
    const run_storage_property_test = b.addRunArtifact(storage_property_test);
    const storage_property_step = b.step("test-storage-properties", "Run deterministic storage property tests");
    storage_property_step.dependOn(&run_storage_property_test.step);
    storage_step.dependOn(&run_storage_property_test.step);

    const storage_stress_test = b.addExecutable(.{
        .name = "test_storage_stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_storage_stress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    storage_stress_test.root_module.addImport("zqlite", lib.root_module);
    storage_stress_test.root_module.addOptions("build_options", build_options);
    const run_storage_stress_test = b.addRunArtifact(storage_stress_test);
    const storage_stress_step = b.step("test-storage-stress", "Run deterministic reopen/checkpoint/rollback storage stress tests");
    storage_stress_step.dependOn(&run_storage_stress_test.step);

    const concurrent_access_test = b.addExecutable(.{
        .name = "test_concurrent_access",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_concurrent_access.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    concurrent_access_test.root_module.addImport("zqlite", lib.root_module);
    concurrent_access_test.root_module.addOptions("build_options", build_options);
    const run_concurrent_access_test = b.addRunArtifact(concurrent_access_test);
    const concurrent_access_step = b.step("test-concurrent-access", "Run deterministic multi-connection access tests");
    concurrent_access_step.dependOn(&run_concurrent_access_test.step);
    storage_step.dependOn(&run_concurrent_access_test.step);

    const wal_recovery_test = b.addExecutable(.{
        .name = "test_wal_recovery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_wal_recovery.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wal_recovery_test.root_module.addImport("zqlite", lib.root_module);
    wal_recovery_test.root_module.addOptions("build_options", build_options);
    const run_wal_recovery_test = b.addRunArtifact(wal_recovery_test);
    const wal_recovery_step = b.step("test-wal-recovery", "Run WAL corruption and crash-recovery tests");
    wal_recovery_step.dependOn(&run_wal_recovery_test.step);
    storage_step.dependOn(&run_wal_recovery_test.step);

    const catalog_format_test = b.addExecutable(.{
        .name = "test_catalog_format",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_catalog_format.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    catalog_format_test.root_module.addImport("zqlite", lib.root_module);
    catalog_format_test.root_module.addOptions("build_options", build_options);
    const run_catalog_format_test = b.addRunArtifact(catalog_format_test);
    const catalog_format_step = b.step("test-catalog-format", "Run catalog format, corruption, and migration tests");
    catalog_format_step.dependOn(&run_catalog_format_test.step);
    storage_step.dependOn(&run_catalog_format_test.step);

    const filesystem_error_test = b.addExecutable(.{
        .name = "test_filesystem_errors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_filesystem_errors.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    filesystem_error_test.root_module.addImport("zqlite", lib.root_module);
    filesystem_error_test.root_module.addOptions("build_options", build_options);
    const run_filesystem_error_test = b.addRunArtifact(filesystem_error_test);
    const filesystem_error_step = b.step("test-filesystem-errors", "Run filesystem error handling tests");
    filesystem_error_step.dependOn(&run_filesystem_error_test.step);
    storage_step.dependOn(&run_filesystem_error_test.step);

    const sqlite_diff_test = b.addExecutable(.{
        .name = "test_sqlite_diff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/standalone/test_sqlite_diff.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sqlite_diff_test.root_module.addImport("zqlite", lib.root_module);
    sqlite_diff_test.root_module.addOptions("build_options", build_options);
    const run_sqlite_diff_test = b.addRunArtifact(sqlite_diff_test);
    const sqlite_diff_step = b.step("test-sqlite-diff", "Run explicit SQLite differential tests; requires sqlite3 on PATH");
    sqlite_diff_step.dependOn(&run_sqlite_diff_test.step);

    if (enable_ffi) {
        const c_api_tests = b.addTest(.{
            .name = "c_api_tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/ffi/c_api.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        c_api_tests.root_module.addImport("zqlite", lib.root_module);
        c_api_tests.root_module.addOptions("build_options", build_options);

        const run_c_api_tests = b.addRunArtifact(c_api_tests);

        const c_api_test_step = b.step("test-c-api", "Run C API unit tests");
        c_api_test_step.dependOn(&run_c_api_tests.step);
    }

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

    const run_benchmark_suite = b.addRunArtifact(benchmark_suite);

    const benchmark_step = b.step("bench", "Run simple performance benchmark");
    benchmark_step.dependOn(&run_benchmark_suite.step);

    const operational_benchmark = b.addExecutable(.{
        .name = "operational_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench/operational_benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    operational_benchmark.root_module.addImport("zqlite", lib.root_module);
    const run_operational_benchmark = b.addRunArtifact(operational_benchmark);
    const operational_benchmark_step = b.step("bench-operational", "Run operational performance evidence benchmarks");
    operational_benchmark_step.dependOn(&run_operational_benchmark.step);

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

    const run_minimal_bench = b.addRunArtifact(minimal_bench);

    const minimal_bench_step = b.step("bench-minimal", "Run minimal benchmark (debug)");
    minimal_bench_step.dependOn(&run_minimal_bench.step);

    // Examples are explicit opt-in artifacts and are not part of the default install.
    const examples_step = b.step("examples", "Build and install examples supported by the selected profile");

    const stable_examples = [_][]const u8{
        "powerdns_example",
        "cipher_dns",
        "simple_api_test",
        "secure_by_default_app",
        "improved_api_demo",
        "insert_memory_regression_test",
        "datetime_test",
        "demo_enhanced_features",
        "advanced_indexing_demo",
        "universal_api_demo",
        "web_backend_demo",
    };
    for (stable_examples) |name| {
        createBasicExample(b, examples_step, name, lib, target, optimize, build_options);
    }

    // v1.3.0 PostgreSQL compatibility demos
    createDemo(b, examples_step, "uuid_demo", lib, target, optimize, build_options);
    if (enable_json) createDemo(b, examples_step, "json_demo", lib, target, optimize, build_options);
    createDemo(b, examples_step, "connection_pool_demo", lib, target, optimize, build_options);
    createDemo(b, examples_step, "window_functions_demo", lib, target, optimize, build_options);
    if (enable_performance) createDemo(b, examples_step, "query_cache_demo", lib, target, optimize, build_options);
    createDemo(b, examples_step, "array_operations_demo", lib, target, optimize, build_options);

    const check_c_api_cmd = b.addSystemCommand(&.{ "bash", "scripts/check-c-api.sh" });
    const check_c_api_step = b.step("check-c-api", "Verify that the C header matches implementation exports and constants");
    check_c_api_cmd.step.dependOn(b.getInstallStep());
    check_c_api_step.dependOn(&check_c_api_cmd.step);

    const release_smoke_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-release-package.sh" });
    const release_smoke_step = b.step("test-release-package", "Build a release layout and test Zig and C consumers");
    release_smoke_step.dependOn(&release_smoke_cmd.step);

    const release_validation_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-release.sh" });
    const check_step = b.step("check", "Run the authoritative stable release validation gate");
    check_step.dependOn(&release_validation_cmd.step);

    const stable_profiles_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-stable-profiles.sh" });
    const stable_profiles_step = b.step("test-stable-profiles", "Run unit tests across supported profiles and optimized modes");
    stable_profiles_step.dependOn(&stable_profiles_cmd.step);

    const install_smoke_cmd = b.addSystemCommand(&.{ "bash", "scripts/test-install.sh" });
    const install_smoke_step = b.step("test-install", "Test release archive and local source install paths");
    install_smoke_step.dependOn(&install_smoke_cmd.step);
}

fn createBasicExample(b: *std.Build, examples_step: *std.Build.Step, name: []const u8, lib: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, build_options: *std.Build.Step.Options) void {
    const example = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        }),
    });

    example.root_module.addImport("zqlite", lib.root_module);
    example.root_module.addOptions("build_options", build_options);
    examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);
}

fn createDemo(b: *std.Build, examples_step: *std.Build.Step, name: []const u8, lib: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, build_options: *std.Build.Step.Options) void {
    const demo = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        }),
    });

    demo.root_module.addImport("zqlite", lib.root_module);
    demo.root_module.addOptions("build_options", build_options);
    examples_step.dependOn(&b.addInstallArtifact(demo, .{}).step);
}
