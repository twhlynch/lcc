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

/// one assembled input file; segments[0] is the main program and any
/// further segments are extras loaded at their own origins
pub const Segment = struct {
    air: elk.Air,
    source: elk.Source,

    pub fn deinit(seg: *Segment, gpa: std.mem.Allocator) void {
        seg.air.deinit(gpa);
        // source.text and the file buffer are the same allocation
        gpa.free(seg.source.text);
        if (seg.source.path) |path| {
            gpa.free(path);
        }
    }
};

/// program of one or more elk segments
pub const Program = struct {
    segments: []Segment,

    pub fn deinit(program: *Program, gpa: std.mem.Allocator) void {
        for (program.segments) |*seg| seg.deinit(gpa);
        gpa.free(program.segments);
    }

    pub fn mainPath(program: *const Program) ?[]const u8 {
        if (program.segments.len == 0) return null;
        return program.segments[0].source.path;
    }

    pub fn totalWords(program: *const Program) usize {
        var total: usize = 0;
        for (program.segments) |*seg| total += seg.air.lines.items.len;
        return total;
    }

    pub fn totalLabels(program: *const Program) usize {
        var total: usize = 0;
        for (program.segments) |*seg| total += seg.air.labels.items.len;
        return total;
    }

    pub fn mainOrigin(program: *const Program) u16 {
        if (program.segments.len == 0) return 0;
        return program.segments[0].air.origin;
    }
};

/// read assembly files in order, parse each with elk and merge them into
/// one image; labels resolve per file, so each file keeps its own origin
/// diagnostics are reported through the provided reporter
pub fn assembleFiles(
    io: std.Io,
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    traps: *const elk.Traps,
    reporter: *elk.reporting.Primary,
) Error!Program {
    if (paths.len == 0) {
        std.log.err("no input files", .{});
        return error.FileNotFound;
    }

    var segments: std.ArrayList(Segment) = .empty;
    errdefer {
        for (segments.items) |*seg| seg.deinit(gpa);
        segments.deinit(gpa);
    }

    // each input claims its address range as it is assembled so a
    // collision fails before later files are even read
    var used = std.StaticBitSet(65536).initEmpty();
    for (paths) |path| {
        var seg = assembleOne(io, gpa, path, traps, reporter) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("file not found: {s}", .{path});
                return error.FileNotFound;
            },
            else => |other| return other,
        };
        errdefer seg.deinit(gpa);
        try claim(&used, segments.items, seg);
        try segments.append(gpa, seg);
    }

    return .{ .segments = try segments.toOwnedSlice(gpa) };
}

/// read a single assembly file, parse it with elk
fn assembleOne(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    traps: *const elk.Traps,
    reporter: *elk.reporting.Primary,
) Error!Segment {
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

    return .{ .air = air, .source = source };
}

/// marks a segment's address range, rejecting overflow past xFFFF and
/// addresses already claimed by an earlier input
fn claim(
    used: *std.StaticBitSet(65536),
    earlier: []const Segment,
    seg: Segment,
) Error!void {
    const origin: usize = seg.air.origin;
    const len = seg.air.lines.items.len;
    if (origin + len > 65536) {
        std.log.err(
            "segment at x{X:04} with {} words overflows memory",
            .{ seg.air.origin, len },
        );
        return error.AssemblyFailed;
    }
    for (0..len) |i| {
        const addr = origin + i;
        if (used.isSet(addr)) {
            std.log.err("address x{X:04} in {s} already loaded by {s}", .{
                addr,
                seg.source.path orelse "?",
                ownerOf(earlier, addr) orelse "an earlier input",
            });
            return error.AssemblyFailed;
        }
        used.set(addr);
    }
}

/// the earlier segment that claimed addr, for conflict diagnostics
fn ownerOf(earlier: []const Segment, addr: usize) ?[]const u8 {
    for (earlier) |seg| {
        const origin: usize = seg.air.origin;
        if (addr >= origin and addr < origin + seg.air.lines.items.len) {
            return seg.source.path;
        }
    }
    return null;
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
    var airs: std.ArrayList(*const elk.Air) = .empty;
    defer airs.deinit(gpa);
    for (program.segments) |*seg| {
        try airs.append(gpa, &seg.air);
    }
    var output = try codegen.CodeGen.emit(airs.items, gpa, &table.symbols);
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

    const scratch = initScratchPaths(program.mainPath());

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
    // file sets compile in place; bundled sets are appended below from
    // their scratch copy
    for (table.sets.items) |set| {
        if (set.bundled) continue;
        try sources.append(gpa, set.path);
    }

    // the header is force-included while compiling the runtime and sets;
    // function scope so a later link failure still removes it
    const will_generate = dynamic and lib_path == null;
    var bundled_count: usize = 0;
    for (table.sets.items) |set| {
        if (set.bundled) bundled_count += 1;
    }
    const write_header = sources.items.len > 0 or bundled_count > 0 or will_generate;
    const hdr_dir = std.fs.path.dirname(scratch.hdr) orelse ".";
    errdefer if (write_header) {
        std.Io.Dir.cwd().deleteTree(io, hdr_dir) catch {};
    };
    if (write_header) {
        try std.Io.Dir.cwd().createDirPath(io, hdr_dir);
        try writeFile(io, scratch.hdr, trapsets.trap_header);
    }

    // bundled sets compile from a scratch copy inside the trap directory
    // (their name has no extension and no directory to read from), and
    // the directory is removed together with the header after the link
    var bundled_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (bundled_paths.items) |path| gpa.free(path);
        bundled_paths.deinit(gpa);
    }
    for (table.sets.items) |set| {
        if (!set.bundled) continue;
        const name = try std.fmt.allocPrint(gpa, "{s}{s}", .{ set.path, set.ext });
        defer gpa.free(name);
        const path = try std.fs.path.join(gpa, &.{ hdr_dir, name });
        bundled_paths.append(gpa, path) catch |err| {
            gpa.free(path);
            return err;
        };
        try writeFile(io, path, set.source);
        try sources.append(gpa, path);
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
