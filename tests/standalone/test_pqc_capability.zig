const std = @import("std");
const zqlite = @import("zqlite");

const c_api = @import("c_api");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try unavailableWhenNotCompiled();
    try compiledDefaultIsUnavailable();
    try explicitFallbackIsObservable();
    try simulatedNeverReportsProductionReady();
    try missingBackendFailsClosedWithoutFallback();
    try missingBackendFallsBackOnlyWhenAllowed();
    try realBackendStatesAreDistinct();
    try backendInterfaceReportsProviderAndAlgorithms();
    try liboqsPlaceholderIsGatedUnavailable(allocator);
    try liboqsProviderSelectionFailsClosed(allocator);
    try liboqsConfiguredButUnlinkedDiagnostics(allocator);
    try stdlibProviderSelectionRemainsActive();
    try providerLifecyclePolicyAndZeroization();
    try backendKatFixturesRunThroughStdlibProvider(allocator);
    try backendKatFixtureFilesRunThroughStdlibProvider(allocator);
    try stdlibMlKem768RoundTripAndTamper();
    try stdlibMlDsa65SignVerifyAndTamper();
    try cryptoInterfaceUsesStdlibMlDsaWhenCompiled(allocator);
    try diagnosticsJsonIsMachineReadable(allocator);
    try cApiParityForDefaultState();

    std.log.info("=== PQC CAPABILITY TESTS PASSED ===", .{});
}

fn unavailableWhenNotCompiled() !void {
    const pq = zqlite.evaluatePQCapability(false, .{ .pq_mode = .pqc }, .real);
    try std.testing.expectEqual(zqlite.PQRuntimeState.unavailable, pq.state);
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.none, pq.backend);
    try std.testing.expectEqual(zqlite.PQDecisionReason.not_compiled, pq.reason);
    try std.testing.expect(!pq.enabled);
    try std.testing.expect(!pq.production_ready);
    try std.testing.expect(!pq.isAvailable());
}

fn compiledDefaultIsUnavailable() !void {
    const pq = zqlite.evaluatePQCapability(true, .{}, .none);
    try std.testing.expectEqual(zqlite.PQMode.disabled, pq.requested_mode);
    try std.testing.expectEqual(zqlite.PQRuntimeState.unavailable, pq.state);
    try std.testing.expectEqual(zqlite.PQDecisionReason.disabled, pq.reason);
    try std.testing.expectEqualStrings("none", pq.algorithmSummary());
    try std.testing.expect(!pq.isAvailable());
}

fn explicitFallbackIsObservable() !void {
    const pq = zqlite.evaluatePQCapability(true, .{
        .pq_mode = .classical_fallback,
        .allow_classical_fallback = true,
    }, .none);

    try std.testing.expectEqual(zqlite.PQRuntimeState.classical_fallback, pq.state);
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.native_fallback, pq.backend);
    try std.testing.expectEqual(zqlite.PQDecisionReason.fallback_explicit, pq.reason);
    try std.testing.expect(pq.isFallback());
    try std.testing.expect(pq.fallback_allowed);
    try std.testing.expect(!pq.production_ready);
    try std.testing.expect(!pq.isAvailable());
}

fn simulatedNeverReportsProductionReady() !void {
    const pq = zqlite.evaluatePQCapability(true, .{ .pq_mode = .simulated }, .simulated);
    try std.testing.expectEqual(zqlite.PQRuntimeState.simulated, pq.state);
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.simulated, pq.backend);
    try std.testing.expectEqual(zqlite.PQDecisionReason.simulated, pq.reason);
    try std.testing.expect(pq.isSimulated());
    try std.testing.expect(!pq.enabled);
    try std.testing.expect(!pq.production_ready);
    try std.testing.expect(!pq.isAvailable());
}

fn missingBackendFailsClosedWithoutFallback() !void {
    const pq = zqlite.evaluatePQCapability(true, .{
        .pq_mode = .pqc,
        .allow_classical_fallback = false,
    }, .none);

    try std.testing.expectEqual(zqlite.PQRuntimeState.unavailable, pq.state);
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.none, pq.backend);
    try std.testing.expectEqual(zqlite.PQDecisionReason.backend_missing, pq.reason);
    try std.testing.expect(!pq.fallback_allowed);
    try std.testing.expect(!pq.isAvailable());
}

