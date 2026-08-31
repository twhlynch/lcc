//! instruction lowering
//!
//! returns whether the instruction terminated its basic block; the caller
//! adds an explicit fall-through branch otherwise

const std = @import("std");

const elk = @import("../elk.zig");
const llvm = @import("../llvmc/root.zig");
const codegen = @import("codegen.zig");
const traps = @import("traps.zig");

const CodeGen = codegen.CodeGen;

pub fn lower(cg: *CodeGen, instruction: elk.Instruction, index: usize) codegen.Error!bool {
    switch (instruction) {
        .add => |ops| {
            try binary(cg, .add, ops.dest.value.code, ops.src_a.value.code, ops.src_b.value);
            return false;
        },
        .@"and" => |ops| {
            try binary(cg, .@"and", ops.dest.value.code, ops.src_a.value.code, ops.src_b.value);
            return false;
        },
        .not => |ops| {
            const lhs = cg.loadReg(ops.src.value.code);
            const minus_one = llvm.value.constInt(cg.word_type, -1);
            cg.writeReg(
                ops.dest.value.code,
                cg.builder.buildXor(lhs, minus_one, ""),
            );
            return false;
        },

        .br => |ops| {
            return br(cg, ops.condition.value, ops.dest, index);
        },
        .jmp => |ops| {
            cg.dispatchTo(cg.loadReg(ops.base.value.code));
            return true;
        },
        .ret => {
            cg.dispatchTo(cg.loadReg(7));
            return true;
        },
        .jsr => |ops| {
            // R7 <- address of the following word, CC untouched
            cg.writeRegNoCc(7, cg.pcValue(index));
            const target = try resolvedTarget(cg, ops.dest, index);
            _ = cg.builder.buildBr(cg.blocks[target]);
            return true;
        },
        .jsrr => |ops| {
            cg.writeRegNoCc(7, cg.pcValue(index));
            cg.dispatchTo(cg.loadReg(ops.base.value.code));
            return true;
        },

        .trap => |ops| {
            return traps.lower(cg, ops.vect.value.immediate.integer, index);
        },

        .lea => |ops| {
            const address = try resolvedAddress(cg, ops.src, index);
            cg.writeRegNoCc(ops.dest.value.code, address);
            return false;
        },

        .ld => |ops| {
            const pointer = cg.memoryPointer(try resolvedAddress(cg, ops.src, index));
            const value = cg.builder.buildLoad(cg.word_type, pointer, "v");
            cg.writeReg(ops.dest.value.code, value);
            return false;
        },
        .ldi => |ops| {
            const indirect_pointer =
                cg.memoryPointer(try resolvedAddress(cg, ops.src, index));
            const address =
                cg.builder.buildLoad(cg.word_type, indirect_pointer, "addr");
            const pointer = cg.memoryPointer(address);
            const value = cg.builder.buildLoad(cg.word_type, pointer, "v");
            cg.writeReg(ops.dest.value.code, value);
            return false;
        },
        .ldr => |ops| {
            const base = cg.loadReg(ops.base.value.code);
            const offset = llvm.value.constInt(cg.word_type, ops.offset.value.immediate.integer);
            const address = cg.builder.buildAdd(base, offset, "addr");
            const pointer = cg.memoryPointer(address);
            const value = cg.builder.buildLoad(cg.word_type, pointer, "v");
            cg.writeReg(ops.dest.value.code, value);
            return false;
        },

        .st => |ops| {
            const pointer = cg.memoryPointer(try resolvedAddress(cg, ops.dest, index));
            _ = cg.builder.buildStore(cg.loadReg(ops.src.value.code), pointer);
            return false;
        },
        .sti => |ops| {
            const indirect_pointer =
                cg.memoryPointer(try resolvedAddress(cg, ops.dest, index));
            const address =
                cg.builder.buildLoad(cg.word_type, indirect_pointer, "addr");
            const pointer = cg.memoryPointer(address);
            _ = cg.builder.buildStore(cg.loadReg(ops.src.value.code), pointer);
            return false;
        },
        .str => |ops| {
            const base = cg.loadReg(ops.base.value.code);
            const offset = llvm.value.constInt(cg.word_type, ops.offset.value.immediate.integer);
            const address = cg.builder.buildAdd(base, offset, "addr");
            const pointer = cg.memoryPointer(address);
            _ = cg.builder.buildStore(cg.loadReg(ops.src.value.code), pointer);
            return false;
        },

        .rti => {
            std.log.warn("rti instruction at x{X} treated as nop", .{cg.air.origin + index});
            return false;
        },

        inline else => |_, tag| {
            std.log.err("instruction not supported yet: {s}", .{@tagName(tag)});
            return error.UnsupportedInstruction;
        },
    }
}

