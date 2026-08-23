//! Instruction lowering

const std = @import("std");

const elk = @import("../elk.zig");
const llvm = @import("../llvmc/root.zig");
const codegen = @import("codegen.zig");

const CodeGen = codegen.CodeGen;

pub fn lower(cg: *CodeGen, instruction: elk.Instruction) codegen.Error!void {
    switch (instruction) {
        .add => |ops| try binary(cg, .add, ops.dest.value.code, ops.src_a.value.code, ops.src_b.value),
        .@"and" => |ops| try binary(cg, .@"and", ops.dest.value.code, ops.src_a.value.code, ops.src_b.value),
        .not => |ops| try notOp(cg, ops.dest.value.code, ops.src.value.code),

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
    const lhs = cg.regValue(cg.regs[src_a_code]);
    const rhs = switch (src_b) {
        .register => |reg| cg.regValue(cg.regs[reg.code]),
        .immediate => |imm| llvm.value.constInt(cg.word_type, imm.integer),
    };

    const result = switch (op) {
        .add => cg.builder.buildAdd(lhs, rhs, ""),
        .@"and" => cg.builder.buildAnd(lhs, rhs, ""),
    };

    cg.setReg(dest_code, .{ .value = result });
    cg.updateCc(result);
}

/// NOT
/// bitwise complement via xor with -1
fn notOp(cg: *CodeGen, dest_code: u3, src_code: u3) codegen.Error!void {
    const lhs = cg.regValue(cg.regs[src_code]);
    const minus_one = llvm.value.constInt(cg.word_type, -1);
    const result = cg.builder.buildXor(lhs, minus_one, "");

    cg.setReg(dest_code, .{ .value = result });
    cg.updateCc(result);
}
