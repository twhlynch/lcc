//! LLVM optimisation pipeline

const std = @import("std");
const bindings = @import("bindings.zig");
const module_mod = @import("module.zig");
const target_mod = @import("target.zig");

pub const PassError = error{ PassRunFailed, OutOfMemory };

pub const Level = enum(u2) {
    o0 = 0,
    o1 = 1,
    o2 = 2,
    o3 = 3,

    fn pipeline(level: Level) [*:0]const u8 {
        return switch (level) {
            .o0 => "default<O0>",
            .o1 => "default<O1>",
            .o2 => "default<O2>",
            .o3 => "default<O3>",
        };
    }
};

/// runs the standard optimisation pipeline over module
pub fn runDefault(
    level: Level,
    gpa: std.mem.Allocator,
    module: module_mod.Module,
    machine: target_mod.TargetMachine,
) PassError!void {
    _ = gpa;
    const options = bindings.LLVMCreatePassBuilderOptions();
    defer bindings.LLVMDisposePassBuilderOptions(options);

    if (bindings.LLVMRunPasses(module.ref, level.pipeline(), machine.ref, options) != 0) {
        return error.PassRunFailed;
    }
}
