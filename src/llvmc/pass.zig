//! LLVM optimisation pipeline

const std = @import("std");
const bindings = @import("bindings.zig");
const module_mod = @import("module.zig");
const target_mod = @import("target.zig");

pub const PassError = error{ PassRunFailed, OutOfMemory };

pub const Level = enum(u8) {
    /// no passes at all
    none = 0,
    o0 = 1,
    o1 = 2,
    o2 = 3,
    o3 = 4,

    fn pipeline(level: Level) [*:0]const u8 {
        return switch (level) {
            .none => unreachable,
            .o0 => "default<O0>",
            .o1 => "default<O1>",
            .o2 => "default<O2>",
            .o3 => "default<O3>",
        };
    }
};

/// runs the standard optimisation pipeline over module
/// level .none skips the pipeline entirely
pub fn runDefault(
    level: Level,
    gpa: std.mem.Allocator,
    module: module_mod.Module,
    machine: target_mod.TargetMachine,
) PassError!void {
    if (level == .none) return;

    _ = gpa;
    const options = bindings.LLVMCreatePassBuilderOptions();
    defer bindings.LLVMDisposePassBuilderOptions(options);

    if (bindings.LLVMRunPasses(module.ref, level.pipeline(), machine.ref, options) != 0) {
        return error.PassRunFailed;
    }
}