const Op = enum { add, @"and" };

/// ADD/AND
/// dest = src_a <op> src_b where src_b is register or imm5
fn binary(
    cg: *CodeGen,
    op: Op,
    dest_code: u3,
    src_a_code: u3,
    src_b: anytype,
) codegen.Error!void {
    const lhs = cg.loadReg(src_a_code);
    const rhs = switch (src_b) {
        .register => |reg| cg.loadReg(reg.code),
        .immediate => |imm| llvm.value.constInt(cg.word_type, imm.integer),
    };

    const result = switch (op) {
        .add => cg.builder.buildAdd(lhs, rhs, ""),
        .@"and" => cg.builder.buildAnd(lhs, rhs, ""),
    };

    cg.writeReg(dest_code, result);
}

/// BR
/// conditional branch on the condition code against the nzp mask
fn br(
    cg: *CodeGen,
    mask: anytype,
    dest: anytype,
    index: usize,
) codegen.Error!bool {
    const bits = @intFromEnum(mask);
    if (bits == 0) {
        return false;
    }

    const cc = cg.loadCc();

    var cond: ?llvm.bindings.ValueRef = null;
    if (bits & 0b100 != 0) {
        cond = orInto(cg, cond, cg.builder.buildIcmpZero(.slt, cc, "n"));
    }
    if (bits & 0b010 != 0) {
        cond = orInto(cg, cond, cg.builder.buildIcmpZero(.eq, cc, "z"));
    }
    if (bits & 0b001 != 0) {
        cond = orInto(cg, cond, cg.builder.buildIcmpZero(.sgt, cc, "p"));
    }

    const target = try resolvedTarget(cg, dest, index);
    _ = cg.builder.buildCondBr(cond.?, cg.blocks[target], cg.blocks[index + 1]);
    return true;
}

fn orInto(
    cg: *CodeGen,
    current: ?llvm.bindings.ValueRef,
    next: llvm.bindings.ValueRef,
) llvm.bindings.ValueRef {
    if (current) |c| {
        return cg.builder.buildOr(c, next, "");
    }
    return next;
}

/// extracts a validated word index from a resolved PC-relative operand
fn resolvedTarget(
    cg: *CodeGen,
    operand: anytype,
    index: usize,
) codegen.Error!usize {
    return switch (operand.value) {
        .resolved => |formed| cg.branchTargetIndex(index, formed.integer),
        .unresolved => blk: {
            std.log.err("unresolved label reference at x{X}", .{@as(u64, @intCast(cg.air.origin + index))});
            break :blk error.InvalidTarget;
        },
    };
}

/// absolute LC-3 address of a resolved PC-relative operand
fn resolvedAddress(
    cg: *CodeGen,
    operand: anytype,
    index: usize,
) codegen.Error!llvm.bindings.ValueRef {
    return absoluteAddress(cg, try resolvedTarget(cg, operand, index));
}

/// absolute LC-3 address of a word index
fn absoluteAddress(cg: *CodeGen, target_index: usize) llvm.bindings.ValueRef {
    return llvm.value.constInt(
        cg.word_type,
        @as(i64, cg.air.origin) + @as(i64, @intCast(target_index)),
    );
}
