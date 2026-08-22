//! lcc LC-3 to LLVM compiler

const std = @import("std");

const compiler = @import("compiler.zig");
const elk = compiler.elk;

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

const Diagnostics = struct {
    stderr_buffer: [1024]u8 = undefined,
    stderr_writer: std.Io.File.Writer = undefined,
    fancy_sink: elk.reporting.Sink.Fancy = undefined,
    reporter: elk.reporting.Primary = undefined,

    fn init(diags: *Diagnostics, io: std.Io) void {
        diags.stderr_writer = std.Io.File.stderr().writer(io, &diags.stderr_buffer);
        diags.fancy_sink = .new(&diags.stderr_writer.interface);
        diags.reporter = .new(diags.fancy_sink.interface());
    }

    fn summarize(diags: *Diagnostics) void {
        diags.reporter.summarize();
    }
};

fn compile(
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    diags: *Diagnostics,
) (error{CompileFailed} || compiler.Error)!compiler.Program {
    return compiler.assembleFile(io, gpa, options.input.?, &diags.reporter) catch |err| switch (err) {
        error.AssemblyFailed => {
            diags.summarize();
            return error.CompileFailed;
        },
        error.FileNotFound => {
            std.log.err("file not found: {s}", .{options.input.?});
            return error.CompileFailed;
        },
        else => |other| return other,
    };
}

fn printSummary(
    out: *std.Io.Writer,
    program: *const compiler.Program,
) std.Io.Writer.Error!void {
    try out.print(
        "Assembled {} words at origin x{X:04} ({} labels)\n",
        .{
            program.air.lines.items.len,
            program.air.origin,
            program.air.labels.items.len,
        },
    );
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

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

    var diags: Diagnostics = undefined;
    diags.init(io);

    var program = compile(io, gpa, options, &diags) catch {
        try out.flush();
        return 1;
    };
    defer program.deinit(gpa);

    try printSummary(out, &program);

    diags.summarize();
    try out.flush();

    return 0;
}