fn missingBackendFallsBackOnlyWhenAllowed() !void {
    const pq = zqlite.evaluatePQCapability(true, .{
        .pq_mode = .hybrid,
        .allow_classical_fallback = true,
    }, .none);

    try std.testing.expectEqual(zqlite.PQRuntimeState.classical_fallback, pq.state);
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.native_fallback, pq.backend);
    try std.testing.expectEqual(zqlite.PQDecisionReason.fallback_allowed, pq.reason);
    try std.testing.expect(pq.fallback_allowed);
    try std.testing.expect(!pq.production_ready);
}

fn realBackendStatesAreDistinct() !void {
    const hybrid = zqlite.evaluatePQCapability(true, .{ .pq_mode = .hybrid }, .real);
    try std.testing.expectEqual(zqlite.PQRuntimeState.hybrid_active, hybrid.state);
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.hybrid, hybrid.backend);
    try std.testing.expectEqual(zqlite.PQDecisionReason.backend_active, hybrid.reason);
    try std.testing.expect(hybrid.enabled);
    try std.testing.expect(hybrid.production_ready);
    try std.testing.expect(hybrid.algorithms.hybrid_signatures);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.stdlib, hybrid.provider);
    try std.testing.expectEqualStrings("stdlib", hybrid.providerName());
    try std.testing.expect(hybrid.isAvailable());

    const pqc = zqlite.evaluatePQCapability(true, .{ .pq_mode = .pqc }, .real);
    try std.testing.expectEqual(zqlite.PQRuntimeState.pqc_active, pqc.state);
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.pqc, pqc.backend);
    try std.testing.expectEqual(zqlite.PQDecisionReason.backend_active, pqc.reason);
    try std.testing.expect(pqc.enabled);
    try std.testing.expect(pqc.production_ready);
    try std.testing.expect(!pqc.algorithms.hybrid_signatures);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.stdlib, pqc.provider);
    try std.testing.expect(pqc.isAvailable());
}

fn backendInterfaceReportsProviderAndAlgorithms() !void {
    const backend = zqlite.pqc_backend.StdlibPQCBackend.backend;
    const algorithms = backend.supportedAlgorithms();

    try std.testing.expectEqual(zqlite.pqc_backend.Provider.stdlib, backend.provider);
    try std.testing.expectEqualStrings("stdlib", backend.name);
    try std.testing.expect(algorithms.ml_kem_768);
    try std.testing.expect(algorithms.ml_dsa_65);
}

fn liboqsPlaceholderIsGatedUnavailable(allocator: std.mem.Allocator) !void {
    const backend = zqlite.pqc_backend.LibOQSPQCBackend.backend;
    const seed: [zqlite.pqc_backend.MlKem768.key_seed_length]u8 = @splat(0);

    try std.testing.expectEqual(zqlite.pqc_backend.Provider.liboqs, backend.provider);
    try std.testing.expectEqualStrings("liboqs", backend.name);
    try std.testing.expect(!backend.algorithms.ml_kem_768);
    try std.testing.expect(!backend.algorithms.ml_dsa_65);
    try std.testing.expectError(error.BackendUnavailable, backend.kemKeypair(allocator, &seed));
}

