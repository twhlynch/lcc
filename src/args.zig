const std = @import("std");
const zilc = @import("zilc");

pub const usage =
    \\Usage: lcc [options] <input.asm> [extra.asm ...]
    \\
    \\Options:
    \\  -o <file>               Output executable path
    \\  -O<N>                   Optimisation level: none, 0-3
    \\  -target <triple>        LLVM target triple for code generation
    \\  -arch <name>            Architecture component of the host triple
    \\  -E, -emit-llvm          Print optimised LLVM IR
    \\
    \\  -dynamic                Link against liblc3 dynamically
    \\  -L<dir>                 Directory to search for liblc3
    \\  -generate-liblc3        Generate liblc3 shared library
    \\
    \\  -T, -traps <name|file>  Load a set: bundled name or source file (repeatable)
    \\  -generate-traps-header  Generate lcc_trap.h
    \\
    \\  -v, --version           Print version information
    \\  -h, --help              Show this help
    \\
;

pub const version =
    \\lcc 0.4.0
    \\Copyright (C) 2026 Tom Lynch
    \\License GPL-3.0
    \\
;

pub const Optimize = enum(u8) {
    none = 0,
    @"0" = 1,
    @"1" = 2,
    @"2" = 3,
    @"3" = 4,
};

pub const Options = struct {
    inputs: []const []const u8,
    output: ?[]const u8,
    optimize: Optimize,
    emit_llvm: bool,
    target: ?[]const u8,
    arch: ?[]const u8,
    dynamic: bool,
    lib_path: ?[]const u8,
    generate_liblc3: bool,
    trap_specs: []const []const u8,
};

pub const Result = union(enum) {
    help,
    version,
    generate_traps_header,
    generate_liblc3: GenerateLiblc3,
    run: Options,
};

pub const GenerateLiblc3 = struct {
    target: ?[]const u8,
    arch: ?[]const u8,
};

const template = .{
    .output = zilc.Flag{
        .short = 'o',
        .long = "output",
        .value = zilc.types.string,
    },
    .optimize = zilc.Flag{
        .short = 'O',
        .long = "optimize",
        .value = .{ .type = Optimize, .parser = parseOptimize },
    },
    .emit_llvm = zilc.Flag{
        .short = 'E',
        .long = "emit-llvm",
    },
    .target = zilc.Flag{
        .long = "target",
        .value = zilc.types.string,
    },
    .arch = zilc.Flag{
        .long = "arch",
        .value = zilc.types.string,
    },
    .dynamic = zilc.Flag{
        .long = "dynamic",
    },
    .lib_path = zilc.Flag{
        .short = 'L',
        .long = "lib-path",
        .value = zilc.types.string,
    },
    .generate_liblc3 = zilc.Flag{
        .long = "generate-liblc3",
    },
    .generate_traps_header = zilc.Flag{
        .long = "generate-traps-header",
    },
};

const parse_config: zilc.ParseConfig = .{
    .single_dash_long = true,
    .joined_short_value = true,
};

fn isValidOptimize(src: []const u8) bool {
    return std.mem.eql(u8, src, "none") or
        (src.len == 1 and src[0] >= '0' and src[0] <= '3');
}

fn parseOptimize(dest: *anyopaque, src: []const u8, _: std.mem.Allocator) !void {
    const optimize: *?Optimize = @ptrCast(@alignCast(dest));
    if (std.mem.eql(u8, src, "none")) {
        optimize.* = .none;
    } else if (src.len == 1 and src[0] >= '0' and src[0] <= '3') {
        optimize.* = @enumFromInt(src[0] - '0' + 1);
    } else {
        return error.InvalidValue;
    }
}

/// zilc's parser callback can only return `error.InvalidValue`, so when
/// that surfaces the rejected value is recovered from the argument list
/// to keep the diagnostic specific.
fn invalidOptimizeMessage(arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const fmt = "invalid optimisation level '{s}' (expected -Onone or -O0..-O3)";
    for (argv, 0..) |arg, idx| {
        const value: ?[]const u8 = if (std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "-optimize"))
            if (idx + 1 < argv.len) argv[idx + 1] else null
        else if (std.mem.startsWith(u8, arg, "-O") and arg.len > 2)
            arg[2..]
        else
            null;
        if (value) |v| {
            if (!isValidOptimize(v)) return std.fmt.allocPrint(arena, fmt, .{v});
        }
    }
    return std.fmt.allocPrint(arena, "invalid optimisation level (expected -Onone or -O0..-O3)", .{});
}

