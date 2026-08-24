//! trap lowering into native runtime calls

const std = @import("std");
const codegen = @import("codegen.zig");
const bindings = @import("../llvmc/root.zig").bindings;

const CodeGen = codegen.CodeGen;

/// standard trap vectors
pub const Vect = struct {
    pub const getc: u8 = 0x20;
    pub const out: u8 = 0x21;
    pub const puts: u8 = 0x22;
    pub const in: u8 = 0x23;
    pub const putsp: u8 = 0x24;
    pub const halt: u8 = 0x25;
    pub const putn: u8 = 0x26;
    pub const reg: u8 = 0x27;
};

/// lowers one trap; returns whether the block terminated
pub fn lower(cg: *CodeGen, vect: u8, index: usize) codegen.Error!bool {
    switch (vect) {
        Vect.getc => {
            // elk does not update the condition code on getc/in
            const char = cg.callRuntime(.getc, &.{});
            cg.writeRegNoCc(0, char);
            return false;
        },
        Vect.out => {
            _ = cg.callRuntime(.out, &.{cg.loadReg(0)});
            return false;
        },
        Vect.puts => {
            _ = cg.callRuntime(.puts, &.{ cg.memory_global, cg.loadReg(0) });
            return false;
        },
        Vect.in => {
            const char = cg.callRuntime(.in, &.{});
            cg.writeRegNoCc(0, char);
            return false;
        },
        Vect.putsp => {
            _ = cg.callRuntime(.putsp, &.{ cg.memory_global, cg.loadReg(0) });
            return false;
        },
        Vect.halt => {
            _ = cg.callRuntime(.halt, &.{});
            // lc3_halt does not return
            _ = cg.builder.buildUnreachable();
            return true;
        },
        Vect.putn => {
            _ = cg.callRuntime(.putn, &.{cg.loadReg(0)});
            return false;
        },
        Vect.reg => {
            var args: [10]bindings.ValueRef = undefined;
            inline for (0..8) |i| args[i] = cg.loadReg(@intCast(i));
            args[8] = cg.pcValue(index);
            args[9] = cg.loadCc();
            _ = cg.callRuntime(.reg, &args);
            return false;
        },
        else => {
            std.log.err("trap vector x{X:0>2} has no native equivalent", .{vect});
            return error.UnsupportedInstruction;
        },
    }
}
