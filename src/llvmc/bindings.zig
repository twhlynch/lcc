//! Raw LLVM-C bindings

const std = @import("std");

pub const LLVMBool = c_int;

pub const ContextRef = *opaque {};
pub const ModuleRef = *opaque {};
pub const TypeRef = *opaque {};
pub const ValueRef = *opaque {};
pub const BasicBlockRef = *opaque {};
pub const BuilderRef = *opaque {};
pub const TargetRef = *opaque {};
pub const TargetMachineRef = *opaque {};
pub const TargetDataRef = *opaque {};
pub const MemoryBufferRef = *opaque {};
pub const PassBuilderOptionsRef = *opaque {};

/// LLVMVerifierFailureAction
pub const VerifierFailureAction = enum(c_int) {
    return_status = 0,
    print_message = 1,
    abort_process = 2,
};

/// LLVMCodeGenOptLevel
pub const CodeGenOptLevel = enum(c_int) {
    none = 0,
    less = 1,
    default = 2,
    aggressive = 3,
};

/// LLVMRelocMode
pub const RelocMode = enum(c_int) {
    default = 0,
    static = 1,
    pic = 2,
};

/// LLVMCodeModel
pub const CodeModel = enum(c_int) {
    default = 0,
};

/// LLVMCodeGenFileType
pub const CodeGenFileType = enum(c_int) {
    assembly_file = 0,
    object_file = 1,
};

/// LLVMIntPredicate
pub const IntPredicate = enum(c_int) {
    eq = 32,
    ne = 33,
    ugt = 34,
    uge = 35,
    ult = 36,
    ule = 37,
    sgt = 38,
    sge = 39,
    slt = 40,
    sle = 41,
};

// context
pub extern fn LLVMContextCreate() ContextRef;
pub extern fn LLVMContextDispose(C: ContextRef) void;

// module
pub extern fn LLVMModuleCreateWithNameInContext(Name: [*:0]const u8, C: ContextRef) ModuleRef;
pub extern fn LLVMDisposeModule(M: ModuleRef) void;
pub extern fn LLVMSetTarget(M: ModuleRef, Triple: [*:0]const u8) void;
pub extern fn LLVMSetModuleDataLayout(M: ModuleRef, DL: TargetDataRef) void;
pub extern fn LLVMPrintModuleToString(M: ModuleRef) [*:0]u8;
pub extern fn LLVMVerifyModule(M: ModuleRef, Action: VerifierFailureAction, OutMessage: *?[*:0]u8) LLVMBool;

// types
pub extern fn LLVMInt1TypeInContext(C: ContextRef) TypeRef;
pub extern fn LLVMInt8TypeInContext(C: ContextRef) TypeRef;
pub extern fn LLVMInt16TypeInContext(C: ContextRef) TypeRef;
pub extern fn LLVMInt32TypeInContext(C: ContextRef) TypeRef;
pub extern fn LLVMVoidTypeInContext(C: ContextRef) TypeRef;
pub extern fn LLVMPointerTypeInContext(C: ContextRef, AddressSpace: c_uint) TypeRef;
pub extern fn LLVMArrayType2(ElementType: TypeRef, ElementCount: c_ulonglong) TypeRef;
pub extern fn LLVMFunctionType(ReturnType: TypeRef, ParamTypes: ?[*]const TypeRef, ParamCount: c_uint, IsVarArg: LLVMBool) TypeRef;