fn liboqsProviderSelectionFailsClosed(allocator: std.mem.Allocator) !void {
    const pq = zqlite.evaluatePQCapabilityWithBuild(true, false, .{
        .pq_mode = .pqc,
        .pq_provider = .liboqs,
    }, .real);

    try std.testing.expectEqual(zqlite.PQRuntimeState.unavailable, pq.state);
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.none, pq.backend);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.liboqs, pq.provider);
    try std.testing.expectEqual(zqlite.pqc_backend.LibOQSProviderStatus.not_configured, pq.liboqs_status);
    try std.testing.expectEqual(zqlite.PQDecisionReason.provider_not_configured, pq.reason);
    try std.testing.expect(!pq.production_ready);
    try std.testing.expect(!pq.isAvailable());

    const json = try zqlite.pqDiagnosticsJson(allocator, pq);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"liboqs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requested_provider\":\"liboqs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"liboqs_status\":\"not_configured\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"production_ready\":false") != null);

    const fallback = zqlite.evaluatePQCapabilityWithBuild(true, false, .{
        .pq_mode = .pqc,
        .pq_provider = .liboqs,
        .allow_classical_fallback = true,
    }, .real);
    try std.testing.expectEqual(zqlite.PQRuntimeState.classical_fallback, fallback.state);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.liboqs, fallback.provider);
    try std.testing.expect(!fallback.production_ready);
    try std.testing.expect(!fallback.isAvailable());
}

fn liboqsConfiguredButUnlinkedDiagnostics(allocator: std.mem.Allocator) !void {
    const pq = zqlite.evaluatePQCapabilityWithBuild(true, true, .{
        .pq_mode = .pqc,
        .pq_provider = .liboqs,
    }, .real);

    try std.testing.expectEqual(zqlite.PQRuntimeState.unavailable, pq.state);
    try std.testing.expectEqual(zqlite.PQCapability.PQBackend.none, pq.backend);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.liboqs, pq.provider);
    try std.testing.expectEqual(zqlite.pqc_backend.LibOQSProviderStatus.configured_but_unlinked, pq.liboqs_status);
    try std.testing.expectEqual(zqlite.PQDecisionReason.configured_but_unlinked, pq.reason);
    try std.testing.expect(!pq.algorithms.ml_kem_768);
    try std.testing.expect(!pq.algorithms.ml_dsa_65);
    try std.testing.expect(!pq.production_ready);
    try std.testing.expect(!pq.isAvailable());

    const json = try zqlite.pqDiagnosticsJson(allocator, pq);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"liboqs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requested_provider\":\"liboqs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"liboqs_status\":\"configured_but_unlinked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"available\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"production_ready\":false") != null);

    const fallback = zqlite.evaluatePQCapabilityWithBuild(true, true, .{
        .pq_mode = .hybrid,
        .pq_provider = .liboqs,
        .allow_classical_fallback = true,
    }, .real);
    try std.testing.expectEqual(zqlite.PQRuntimeState.classical_fallback, fallback.state);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.liboqs, fallback.provider);
    try std.testing.expectEqual(zqlite.pqc_backend.LibOQSProviderStatus.configured_but_unlinked, fallback.liboqs_status);
    try std.testing.expect(!fallback.production_ready);
    try std.testing.expect(!fallback.isAvailable());
}

fn stdlibProviderSelectionRemainsActive() !void {
    const stdlib = zqlite.evaluatePQCapabilityWithBuild(true, true, .{
        .pq_mode = .pqc,
        .pq_provider = .stdlib,
    }, .real);
    try std.testing.expectEqual(zqlite.PQRuntimeState.pqc_active, stdlib.state);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.stdlib, stdlib.provider);
    try std.testing.expectEqual(zqlite.pqc_backend.LibOQSProviderStatus.not_configured, stdlib.liboqs_status);
    try std.testing.expect(stdlib.production_ready);
    try std.testing.expect(stdlib.isAvailable());

    const auto = zqlite.evaluatePQCapabilityWithBuild(true, true, .{
        .pq_mode = .pqc,
        .pq_provider = .auto,
    }, .real);
    try std.testing.expectEqual(zqlite.PQRuntimeState.pqc_active, auto.state);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.stdlib, auto.provider);
    try std.testing.expect(auto.production_ready);
    try std.testing.expect(auto.isAvailable());
}

