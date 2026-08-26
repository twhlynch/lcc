//! LLVM target wrapper

const std = @import("std");
pub const bindings = @import("bindings.zig");
const module_mod = @import("module.zig");

pub const TargetError = error{ UnknownTriple, EmissionFailed, OutOfMemory };

pub const Module = module_mod.Module;

pub const TargetMachine = struct {
    ref: bindings.TargetMachineRef,
    triple_owned: [:0]u8,
    data_layout: bindings.TargetDataRef,

    /// target machine for triple, at opt_level
    pub fn create(triple: [*:0]const u8, opt_level: bindings.CodeGenOptLevel) TargetError!TargetMachine {
        initializeTargetFor(std.mem.span(triple));

        var error_message: ?[*:0]u8 = null;
        var target: bindings.TargetRef = undefined;
        if (bindings.LLVMGetTargetFromTriple(triple, &target, &error_message) != 0) {
            if (error_message) |msg| {
                std.log.err("LLVM: {s}", .{std.mem.span(msg)});
                bindings.LLVMDisposeMessage(msg);
            }
            return error.UnknownTriple;
        }

        const ref = bindings.LLVMCreateTargetMachine(
            target,
            triple,
            "",
            "",
            opt_level,
            .default,
            .default,
        );

        // keep an owned copy; the caller frees the original triple.
        const triple_copy: [:0]u8 = std.heap.c_allocator.dupeZ(u8, std.mem.span(triple)) catch {
            bindings.LLVMDisposeTargetMachine(ref);
            return error.OutOfMemory;
        };

        return .{
            .ref = ref,
            .triple_owned = triple_copy,
            .data_layout = bindings.LLVMCreateTargetDataLayout(ref),
        };
    }

    /// default target machine for this host, at opt_level
    pub fn createDefault(opt_level: bindings.CodeGenOptLevel) TargetError!TargetMachine {
        const triple_raw = bindings.LLVMGetDefaultTargetTriple();
        defer bindings.LLVMDisposeMessage(triple_raw);
        return create(triple_raw, opt_level);
    }

    pub fn dispose(machine: *TargetMachine) void {
        bindings.LLVMDisposeTargetData(machine.data_layout);
        bindings.LLVMDisposeTargetMachine(machine.ref);
        std.heap.c_allocator.free(machine.triple_owned);
    }

    /// applies target triple and data layout to module
    pub fn configureModule(machine: TargetMachine, module: Module) void {
        module.setTarget(machine.triple_owned.ptr);
        module.setDataLayout(machine.data_layout);
    }

    /// emits an object file into memory. caller frees the result
    pub fn emitObjectAlloc(
        machine: TargetMachine,
        gpa: std.mem.Allocator,
        module: Module,
    ) (TargetError || std.mem.Allocator.Error)![]u8 {
        var message: ?[*:0]u8 = null;
        var buffer: bindings.MemoryBufferRef = undefined;

        if (bindings.LLVMTargetMachineEmitToMemoryBuffer(
            machine.ref,
            module.ref,
            .object_file,
            &message,
            &buffer,
        ) != 0) {
            if (message) |msg| {
                std.log.err("LLVM: {s}", .{std.mem.span(msg)});
                bindings.LLVMDisposeMessage(msg);
            }
            return error.EmissionFailed;
        }
        defer bindings.LLVMDisposeMemoryBuffer(buffer);

        const bytes = bindings.LLVMGetBufferStart(buffer)[0..bindings.LLVMGetBufferSize(buffer)];
        return gpa.dupe(u8, bytes);
    }
};

/// initialises the llvm backend matching the triple's architecture
/// backends are resolved through dlsym so lcc does not link every target
fn initializeTargetFor(triple: []const u8) void {
    const prefix = if (std.mem.indexOfScalar(u8, triple, '-')) |dash|
        triple[0..dash]
    else
        triple;

    const names = [_]struct { match: []const u8, backend: []const u8 }{
        .{ .match = "x86_64", .backend = "X86" },
        .{ .match = "amd64", .backend = "X86" },
        .{ .match = "i386", .backend = "X86" },
        .{ .match = "i686", .backend = "X86" },
        .{ .match = "arm64", .backend = "AArch64" },
        .{ .match = "aarch64", .backend = "AArch64" },
        .{ .match = "arm", .backend = "ARM" },
        .{ .match = "riscv32", .backend = "RISCV" },
        .{ .match = "riscv64", .backend = "RISCV" },
    };

    var backend: ?[]const u8 = null;
    for (names) |name| {
        if (std.mem.eql(u8, prefix, name.match)) backend = name.backend;
    }
    // unknown architectures fall back to whatever llvm resolves itself
    const backend_name = backend orelse return;

    const suffixes = [_][]const u8{ "TargetInfo", "Target", "TargetMC", "AsmPrinter", "AsmParser" };

    // handle for the current process image, which includes libLLVM
    const handle = std.c.dlopen(null, .{ .LAZY = true }) orelse return;
    defer _ = std.c.dlclose(handle);

    for (suffixes) |suffix| {
        var buffer: [64]u8 = undefined;
        const symbol = std.fmt.bufPrintZ(
            &buffer,
            "LLVMInitialize{s}{s}",
            .{ backend_name, suffix },
        ) catch unreachable;

        const init_fn: ?*const fn () callconv(.c) void =
            @ptrCast(@alignCast(std.c.dlsym(handle, symbol.ptr)));
        if (init_fn) |f| f();
    }
}
