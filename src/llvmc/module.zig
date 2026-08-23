//! LLVM module wrapper

const std = @import("std");
const bindings = @import("bindings.zig");
const context_mod = @import("context.zig");

pub const Context = context_mod.Context;

pub const VerifyError = error{ InvalidModule, OutOfMemory };

pub const Module = struct {
    ref: bindings.ModuleRef,
    context: Context,

    pub fn create(name: [:0]const u8, context: Context) Module {
        return .{
            .ref = bindings.LLVMModuleCreateWithNameInContext(name.ptr, context.ref),
            .context = context,
        };
    }

    pub fn dispose(module: Module) void {
        bindings.LLVMDisposeModule(module.ref);
    }

    pub fn setTarget(module: Module, triple: [*:0]const u8) void {
        bindings.LLVMSetTarget(module.ref, triple);
    }

    pub fn setDataLayout(module: Module, layout: bindings.TargetDataRef) void {
        bindings.LLVMSetModuleDataLayout(module.ref, layout);
    }

    /// renders the module as textual IR
    pub fn printToStringAlloc(module: Module, gpa: std.mem.Allocator) VerifyError![]u8 {
        const text: [*:0]u8 = bindings.LLVMPrintModuleToString(module.ref);
        defer bindings.LLVMDisposeMessage(text);
        return gpa.dupe(u8, std.mem.span(text));
    }

    /// runs the LLVM verifier
    /// on failure returns InvalidModule with the verifier messag
    pub fn verify(
        module: Module,
        gpa: std.mem.Allocator,
        message: *?[]u8,
    ) VerifyError!void {
        var raw: ?[*:0]u8 = null;
        if (bindings.LLVMVerifyModule(module.ref, .print_message, &raw) != 0) {
            if (raw) |msg| {
                defer bindings.LLVMDisposeMessage(msg);
                message.* = try gpa.dupe(u8, std.mem.span(msg));
            }
            return error.InvalidModule;
        }
    }
};
