//! end-to-end pipeline tests

const std = @import("std");

const lcc_exe = "zig-out/bin/lcc";

/// reference behaviour of each example
const Example = struct {
    name: []const u8,
    exit_code: u8,
    stdout: []const u8 = "",
    match_emulator: bool = true,
};

const examples = [_]Example{
    .{ .name = "arithmetic", .exit_code = 12 },
    .{ .name = "inline_storage", .exit_code = 0, .stdout = "+----------------------------------+\n|       hex      int    uint   chr |\n| R0  x3000   +12288   12288   --- |\n| R1  x3001   +12289   12289   --- |\n| R2  x0000       +0       0   NUL |\n| R3  x0000       +0       0   NUL |\n| R4  x0000       +0       0   NUL |\n| R5  x0000       +0       0   NUL |\n| R6  x0000       +0       0   NUL |\n| R7  x0000       +0       0   NUL |\n+----------------+-----------------+\n|    PC x3008    |   CC POSITIVE   |\n+----------------+-----------------+\n", .match_emulator = false },
    .{ .name = "debug", .exit_code = 0, .stdout = "1\n3\n6\n10\n15\n21\n28\n36\n45\n55\n66\n+----------------------------------+\n|       hex      int    uint   chr |\n| R0  x0042      +66      66    B  |\n| R1  x000B      +11      11    VT |\n| R2  x000A      +10      10    LF |\n| R3  x0001       +1       1   SOH |\n| R4  x0000       +0       0   NUL |\n| R5  x0000       +0       0   NUL |\n| R6  x0000       +0       0   NUL |\n| R7  x0000       +0       0   NUL |\n+----------------+-----------------+\n|    PC x300D    |   CC POSITIVE   |\n+----------------+-----------------+\n" },
    .{ .name = "echo", .exit_code = 0, .stdout = "1\n" },
    .{ .name = "fibonacci", .exit_code = 55 },
    .{ .name = "greet", .exit_code = 0, .stdout = "Input> 1\n\nHello, 1\nOK\n" },
    .{ .name = "hello", .exit_code = 0, .stdout = "Hello World!\n" },
    .{ .name = "loops", .exit_code = 15 },
    .{ .name = "memory", .exit_code = 12 },
    .{ .name = "pyramid", .exit_code = 0, .stdout = "Pyramid height (0-9): 1\n*\n" },
    .{ .name = "subroutines", .exit_code = 50 },
    .{ .name = "subsubroutine", .exit_code = 0, .stdout = "+----------------------------------+\n|       hex      int    uint   chr |\n| R0  x0000       +0       0   NUL |\n| R1  x0000       +0       0   NUL |\n| R2  x0000       +0       0   NUL |\n| R3  x0000       +0       0   NUL |\n| R4  x0000       +0       0   NUL |\n| R5  x0000       +0       0   NUL |\n| R6  x0000       +0       0   NUL |\n| R7  x3004   +12292   12292   --- |\n+----------------+-----------------+\n|    PC x3007    |   CC   ZERO     |\n+----------------+-----------------+\n" },
    .{ .name = "uppercase", .exit_code = 0, .stdout = "1\n" },
};

fn requireLcc(io: std.Io) void {
    std.Io.Dir.cwd().access(io, lcc_exe, .{}) catch {
        std.debug.print("`{s}` not found; run `zig build` first\n", .{lcc_exe});
        @panic("missing lcc binary");
    };
}

const RunResult = struct { exit: u8, stdout: []const u8, stderr: []const u8 };

/// compiles one example at opt level and executes the result with "1" on
/// stdin, returning the exit code and stdout of the compiled program
fn runProgram(
    alloc: std.mem.Allocator,
    io: std.Io,
    example: []const u8,
    opt_level: []const u8,
) !RunResult {
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

    return execWithStdin(alloc, io, &.{out_path}, "1\n");
}

/// spawns argv with input piped to stdin and collects its stdout and stderr
fn execWithStdin(
    alloc: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    input: []const u8,
) !RunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        // captured so emulator noise does not pollute the test output
        .stderr = .pipe,
    });

    // feed the same input to every program: numeric readers take 1 as a
    // number and string readers take it as a string
    var input_buffer: [64]u8 = undefined;
    var input_writer = child.stdin.?.writer(io, &input_buffer);
    input_writer.interface.writeAll(input) catch {};
    input_writer.interface.flush() catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    const stdout_data = try drain(alloc, io, &child, .stdout);
    const stderr_data = try drain(alloc, io, &child, .stderr);

    switch (child.wait(io) catch {
        return error.ProgramCrashed;
    }) {
        .exited => |code| {
            return .{ .exit = code, .stdout = stdout_data, .stderr = stderr_data };
        },
        else => {
            alloc.free(stdout_data);
            alloc.free(stderr_data);
            return error.ProgramCrashed;
        },
    }
}

/// reads a pipe of the child to end of file and closes it
fn drain(
    alloc: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    comptime which: enum { stdout, stderr },
) ![]u8 {
    const file = switch (which) {
        .stdout => child.stdout orelse {
            return alloc.dupe(u8, "");
        },
        .stderr => child.stderr orelse {
            return alloc.dupe(u8, "");
        },
    };

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var list: std.ArrayList(u8) = .empty;
    reader.interface.appendRemainingUnlimited(alloc, &list) catch |err| {
        child.kill(io);
        return err;
    };
    file.close(io);
    switch (which) {
        .stdout => child.stdout = null,
        .stderr => child.stderr = null,
    }
    return try list.toOwnedSlice(alloc);
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

    for (examples) |expect| {
        try checkExample(std.testing.allocator, expect, "-O0");
    }
}

