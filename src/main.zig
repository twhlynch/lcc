//! lcc LC-3 to LLVM compiler

const std = @import("std");

const compiler = @import("compiler.zig");
const elk = compiler.elk;
const args = @import("args.zig");
const zilc = @import("zilc");

test {
    _ = @import("tests.zig");
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
    options: args.Options,
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
    var cli_args = try zilc.collectArgs(args_allocator, init.minimal.args);
    defer cli_args.deinit(init.arena.allocator());

    const parsed = args.parse(gpa, gpa, cli_args.items, out) catch |err| switch (err) {
        error.Usage, error.ParseFailed, error.InvalidValue => {
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
    const ext = std.fs.path.extension(basename);
    if (ext.len > 0 and ext.len < basename.len)
        return basename[0 .. basename.len - ext.len];
    return "a.out";
}
