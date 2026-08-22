//! lcc LC-3 to LLVM compiler

const std = @import("std");

const usage =
    \\Usage: lcc [options] <input.asm>
    \\
    \\Options:
    \\  -o <file>     Output executable path
    \\  -O<N>         Optimisation level, 0-3
    \\  -h, --help    Show this help
    \\
;

pub const Optimize = enum(u8) {
    @"0" = 0,
    @"1" = 1,
    @"2" = 2,
    @"3" = 3,
};

pub const Options = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    optimize: Optimize = .@"0",
};

const ParsedArgs = union(enum) {
    help,
    run: Options,
};

const ArgsError = error{Usage} || std.Io.Writer.Error;

fn parseArgs(
    args: []const [*:0]const u8,
    out: *std.Io.Writer,
) ArgsError!ParsedArgs {
    var options: Options = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            return .help;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i == args.len) {
                std.log.err("-o requires a file argument", .{});
                return error.Usage;
            }
            options.output = std.mem.span(args[i]);
        } else if (std.mem.startsWith(u8, arg, "-O")) {
            const level = arg[2..];
            if (level.len != 1 or level[0] < '0' or level[0] > '3') {
                std.log.err("invalid optimisation level '{s}' (expected -O0..-O3)", .{arg});
                return error.Usage;
            }
            options.optimize = @enumFromInt(level[0] - '0');
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("unknown option '{s}'", .{arg});
            return error.Usage;
        } else if (options.input == null) {
            options.input = arg;
        } else {
            std.log.err("unexpected argument '{s}'", .{arg});
            return error.Usage;
        }
    }

    if (options.input == null) {
        std.log.err("no input file\n{s}", .{usage});
        return error.Usage;
    }

    return .{ .run = options };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const parsed = parseArgs(init.minimal.args.vector[1..], out) catch |err| switch (err) {
        error.Usage => {
            try out.flush();
            return 2;
        },
        else => |other| return other,
    };
    try out.flush();
    const options = switch (parsed) {
        .help => return 0,
        .run => |options| options,
    };
    _ = options;

    return 0;
}
