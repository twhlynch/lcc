//! compiler pipeline

const std = @import("std");
const args = @import("args.zig");
pub const elk = @import("elk.zig");
pub const codegen = @import("codegen/codegen.zig");
pub const linker = @import("linker.zig");
pub const llvm = @import("llvmc/root.zig");
pub const trapsets = @import("trapsets.zig");

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
        if (program.source.path) |path| {
            gpa.free(path);
        }
    }
};

/// read an assembly file, parse it with elk
/// diagnostics are reported through the provided reporter
pub fn assembleFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    traps: *const elk.Traps,
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
        traps,
        elk.standard_policies,
        reporter,
    );
    errdefer air.deinit(gpa);

    return .{ .air = air, .source = source, .text = text };
}

/// scratch locations for the temp object, runtime and trap header
var obj_scratch_buf: [64]u8 = undefined;
var rt_scratch_buf: [64]u8 = undefined;
var hdr_scratch_buf: [64]u8 = undefined;

fn initScratchPaths(source_path: ?[]const u8) struct { obj: []const u8, rt: []const u8, hdr: []const u8 } {
    const stem = if (source_path) |p| std.fs.path.basename(p) else "lcc-tmp";
    const obj = std.fmt.bufPrint(&obj_scratch_buf, ".{s}.o", .{stem}) catch "lcc-tmp.o";
    const rt = std.fmt.bufPrint(&rt_scratch_buf, ".{s}.c", .{stem}) catch "lcc-tmp.c";
    const hdr = std.fmt.bufPrint(&hdr_scratch_buf, ".{s}.trap/{s}", .{ stem, trapsets.trap_header_name }) catch ".lcc-tmp.trap/lcc_trap.h";
    return .{ .obj = obj, .rt = rt, .hdr = hdr };
}

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
} || linker.LinkError || std.Io.File.OpenError || std.Io.Writer.Error || error{
    // createDirPath can fail with these beyond OpenError
    DiskQuota,
    LinkQuotaExceeded,
    Streaming,
};

/// resolves the -target and -arch flags into an llvm triple
/// -arch replaces the architecture component of the host triple
pub fn resolveTriple(
    gpa: std.mem.Allocator,
    target: ?[]const u8,
    arch: ?[]const u8,
) error{OutOfMemory}!?[]u8 {
    if (target) |t| {
        return try gpa.dupe(u8, t);
    }

    const arch_name = arch orelse {
        return null;
    };

    const host = llvm.bindings.LLVMGetDefaultTargetTriple();
    defer llvm.bindings.LLVMDisposeMessage(host);
    const triple = std.mem.span(host);

    // keep vendor-os-environment, swap the architecture
    const rest = if (std.mem.indexOfScalar(u8, triple, '-')) |dash| triple[dash..] else "";
    return try std.fmt.allocPrint(gpa, "{s}{s}", .{ arch_name, rest });
}