// values
pub extern fn LLVMAddFunction(M: ModuleRef, Name: [*:0]const u8, FunctionTy: TypeRef) ValueRef;
pub extern fn LLVMGetNamedFunction(M: ModuleRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMGlobalGetValueType(Global: ValueRef) TypeRef;
pub extern fn LLVMAddGlobal(M: ModuleRef, Ty: TypeRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMSetInitializer(GlobalVar: ValueRef, ConstantVal: ValueRef) void;
pub extern fn LLVMConstInt(IntTy: TypeRef, N: c_ulonglong, SignExtend: LLVMBool) ValueRef;
pub extern fn LLVMConstNull(Ty: TypeRef) ValueRef;

// builder
pub extern fn LLVMAppendBasicBlockInContext(C: ContextRef, Fn: ValueRef, Name: [*:0]const u8) BasicBlockRef;
pub extern fn LLVMCreateBuilderInContext(C: ContextRef) BuilderRef;
pub extern fn LLVMPositionBuilderAtEnd(Builder: BuilderRef, Block: BasicBlockRef) void;
pub extern fn LLVMBuildRet(Builder: BuilderRef, V: ValueRef) ValueRef;
pub extern fn LLVMBuildBr(Builder: BuilderRef, Dest: BasicBlockRef) ValueRef;
pub extern fn LLVMBuildCondBr(Builder: BuilderRef, If: ValueRef, Then: BasicBlockRef, Else: BasicBlockRef) ValueRef;
pub extern fn LLVMBuildSwitch(Builder: BuilderRef, V: ValueRef, Else: BasicBlockRef, NumCases: c_uint) ValueRef;
pub extern fn LLVMAddCase(Switch: ValueRef, OnVal: ValueRef, Dest: BasicBlockRef) void;
pub extern fn LLVMBuildUnreachable(Builder: BuilderRef) ValueRef;
pub extern fn LLVMBuildCall2(Builder: BuilderRef, Ty: TypeRef, Fn: ValueRef, Args: [*]const ValueRef, NumArgs: c_uint, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildAlloca(Builder: BuilderRef, Ty: TypeRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildLoad2(Builder: BuilderRef, Ty: TypeRef, PointerVal: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildStore(Builder: BuilderRef, Val: ValueRef, Ptr: ValueRef) ValueRef;
pub extern fn LLVMBuildGEP2(Builder: BuilderRef, Ty: TypeRef, Pointer: ValueRef, Indices: [*]const ValueRef, NumIndices: c_uint, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildAdd(Builder: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildAnd(Builder: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildOr(Builder: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildXor(Builder: BuilderRef, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildICmp(Builder: BuilderRef, Op: IntPredicate, LHS: ValueRef, RHS: ValueRef, Name: [*:0]const u8) ValueRef;
pub extern fn LLVMBuildZExt(Builder: BuilderRef, Val: ValueRef, DestTy: TypeRef, Name: [*:0]const u8) ValueRef;

// target
pub extern fn LLVMGetDefaultTargetTriple() [*:0]u8;
pub extern fn LLVMGetTargetFromTriple(Triple: [*:0]const u8, T: *TargetRef, ErrorMessage: *?[*:0]u8) LLVMBool;
pub extern fn LLVMCreateTargetMachine(
    T: TargetRef,
    Triple: [*:0]const u8,
    CPU: [*:0]const u8,
    Features: [*:0]const u8,
    Level: CodeGenOptLevel,
    Reloc: RelocMode,
    CodeModel: CodeModel,
) TargetMachineRef;
pub extern fn LLVMDisposeTargetMachine(T: TargetMachineRef) void;
pub extern fn LLVMCreateTargetDataLayout(TM: TargetMachineRef) TargetDataRef;
pub extern fn LLVMDisposeTargetData(DL: TargetDataRef) void;

// target registration
pub extern fn LLVMInitializeAArch64TargetInfo() void;
pub extern fn LLVMInitializeAArch64Target() void;
pub extern fn LLVMInitializeAArch64TargetMC() void;
pub extern fn LLVMInitializeAArch64AsmPrinter() void;
pub extern fn LLVMInitializeAArch64AsmParser() void;
pub extern fn LLVMInitializeX86TargetInfo() void;
pub extern fn LLVMInitializeX86Target() void;
pub extern fn LLVMInitializeX86TargetMC() void;
pub extern fn LLVMInitializeX86AsmPrinter() void;
pub extern fn LLVMInitializeX86AsmParser() void;

/// registers target information for the host architecture
pub fn initializeNativeTarget(arch: std.Target.Cpu.Arch) void {
    switch (arch) {
        .aarch64 => {
            LLVMInitializeAArch64TargetInfo();
            LLVMInitializeAArch64Target();
            LLVMInitializeAArch64TargetMC();
            LLVMInitializeAArch64AsmPrinter();
            LLVMInitializeAArch64AsmParser();
        },
        .x86_64 => {
            LLVMInitializeX86TargetInfo();
            LLVMInitializeX86Target();
            LLVMInitializeX86TargetMC();
            LLVMInitializeX86AsmPrinter();
            LLVMInitializeX86AsmParser();
        },
        else => std.debug.panic("no registered LLVM backend for {s}", .{@tagName(arch)}),
    }
}

// object emission
pub extern fn LLVMTargetMachineEmitToMemoryBuffer(
    T: TargetMachineRef,
    M: ModuleRef,
    CodeGen: CodeGenFileType,
    ErrorMessage: *?[*:0]u8,
    OutMemBuf: *MemoryBufferRef,
) LLVMBool;
pub extern fn LLVMGetBufferStart(MemBuf: MemoryBufferRef) [*]const u8;
pub extern fn LLVMGetBufferSize(MemBuf: MemoryBufferRef) usize;
pub extern fn LLVMDisposeMemoryBuffer(MemBuf: MemoryBufferRef) void;

// new pass manager
pub extern fn LLVMRunPasses(M: ModuleRef, Passes: [*:0]const u8, TM: TargetMachineRef, Options: PassBuilderOptionsRef) LLVMBool;
pub extern fn LLVMCreatePassBuilderOptions() PassBuilderOptionsRef;
pub extern fn LLVMDisposePassBuilderOptions(Options: PassBuilderOptionsRef) void;

// message disposal (for strings returned by the C API)
pub extern fn LLVMDisposeMessage(Message: [*:0]u8) void;
