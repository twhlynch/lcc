//! LLVM value helpers

const std = @import("std");
pub const bindings = @import("bindings.zig");
const type_mod = @import("type.zig");

/// constant integer of the given type
pub fn constInt(ty: bindings.TypeRef, value: i64) bindings.ValueRef {
    return bindings.LLVMConstInt(
        ty,
        @bitCast(value),
        // sign-extend negative constants to the target width
        @intFromBool(value < 0),
    );
}

/// all-zero constant of the given type
pub fn constNull(ty: bindings.TypeRef) bindings.ValueRef {
    return bindings.LLVMConstNull(ty);
}

comptime {
    _ = type_mod;
}