/// zilc only accepts long flags written with a single dash under
/// `single_dash_long`, so `--output` is rewritten to `-output` before
/// parsing. The `--` marker and values that cannot be flags (`-`, `---x`)
/// pass through untouched; everything after `--` is positional. rewrites
/// share one scratch buffer so deinit frees everything.
const Normalized = struct {
    list: std.ArrayList([]const u8),
    scratch: ?[]u8,

    fn deinit(self: *Normalized, arena: std.mem.Allocator) void {
        self.list.deinit(arena);
        if (self.scratch) |buf| arena.free(buf);
    }
};

fn isRewritable(arg: []const u8) bool {
    return arg.len > 2 and arg[0] == '-' and arg[1] == '-' and arg[2] != '-';
}

fn normalizeArgs(arena: std.mem.Allocator, args: []const []const u8) !Normalized {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(arena);

    var scratch_len: usize = 0;
    for (args) |arg| {
        if (isRewritable(arg)) scratch_len += arg.len - 1;
    }
    const scratch: ?[]u8 = if (scratch_len > 0) try arena.alloc(u8, scratch_len) else null;
    errdefer if (scratch) |buf| arena.free(buf);

    var at: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            try list.appendSlice(arena, args[i..]);
            break;
        }
        if (isRewritable(arg)) {
            const buf = scratch.?;
            buf[at] = '-';
            @memcpy(buf[at + 1 ..][0 .. arg.len - 2], arg[2..]);
            try list.append(arena, buf[at .. at + arg.len - 1]);
            at += arg.len - 1;
            continue;
        }
        try list.append(arena, arg);
    }
    return .{ .list = list, .scratch = scratch };
}

/// mirrors zilc's cutArgPrefix: arguments that cannot be flag values
fn looksLikeFlag(arg: []const u8) bool {
    return (arg.len >= 2 and arg[0] == '-' and arg[1] != '-') or
        (arg.len >= 3 and arg[0] == '-' and arg[1] == '-' and arg[2] != '-');
}

const TrapScan = struct {
    specs: std.ArrayList([]const u8),
    rest: std.ArrayList([]const u8),
    /// the spelling the user typed, kept for diagnostics; -traps when no
    /// flag was given
    flag: []const u8 = "-traps",
};

fn isTrapsFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-traps") or std.mem.eql(u8, arg, "-T");
}

/// diagnostics for one spelling of the traps flag. errmsg is never freed
/// by the cli layer and unit tests pass the testing allocator through, so
/// every message is a static string.
const TrapsMessages = struct {
    missing: []const u8,
    empty: []const u8,
    header: []const u8,
    liblc3: []const u8,
};

fn trapsMessages(flag: []const u8) TrapsMessages {
    return if (std.mem.eql(u8, flag, "-T")) .{
        .missing = "missing value for -T",
        .empty = "empty trap set path in -T",
        .header = "cannot combine -T with -generate-traps-header",
        .liblc3 = "cannot combine -T with -generate-liblc3",
    } else .{
        .missing = "missing value for -traps",
        .empty = "empty trap set path in -traps",
        .header = "cannot combine -traps with -generate-traps-header",
        .liblc3 = "cannot combine -traps with -generate-liblc3",
    };
}

/// pulls every `-traps <value>` pair out of the argument list so zilc
/// never sees the flag (it would reject it as unknown, and repeated value
/// flags would overwrite each other). each flag carries one set path.
/// failures are reported through `errmsg` rather than logged: the cli
/// layer owns diagnostics so unit tests can exercise error paths.
/// TODO: add this to zilc?
fn extractTrapSpecs(
    arena: std.mem.Allocator,
    args: []const []const u8,
    errmsg: *?[]const u8,
) !TrapScan {
    var specs: std.ArrayList([]const u8) = .empty;
    errdefer specs.deinit(arena);
    var rest: std.ArrayList([]const u8) = .empty;
    errdefer rest.deinit(arena);
    var flag: []const u8 = "-traps";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            try rest.appendSlice(arena, args[i..]);
            break;
        }
        if (isTrapsFlag(arg)) {
            if (i + 1 >= args.len or std.mem.eql(u8, args[i + 1], "--") or looksLikeFlag(args[i + 1])) {
                errmsg.* = trapsMessages(arg).missing;
                return error.Usage;
            }
            const value = args[i + 1];
            if (value.len == 0) {
                errmsg.* = trapsMessages(arg).empty;
                return error.Usage;
            }
            if (specs.items.len == 0) flag = arg;
            try specs.append(arena, value);
            i += 1;
            continue;
        }
        try rest.append(arena, arg);
    }
    return .{ .specs = specs, .rest = rest, .flag = flag };
}

