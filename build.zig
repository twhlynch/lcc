const std = @import("std");

pub fn build(b: *std.Build) void {
    // options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // elk
    const elk_dep = b.dependency("elk", .{});
    const elk_mod = elk_dep.module("elk");

    // system LLVM linked as an external library
    const llvm = discoverLlvm(b);

    // module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "elk", .module = elk_mod },
        },
    });
    linkLlvm(root_module, llvm);

    // main executable
    const exe = b.addExecutable(.{
        .name = "lcc",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    // run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the compiler");
    run_step.dependOn(&run_cmd.step);

    // test executable
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "elk", .module = elk_mod },
        },
    });
    linkLlvm(test_mod, llvm);

    // test
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.has_side_effects = true;
    run_unit_tests.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

// MARK: LLVM

const LlvmPaths = struct {
    lib_dir: []const u8,
    dylib_name: []const u8,
};

fn linkLlvm(module: *std.Build.Module, paths: LlvmPaths) void {
    const lib_path = std.fs.path.join(
        module.owner.allocator,
        &.{ paths.lib_dir, paths.dylib_name },
    ) catch @panic("oom");
    module.addObjectFile(.{ .cwd_relative = lib_path });
}

/// Locates a system LLVM with llvm-config on PATH or homebrew
fn discoverLlvm(b: *std.Build) LlvmPaths {
    const candidates = [_][]const u8{
        "llvm-config",
        "/opt/homebrew/opt/llvm/bin/llvm-config",
        "/usr/local/opt/llvm/bin/llvm-config",
    };

    for (candidates) |candidate| {
        const lib_dir = queryLlvmConfig(b, candidate, "--libdir") orelse continue;
        const shared = queryLlvmConfig(b, candidate, "--shared-mode") orelse continue;
        const dylib_name = if (std.mem.eql(u8, shared, "static"))
            continue
        else if (isDarwin(b))
            "libLLVM.dylib"
        else
            "libLLVM.so";
        return .{ .lib_dir = lib_dir, .dylib_name = dylib_name };
    }

    std.debug.print(
        \\error: LLVM not found.
        \\Install LLVM 15+ and ensure `llvm-config --libdir --shared-mode` works:
        \\  brew install llvm      (macOS)
        \\  apt install llvm-dev   (Debian/Ubuntu)
        \\
    , .{});
    @panic("LLVM dependency missing");
}

fn isDarwin(b: *std.Build) bool {
    return b.graph.host.result.os.tag.isDarwin();
}

fn queryLlvmConfig(b: *std.Build, cmd: []const u8, flag: []const u8) ?[]const u8 {
    const result = std.process.run(b.graph.arena, b.graph.io, .{
        .argv = &.{ cmd, flag },
    }) catch return null;

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    return b.dupePath(std.mem.trim(u8, result.stdout, " \n\r\t"));
}