test "optimised builds preserve behaviour" {
    requireLcc(std.testing.io);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, ".lcc-test");

    for (examples) |expect| {
        try checkExample(std.testing.allocator, expect, "-O2");
    }
}

test "output matches the elk emulator" {
    requireLcc(std.testing.io);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, ".lcc-test");
    const io = std.testing.io;

    for (examples) |expect| {
        if (!expect.match_emulator) {
            continue;
        }
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var asm_path_buf: [128]u8 = undefined;
        const asm_path = try std.fmt.bufPrint(&asm_path_buf, "examples/{s}.asm", .{expect.name});

        // the emulator always exits 0 regardless of R0, so only output is
        // compared here; exit codes are covered by checkExample
        const emulated = execWithStdin(alloc, io, &.{ "elk", asm_path }, "1\n") catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("elk not installed; skipping emulator comparison\n", .{});
                return;
            },
            else => return err,
        };

        var out_path_buf: [128]u8 = undefined;
        const out_path = try std.fmt.bufPrint(&out_path_buf, ".lcc-test/{s}", .{expect.name});
        errdefer std.debug.print("{s}: compiled output differs from the emulator\n", .{expect.name});
        const compiled = try execWithStdin(alloc, io, &.{out_path}, "1\n");

        try std.testing.expectEqualStrings(emulated.stdout, compiled.stdout);
    }
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
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "define i32 @main(") != null);
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

test "dynamic linking produces identical output" {
    requireLcc(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;

    // compile hello example with dynamic linking (library is generated automatically)
    const compile_result = try std.process.run(alloc, io, .{
        .argv = &.{ lcc_exe, "-o", ".lcc-test/hello_dynamic", "-dynamic", "examples/hello.asm" },
    });
    try std.testing.expectEqual(@as(u8, 0), switch (compile_result.term) {
        .exited => |code| code,
        else => {
            std.debug.print("compile failed: {s}\n", .{compile_result.stderr});
            return error.Crashed;
        },
    });
    defer {
        std.Io.Dir.cwd().deleteFile(io, ".lcc-test/hello_dynamic") catch {};
        std.Io.Dir.cwd().deleteFile(io, "liblc3.dylib") catch {};
        std.Io.Dir.cwd().deleteFile(io, "liblc3.so") catch {};
    }

    // run and compare output
    const run_result = try execWithStdin(alloc, io, &.{".lcc-test/hello_dynamic"}, "1\n");
    try std.testing.expectEqual(@as(u8, 0), run_result.exit);
    try std.testing.expectEqualStrings("Hello World!\n", run_result.stdout);
}

test "dynamic linking from lib-path subdirectory" {
    requireLcc(std.testing.io);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    // create .lcc-test/lib/ and generate liblc3 there
    try cwd.createDirPath(io, ".lcc-test/lib");
    defer {
        cwd.deleteFile(io, ".lcc-test/lib/liblc3.dylib") catch {};
        cwd.deleteFile(io, ".lcc-test/lib/liblc3.so") catch {};
        cwd.deleteTree(io, ".lcc-test/lib") catch {};
    }

    const lib_name = if (comptime @import("builtin").os.tag.isDarwin()) "liblc3.dylib" else "liblc3.so";
    const gen_result = try std.process.run(alloc, io, .{
        .argv = &.{ lcc_exe, "-generate-liblc3" },
    });
    try std.testing.expectEqual(@as(u8, 0), switch (gen_result.term) {
        .exited => |code| code,
        else => return error.Crashed,
    });
    // move liblc3 from cwd to .lcc-test/lib/
    const mv_result = try std.process.run(alloc, io, .{
        .argv = &.{ "mv", lib_name, ".lcc-test/lib/" },
    });
    try std.testing.expectEqual(@as(u8, 0), switch (mv_result.term) {
        .exited => |code| code,
        else => return error.Crashed,
    });

    // compile with -L pointing to the subdirectory (auto-generates a new lib in cwd)
    const compile_result = try std.process.run(alloc, io, .{
        .argv = &.{ lcc_exe, "-o", ".lcc-test/hello_libpath", "-dynamic", "-L", ".lcc-test/lib", "examples/hello.asm" },
    });
    try std.testing.expectEqual(@as(u8, 0), switch (compile_result.term) {
        .exited => |code| code,
        else => {
            std.debug.print("compile failed: {s}\n", .{compile_result.stderr});
            return error.Crashed;
        },
    });
    defer {
        cwd.deleteFile(io, ".lcc-test/hello_libpath") catch {};
        cwd.deleteFile(io, "liblc3.dylib") catch {};
        cwd.deleteFile(io, "liblc3.so") catch {};
    }

    const run_result = try execWithStdin(alloc, io, &.{".lcc-test/hello_libpath"}, "1\n");
    try std.testing.expectEqual(@as(u8, 0), run_result.exit);
    try std.testing.expectEqualStrings("Hello World!\n", run_result.stdout);
}
