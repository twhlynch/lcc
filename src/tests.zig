//! end-to-end pipeline tests

const std = @import("std");

const lcc_exe = "zig-out/bin/lcc";
const test_dir = ".lcc-test";

const Example = struct {
    name: []const u8,
    exit_code: u8,
    stdout: []const u8 = "",
    match_emulator: bool = true,
    args: []const []const u8 = &.{},
};

const examples = [_]Example{
    .{ .name = "arithmetic", .exit_code = 12 },
    .{ .name = "echo", .exit_code = 0, .stdout = "1\n" },
    .{ .name = "fibonacci", .exit_code = 55 },
    .{ .name = "greet", .exit_code = 0, .stdout = "Input> 1\n\nHello, 1\nOK\x00\n" },
    .{ .name = "hello", .exit_code = 0, .stdout = "Hello World!\n" },
    .{ .name = "loops", .exit_code = 15 },
    .{ .name = "memory", .exit_code = 12 },
    .{ .name = "pyramid", .exit_code = 0, .stdout = "Pyramid height (0-9): 1\n*\n" },
    .{ .name = "subroutines", .exit_code = 50 },
    .{ .name = "uppercase", .exit_code = 0, .stdout = "1\n" },
    .{ .name = "subsubroutine", .exit_code = 0, .stdout = "12289\n12294\n12294\n12289\n" },
    .{ .name = "debug", .exit_code = 0, .stdout = "1\n3\n6\n10\n15\n21\n28\n36\n45\n55\n66\n" },
    .{
        .name = "box",
        .exit_code = 0,
        .stdout =
        \\┌────┐
        \\│    │
        \\│    │
        \\│    │
        \\│    │
        \\│    │
        \\└────┘
        \\
        ,
        .args = &.{ "4", "5" },
    },
    .{
        .name = "inline_storage",
        .exit_code = 0,
        .stdout =
        \\+----------------------------------+
        \\|       hex      int    uint   chr |
        \\| R0  x3000   +12288   12288   --- |
        \\| R1  x3001   +12289   12289   --- |
        \\| R2  x0000       +0       0   NUL |
        \\| R3  x0000       +0       0   NUL |
        \\| R4  x0000       +0       0   NUL |
        \\| R5  x0000       +0       0   NUL |
        \\| R6  x0000       +0       0   NUL |
        \\| R7  x0000       +0       0   NUL |
        \\+----------------+-----------------+
        \\|    PC x3008    |   CC POSITIVE   |
        \\+----------------+-----------------+
        \\
        ,
        .match_emulator = false,
    },
};

const RunResult = struct {
    exit: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn ensureTestDir(io: std.Io) !void {
    try std.Io.Dir.cwd().createDirPath(io, test_dir);
}

fn outPath(buf: *[128]u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, test_dir ++ "/{s}", .{name});
}

fn asmPath(buf: *[128]u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "examples/{s}.asm", .{name});
}

/// join args with spaces and append newline for stdin
fn buildArgStdin(buf: *[64]u8, args: []const []const u8) []const u8 {
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + arg.len], arg);
        pos += arg.len;
    }
    buf[pos] = '\n';
    return buf[0 .. pos + 1];
}

/// delete a list of files and a list of directories (either defaults to empty)
fn cleanup(io: std.Io, opts: struct {
    files: []const []const u8 = &.{},
    dirs: []const []const u8 = &.{},
}) void {
    const cwd = std.Io.Dir.cwd();
    for (opts.files) |f| cwd.deleteFile(io, f) catch {};
    for (opts.dirs) |d| cwd.deleteTree(io, d) catch {};
}

/// compiles one example at opt level and executes the result
fn runProgram(
    alloc: std.mem.Allocator,
    io: std.Io,
    example: []const u8,
    opt_level: []const u8,
    args: []const []const u8,
) !RunResult {
    var out_buf: [128]u8 = undefined;
    const out = try outPath(&out_buf, example);
    var in_buf: [128]u8 = undefined;
    const inp = try asmPath(&in_buf, example);

    const compile = try std.process.run(alloc, io, .{
        .argv = &.{ lcc_exe, "-o", out, opt_level, inp },
    });
    defer alloc.free(compile.stdout);
    defer alloc.free(compile.stderr);

    switch (compile.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("compiling {s} failed ({d}): {s}{s}\n", .{ example, code, compile.stderr, compile.stdout });
            return error.CompileFailed;
        },
        else => {
            std.debug.print("compiling {s} crashed\n{s}", .{ example, compile.stderr });
            return error.CompileFailed;
        },
    }

    var argv: [8][]const u8 = undefined;
    argv[0] = out;
    for (args, 0..) |a, i| argv[1 + i] = a;
    return execWithStdin(alloc, io, argv[0 .. 1 + args.len], if (args.len > 0) "\n" else "1\n");
}

