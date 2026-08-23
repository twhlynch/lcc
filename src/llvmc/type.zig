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

/// Function type with no parameters returning return_type
pub fn function(return_type: bindings.TypeRef) bindings.TypeRef {
    return bindings.LLVMFunctionType(return_type, null, 0, 0);
}
