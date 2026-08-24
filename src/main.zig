//! lcc LC-3 to LLVM compiler

const std = @import("std");

const compiler = @import("compiler.zig");
const elk = compiler.elk;

const version = "0.1.0";

test {
    _ = @import("tests.zig");
}

const usage =
    \\Usage: lcc [options] <input.asm>
    \\
    \\Options:
    \\  -o <file>        Output executable path
    \\  -O<N>            Optimisation level: none, 0-3
    \\  -target <triple> LLVM target triple for code generation
    \\  -arch <name>     Architecture component of the host triple
    \\  -emit-llvm       Print optimised LLVM IR
    \\  --version        Print version information
    \\  -h, --help       Show this help
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
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    optimize: Optimize = .@"0",
    emit_llvm: bool = false,
    target: ?[]const u8 = null,
    arch: ?[]const u8 = null,
};

const ParsedArgs = union(enum) {
    help,
    version,
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
        } else if (std.mem.eql(u8, arg, "--version")) {
            try out.print("lcc {s}\n", .{version});
            return .version;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i == args.len) {
                std.log.err("-o requires a file argument", .{});
                return error.Usage;
            }
            options.output = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "-target") or std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i == args.len) {
                std.log.err("-target requires a triple argument", .{});
                return error.Usage;
            }
            options.target = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "-arch")) {
            i += 1;
            if (i == args.len) {
                std.log.err("-arch requires an architecture name", .{});
                return error.Usage;
            }
            options.arch = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "-emit-llvm")) {
            options.emit_llvm = true;
        } else if (std.mem.startsWith(u8, arg, "-O")) {
            const level = arg[2..];
            if (std.mem.eql(u8, level, "none")) {
                options.optimize = .none;
            } else if (level.len == 1 and level[0] >= '0' and level[0] <= '3') {
                options.optimize = @enumFromInt(level[0] - '0' + 1);
            } else {
                std.log.err("invalid optimisation level '{s}' (expected -Onone or -O0..-O3)", .{arg});
                return error.Usage;
            }
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
        diags.fancy_sink = .new(&diags.stderr_writer.interface, true);
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
        .version => return 0,
        .run => |options| options,
    };

    var diags: Diagnostics = undefined;
    diags.init(io);

    var program = compile(io, gpa, options, &diags) catch {
        try out.flush();
        return 1;
    };
    defer program.deinit(gpa);

    diags.summarize();

    try printSummary(out, &program);
    if (options.emit_llvm) try out.writeByte('\n');

    const triple = compiler.resolveTriple(gpa, options.target, options.arch) catch |err| return err;
    defer if (triple) |t| gpa.free(t);

    compiler.compileAndLink(
        io,
        gpa,
        &program,
        init.environ_map,
        options.output orelse defaultOutput(options.input.?),
        @enumFromInt(@intFromEnum(options.optimize)),
        options.emit_llvm,
        triple,
    ) catch |err| switch (err) {
        error.InvalidModule => {
            std.log.err("generated LLVM IR failed verification", .{});
            out.flush() catch {};
            return 1;
        },
        // unsupported instructions and bad targets are logged at the
        // failing word during code generation
        error.UnsupportedInstruction, error.InvalidTarget => {
            out.flush() catch {};
            return 1;
        },
        error.ClangNotFound => {
            std.log.err("'clang' not found; cannot link the executable", .{});
            out.flush() catch {};
            return 1;
        },
        error.LinkFailed => {
            std.log.err("linking failed", .{});
            out.flush() catch {};
            return 1;
        },
        error.PassRunFailed => {
            std.log.err("LLVM optimisation pipeline failed", .{});
            out.flush() catch {};
            return 1;
        },
        // everything left already logged where it occurred, or is
        // environmental; report cleanly instead of unwinding
        else => |other| {
            std.log.err("compilation failed: {s}", .{@errorName(other)});
            out.flush() catch {};
            return 1;
        },
    };

    // a closed pipe is not an error
    out.flush() catch {};

    return 0;
}

/// lcc foo.asm -> foo
fn defaultOutput(input: []const u8) []const u8 {
    const basename = std.fs.path.basename(input);
    const stem = if (std.fs.path.extension(basename).len > 0)
        basename[0 .. basename.len - std.fs.path.extension(basename).len]
    else
        basename;
    return stem;
}