pub fn parse(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    args: []const []const u8,
    out: *std.Io.Writer,
    errmsg: *?[]const u8,
) !Result {
    if (zilc.getMetaArg(args, .help)) |meta| {
        switch (meta) {
            .help => {
                try out.writeAll(usage);
                return .help;
            },
            .version => {
                try out.writeAll(version);
                return .version;
            },
        }
    }

    var normalized = try normalizeArgs(arena, args);
    defer normalized.deinit(arena);

    var scan = try extractTrapSpecs(arena, normalized.list.items, errmsg);
    defer scan.rest.deinit(arena);
    errdefer scan.specs.deinit(arena);

    var options: zilc.Options(template) = zilc.Options(template).parse(gpa, arena, scan.rest.items, parse_config) catch |err| switch (err) {
        error.InvalidValue => {
            errmsg.* = try invalidOptimizeMessage(arena, scan.rest.items);
            return error.InvalidValue;
        },
        else => |other| return other,
    };
    defer options.deinit(arena);

    if (options.flags.generate_traps_header) {
        if (scan.specs.items.len > 0) {
            errmsg.* = trapsMessages(scan.flag).header;
            return error.Usage;
        }
        return .generate_traps_header;
    }

    if (options.flags.generate_liblc3) {
        if (scan.specs.items.len > 0) {
            errmsg.* = trapsMessages(scan.flag).liblc3;
            return error.Usage;
        }
        return .{ .generate_liblc3 = .{
            .target = options.flags.target,
            .arch = options.flags.arch,
        } };
    }

    // first positional is the main file, any further positionals are
    // extra files assembled alongside it at their own origins
    _ = options.getPos(gpa, zilc.types.string, .input, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Usage,
    };
    const inputs = try arena.alloc([]const u8, options.pos.items.len);
    @memcpy(inputs, options.pos.items);

    // shrink so the returned slices can be freed by exact length
    if (scan.specs.items.len > 0) try scan.specs.shrinkToLen(arena);

    return .{ .run = .{
        .inputs = inputs,
        .output = options.flags.output,
        .optimize = options.flags.optimize orelse .@"0",
        .emit_llvm = options.flags.emit_llvm,
        .target = options.flags.target,
        .arch = options.flags.arch,
        .dynamic = options.flags.dynamic,
        .lib_path = options.flags.lib_path,
        .generate_liblc3 = options.flags.generate_liblc3,
        .trap_specs = scan.specs.items,
    } };
}

