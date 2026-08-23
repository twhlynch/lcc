//! compiler pipeline

const std = @import("std");
pub const elk = @import("elk.zig");
pub const codegen = @import("codegen/codegen.zig");
pub const linker = @import("linker.zig");
pub const llvm = @import("llvmc/root.zig");

pub const Error = error{
    AssemblyFailed,
} || std.Io.Dir.RealPathFileError || std.Io.Dir.ReadFileAllocError;

/// program elk ir and source
pub const Program = struct {
    air: elk.Air,
    source: elk.Source,
    text: []const u8,

    pub fn deinit(program: *Program, gpa: std.mem.Allocator) void {
        program.air.deinit(gpa);
        gpa.free(program.text);
        if (program.source.path) |path| gpa.free(path);
    }
};

/// read an assembly file, parse it with elk
/// diagnostics are reported through the provided reporter
pub fn assembleFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    reporter: *elk.reporting.Primary,
) Error!Program {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try std.Io.Dir.cwd().realPathFile(io, path, &path_buffer);
    const resolved_path = path_buffer[0..length];

    const text = try std.Io.Dir.cwd().readFileAlloc(
        io,
        resolved_path,
        gpa,
        .unlimited,
    );
    errdefer gpa.free(text);

    // keep the path alive for diagnostics
    const owned_path = try gpa.dupe(u8, resolved_path);
    errdefer gpa.free(owned_path);

    const source: elk.Source = .{ .text = text, .path = owned_path };
    reporter.source = source;

    var air = try elk.assemble(
        gpa,
        source,
        &elk.standard_traps,
        elk.standard_policies,
        reporter,
    );
    errdefer air.deinit(gpa);

    return .{ .air = air, .source = source, .text = text };
}

/// scratch locations for temp object file and runtime source
const obj_scratch_path = ".lcc-tmp.o";
const rt_scratch_path = ".lcc-tmp-rt.c";

/// native trap runtime, written next to the object file at link time
const runtime_source = @embedFile("runtime/lc3_runtime.c");

pub const CompileError = error{
    UnsupportedInstruction,
    InvalidTarget,
    InvalidModule,
    UnknownTriple,
    EmissionFailed,
    PassRunFailed,
    OutOfMemory,
} || linker.LinkError || std.Io.File.OpenError || std.Io.Writer.Error;

/// elk.Air -> LLVM module -> verify -> optimise -> object file -> link
pub fn compileAndLink(
    io: std.Io,
    gpa: std.mem.Allocator,
    program: *const Program,
    environ_map: ?*const std.process.Environ.Map,
    output_path: []const u8,
    level: llvm.pass.Level,
    emit_llvm: bool,
) CompileError!void {
    var output = try codegen.CodeGen.emit(&program.air, gpa);
    defer output.deinit();

    var machine = try llvm.target.TargetMachine.createDefault(codeGenLevel(level));
    defer machine.dispose();
    machine.configureModule(output.module);

    var message: ?[]u8 = null;
    output.module.verify(gpa, &message) catch |err| switch (err) {
        error.InvalidModule => {
            if (message) |msg| {
                std.log.err("LLVM verifier: {s}", .{msg});
                gpa.free(msg);
            }
            return error.InvalidModule;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    try llvm.pass.runDefault(level, gpa, output.module, machine);

    // printed after optimisation so the -O level is visible
    if (emit_llvm) printLlvm(io, gpa, output.module);

    const object = try machine.emitObjectAlloc(gpa, output.module);
    defer gpa.free(object);

    try writeScratch(io, obj_scratch_path, object);
    errdefer std.Io.Dir.cwd().deleteFile(io, obj_scratch_path) catch {};
    try writeScratch(io, rt_scratch_path, runtime_source);
    errdefer std.Io.Dir.cwd().deleteFile(io, rt_scratch_path) catch {};

    try linker.link(io, gpa, environ_map, obj_scratch_path, rt_scratch_path, output_path);

    std.Io.Dir.cwd().deleteFile(io, obj_scratch_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, rt_scratch_path) catch {};
}

fn codeGenLevel(level: llvm.pass.Level) llvm.bindings.CodeGenOptLevel {
    return switch (level) {
        .none => .none,
        .o0 => .none,
        .o1 => .less,
        .o2 => .default,
        .o3 => .aggressive,
    };
}

fn printLlvm(io: std.Io, gpa: std.mem.Allocator, module: llvm.module.Module) void {
    const text = module.printToStringAlloc(gpa) catch return;
    defer gpa.free(text);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    // ignore failure
    stdout_writer.interface.writeAll(text) catch {};
    stdout_writer.interface.flush() catch {};
}

fn writeScratch(io: std.Io, path: []const u8, bytes: []const u8) (std.Io.File.OpenError || std.Io.Writer.Error)!void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
