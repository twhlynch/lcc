//! LLVM IR builder wrapper

const std = @import("std");
const bindings = @import("bindings.zig");
const context_mod = @import("context.zig");

const Context = context_mod.Context;

pub const Builder = struct {
    ref: bindings.BuilderRef,
    context: Context,

    pub fn create(context: Context) Builder {
        return .{
            .ref = bindings.LLVMCreateBuilderInContext(context.ref),
            .context = context,
        };
    }

    pub fn dispose(builder: Builder) void {
        _ = builder;
    }

    pub fn positionAtEnd(builder: Builder, block: bindings.BasicBlockRef) void {
        bindings.LLVMPositionBuilderAtEnd(builder.ref, block);
    }

    pub fn buildRet(builder: Builder, value: bindings.ValueRef) bindings.ValueRef {
        return bindings.LLVMBuildRet(builder.ref, value);
    }

    pub fn buildAdd(builder: Builder, lhs: bindings.ValueRef, rhs: bindings.ValueRef, name: []const u8) bindings.ValueRef {
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildAdd(builder.ref, lhs, rhs, nameZ(&buffer, name));
    }

    pub fn buildAnd(builder: Builder, lhs: bindings.ValueRef, rhs: bindings.ValueRef, name: []const u8) bindings.ValueRef {
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildAnd(builder.ref, lhs, rhs, nameZ(&buffer, name));
    }

    pub fn buildXor(builder: Builder, lhs: bindings.ValueRef, rhs: bindings.ValueRef, name: []const u8) bindings.ValueRef {
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildXor(builder.ref, lhs, rhs, nameZ(&buffer, name));
    }

    /// signed compare against zero (the LC-3 condition code)
    pub fn buildIcmpZero(
        builder: Builder,
        predicate: bindings.IntPredicate,
        value: bindings.ValueRef,
        name: []const u8,
    ) bindings.ValueRef {
        const i16ty = @import("type.zig").int16(builder.context);
        const zero = bindings.LLVMConstInt(i16ty, 0, 0);
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildICmp(builder.ref, predicate, value, zero, nameZ(&buffer, name));
    }

    pub fn buildZExtToInt32(builder: Builder, value: bindings.ValueRef, name: []const u8) bindings.ValueRef {
        const i32ty = @import("type.zig").int32(builder.context);
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildZExt(builder.ref, value, i32ty, nameZ(&buffer, name));
    }
};

/// copies name without the leading % as NULL terminated storage
fn nameZ(buffer: *[32]u8, name: []const u8) [*:0]const u8 {
    const trimmed = name[0..@min(name.len, buffer.len - 1)];
    @memcpy(buffer[0..trimmed.len], trimmed);
    buffer[trimmed.len] = 0;
    return buffer[0..trimmed.len :0].ptr;
}