fn providerLifecyclePolicyAndZeroization() !void {
    const strict = zqlite.pqc_backend.AlgorithmPolicy.experimental_default;
    var stdlib_handle = try zqlite.pqc_backend.StdlibPQCBackend.initProvider(strict);
    defer stdlib_handle.deinit();
    try std.testing.expectEqual(zqlite.pqc_backend.ProviderRuntimeStatus.ready, stdlib_handle.status);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.stdlib, stdlib_handle.backend.provider);

    const no_signatures = zqlite.pqc_backend.AlgorithmPolicy{
        .allow_ml_kem_768 = true,
        .allow_ml_dsa_65 = false,
        .require_real_backend = true,
    };
    try std.testing.expectError(error.AlgorithmDisabledByPolicy, zqlite.pqc_backend.StdlibPQCBackend.initProvider(no_signatures));

    var liboqs_handle = try zqlite.pqc_backend.LibOQSPQCBackend.initProvider(strict);
    defer liboqs_handle.deinit();
    try std.testing.expectEqual(zqlite.pqc_backend.ProviderRuntimeStatus.configured_but_unlinked, liboqs_handle.status);
    try std.testing.expectEqual(zqlite.pqc_backend.Provider.liboqs, liboqs_handle.backend.provider);

    var secret = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    zqlite.pqc_backend.secureZero(&secret);
    for (secret) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

fn backendKatFixturesRunThroughStdlibProvider(allocator: std.mem.Allocator) !void {
    const backend = zqlite.pqc_backend.StdlibPQCBackend.backend;

    var kem_key_seed: [zqlite.pqc_backend.MlKem768.key_seed_length]u8 = undefined;
    for (&kem_key_seed, 0..) |*byte, i| byte.* = @intCast((i * 19 + 1) & 0xff);

    var kem_encaps_seed: [zqlite.pqc_backend.MlKem768.encaps_seed_length]u8 = undefined;
    for (&kem_encaps_seed, 0..) |*byte, i| byte.* = @intCast((i * 23 + 5) & 0xff);

    try zqlite.pqc_backend.runKemKatFixture(backend, allocator, .{
        .name = "stdlib-ml-kem-768-drop-in-fixture",
        .key_seed = &kem_key_seed,
        .encaps_seed = &kem_encaps_seed,
    });

    var sign_seed: [zqlite.pqc_backend.MlDsa65.seed_length]u8 = undefined;
    for (&sign_seed, 0..) |*byte, i| byte.* = @intCast((i * 31 + 7) & 0xff);

    try zqlite.pqc_backend.runSignKatFixture(backend, allocator, .{
        .name = "stdlib-ml-dsa-65-drop-in-fixture",
        .seed = &sign_seed,
        .message = "fixture message for backend-agnostic ml-dsa verification",
    });
}

fn backendKatFixtureFilesRunThroughStdlibProvider(allocator: std.mem.Allocator) !void {
    const backend = zqlite.pqc_backend.StdlibPQCBackend.backend;

    var kem = try zqlite.pqc_backend.loadKemKatFixture(
        allocator,
        "tests/standalone/fixtures/pqc/ml-kem-768/sample.kat",
        @embedFile("fixtures/pqc/ml-kem-768/sample.kat"),
    );
    defer kem.deinit(allocator);
    try zqlite.pqc_backend.runKemKatFixture(backend, allocator, kem.fixture);

    var sign = try zqlite.pqc_backend.loadSignKatFixture(
        allocator,
        "tests/standalone/fixtures/pqc/ml-dsa-65/sample.kat",
        @embedFile("fixtures/pqc/ml-dsa-65/sample.kat"),
    );
    defer sign.deinit(allocator);
    try zqlite.pqc_backend.runSignKatFixture(backend, allocator, sign.fixture);
}

