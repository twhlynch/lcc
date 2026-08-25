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

    const options: zilc.Options(template) = try .parse(gpa, arena, args, parse_config);

    const input = options.getPos(gpa, zilc.types.string, .input, 0) catch {
        std.log.err("missing input file", .{});
        return error.Usage;
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