/// elk.Air -> LLVM module -> verify -> optimise -> object file -> link
pub fn compileAndLink(
    io: std.Io,
    gpa: std.mem.Allocator,
    program: *const Program,
    table: *const trapsets.Table,
    environ_map: ?*const std.process.Environ.Map,
    output_path: []const u8,
    level: llvm.pass.Level,
    emit_llvm: bool,
    triple: ?[]const u8,
    dynamic: bool,
    lib_path: ?[]const u8,
) CompileError!void {
    var output = try codegen.CodeGen.emit(&program.air, gpa, &table.symbols);
    defer output.deinit();

    var machine = if (triple) |t| blk: {
        const triple_z = try gpa.dupeZ(u8, t);
        defer gpa.free(triple_z);
        break :blk try llvm.target.TargetMachine.create(triple_z, codeGenLevel(level));
    } else blk: {
        break :blk try llvm.target.TargetMachine.createDefault(codeGenLevel(level));
    };

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
    if (emit_llvm) {
        printLlvm(io, gpa, output.module);
        return;
    }

    const object = try machine.emitObjectAlloc(gpa, output.module);
    defer gpa.free(object);

    const scratch = initScratchPaths(program.source.path);

    errdefer std.Io.Dir.cwd().deleteFile(io, scratch.obj) catch {};
    try writeFile(io, scratch.obj, object);

    // the static build compiles the runtime; every build compiles its
    // sets, which are always used in place
    var sources: std.ArrayList([]const u8) = .empty;
    defer sources.deinit(gpa);
    var wrote_rt = false;
    errdefer if (wrote_rt) {
        std.Io.Dir.cwd().deleteFile(io, scratch.rt) catch {};
    };

    if (!dynamic) {
        wrote_rt = true;
        try writeFile(io, scratch.rt, runtime_source);
        try sources.append(gpa, scratch.rt);
    }
    for (table.sets.items) |set| {
        try sources.append(gpa, set.path);
    }

    // the header is force-included while compiling the runtime and sets;
    // function scope so a later link failure still removes it
    const will_generate = dynamic and lib_path == null;
    const write_header = sources.items.len > 0 or will_generate;
    const hdr_dir = std.fs.path.dirname(scratch.hdr) orelse ".";
    errdefer if (write_header) {
        std.Io.Dir.cwd().deleteTree(io, hdr_dir) catch {};
    };
    if (write_header) {
        try std.Io.Dir.cwd().createDirPath(io, hdr_dir);
        try writeFile(io, scratch.hdr, trapsets.trap_header);
    }
    const include_header: ?[]const u8 = if (write_header) scratch.hdr else null;

    if (dynamic) {
        if (will_generate) {
            // no -L specified: auto-generate liblc3 in cwd
            errdefer std.Io.Dir.cwd().deleteFile(io, scratch.rt) catch {};
            try writeFile(io, scratch.rt, runtime_source);
            try linker.generateLib(io, gpa, environ_map, scratch.rt, include_header, defaultLibName(), triple);
            std.Io.Dir.cwd().deleteFile(io, scratch.rt) catch {};
        }
        // -L specified: link against the user's library, skip generation
        try linker.link(io, gpa, environ_map, scratch.obj, sources.items, include_header, table.link_flags.items, triple, output_path, true, lib_path);
    } else {
        try linker.link(io, gpa, environ_map, scratch.obj, sources.items, include_header, table.link_flags.items, triple, output_path, false, null);
    }

    std.Io.Dir.cwd().deleteFile(io, scratch.obj) catch {};
    if (write_header) {
        std.Io.Dir.cwd().deleteTree(io, hdr_dir) catch {};
    }
    if (wrote_rt) {
        std.Io.Dir.cwd().deleteFile(io, scratch.rt) catch {};
    }
}

/// default shared library name per platform
pub fn defaultLibName() []const u8 {
    return if (@import("builtin").os.tag.isDarwin()) "liblc3.dylib" else "liblc3.so";
}

/// generates the liblc3 shared library from the embedded runtime source
pub fn generateLiblc3(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    output_path: []const u8,
    triple: ?[]const u8,
) CompileError!void {
    const scratch = initScratchPaths(null);

    errdefer std.Io.Dir.cwd().deleteFile(io, scratch.rt) catch {};
    try writeFile(io, scratch.rt, runtime_source);

    // function scope: a later generateLib failure must still remove it
    const hdr_dir = std.fs.path.dirname(scratch.hdr) orelse ".";
    errdefer std.Io.Dir.cwd().deleteTree(io, hdr_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, hdr_dir);
    try writeFile(io, scratch.hdr, trapsets.trap_header);

    try linker.generateLib(io, gpa, environ_map, scratch.rt, scratch.hdr, output_path, triple);

    std.Io.Dir.cwd().deleteTree(io, hdr_dir) catch {};
    std.Io.Dir.cwd().deleteFile(io, scratch.rt) catch {};
}

pub fn optimizeLevel(level: args.Optimize) llvm.pass.Level {
    return switch (level) {
        .none => .none,
        .@"0" => .o0,
        .@"1" => .o1,
        .@"2" => .o2,
        .@"3" => .o3,
    };
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
    const text = module.printToStringAlloc(gpa) catch {
        return;
    };
    defer gpa.free(text);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    // ignore failure
    stdout_writer.interface.writeAll(text) catch {};
    stdout_writer.interface.flush() catch {};
}

/// writes bytes to path, creating or truncating it
pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) (std.Io.File.OpenError || std.Io.Writer.Error)!void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
