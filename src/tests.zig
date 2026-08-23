//! end-to-end pipeline tests

const std = @import("std");

const lcc_exe = "zig-out/bin/lcc";

/// reference behaviour of each example
const Example = struct {
    name: []const u8,
    exit_code: u8,
    stdout: []const u8 = "",
};

const examples = [_]Example{
    .{ .name = "arithmetic", .exit_code = 12 },
    .{ .name = "echo", .exit_code = 0, .stdout = "1\n" },
    .{ .name = "fibonacci", .exit_code = 55 },
    .{ .name = "greet", .exit_code = 0, .stdout = "Input> 1\n\nHello, 1\nOK" },
    .{ .name = "hello", .exit_code = 0, .stdout = "Hello World!\n" },
    .{ .name = "loops", .exit_code = 15 },
    .{ .name = "memory", .exit_code = 12 },
    .{ .name = "pyramid", .exit_code = 0, .stdout = "Pyramid height (0-9): 1\n*\n" },
    .{ .name = "subroutines", .exit_code = 50 },
    .{ .name = "uppercase", .exit_code = 0, .stdout = "1" },
};

fn requireLcc(io: std.Io) void {
    std.Io.Dir.cwd().access(io, lcc_exe, .{}) catch {
        std.debug.print("`{s}` not found; run `zig build` first\n", .{lcc_exe});
        @panic("missing lcc binary");
    };
}

/// compiles one example at opt level and executes the result with "1" on
/// stdin, returning the exit code and stdout of the compiled program
fn runProgram(
    alloc: std.mem.Allocator,
    io: std.Io,
    example: []const u8,
    opt_level: []const u8,
) !struct { exit: u8, stdout: []const u8 } {
    var out_path_buf: [128]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&out_path_buf, ".lcc-test/{s}", .{example});

    var in_path_buf: [128]u8 = undefined;
    const in_path = try std.fmt.bufPrint(&in_path_buf, "examples/{s}.asm", .{example});

    var argv_buf: [5][]const u8 = undefined;
    argv_buf[0] = lcc_exe;
    argv_buf[1] = "-o";
    argv_buf[2] = out_path;
    argv_buf[3] = opt_level;
    argv_buf[4] = in_path;

    const compile_result = std.process.run(alloc, io, .{ .argv = &argv_buf }) catch |err| {
        std.debug.print("failed to spawn {s}: {s}\n", .{ lcc_exe, @errorName(err) });
        return err;
    };
    defer alloc.free(compile_result.stdout);
    defer alloc.free(compile_result.stderr);

    switch (compile_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print(
                "compiling {s} failed ({d}): {s}{s}\n",
                .{ example, code, compile_result.stderr, compile_result.stdout },
            );
            return error.CompileFailed;
        },
        else => {
            std.debug.print("compiling {s} crashed\n{s}", .{ example, compile_result.stderr });
            return error.CompileFailed;
        },
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{out_path},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    // feed the same input to every program: numeric readers take 1 as a
    // number and string readers take it as a string
    var input_buffer: [64]u8 = undefined;
    var input_writer = child.stdin.?.writer(io, &input_buffer);
    input_writer.interface.writeAll("1\n") catch {};
    input_writer.interface.flush() catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    var output_buffer: [4096]u8 = undefined;
    var output_reader = child.stdout.?.reader(io, &output_buffer);
    var stdout_list: std.ArrayList(u8) = .empty;
    output_reader.interface.appendRemainingUnlimited(alloc, &stdout_list) catch |err| {
        child.kill(io);
        return err;
    };
    const stdout_data: []u8 = try stdout_list.toOwnedSlice(alloc);
    child.stdout.?.close(io);
    child.stdout = null;

    switch (child.wait(io) catch return error.ProgramCrashed) {
        .exited => |code| return .{ .exit = code, .stdout = stdout_data },
        else => {
            alloc.free(stdout_data);
            return error.ProgramCrashed;
        },
    }
}

fn checkExample(alloc: std.mem.Allocator, expect: Example, opt_level: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const result = try runProgram(arena.allocator(), std.testing.io, expect.name, opt_level);
    errdefer std.debug.print("{s} (opt {s})\n", .{ expect.name, opt_level });

    try std.testing.expectEqual(expect.exit_code, result.exit);
    try std.testing.expectEqualStrings(expect.stdout, result.stdout);
}

test "compile and run every example" {
    requireLcc(std.testing.io);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, ".lcc-test");

    for (examples) |expect| try checkExample(std.testing.allocator, expect, "-O0");
}

test "optimised builds preserve behaviour" {
    requireLcc(std.testing.io);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, ".lcc-test");

    for (examples) |expect| try checkExample(std.testing.allocator, expect, "-O2");
}

test "emit llvm produces a main function" {
    requireLcc(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try std.process.run(arena.allocator(), std.testing.io, .{
        .argv = &.{ lcc_exe, "-emit-llvm", "examples/fibonacci.asm" },
    });

    try std.testing.expectEqual(@as(u8, 0), switch (result.term) {
        .exited => |code| code,
        else => return error.Crashed,
    });
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "define i32 @main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "@memory = global [65536 x i16]") != null);
}

test "version and help flags succeed" {
    requireLcc(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    inline for (.{ "--version", "-h", "--help" }) |flag| {
        const result = try std.process.run(arena.allocator(), std.testing.io, .{
            .argv = &.{ lcc_exe, flag },
        });
        try std.testing.expectEqual(@as(u8, 0), switch (result.term) {
            .exited => |code| code,
            else => return error.Crashed,
        });
        try std.testing.expect(result.stdout.len > 0);
    }
}

test "usage errors are reported" {
    requireLcc(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // unknown option
    {
        const result = try std.process.run(arena.allocator(), std.testing.io, .{
            .argv = &.{ lcc_exe, "--definitely-not-a-flag" },
        });
        try std.testing.expect(switch (result.term) {
            .exited => |code| code != 0,
            else => true,
        });
    }

    // missing input file
    {
        const result = try std.process.run(arena.allocator(), std.testing.io, .{
            .argv = &.{ lcc_exe, "/nonexistent.asm" },
        });
        try std.testing.expect(switch (result.term) {
            .exited => |code| code != 0,
            else => true,
        });
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "file not found") != null);
    }
}
