//! trap lowering into native calls through the uniform trap ABI

const std = @import("std");
const codegen = @import("codegen.zig");

const CodeGen = codegen.CodeGen;

/// lowers one trap; falls through to the next word afterwards
pub fn lower(cg: *CodeGen, vect: u8, index: usize) void {
    const symbol = cg.trap_symbols[vect] orelse {
        std.log.warn("trap vector x{X:0>2} at x{X} has no registered handler, treated as nop", .{ vect, cg.air.origin + index });
        return;
    };

    // handlers observe the PC of the following instruction
    _ = cg.builder.buildStore(cg.pcValue(index), cg.contextFieldAddress(2));
    const handler = cg.trapFunction(symbol);
    _ = cg.builder.buildCall(handler, &.{cg.ctx_slot}, "");
}
