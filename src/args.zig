const std = @import("std");
const zilc = @import("zilc");

pub const usage =
    \\Usage: lcc [options] <input.asm>
    \\
    \\Options:
    \\  -o <file>         Output executable path
    \\  -O<N>             Optimisation level: none, 0-3
    \\  -target <triple>  LLVM target triple for code generation
    \\  -arch <name>      Architecture component of the host triple
    \\  -emit-llvm        Print optimised LLVM IR
    \\  -v, --version     Print version information
    \\  -h, --help        Show this help
    \\
;

pub const version =
    \\lcc 0.1.0
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
    input: []const u8,
    output: ?[]const u8,
    optimize: Optimize,
    emit_llvm: bool,
    target: ?[]const u8,
    arch: ?[]const u8,
};

pub const Result = union(enum) {
    help,
    version,
    run: Options,
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
};

const parse_config: zilc.ParseConfig = .{
    .single_dash_long = true,
    .joined_short_value = true,
};

fn parseOptimize(dest: *anyopaque, src: []const u8, _: std.mem.Allocator) !void {
    const optimize: *?Optimize = @ptrCast(@alignCast(dest));
    if (std.mem.eql(u8, src, "none")) {
        optimize.* = .none;
    } else if (src.len == 1 and src[0] >= '0' and src[0] <= '3') {
        optimize.* = @enumFromInt(src[0] - '0' + 1);
    } else {
        std.log.err("invalid optimisation level '{s}' (expected -Onone or -O0..-O3)", .{src});
        return error.InvalidValue;
    }
}

pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !Result {
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

    var options: zilc.Options(template) = try .parse(gpa, arena, args, parse_config);
    defer options.deinit(arena);

    const input = options.getPos(gpa, zilc.types.string, .input, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Usage,
    };
    if (options.pos.items.len > 1) {
        std.log.err("unexpected argument '{s}'", .{options.pos.items[1]});
        return error.Usage;
    }

    return .{ .run = .{
        .input = input,
        .output = options.flags.output,
        .optimize = options.flags.optimize orelse .@"0",
        .emit_llvm = options.flags.emit_llvm,
        .target = options.flags.target,
        .arch = options.flags.arch,
    } };
}

test parse {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    const testParse = struct {
        fn testParse(args: []const []const u8) !Result {
            var buf: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            var writer = std.Io.Writer{ .interface = .{
                .context = @ptrCast(&fbs),
                .writeFn = @ptrCast(&std.io.FixedBufferStream([]u8).write),
            } };
            return parse(std.testing.allocator, std.testing.allocator, args, &writer);
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
        try expectEqualStrings("file.asm", r.input);
        try expectEqual(.@"0", r.optimize);
        try expect(!r.emit_llvm);
    }

    // -o flag
    {
        const r = (try testParse(&.{ "-o", "out", "file.asm" })).run;
        try expectEqualStrings("out", r.output.?);
    }

    // -O flags: joined value
    try expectEqual(.@"0", (try testParse(&.{ "-O0", "f" })).run.optimize);
    try expectEqual(.@"1", (try testParse(&.{ "-O1", "f" })).run.optimize);
    try expectEqual(.@"2", (try testParse(&.{ "-O2", "f" })).run.optimize);
    try expectEqual(.@"3", (try testParse(&.{ "-O3", "f" })).run.optimize);
    try expectEqual(.none, (try testParse(&.{ "-Onone", "f" })).run.optimize);

    // -O flag: separate value
    try expectEqual(.@"2", (try testParse(&.{ "-O", "2", "f" })).run.optimize);

    // -emit-llvm
    try expect((try testParse(&.{ "-emit-llvm", "f" })).run.emit_llvm);

    // -target
    try expectEqualStrings("x86_64-linux-gnu", (try testParse(&.{ "-target", "x86_64-linux-gnu", "f" })).run.target.?);

    // -arch
    try expectEqualStrings("x86_64", (try testParse(&.{ "-arch", "x86_64", "f" })).run.arch.?);

    // combined flags
    {
        const r = (try testParse(&.{ "-o", "out", "-O2", "-emit-llvm", "-arch", "arm64", "f" })).run;
        try expectEqualStrings("out", r.output.?);
        try expectEqual(.@"2", r.optimize);
        try expect(r.emit_llvm);
        try expectEqualStrings("arm64", r.arch.?);
    }

    // end-of-options marker
    try expectEqualStrings("file.asm", (try testParse(&.{ "--", "file.asm" })).run.input);
}