/// spawns argv with input piped to stdin and collects stdout/stderr
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
        .stderr = .pipe,
    });

    var input_buf: [64]u8 = undefined;
    var w = child.stdin.?.writer(io, &input_buf);
    w.interface.writeAll(input) catch {};
    w.interface.flush() catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    const stdout = try drain(alloc, io, &child, .stdout);
    const stderr = try drain(alloc, io, &child, .stderr);

    return switch (child.wait(io) catch {
        return error.ProgramCrashed;
    }) {
        .exited => |code| .{ .exit = code, .stdout = stdout, .stderr = stderr },
        else => {
            alloc.free(stdout);
            alloc.free(stderr);
            return error.ProgramCrashed;
        },
    };
}

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

    const result = try runProgram(arena.allocator(), std.testing.io, expect.name, opt_level, expect.args);

    try std.testing.expectEqual(expect.exit_code, result.exit);
    try std.testing.expectEqualStrings(expect.stdout, result.stdout);
}

test "compile and run every example" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);

    for (examples) |expect| {
        try checkExample(std.testing.allocator, expect, "-O0");
    }
}

test "optimised builds preserve behaviour" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);

    for (examples) |expect| {
        try checkExample(std.testing.allocator, expect, "-O2");
    }
}

test "output matches the elk emulator" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;

    for (examples) |expect| {
        if (!expect.match_emulator) {
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var asm_buf: [128]u8 = undefined;
        const asm_path = try asmPath(&asm_buf, expect.name);

        var stdin_buf: [64]u8 = undefined;
        const stdin = if (expect.args.len > 0) buildArgStdin(&stdin_buf, expect.args) else "1\n";

        const emulated = execWithStdin(alloc, io, &.{ "elk", asm_path }, stdin) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("elk not installed; skipping emulator comparison\n", .{});
                return;
            },
            else => return err,
        };

        var out_buf: [128]u8 = undefined;
        const out_path = try outPath(&out_buf, expect.name);
        const compiled = try execWithStdin(alloc, io, &.{out_path}, stdin);

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

    {
        const result = try std.process.run(arena.allocator(), std.testing.io, .{
            .argv = &.{ lcc_exe, "--definitely-not-a-flag" },
        });
        try std.testing.expect(switch (result.term) {
            .exited => |code| code != 0,
            else => true,
        });
    }

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

    const compile_result = try std.process.run(alloc, io, .{
        .argv = &.{ lcc_exe, "-o", test_dir ++ "/hello_dynamic", "-dynamic", "examples/hello.asm" },
    });
    try std.testing.expectEqual(@as(u8, 0), switch (compile_result.term) {
        .exited => |code| code,
        else => {
            std.debug.print("compile failed: {s}\n", .{compile_result.stderr});
            return error.Crashed;
        },
    });
    defer cleanup(io, .{ .files = &.{
        test_dir ++ "/hello_dynamic",
        "liblc3.dylib",
        "liblc3.so",
    } });

    const run_result = try execWithStdin(alloc, io, &.{test_dir ++ "/hello_dynamic"}, "1\n");
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

    try cwd.createDirPath(io, test_dir ++ "/lib");
    defer cleanup(io, .{
        .files = &.{
            test_dir ++ "/lib/liblc3.dylib",
            test_dir ++ "/lib/liblc3.so",
        },
        .dirs = &.{test_dir ++ "/lib"},
    });

    const lib_name = if (comptime @import("builtin").os.tag.isDarwin()) "liblc3.dylib" else "liblc3.so";

    const gen = try std.process.run(alloc, io, .{
        .argv = &.{ lcc_exe, "-generate-liblc3" },
    });
    try std.testing.expectEqual(@as(u8, 0), switch (gen.term) {
        .exited => |code| code,
        else => return error.Crashed,
    });

    const mv = try std.process.run(alloc, io, .{
        .argv = &.{ "mv", lib_name, test_dir ++ "/lib/" },
    });
    try std.testing.expectEqual(@as(u8, 0), switch (mv.term) {
        .exited => |code| code,
        else => return error.Crashed,
    });

    const compile = try std.process.run(alloc, io, .{
        .argv = &.{ lcc_exe, "-o", test_dir ++ "/hello_libpath", "-dynamic", "-L", test_dir ++ "/lib", "examples/hello.asm" },
    });
    try std.testing.expectEqual(@as(u8, 0), switch (compile.term) {
        .exited => |code| code,
        else => {
            std.debug.print("compile failed: {s}\n", .{compile.stderr});
            return error.Crashed;
        },
    });
    defer cleanup(io, .{ .files = &.{
        test_dir ++ "/hello_libpath",
        "liblc3.dylib",
        "liblc3.so",
    } });

    const run_result = try execWithStdin(alloc, io, &.{test_dir ++ "/hello_libpath"}, "1\n");
    try std.testing.expectEqual(@as(u8, 0), run_result.exit);
    try std.testing.expectEqualStrings("Hello World!\n", run_result.stdout);
}

fn requireLcc(io: std.Io) void {
    std.Io.Dir.cwd().access(io, lcc_exe, .{}) catch {
        std.debug.print("`{s}` not found; run `zig build` first\n", .{lcc_exe});
        @panic("missing lcc binary");
    };
}
