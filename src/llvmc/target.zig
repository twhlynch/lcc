//! LLVM target wrapper

const std = @import("std");
pub const bindings = @import("bindings.zig");
const module_mod = @import("module.zig");

pub const TargetError = error{ UnknownTriple, EmissionFailed };

pub const Module = module_mod.Module;

/// default target machine for this host, at opt_level
pub const TargetMachine = struct {
    ref: bindings.TargetMachineRef,
    triple_owned: [:0]u8,
    data_layout: bindings.TargetDataRef,

    pub fn createDefault(opt_level: bindings.CodeGenOptLevel) TargetError!TargetMachine {
        bindings.initializeNativeTarget(@import("builtin").cpu.arch);

        const triple_raw = bindings.LLVMGetDefaultTargetTriple();
        defer bindings.LLVMDisposeMessage(triple_raw);

        var error_message: ?[*:0]u8 = null;
        var target: bindings.TargetRef = undefined;
        if (bindings.LLVMGetTargetFromTriple(triple_raw, &target, &error_message) != 0) {
            if (error_message) |msg| {
                std.log.err("LLVM: {s}", .{std.mem.span(msg)});
                bindings.LLVMDisposeMessage(msg);
            }
            return error.UnknownTriple;
        }

        const ref = bindings.LLVMCreateTargetMachine(
            target,
            triple_raw,
            "",
            "",
            opt_level,
            .default,
            .default,
        );

        // keep an owned copy, the C API string is disposed above.
        const triple_copy: [:0]u8 = std.heap.c_allocator.dupeZ(u8, std.mem.span(triple_raw)) catch return error.EmissionFailed;

        return .{
            .ref = ref,
            .triple_owned = triple_copy,
            .data_layout = bindings.LLVMCreateTargetDataLayout(ref),
        };
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

    /// emits a native object file into memory. caller frees the result
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
