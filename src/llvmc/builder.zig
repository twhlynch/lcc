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
        bindings.LLVMDisposeBuilder(builder.ref);
    }

    pub fn positionAtEnd(builder: Builder, block: bindings.BasicBlockRef) void {
        bindings.LLVMPositionBuilderAtEnd(builder.ref, block);
    }

    pub fn buildRet(builder: Builder, value: bindings.ValueRef) bindings.ValueRef {
        return bindings.LLVMBuildRet(builder.ref, value);
    }

    pub fn buildBr(builder: Builder, dest: bindings.BasicBlockRef) bindings.ValueRef {
        return bindings.LLVMBuildBr(builder.ref, dest);
    }

    pub fn buildCondBr(
        builder: Builder,
        condition: bindings.ValueRef,
        then_block: bindings.BasicBlockRef,
        else_block: bindings.BasicBlockRef,
    ) bindings.ValueRef {
        return bindings.LLVMBuildCondBr(builder.ref, condition, then_block, else_block);
    }

    /// builds a switch with case_count cases plus default
    pub fn buildSwitch(
        builder: Builder,
        value: bindings.ValueRef,
        default: bindings.BasicBlockRef,
        case_count: usize,
    ) bindings.ValueRef {
        return bindings.LLVMBuildSwitch(builder.ref, value, default, @intCast(case_count));
    }

    pub fn addCase(switch_inst: bindings.ValueRef, on: bindings.ValueRef, dest: bindings.BasicBlockRef) void {
        bindings.LLVMAddCase(switch_inst, on, dest);
    }

    pub fn buildUnreachable(builder: Builder) bindings.ValueRef {
        return bindings.LLVMBuildUnreachable(builder.ref);
    }

    pub fn buildCall(
        builder: Builder,
        fn_value: bindings.ValueRef,
        args: []const bindings.ValueRef,
        name: []const u8,
    ) bindings.ValueRef {
        var buffer: [32]u8 = undefined;
        const ty = bindings.LLVMGlobalGetValueType(fn_value);
        return bindings.LLVMBuildCall2(
            builder.ref,
            ty,
            fn_value,
            args.ptr,
            @intCast(args.len),
            nameZ(&buffer, name),
        );
    }

    pub fn buildAlloca(builder: Builder, ty: bindings.TypeRef, name: []const u8) bindings.ValueRef {
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildAlloca(builder.ref, ty, nameZ(&buffer, name));
    }

    pub fn buildLoad(builder: Builder, ty: bindings.TypeRef, pointer: bindings.ValueRef, name: []const u8) bindings.ValueRef {
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildLoad2(builder.ref, ty, pointer, nameZ(&buffer, name));
    }

    pub fn buildStore(builder: Builder, value: bindings.ValueRef, pointer: bindings.ValueRef) bindings.ValueRef {
        return bindings.LLVMBuildStore(builder.ref, value, pointer);
    }

    /// word-indexed gep into an i16 array
    /// zero-extends the 16-bit address so values at or above x8000 stay positive
    pub fn buildMemoryAddress(
        builder: Builder,
        base: bindings.ValueRef,
        index: bindings.ValueRef,
    ) bindings.ValueRef {
        const i16ty = @import("type.zig").int16(builder.context);
        const wide = builder.buildZExtToInt32(index, "addr");
        var indices = [1]bindings.ValueRef{wide};
        return bindings.LLVMBuildGEP2(builder.ref, i16ty, base, &indices, 1, "ptr");
    }

    pub fn buildAdd(builder: Builder, lhs: bindings.ValueRef, rhs: bindings.ValueRef, name: []const u8) bindings.ValueRef {
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildAdd(builder.ref, lhs, rhs, nameZ(&buffer, name));
    }

    pub fn buildAnd(builder: Builder, lhs: bindings.ValueRef, rhs: bindings.ValueRef, name: []const u8) bindings.ValueRef {
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildAnd(builder.ref, lhs, rhs, nameZ(&buffer, name));
    }

    pub fn buildOr(builder: Builder, lhs: bindings.ValueRef, rhs: bindings.ValueRef, name: []const u8) bindings.ValueRef {
        var buffer: [32]u8 = undefined;
        return bindings.LLVMBuildOr(builder.ref, lhs, rhs, nameZ(&buffer, name));
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
