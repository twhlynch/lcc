//! LLVM type helpers

const std = @import("std");
pub const bindings = @import("bindings.zig");
const context_mod = @import("context.zig");

const Context = context_mod.Context;

/// i16
/// the LC-3 word type
pub fn int16(context: Context) bindings.TypeRef {
    return bindings.LLVMInt16TypeInContext(context.ref);
}

/// i32
/// the native ABI word type
pub fn int32(context: Context) bindings.TypeRef {
    return bindings.LLVMInt32TypeInContext(context.ref);
}

/// [count x i16]
/// LC-3 memory
pub fn memoryArray(element_type: bindings.TypeRef, count: u64) bindings.TypeRef {
    return bindings.LLVMArrayType2(element_type, count);
}

/// void
pub fn void_(context: Context) bindings.TypeRef {
    return bindings.LLVMVoidTypeInContext(context.ref);
}

/// opaque pointer in the default address space
pub fn pointer(context: Context) bindings.TypeRef {
    return bindings.LLVMPointerTypeInContext(context.ref, 0);
}

/// Function type with param_types returning return_type
pub fn function(return_type: bindings.TypeRef, param_types: []const bindings.TypeRef) bindings.TypeRef {
    return bindings.LLVMFunctionType(return_type, param_types.ptr, @intCast(param_types.len), 0);
}
