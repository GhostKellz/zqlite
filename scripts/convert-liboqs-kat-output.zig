const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    const exe = args.next() orelse "convert-liboqs-kat-output";
    const kind = args.next() orelse fatal("usage: {s} <kem|sig> <suite> <input-file> <output-file> <provenance>", .{exe});
    const suite = args.next() orelse fatal("usage: {s} <kem|sig> <suite> <input-file> <output-file> <provenance>", .{exe});
    const input_path = args.next() orelse fatal("usage: {s} <kem|sig> <suite> <input-file> <output-file> <provenance>", .{exe});
    const output_path = args.next() orelse fatal("usage: {s} <kem|sig> <suite> <input-file> <output-file> <provenance>", .{exe});
    const provenance = args.next() orelse fatal("usage: {s} <kem|sig> <suite> <input-file> <output-file> <provenance>", .{exe});
    if (args.next() != null) {
        fatal("usage: {s} <kem|sig> <suite> <input-file> <output-file> <provenance>", .{exe});
    }

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(input);

    if (std.mem.eql(u8, kind, "kem")) {
        try convertKem(init.io, allocator, suite, input, output_path, provenance);
    } else if (std.mem.eql(u8, kind, "sig")) {
        try convertSig(init.io, allocator, suite, input, output_path, provenance);
    } else {
        fatal("unsupported kind: {s}", .{kind});
    }
}

fn convertKem(io: std.Io, allocator: std.mem.Allocator, suite: []const u8, input: []const u8, output_path: []const u8, provenance: []const u8) !void {
    const seed = findValue(input, "seed") orelse fatal("missing liboqs seed field", .{});
    const pk = findValue(input, "pk") orelse fatal("missing liboqs pk field", .{});
    const sk = findValue(input, "sk") orelse fatal("missing liboqs sk field", .{});
    const ct = findValue(input, "ct") orelse fatal("missing liboqs ct field", .{});
    const ss = findValue(input, "ss") orelse fatal("missing liboqs ss field", .{});

    try validateHex(seed);
    try validateHex(pk);
    try validateHex(sk);
    try validateHex(ct);
    try validateHex(ss);

    var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;
    defer out.flush() catch {};

    try out.writeAll("# Converted from liboqs KAT output. Provenance required.\n");
    try out.print("suite = {s}\n", .{suite});
    try out.writeAll("source = liboqs-kat-output\n");
    try out.writeAll("classification = generated-liboqs\n");
    try out.print("provenance = {s}\n", .{provenance});
    try out.writeAll("# liboqs uses a KAT PRNG seed; ZQLite's stdlib backend uses split deterministic seeds.\n");
    try out.writeAll("# This file is for provenance tracking until a liboqs backend can execute it directly.\n");
    try out.print("liboqs_seed = {s}\n", .{seed});
    try out.print("expected_public_key = {s}\n", .{pk});
    try out.print("expected_secret_key = {s}\n", .{sk});
    try out.print("expected_ciphertext = {s}\n", .{ct});
    try out.print("expected_shared_secret = {s}\n", .{ss});
    _ = allocator;
}

fn convertSig(io: std.Io, _: std.mem.Allocator, suite: []const u8, input: []const u8, output_path: []const u8, provenance: []const u8) !void {
    const seed = findValue(input, "seed") orelse fatal("missing liboqs seed field", .{});
    const msg = findValue(input, "msg") orelse findValue(input, "message") orelse fatal("missing liboqs msg/message field", .{});
    const pk = findValue(input, "pk") orelse fatal("missing liboqs pk field", .{});
    const sk = findValue(input, "sk") orelse fatal("missing liboqs sk field", .{});
    const sig = findValue(input, "sig") orelse findValue(input, "sm") orelse fatal("missing liboqs sig/sm field", .{});

    try validateHex(seed);
    try validateHex(pk);
    try validateHex(sk);
    try validateHex(sig);

    var file = try std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;
    defer out.flush() catch {};

    try out.writeAll("# Converted from liboqs KAT output. Provenance required.\n");
    try out.print("suite = {s}\n", .{suite});
    try out.writeAll("source = liboqs-kat-output\n");
    try out.writeAll("classification = generated-liboqs\n");
    try out.print("provenance = {s}\n", .{provenance});
    try out.writeAll("# This file is for provenance tracking until a liboqs backend can execute it directly.\n");
    try out.print("liboqs_seed = {s}\n", .{seed});
    try out.print("message = {s}\n", .{msg});
    try out.print("expected_public_key = {s}\n", .{pk});
    try out.print("expected_secret_key = {s}\n", .{sk});
    try out.print("expected_signature = {s}\n", .{sig});
}

fn findValue(data: []const u8, wanted_key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const delimiter = std.mem.indexOfScalar(u8, line, '=') orelse std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..delimiter], " \t");
        if (!std.ascii.eqlIgnoreCase(key, wanted_key)) continue;
        return std.mem.trim(u8, line[delimiter + 1 ..], " \t");
    }
    return null;
}

fn validateHex(value: []const u8) !void {
    if (value.len % 2 != 0) return error.InvalidHex;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return error.InvalidHex;
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}
