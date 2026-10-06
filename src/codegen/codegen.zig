//! LC-3 to LLVM code generation
//!
//! one basic block per LC-3 word, plus an exit block and a shared dispatch
//! block for indirect jumps. R0-R7 and the condition code live in stack slots
//! so values merge correctly across block boundaries. all encoded program
//! words are stored into memory before execution starts so programs can
//! self-read. execution still follows basic blocks, so no self-modifying code.

const std = @import("std");

const elk = @import("../elk.zig");
const llvm = @import("../llvmc/root.zig");
const bindings = llvm.bindings;
pub const instruction = @import("instruction.zig");

pub const Error = error{
    UnsupportedInstruction,
    InvalidTarget,
    OutOfMemory,
};

/// everything the pipeline keeps alive between stages
/// owned by the caller
pub const Output = struct {
    context: llvm.context.Context,
    module: llvm.module.Module,
    builder: llvm.builder.Builder,

    pub fn deinit(output: Output) void {
        output.builder.dispose();
        output.module.dispose();
        output.context.dispose();
    }
};

pub const CodeGen = struct {
    /// LC-3 address of every word, in ascending origin order
    addresses: []const u16,
    /// global block index per address, -1 where no word is loaded
    addr_to_block: []const i32,
    module: llvm.module.Module,
    builder: llvm.builder.Builder,
    gpa: std.mem.Allocator,

    /// cached type handles.
    word_type: bindings.TypeRef,

    /// the flat LC-3 address space
    memory_global: bindings.ValueRef,

    /// stack slots for R0-R7 as one array, the condition code and the
    /// pending indirect jump target
    regs: bindings.ValueRef,
    cc_slot: bindings.ValueRef,
    dispatch_slot: bindings.ValueRef,

    /// one shared trap context; pc is stored at each trap site
    ctx_type: bindings.TypeRef,
    ctx_slot: bindings.ValueRef,

    /// symbol per trap vector; handlers are declared on demand
    trap_symbols: *const [256]?[:0]const u8,
    /// llvm type of a trap handler: void(ptr)
    trap_fn_type: bindings.TypeRef,

    /// one basic block per LC-3 word; blocks[len] is the exit block
    blocks: []bindings.BasicBlockRef,

    /// shared dispatch target for JMP/JSRR/RET
    dispatch_block: bindings.BasicBlockRef,

    /// lowers a whole program into an LLVM module
    /// airs[0] is the main file; blocks are ordered by ascending origin
    pub fn emit(
        airs: []const *const elk.Air,
        gpa: std.mem.Allocator,
        trap_symbols: *const [256]?[:0]const u8,
    ) Error!Output {
        if (airs.len == 0) {
            std.log.err("no input files", .{});
            return error.InvalidTarget;
        }

        // segments in ascending origin order; overlap was already
        // rejected during assembly, so equal origins only come from
        // empty segments, which contribute no blocks
        const order = gpa.alloc(usize, airs.len) catch return error.OutOfMemory;
        defer gpa.free(order);
        for (order, 0..) |*slot, i| slot.* = i;
        std.mem.sort(usize, order, airs, struct {
            fn lessThan(ctx: []const *const elk.Air, a: usize, b: usize) bool {
                return ctx[a].origin < ctx[b].origin;
            }
        }.lessThan);

        var bases = gpa.alloc(usize, airs.len) catch return error.OutOfMemory;
        defer gpa.free(bases);

        var total: usize = 0;
        for (order) |s| {
            bases[s] = total;
            total += airs[s].lines.items.len;
        }

        var addresses = gpa.alloc(u16, total) catch return error.OutOfMemory;
        defer gpa.free(addresses);

        var addr_to_block = gpa.alloc(i32, 65536) catch return error.OutOfMemory;
        defer gpa.free(addr_to_block);
        @memset(addr_to_block, -1);

        for (order) |s| {
            const air = airs[s];
            const base = bases[s];
            const origin: usize = air.origin;
            for (air.lines.items, 0..) |_, i| {
                if (origin + i >= 65536) {
                    std.log.err(
                        "segment at x{X:04} with {} words overflows memory",
                        .{ air.origin, air.lines.items.len },
                    );
                    return error.InvalidTarget;
                }
                const addr: u16 = @intCast(origin + i);
                const global = base + i;
                if (addr_to_block[addr] != -1) {
                    std.log.err("address x{X:04} loaded by multiple inputs", .{addr});
                    return error.InvalidTarget;
                }
                addr_to_block[addr] = @intCast(global);
                addresses[global] = addr;
            }
        }

        const context = llvm.context.Context.create();

        const line_count = total;

        var blocks = gpa.alloc(bindings.BasicBlockRef, line_count + 1) catch |err| {
            context.dispose();
            return err;
        };
        defer gpa.free(blocks);

        const builder = llvm.builder.Builder.create(context);

        var output: Output = .{ .context = context, .module = undefined, .builder = builder };
        errdefer output.deinit();

        output.module = llvm.module.Module.create("lcc", context);

        var cg: CodeGen = .{
            .addresses = addresses,
            .addr_to_block = addr_to_block,
            .module = output.module,
            .builder = builder,
            .gpa = gpa,
            .word_type = llvm.types.int16(context),
            .memory_global = undefined,
            .regs = undefined,
            .cc_slot = undefined,
            .dispatch_slot = undefined,
            .ctx_type = llvm.types.trapContext(context),
            .ctx_slot = undefined,
            .trap_symbols = trap_symbols,
            .trap_fn_type = llvm.types.function(llvm.types.void_(context), &.{llvm.types.pointer(context)}),
            .blocks = blocks.ptr[0 .. line_count + 1],
            .dispatch_block = undefined,
        };

        const main_fn = bindings.LLVMAddFunction(
            output.module.ref,
            "main",
            llvm.types.function(llvm.types.int32(context), &.{
                llvm.types.int32(context),
                llvm.types.pointer(context),
                llvm.types.pointer(context),
            }),
        );

        // declare lcc_set_args(argc, argv)
        const set_args_fn = bindings.LLVMAddFunction(
            output.module.ref,
            "lcc_set_args",
            llvm.types.function(llvm.types.void_(context), &.{
                llvm.types.int32(context),
                llvm.types.pointer(context),
            }),
        );

        // entry block: call lcc_set_args, then set up slots and memory
        const entry = bindings.LLVMAppendBasicBlockInContext(context.ref, main_fn, "entry");
        cg.builder.positionAtEnd(entry);

        const argc = bindings.LLVMGetParam(main_fn, 0);
        const argv = bindings.LLVMGetParam(main_fn, 1);
        _ = cg.builder.buildCall(set_args_fn, &.{ argc, argv }, "");

        // one array for R0-R7 so the trap context can point at it
        const regs_type = llvm.types.memoryArray(cg.word_type, 8);
        cg.regs = cg.builder.buildAlloca(regs_type, "regs");
        cg.cc_slot = cg.builder.buildAlloca(cg.word_type, "cc");
        cg.dispatch_slot = cg.builder.buildAlloca(cg.word_type, "target");
        // starts with all registers and condition codes cleared
        const zero = llvm.value.constInt(cg.word_type, 0);
        _ = cg.builder.buildStore(llvm.value.constNull(regs_type), cg.regs);
        _ = cg.builder.buildStore(zero, cg.cc_slot);

        const memory_type = llvm.types.memoryArray(cg.word_type, 65536);
        cg.memory_global = bindings.LLVMAddGlobal(
            output.module.ref,
            memory_type,
            "memory",
        );
        bindings.LLVMSetInitializer(cg.memory_global, llvm.value.constNull(memory_type));

        // the trap context is shared by every handler; only pc changes
        cg.ctx_slot = cg.builder.buildAlloca(cg.ctx_type, "trap_ctx");
        _ = cg.builder.buildStore(cg.memory_global, cg.contextFieldAddress(0));
        _ = cg.builder.buildStore(cg.regs, cg.contextFieldAddress(1));
        _ = cg.builder.buildStore(cg.cc_slot, cg.contextFieldAddress(3));

        // store all encoded words into memory before execution starts
        for (airs, 0..) |air, s| {
            const base = bases[s];
            for (air.lines.items, 0..) |line, i| {
                try cg.storeProgramWord(base + i, line.statement.encode());
            }
        }

        for (0..line_count) |i| {
            var name_buffer: [16]u8 = undefined;
            const name = std.fmt.bufPrintZ(&name_buffer, "w{d}", .{i}) catch unreachable;
            cg.blocks[i] = bindings.LLVMAppendBasicBlockInContext(context.ref, main_fn, name.ptr);
        }
        cg.blocks[line_count] = bindings.LLVMAppendBasicBlockInContext(context.ref, main_fn, "exit");
        cg.dispatch_block = bindings.LLVMAppendBasicBlockInContext(context.ref, main_fn, "dispatch");

        // entry is the first word of the main file, wherever it sits in
        // the origin-ordered block layout
        _ = cg.builder.buildBr(cg.blocks[bases[0]]);

        // lower in ascending origin order: each word falls through to the
        // next word by address, and a file's last word falls through to
        // the next file's first word, as if the inputs were concatenated
        // in .ORIG order
        var index: usize = 0;
        for (order) |s| {
            for (airs[s].lines.items) |line| {
                cg.builder.positionAtEnd(cg.blocks[index]);
                switch (line.statement) {
                    .raw_word => {
                        // data words are always treated as NOPs
                        _ = cg.builder.buildBr(cg.blocks[index + 1]);
                    },
                    .instruction => |inst| {
                        const terminated = try instruction.lower(&cg, inst, index);
                        // fall through unless the instruction ended its block
                        if (!terminated) {
                            _ = cg.builder.buildBr(cg.blocks[index + 1]);
                        }
                    },
                    .unresolved_word => unreachable,
                }
                index += 1;
            }
        }

        // exit block returns R0 as the process status
        cg.builder.positionAtEnd(cg.blocks[line_count]);
        const r0 = cg.loadReg(0);
        const status = cg.builder.buildZExtToInt32(r0, "exit");
        _ = cg.builder.buildRet(status);

        // dispatch maps a pending indirect target onto its word's block
        cg.builder.positionAtEnd(cg.dispatch_block);
        const pending = cg.builder.buildLoad(cg.word_type, cg.dispatch_slot, "target");
        const bad_target = bindings.LLVMAppendBasicBlockInContext(context.ref, main_fn, "bad_target");
        const switch_inst = cg.builder.buildSwitch(pending, bad_target, line_count);
        for (0..line_count) |j| {
            llvm.builder.Builder.addCase(
                switch_inst,
                llvm.value.constInt(cg.word_type, @intCast(cg.addresses[j])),
                cg.blocks[j],
            );
        }
        cg.builder.positionAtEnd(bad_target);
        // load the bad target address that failed the switch
        const current = cg.builder.buildLoad(cg.word_type, cg.dispatch_slot, "cur");
        // increment to the next address (like falling through a NOP)
        const one = llvm.value.constInt(cg.word_type, 1);
        const next = cg.builder.buildAdd(current, one, "next");
        // update the pending target and retry dispatch
        _ = cg.builder.buildStore(next, cg.dispatch_slot);
        _ = cg.builder.buildBr(cg.dispatch_block);

        return output;
    }

    /// LC-3 address of a global word index
    pub fn addressOf(cg: *CodeGen, index: usize) u16 {
        return cg.addresses[index];
    }

    /// stores one encoded word at its address
    fn storeProgramWord(cg: *CodeGen, index: usize, word: u16) Error!void {
        const address = llvm.value.constInt(
            cg.word_type,
            @intCast(cg.addresses[index]),
        );
        const pointer = cg.builder.buildMemoryAddress(cg.memory_global, address);
        _ = cg.builder.buildStore(llvm.value.constInt(cg.word_type, word), pointer);
    }

    /// LC-3 value of PC while executing word index
    pub fn pcValue(cg: *CodeGen, index: usize) bindings.ValueRef {
        const next: u32 = @as(u32, cg.addresses[index]) + 1;
        return llvm.value.constInt(
            cg.word_type,
            @intCast(next & 0xFFFF),
        );
    }

    /// pointer to one register inside the regs array
    fn regPointer(cg: *CodeGen, code: u3) bindings.ValueRef {
        const index = llvm.value.constInt(cg.word_type, code);
        return cg.builder.buildMemoryAddress(cg.regs, index);
    }

    pub fn loadReg(cg: *CodeGen, code: u3) bindings.ValueRef {
        const pointer = cg.regPointer(code);
        return cg.builder.buildLoad(cg.word_type, pointer, "v");
    }

    /// writes a register and sets the condition codes
    pub fn writeReg(cg: *CodeGen, code: u3, value: bindings.ValueRef) void {
        _ = cg.builder.buildStore(value, cg.regPointer(code));
        _ = cg.builder.buildStore(value, cg.cc_slot);
    }

    /// writes a register without touching the condition codes
    pub fn writeRegNoCc(cg: *CodeGen, code: u3, value: bindings.ValueRef) void {
        _ = cg.builder.buildStore(value, cg.regPointer(code));
    }

    /// loads the current condition-code value
    pub fn loadCc(cg: *CodeGen) bindings.ValueRef {
        return cg.builder.buildLoad(cg.word_type, cg.cc_slot, "cc");
    }

    /// pointer to one field of the shared trap context
    pub fn contextFieldAddress(cg: *CodeGen, field: u32) bindings.ValueRef {
        return cg.builder.buildFieldAddress(cg.ctx_type, cg.ctx_slot, field);
    }

    /// declaration of a trap handler: void(lcc_trap_ctx*), inserted once
    pub fn trapFunction(cg: *CodeGen, symbol: [:0]const u8) bindings.ValueRef {
        if (bindings.LLVMGetNamedFunction(cg.module.ref, symbol.ptr)) |existing| {
            return existing;
        }
        return bindings.LLVMAddFunction(cg.module.ref, symbol.ptr, cg.trap_fn_type);
    }

    /// word pointer for an arbitrary runtime address
    pub fn memoryPointer(cg: *CodeGen, address: bindings.ValueRef) bindings.ValueRef {
        return cg.builder.buildMemoryAddress(cg.memory_global, address);
    }

    /// branches to the dispatch block with target as the pending address
    pub fn dispatchTo(cg: *CodeGen, target: bindings.ValueRef) void {
        _ = cg.builder.buildStore(target, cg.dispatch_slot);
        _ = cg.builder.buildBr(cg.dispatch_block);
    }

    /// maps a PC-relative transfer onto its global block
    pub fn branchTargetIndex(cg: *CodeGen, index: usize, offset: i64) Error!usize {
        const pc = @as(i64, cg.addresses[index]) + 1;
        const target = pc + offset;
        if (target >= 0 and target < 65536) {
            const mapped = cg.addr_to_block[@intCast(target)];
            if (mapped >= 0) return @intCast(mapped);
        }
        std.log.err(
            "control transfer from x{X} reaches x{X}, outside the program image",
            .{ cg.addresses[index], target },
        );
        return error.InvalidTarget;
    }
};
