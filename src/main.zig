//! lcc LC-3 to LLVM compiler

const std = @import("std");

const compiler = @import("compiler.zig");
const elk = compiler.elk;
const zilc = @import("zilc");

test {
    _ = @import("tests.zig");
}

const usage =
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

const version =
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

const Options = struct {
    input: []const u8,
    output: ?[]const u8,
    optimize: Optimize,
    emit_llvm: bool,
    target: ?[]const u8,
    arch: ?[]const u8,
};

const ParsedArgs = union(enum) {
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

pub fn parseArgs(gpa: std.mem.Allocator, arena: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !ParsedArgs {
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
    return compiler.assembleFile(io, gpa, options.input, &diags.reporter) catch |err| switch (err) {
        error.AssemblyFailed => {
            diags.summarize();
            return error.CompileFailed;
        },
        error.FileNotFound => {
            std.log.err("file not found: {s}", .{options.input});
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

    const args_allocator = init.arena.allocator();
    var args = try zilc.collectArgs(args_allocator, init.minimal.args);
    defer args.deinit(init.arena.allocator());

    const parsed = blk: {
        var temp_arena = std.heap.ArenaAllocator.init(gpa);
        defer temp_arena.deinit();
        break :blk parseArgs(gpa, temp_arena.allocator(), args.items, out) catch |err|
            switch (err) {
                error.Usage, error.ParseFailed, error.InvalidValue => {
                    try out.flush();
                    return 2;
                },
                else => |other| return other,
            };
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
        options.output orelse defaultOutput(options.input),
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
