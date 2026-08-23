//! LLVM context wrapper

const std = @import("std");
pub const bindings = @import("bindings.zig");

pub const Context = struct {
    ref: bindings.ContextRef,

    pub fn create() Context {
        return .{ .ref = bindings.LLVMContextCreate() };
    }

    pub fn dispose(context: Context) void {
        bindings.LLVMContextDispose(context.ref);
    }
};
