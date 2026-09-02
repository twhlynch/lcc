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

/// native runtime functions for trap lowering
pub const RuntimeFn = enum { getc, out, puts, in, putsp, halt, putn, reg };

const runtime_names = [_][*:0]const u8{ "lc3_getc", "lc3_out", "lc3_puts", "lc3_in", "lc3_putsp", "lc3_halt", "lc3_putn", "lc3_reg" };

/// llvm type of a native runtime function
fn runtimeType(context: llvm.context.Context, which: RuntimeFn) bindings.TypeRef {
    const word = llvm.types.int16(context);
    const pointer = llvm.types.pointer(context);
    return switch (which) {
        .getc, .in => llvm.types.function(word, &.{}),
        .out, .putn => llvm.types.function(llvm.types.void_(context), &.{word}),
        .puts, .putsp => llvm.types.function(llvm.types.void_(context), &.{ pointer, word }),
        .halt => llvm.types.function(llvm.types.void_(context), &.{}),
        .reg => llvm.types.function(llvm.types.void_(context), &.{ word, word, word, word, word, word, word, word, word, word }),
    };
}

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
    air: *const elk.Air,
    module: llvm.module.Module,
    builder: llvm.builder.Builder,
    gpa: std.mem.Allocator,

    /// cached type handles.
    word_type: bindings.TypeRef,

    /// the flat LC-3 address space
    memory_global: bindings.ValueRef,

    /// stack slots for R0-R7, the condition code and the pending
    /// indirect jump target
    reg_slots: [8]bindings.ValueRef,
    cc_slot: bindings.ValueRef,
    dispatch_slot: bindings.ValueRef,

    /// one basic block per LC-3 word; blocks[len] is the exit block
    blocks: []bindings.BasicBlockRef,

    /// shared dispatch target for JMP/JSRR/RET
    dispatch_block: bindings.BasicBlockRef,

    /// declarations of the native runtime trap functions
    runtime_fns: [runtime_names.len]bindings.ValueRef,

    /// lowers a whole program into an LLVM module
    pub fn emit(
        air: *const elk.Air,
        gpa: std.mem.Allocator,
    ) Error!Output {
        const context = llvm.context.Context.create();

        const line_count = air.lines.items.len;

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
            .air = air,
            .module = output.module,
            .builder = builder,
            .gpa = gpa,
            .word_type = llvm.types.int16(context),
            .memory_global = undefined,
            .reg_slots = undefined,
            .cc_slot = undefined,
            .dispatch_slot = undefined,
            .blocks = blocks.ptr[0 .. line_count + 1],
            .dispatch_block = undefined,
            .runtime_fns = undefined,
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

        // declare the native runtime functions
        inline for (0..runtime_names.len) |which| {
            cg.runtime_fns[which] = bindings.LLVMAddFunction(
                output.module.ref,
                runtime_names[which],
                runtimeType(context, @enumFromInt(which)),
            );
        }

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

        inline for (0..8) |code| {
            var name_buffer: [8]u8 = undefined;
            const name = std.fmt.bufPrintZ(&name_buffer, "r{d}", .{code}) catch unreachable;
            cg.reg_slots[code] = bindings.LLVMBuildAlloca(cg.builder.ref, cg.word_type, name.ptr);
        }
        cg.cc_slot = cg.builder.buildAlloca(cg.word_type, "cc");
        cg.dispatch_slot = cg.builder.buildAlloca(cg.word_type, "target");
        // starts with all registers cleared
        const zero = llvm.value.constInt(cg.word_type, 0);
        for (cg.reg_slots) |slot| _ = cg.builder.buildStore(zero, slot);
        _ = cg.builder.buildStore(zero, cg.cc_slot);

        const memory_type = llvm.types.memoryArray(cg.word_type, 65536);
        cg.memory_global = bindings.LLVMAddGlobal(
            output.module.ref,
            memory_type,
            "memory",
        );
        bindings.LLVMSetInitializer(cg.memory_global, llvm.value.constNull(memory_type));

        // store all encoded words into memory before execution starts
        for (air.lines.items, 0..) |line, i| {
            try cg.storeProgramWord(i, line.statement.encode());
        }

        for (0..line_count) |i| {
            var name_buffer: [16]u8 = undefined;
            const name = std.fmt.bufPrintZ(&name_buffer, "w{d}", .{i}) catch unreachable;
            cg.blocks[i] = bindings.LLVMAppendBasicBlockInContext(context.ref, main_fn, name.ptr);
        }
        cg.blocks[line_count] = bindings.LLVMAppendBasicBlockInContext(context.ref, main_fn, "exit");
        cg.dispatch_block = bindings.LLVMAppendBasicBlockInContext(context.ref, main_fn, "dispatch");

        _ = cg.builder.buildBr(cg.blocks[0]);

        for (air.lines.items, 0..) |line, i| {
            cg.builder.positionAtEnd(cg.blocks[i]);
            switch (line.statement) {
                .raw_word => {
                    // data words are always treated as NOPs
                    _ = cg.builder.buildBr(cg.blocks[i + 1]);
                    continue;
                },
                .instruction => |inst| {
                    const terminated = try instruction.lower(&cg, inst, i);
                    // fall through unless the instruction ended its block
                    if (!terminated) {
                        _ = cg.builder.buildBr(cg.blocks[i + 1]);
                    }
                },
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
                llvm.value.constInt(cg.word_type, @intCast(air.origin + j)),
                cg.blocks[j],
            );
        }
        cg.builder.positionAtEnd(bad_target);
        _ = cg.builder.buildUnreachable();

        return output;
    }

    /// stores one encoded word at its address
    fn storeProgramWord(cg: *CodeGen, index: usize, word: u16) Error!void {
        const address = llvm.value.constInt(
            cg.word_type,
            @intCast(cg.air.origin + index),
        );
        const pointer = cg.builder.buildMemoryAddress(cg.memory_global, address);
        _ = cg.builder.buildStore(llvm.value.constInt(cg.word_type, word), pointer);
    }

    /// LC-3 value of PC while executing word index
    pub fn pcValue(cg: *CodeGen, index: usize) bindings.ValueRef {
        return llvm.value.constInt(
            cg.word_type,
            @as(i64, cg.air.origin) + @as(i64, @intCast(index)) + 1,
        );
    }

    pub fn loadReg(cg: *CodeGen, code: u3) bindings.ValueRef {
        return cg.builder.buildLoad(cg.word_type, cg.reg_slots[code], "v");
    }

    /// writes a register and sets the condition codes
    pub fn writeReg(cg: *CodeGen, code: u3, value: bindings.ValueRef) void {
        _ = cg.builder.buildStore(value, cg.reg_slots[code]);
        _ = cg.builder.buildStore(value, cg.cc_slot);
    }

    /// writes a register without touching the condition codes
    pub fn writeRegNoCc(cg: *CodeGen, code: u3, value: bindings.ValueRef) void {
        _ = cg.builder.buildStore(value, cg.reg_slots[code]);
    }

    /// loads the current condition-code value
    pub fn loadCc(cg: *CodeGen) bindings.ValueRef {
        return cg.builder.buildLoad(cg.word_type, cg.cc_slot, "cc");
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

    /// emits a call to a native runtime function
    pub fn callRuntime(
        cg: *CodeGen,
        which: RuntimeFn,
        args: []const bindings.ValueRef,
    ) bindings.ValueRef {
        return cg.builder.buildCall(
            cg.runtime_fns[@intFromEnum(which)],
            args,
            "",
        );
    }

    /// validates a PC-relative target against the program bounds
    pub fn branchTargetIndex(cg: *CodeGen, index: usize, offset: i64) Error!usize {
        const target = @as(i64, @intCast(index)) + 1 + offset;
        if (target < 0 or target >= cg.air.lines.items.len) {
            std.log.err(
                "control transfer from x{X} reaches x{X}, outside the program image",
                .{ @as(u64, @intCast(cg.air.origin + index + 1)), @as(i64, cg.air.origin) + target },
            );
            return error.InvalidTarget;
        }
        return @intCast(target);
    }
};