test parse {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    const testParse = struct {
        fn testParse(args: []const []const u8) !Result {
            var buf: [8192]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            var errmsg: ?[]const u8 = null;
            return parse(std.testing.allocator, std.testing.allocator, args, &writer, &errmsg);
        }
    }.testParse;

    // meta: help and version
    try expectEqual(.help, try testParse(&.{}));
    try expectEqual(.help, try testParse(&.{"--help"}));
    try expectEqual(.help, try testParse(&.{"-h"}));
    try expectEqual(.version, try testParse(&.{"--version"}));
    try expectEqual(.version, try testParse(&.{"-v"}));

    // meta: extra args ignored
    try expectEqual(.help, try testParse(&.{ "--help", "file.asm" }));
    try expectEqual(.version, try testParse(&.{ "-v", "file.asm" }));

    // basic compile
    {
        const r = (try testParse(&.{"file.asm"})).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqual(@as(usize, 1), r.inputs.len);
        try expectEqualStrings("file.asm", r.inputs[0]);
        try expectEqual(.@"0", r.optimize);
        try expect(!r.emit_llvm);
        try expect(!r.dynamic);
        try expectEqual(null, r.lib_path);
    }

    // -o flag
    {
        const r = (try testParse(&.{ "-o", "out", "file.asm" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqualStrings("out", r.output.?);
    }

    // -O flags: joined value
    {
        inline for ([_][]const []const u8{ &.{ "-O0", "f" }, &.{ "-O1", "f" }, &.{ "-O2", "f" }, &.{ "-O3", "f" }, &.{ "-Onone", "f" } }, [_]Optimize{ .@"0", .@"1", .@"2", .@"3", .none }) |argv, want| {
            const r = (try testParse(argv)).run;
            defer std.testing.allocator.free(r.inputs);
            try expectEqual(want, r.optimize);
        }
    }

    // -O flag: separate value
    {
        const r = (try testParse(&.{ "-O", "2", "f" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqual(.@"2", r.optimize);
    }

    // -emit-llvm
    {
        const r = (try testParse(&.{ "-emit-llvm", "f" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expect(r.emit_llvm);
    }

    // -target
    {
        const r = (try testParse(&.{ "-target", "x86_64-linux-gnu", "f" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqualStrings("x86_64-linux-gnu", r.target.?);
    }

    // -arch
    {
        const r = (try testParse(&.{ "-arch", "x86_64", "f" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqualStrings("x86_64", r.arch.?);
    }

    // --dynamic
    {
        const r = (try testParse(&.{ "--dynamic", "f" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expect(r.dynamic);
    }

    // --lib-path
    {
        const r = (try testParse(&.{ "--lib-path", "/usr/lib", "f" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqualStrings("/usr/lib", r.lib_path.?);
    }

    // --generate-liblc3
    {
        const r = try testParse(&.{"--generate-liblc3"});
        try expectEqual(.generate_liblc3, @as(std.meta.Tag(Result), r));
    }

    // combined flags
    {
        const r = (try testParse(&.{ "-o", "out", "-O2", "-emit-llvm", "-arch", "arm64", "--dynamic", "--lib-path", "/tmp", "f" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqualStrings("out", r.output.?);
        try expectEqual(.@"2", r.optimize);
        try expect(r.emit_llvm);
        try expectEqualStrings("arm64", r.arch.?);
        try expect(r.dynamic);
        try expectEqualStrings("/tmp", r.lib_path.?);
    }

    // end-of-options marker
    {
        const r = (try testParse(&.{ "--", "file.asm" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqualStrings("file.asm", r.inputs[0]);
    }

    // multiple inputs: first is main, rest are extras
    {
        const r = (try testParse(&.{ "main.asm", "extra1.asm", "extra2.asm" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqual(@as(usize, 3), r.inputs.len);
        try expectEqualStrings("main.asm", r.inputs[0]);
        try expectEqualStrings("extra1.asm", r.inputs[1]);
        try expectEqualStrings("extra2.asm", r.inputs[2]);
    }

    // no -traps: empty specs
    {
        const r = (try testParse(&.{"f"})).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqual(@as(usize, 0), r.trap_specs.len);
    }

    // -traps: one path per flag, repeated
    {
        const r = (try testParse(&.{ "-traps", "a.c", "-traps", "b.cpp", "f" })).run;
        defer std.testing.allocator.free(r.trap_specs);
        defer std.testing.allocator.free(r.inputs);
        try expectEqual(@as(usize, 2), r.trap_specs.len);
        try expectEqualStrings("a.c", r.trap_specs[0]);
        try expectEqualStrings("b.cpp", r.trap_specs[1]);
    }

    // --traps: double dash is normalized too
    {
        const r = (try testParse(&.{ "--traps", "x", "f" })).run;
        defer std.testing.allocator.free(r.trap_specs);
        defer std.testing.allocator.free(r.inputs);
        try expectEqual(@as(usize, 1), r.trap_specs.len);
        try expectEqualStrings("x", r.trap_specs[0]);
    }

    // -T: shorthand for -traps, one path per flag, repeated
    {
        const r = (try testParse(&.{ "-T", "a.c", "-T", "b.cpp", "f" })).run;
        defer std.testing.allocator.free(r.trap_specs);
        defer std.testing.allocator.free(r.inputs);
        try expectEqual(@as(usize, 2), r.trap_specs.len);
        try expectEqualStrings("a.c", r.trap_specs[0]);
        try expectEqualStrings("b.cpp", r.trap_specs[1]);
    }

    // -T and -traps mix freely
    {
        const r = (try testParse(&.{ "-traps", "a.c", "-T", "b.cpp", "f" })).run;
        defer std.testing.allocator.free(r.trap_specs);
        defer std.testing.allocator.free(r.inputs);
        try expectEqual(@as(usize, 2), r.trap_specs.len);
        try expectEqualStrings("a.c", r.trap_specs[0]);
        try expectEqualStrings("b.cpp", r.trap_specs[1]);
    }

    // -T after the -- marker stays positional
    {
        const r = (try testParse(&.{ "--", "-T" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqualStrings("-T", r.inputs[0]);
        try expectEqual(@as(usize, 0), r.trap_specs.len);
    }

    // -traps after the -- marker stays positional
    {
        const r = (try testParse(&.{ "--", "-traps" })).run;
        defer std.testing.allocator.free(r.inputs);
        try expectEqualStrings("-traps", r.inputs[0]);
        try expectEqual(@as(usize, 0), r.trap_specs.len);
    }

    // -traps: missing or flag-shaped values
    try std.testing.expectError(error.Usage, testParse(&.{"-traps"}));
    try std.testing.expectError(error.Usage, testParse(&.{ "f", "-traps" }));
    try std.testing.expectError(error.Usage, testParse(&.{ "-traps", "--", "f" }));
    try std.testing.expectError(error.Usage, testParse(&.{ "-traps", "-o", "f" }));
    try std.testing.expectError(error.Usage, testParse(&.{ "-traps", "", "f" }));

    // -T: missing or flag-shaped values
    try std.testing.expectError(error.Usage, testParse(&.{"-T"}));
    try std.testing.expectError(error.Usage, testParse(&.{ "f", "-T" }));
    try std.testing.expectError(error.Usage, testParse(&.{ "-T", "--", "f" }));
    try std.testing.expectError(error.Usage, testParse(&.{ "-T", "-o", "f" }));
    try std.testing.expectError(error.Usage, testParse(&.{ "-T", "", "f" }));

    // -generate-traps-header needs no input file
    try expectEqual(.generate_traps_header, try testParse(&.{"-generate-traps-header"}));

    // -traps with the generated outputs is rejected
    try std.testing.expectError(error.Usage, testParse(&.{ "-traps", "x", "-generate-liblc3" }));
    try std.testing.expectError(error.Usage, testParse(&.{ "-traps", "x", "-generate-traps-header" }));
    try std.testing.expectError(error.Usage, testParse(&.{ "-T", "x", "-generate-liblc3" }));
    try std.testing.expectError(error.Usage, testParse(&.{ "-T", "x", "-generate-traps-header" }));

    // failure diagnostics are returned to the caller instead of logged
    {
        var buf: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var errmsg: ?[]const u8 = null;

        try std.testing.expectError(error.Usage, parse(a, a, &.{"-traps"}, &writer, &errmsg));
        try expectEqualStrings("missing value for -traps", errmsg.?);

        // the diagnostics name the spelling the user typed
        errmsg = null;
        try std.testing.expectError(error.Usage, parse(a, a, &.{"-T"}, &writer, &errmsg));
        try expectEqualStrings("missing value for -T", errmsg.?);

        errmsg = null;
        try std.testing.expectError(error.Usage, parse(a, a, &.{ "-T", "", "f" }, &writer, &errmsg));
        try expectEqualStrings("empty trap set path in -T", errmsg.?);

        errmsg = null;
        try std.testing.expectError(error.Usage, parse(a, a, &.{ "-T", "x", "-generate-liblc3" }, &writer, &errmsg));
        try expectEqualStrings("cannot combine -T with -generate-liblc3", errmsg.?);

        errmsg = null;
        try std.testing.expectError(error.InvalidValue, parse(a, a, &.{ "-O5", "f" }, &writer, &errmsg));
        try expectEqualStrings("invalid optimisation level '5' (expected -Onone or -O0..-O3)", errmsg.?);

        // multiple positionals are accepted (main + extras)
        {
            const r = (try parse(a, a, &.{ "f", "g" }, &writer, &errmsg)).run;
            try expectEqual(@as(usize, 2), r.inputs.len);
        }
    }
}