fn stdlibMlKem768RoundTripAndTamper() !void {
    const MlKem768 = zqlite.pqc_backend.MlKem768;

    var key_seed: [MlKem768.key_seed_length]u8 = undefined;
    for (&key_seed, 0..) |*byte, i| byte.* = @intCast((i * 17 + 9) & 0xff);

    var encaps_seed: [MlKem768.encaps_seed_length]u8 = undefined;
    for (&encaps_seed, 0..) |*byte, i| byte.* = @intCast((i * 29 + 3) & 0xff);

    const kp = try MlKem768.generateDeterministic(key_seed);
    const encapsulated = try MlKem768.encapsulateDeterministic(&kp.public_key, encaps_seed);
    const decapsulated = try MlKem768.decapsulate(&kp.secret_key, &encapsulated.ciphertext);
    try std.testing.expectEqualSlices(u8, &encapsulated.shared_secret, &decapsulated);

    var tampered_ciphertext = encapsulated.ciphertext;
    tampered_ciphertext[0] ^= 0x80;
    const tampered_secret = try MlKem768.decapsulate(&kp.secret_key, &tampered_ciphertext);
    try std.testing.expect(!std.mem.eql(u8, &encapsulated.shared_secret, &tampered_secret));

    try std.testing.expectError(error.InvalidPublicKeyLength, MlKem768.encapsulateDeterministic(kp.public_key[0 .. kp.public_key.len - 1], encaps_seed));
    try std.testing.expectError(error.InvalidSecretKeyLength, MlKem768.decapsulate(kp.secret_key[0 .. kp.secret_key.len - 1], &encapsulated.ciphertext));
    try std.testing.expectError(error.InvalidCiphertextLength, MlKem768.decapsulate(&kp.secret_key, encapsulated.ciphertext[0 .. encapsulated.ciphertext.len - 1]));
}

fn stdlibMlDsa65SignVerifyAndTamper() !void {
    const MlDsa65 = zqlite.pqc_backend.MlDsa65;

    var seed: [MlDsa65.seed_length]u8 = undefined;
    for (&seed, 0..) |*byte, i| byte.* = @intCast((i * 11 + 0x65) & 0xff);

    const message = "zqlite ml-dsa-65 backend adapter test";
    const kp = try MlDsa65.generateDeterministic(seed);
    const signature = try MlDsa65.signDeterministic(message, &kp.secret_key);

    try std.testing.expect(try MlDsa65.verify(message, &signature, &kp.public_key));
    try std.testing.expect(!try MlDsa65.verify("different message", &signature, &kp.public_key));

    var tampered_signature = signature;
    tampered_signature[tampered_signature.len - 1] ^= 0x01;
    const tampered_result = MlDsa65.verify(message, &tampered_signature, &kp.public_key);
    if (tampered_result) |valid| {
        try std.testing.expect(!valid);
    } else |err| {
        try std.testing.expect(err == error.InvalidSignature);
    }

    try std.testing.expectError(error.InvalidSecretKeyLength, MlDsa65.signDeterministic(message, kp.secret_key[0 .. kp.secret_key.len - 1]));
    try std.testing.expectError(error.InvalidSignatureLength, MlDsa65.verify(message, signature[0 .. signature.len - 1], &kp.public_key));
    try std.testing.expectError(error.InvalidPublicKeyLength, MlDsa65.verify(message, &signature, kp.public_key[0 .. kp.public_key.len - 1]));
}

fn cryptoInterfaceUsesStdlibMlDsaWhenCompiled(allocator: std.mem.Allocator) !void {
    if (!zqlite.features.crypto) return;

    const MlDsa65 = zqlite.pqc_backend.MlDsa65;
    const crypto = zqlite.CryptoInterface.init(.{ .pq_mode = .pqc });
    const capability = crypto.pqCapability();
    try std.testing.expectEqual(zqlite.PQRuntimeState.pqc_active, capability.state);
    try std.testing.expect(capability.production_ready);

    var seed: [MlDsa65.seed_length]u8 = undefined;
    for (&seed, 0..) |*byte, i| byte.* = @intCast((i * 7 + 0x42) & 0xff);

    const kp = try MlDsa65.generateDeterministic(seed);
    const message = "zqlite crypto interface ml-dsa-65 path";
    const signature = try crypto.signPQ(message, &kp.secret_key, allocator);
    defer allocator.free(signature);

    try std.testing.expectEqual(@as(usize, MlDsa65.signature_length), signature.len);
    try std.testing.expect(try crypto.verifyPQ(message, signature, &kp.public_key));
    try std.testing.expect(!try crypto.verifyPQ("wrong message", signature, &kp.public_key));
}

