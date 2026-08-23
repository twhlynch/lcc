//! LLVM code generation.
//!
//! Consumes ELK's `Air` into the `@main` function of an LLVM module
//!
//! Machine model:
//!    - R0-R7 are i16 SSA values tracked per register
//!    - the condition code is carried as signed-compare predicates
//!    - PC is represented through LLVM control flow

const std = @import("std");

const elk = @import("../elk.zig");
const llvm = @import("../llvmc/root.zig");
const bindings = llvm.bindings;
pub const instruction = @import("instruction.zig");

pub const Error = error{UnsupportedInstruction};

/// everything the pipeline keeps alive between stages
/// owned by the caller
pub const Output = struct {
    context: llvm.context.Context,
    module: llvm.module.Module,

    pub fn deinit(output: Output) void {
        output.module.dispose();
        output.context.dispose();
    }
};

pub const CodeGen = struct {
    air: *const elk.Air,
    module: llvm.module.Module,
    builder: llvm.builder.Builder,

    /// cached type handles.
    word_type: bindings.TypeRef,

    /// the flat LC-3 address space
    memory_global: bindings.ValueRef,

    /// current LLVM state of each LC-3 register
    regs: [8]RegState,
    /// predicates from the most recent register write
    cc: CC = null,

    pub const RegState = union(enum) {
        /// register content is a known constant
        constant: i16,
        /// register holds an SSA value
        value: bindings.ValueRef,
    };

    /// signed-compare predicates for the current condition code
    pub const CC = ?struct {
        n: bindings.ValueRef,
        z: bindings.ValueRef,
        p: bindings.ValueRef,
    };

    /// lowers a whole program into an LLVM module
    pub fn emit(
        air: *const elk.Air,
        gpa: std.mem.Allocator,
    ) Error!Output {
        _ = gpa;

        const context = llvm.context.Context.create();
        var output: Output = .{ .context = context, .module = undefined };
        errdefer output.deinit();

        output.module = llvm.module.Module.create("lcc", context);

        var cg: CodeGen = .{
            .air = air,
            .module = output.module,
            .builder = llvm.builder.Builder.create(context),
            .word_type = llvm.types.int16(context),
            .memory_global = undefined,
            // all registers cleared
            .regs = @splat(.{ .constant = 0 }),
        };

        const memory_type = llvm.types.memoryArray(cg.word_type, 65536);
        cg.memory_global = bindings.LLVMAddGlobal(
            output.module.ref,
            memory_type,
            "memory",
        );
        bindings.LLVMSetInitializer(cg.memory_global, llvm.value.constNull(memory_type));

        const main_fn = bindings.LLVMAddFunction(
            output.module.ref,
            "main",
            llvm.types.function(llvm.types.int32(context)),
        );
        const entry = bindings.LLVMAppendBasicBlockInContext(context.ref, main_fn, "entry");
        cg.builder.positionAtEnd(entry);

        for (air.lines.items) |line| {
            switch (line.statement) {
                // directives memory lowering (unimplemented)
                .raw_word => return error.UnsupportedInstruction,
                .instruction => |inst| try instruction.lower(&cg, inst),
            }
        }

        // R0 is the exit code
        const r0 = cg.regValue(cg.regs[0]);
        const widened = cg.builder.buildZExtToInt32(r0, "exit");
        _ = cg.builder.buildRet(widened);

        return output;
    }

    /// the LLVM value for a registers current state
    pub fn regValue(cg: *CodeGen, state: RegState) bindings.ValueRef {
        return switch (state) {
            .constant => |c| llvm.value.constInt(cg.word_type, c),
            .value => |v| v,
        };
    }

    pub fn setReg(cg: *CodeGen, code: u3, state: RegState) void {
        cg.regs[code] = state;
        cg.cc = null; // stale until updated by a register write
    }

    /// emits signed-compare predicates for a freshly written register and
    /// records them as the machine's condition code
    pub fn updateCc(cg: *CodeGen, result: bindings.ValueRef) void {
        const n = cg.builder.buildIcmpZero(.slt, result, "cc.n");
        const z = cg.builder.buildIcmpZero(.eq, result, "cc.z");
        const p = cg.builder.buildIcmpZero(.sgt, result, "cc.p");

        cg.cc = .{ .n = n, .z = z, .p = p };
    }
};