fn diagnosticsJsonIsMachineReadable(allocator: std.mem.Allocator) !void {
    const pq = zqlite.evaluatePQCapability(true, .{
        .pq_mode = .pqc,
        .allow_classical_fallback = false,
    }, .none);

    const json = try zqlite.pqDiagnosticsJson(allocator, pq);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"requested_mode\":\"pqc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reason\":\"backend_missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"production_ready\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ml_kem_768\":false") != null);

    const active = zqlite.evaluatePQCapability(true, .{ .pq_mode = .pqc }, .real);
    const active_json = try zqlite.pqDiagnosticsJson(allocator, active);
    defer allocator.free(active_json);
    try std.testing.expect(std.mem.indexOf(u8, active_json, "\"provider\":\"stdlib\"") != null);
}

fn cApiParityForDefaultState() !void {
    const pq = zqlite.getPQCapability();
    try std.testing.expectEqual(@as(c_int, if (pq.isAvailable()) 1 else 0), c_api.zqlite_pq_available());

    const backend = std.mem.span(c_api.zqlite_pq_backend());
    switch (pq.backend) {
        .none => try std.testing.expectEqualStrings("none", backend),
        .native_fallback => try std.testing.expectEqualStrings("native_fallback", backend),
        .simulated => try std.testing.expectEqualStrings("simulated", backend),
        .hybrid => try std.testing.expectEqualStrings("hybrid", backend),
        .pqc => try std.testing.expectEqualStrings("pqc", backend),
    }

    const status = std.mem.span(c_api.zqlite_pq_status());
    try std.testing.expect(status.len > 0);

    const json_ptr = c_api.zqlite_pq_diagnostics_json() orelse return error.ExpectedDiagnosticsJson;
    defer c_api.zqlite_free_string(json_ptr);
    const json = std.mem.span(json_ptr);
    try expectJsonField(json, "compiled", if (pq.compiled) "true" else "false");
    try expectJsonField(json, "available", if (pq.isAvailable()) "true" else "false");
    try expectJsonString(json, "requested_mode", @tagName(pq.requested_mode));
    try expectJsonString(json, "state", @tagName(pq.state));
    try expectJsonString(json, "backend", @tagName(pq.backend));
    try expectJsonString(json, "provider", pq.providerName());
    try expectJsonString(json, "requested_provider", @tagName(pq.requested_provider));
    try expectJsonString(json, "reason", pq.reasonTag());

    const liboqs_status = std.mem.span(c_api.zqlite_pq_liboqs_status());
    const expected_liboqs_status = if (zqlite.features.liboqs) "configured_but_unlinked" else "not_configured";
    try std.testing.expectEqualStrings(expected_liboqs_status, liboqs_status);
    try expectJsonString(json, "liboqs_status", pq.liboqs_status.tag());

    if (zqlite.features.crypto) {
        try std.testing.expect(pq.compiled);
        try std.testing.expectEqual(zqlite.PQDecisionReason.disabled, pq.reason);
    } else {
        try std.testing.expect(!pq.compiled);
        try std.testing.expectEqual(zqlite.PQDecisionReason.not_compiled, pq.reason);
    }

    if (zqlite.features.liboqs) {
        try std.testing.expectEqual(zqlite.pqc_backend.LibOQSProviderStatus.configured_but_unlinked, zqlite.getLibOQSProviderStatus());
    } else {
        try std.testing.expectEqual(zqlite.pqc_backend.LibOQSProviderStatus.not_configured, zqlite.getLibOQSProviderStatus());
    }
}

fn expectJsonString(json: []const u8, key: []const u8, value: []const u8) !void {
    var expected: [256]u8 = undefined;
    const needle = try std.fmt.bufPrint(&expected, "\"{s}\":\"{s}\"", .{ key, value });
    try std.testing.expect(std.mem.indexOf(u8, json, needle) != null);
}

fn expectJsonField(json: []const u8, key: []const u8, value: []const u8) !void {
    var expected: [256]u8 = undefined;
    const needle = try std.fmt.bufPrint(&expected, "\"{s}\":{s}", .{ key, value });
    try std.testing.expect(std.mem.indexOf(u8, json, needle) != null);
}
