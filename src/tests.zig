//! end-to-end pipeline tests

const std = @import("std");
const trapsets = @import("trapsets.zig");

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

fn countFlag(flags: []const []const u8, want: []const u8) usize {
    var count: usize = 0;
    for (flags) |flag| {
        if (std.mem.eql(u8, flag, want)) count += 1;
    }
    return count;
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

/// write a fixture file into the test directory
fn writeFixture(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// run lcc and return its exit code plus captured stdout/stderr
fn runLcc(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !struct { code: u8, stdout: []const u8, stderr: []const u8 } {
    const result = try std.process.run(alloc, io, .{ .argv = argv });
    return .{
        .code = switch (result.term) {
            .exited => |code| code,
            else => return error.Crashed,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

test "trap set can override a standard trap" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fixture = test_dir ++ "/ovr.c";
    try writeFixture(io, fixture, "LCC_TRAP(0x26, putn) {}\n");

    var out_buf: [128]u8 = undefined;
    const out = try outPath(&out_buf, "override_putn");
    const compile = try runLcc(alloc, io, &.{ lcc_exe, "-o", out, "-traps", fixture, "examples/subsubroutine.asm" });
    defer cleanup(io, .{ .files = &.{out} });
    try std.testing.expectEqual(@as(u8, 0), compile.code);

    const run = try execWithStdin(alloc, io, &.{out}, "1\n");
    try std.testing.expectEqual(@as(u8, 0), run.exit);
    try std.testing.expectEqualStrings("", run.stdout);
}

test "multiple trap sets load together" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try writeFixture(io, test_dir ++ "/alpha.c",
        \\LCC_TRAP(0x30, alpha)
        \\{
        \\    ctx->reg[0] = 42;
        \\}
        \\
    );
    try writeFixture(io, test_dir ++ "/multi.asm",
        \\.ORIG x3000
        \\
        \\    alpha
        \\    putn
        \\    halt
        \\
        \\.END
        \\
    );

    // beta is optional; only alpha is needed for behaviour
    try writeFixture(io, test_dir ++ "/beta.c", "LCC_TRAP(0x31, beta) {}\n");

    var out_buf: [128]u8 = undefined;
    const out = try outPath(&out_buf, "multi_set");
    const compile = try runLcc(alloc, io, &.{
        lcc_exe,
        "-o",
        out,
        "-traps",
        test_dir ++ "/alpha.c",
        "-traps",
        test_dir ++ "/beta.c",
        test_dir ++ "/multi.asm",
    });
    defer cleanup(io, .{ .files = &.{ out, test_dir ++ "/alpha.c", test_dir ++ "/beta.c", test_dir ++ "/multi.asm" } });
    try std.testing.expectEqual(@as(u8, 0), compile.code);

    const run = try execWithStdin(alloc, io, &.{out}, "1\n");
    try std.testing.expectEqual(@as(u8, 0), run.exit);
    try std.testing.expectEqualStrings("42\n", run.stdout);
}

test "trap set conflicts are rejected" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // two sets claiming the same vector
    try writeFixture(io, test_dir ++ "/one.c", "LCC_TRAP(0x30, alpha) {}\n");
    try writeFixture(io, test_dir ++ "/two.c", "LCC_TRAP(0x30, gamma) {}\n");
    {
        const result = try runLcc(alloc, io, &.{
            lcc_exe,
            "-traps",
            test_dir ++ "/one.c",
            "-traps",
            test_dir ++ "/two.c",
            "examples/hello.asm",
        });
        defer cleanup(io, .{ .files = &.{ test_dir ++ "/one.c", test_dir ++ "/two.c" } });
        try std.testing.expectEqual(@as(u8, 2), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "already provided by trap set") != null);
    }

    // a set may not rename a standard trap
    try writeFixture(io, test_dir ++ "/rename.c", "LCC_TRAP(0x26, printn) {}\n");
    {
        const result = try runLcc(alloc, io, &.{ lcc_exe, "-traps", test_dir ++ "/rename.c", "examples/hello.asm" });
        defer cleanup(io, .{ .files = &.{test_dir ++ "/rename.c"} });
        try std.testing.expectEqual(@as(u8, 2), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "cannot redeclare") != null);
    }

    // aliases must be lowercase letters
    try writeFixture(io, test_dir ++ "/badalias.c", "LCC_TRAP(0x30, Bad1) {}\n");
    {
        const result = try runLcc(alloc, io, &.{ lcc_exe, "-traps", test_dir ++ "/badalias.c", "examples/hello.asm" });
        defer cleanup(io, .{ .files = &.{test_dir ++ "/badalias.c"} });
        try std.testing.expectEqual(@as(u8, 2), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "invalid trap alias") != null);
    }
}

test "time and sleep set runs" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // print the current epoch as two words: high then low
    try writeFixture(io, test_dir ++ "/time.asm",
        \\.ORIG x3000
        \\
        \\    time
        \\    st r0, tlo
        \\    add r0, r1, #0
        \\    putn
        \\    ld r0, tlo
        \\    putn
        \\    halt
        \\
        \\tlo .FILL #0
        \\
        \\.END
        \\
    );
    defer cleanup(io, .{ .files = &.{ test_dir ++ "/time.asm", test_dir ++ "/time_out" } });

    var time_buf: [128]u8 = undefined;
    const time_out = try outPath(&time_buf, "time_out");
    const compile = try runLcc(alloc, io, &.{ lcc_exe, "-o", time_out, "-traps", "src/runtime/sets/time.cpp", test_dir ++ "/time.asm" });
    try std.testing.expectEqual(@as(u8, 0), compile.code);

    const run = try execWithStdin(alloc, io, &.{time_out}, "1\n");
    try std.testing.expectEqual(@as(u8, 0), run.exit);

    var lines = std.mem.splitScalar(u8, run.stdout, '\n');
    const high = try std.fmt.parseInt(u32, lines.next().?, 10);
    const low = try std.fmt.parseInt(u32, lines.next().?, 10);
    const epoch = (@as(i64, @intCast(high)) << 16) + @as(i64, @intCast(low));
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    try std.testing.expect(@abs(now - epoch) < 300);

    // sleep for 300ms; the delay must be visible in wall time
    try writeFixture(io, test_dir ++ "/sleep.asm",
        \\.ORIG x3000
        \\
        \\    ld r0, ms
        \\    sleep
        \\    halt
        \\
        \\ms  .FILL #300
        \\
        \\.END
        \\
    );
    defer cleanup(io, .{ .files = &.{ test_dir ++ "/sleep.asm", test_dir ++ "/sleep_out" } });

    var sleep_buf: [128]u8 = undefined;
    const sleep_out = try outPath(&sleep_buf, "sleep_out");
    const compile2 = try runLcc(alloc, io, &.{ lcc_exe, "-o", sleep_out, "-traps", "src/runtime/sets/time.cpp", test_dir ++ "/sleep.asm" });
    try std.testing.expectEqual(@as(u8, 0), compile2.code);

    const start = std.Io.Timestamp.now(io, .real);
    const run2 = try execWithStdin(alloc, io, &.{sleep_out}, "1\n");
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .real)).toMilliseconds();
    try std.testing.expectEqual(@as(u8, 0), run2.exit);
    try std.testing.expect(elapsed >= 250);
}

test "seed and rand set runs" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // build the zig implementation into an object lcc can link
    const obj = test_dir ++ "/rand.o";
    const build = try std.process.run(alloc, io, .{ .argv = &.{
        "zig",
        "build-obj",
        "-OReleaseFast",
        "src/runtime/sets/rand.zig",
        "-femit-bin=" ++ obj,
    } });
    defer alloc.free(build.stdout);
    defer alloc.free(build.stderr);
    switch (build.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("zig build-obj failed ({d}): {s}{s}\n", .{ code, build.stderr, build.stdout });
            return error.BuildObjFailed;
        },
        else => {
            std.debug.print("zig build-obj crashed\n{s}", .{build.stderr});
            return error.BuildObjFailed;
        },
    }

    // declarations stub pointing at the object we just built
    try writeFixture(io, test_dir ++ "/randstub.c",
        \\LCC_TRAP(0x40, seed);
        \\LCC_TRAP(0x41, rand);
        \\LCC_LINK(.lcc-test/rand.o)
        \\
    );
    try writeFixture(io, test_dir ++ "/rand.asm",
        \\.ORIG x3000
        \\
        \\    ld r0, sval
        \\    seed
        \\    rand
        \\    putn
        \\    rand
        \\    putn
        \\    rand
        \\    putn
        \\    halt
        \\
        \\sval .FILL #42
        \\
        \\.END
        \\
    );
    defer cleanup(io, .{ .files = &.{ test_dir ++ "/randstub.c", test_dir ++ "/rand.asm", obj, test_dir ++ "/rand_out" } });

    var out_buf: [128]u8 = undefined;
    const out = try outPath(&out_buf, "rand_out");
    const compile = try runLcc(alloc, io, &.{ lcc_exe, "-o", out, "-traps", test_dir ++ "/randstub.c", test_dir ++ "/rand.asm" });
    try std.testing.expectEqual(@as(u8, 0), compile.code);

    const run = try execWithStdin(alloc, io, &.{out}, "1\n");
    try std.testing.expectEqual(@as(u8, 0), run.exit);

    // the same DefaultPrng sequence the set generates for seed 42
    var prng = std.Random.DefaultPrng.init(42);
    var expected: [3]u16 = undefined;
    for (&expected) |*value| {
        value.* = prng.random().int(u16);
    }

    var lines = std.mem.splitScalar(u8, run.stdout, '\n');
    for (expected) |want| {
        const line = lines.next() orelse return error.MissingOutput;
        const got = try std.fmt.parseInt(u16, line, 10);
        try std.testing.expectEqual(want, got);
    }
}

test "C++ trap sets link the C++ runtime automatically" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try writeFixture(io, test_dir ++ "/cxxset.cpp",
        \\#include "lcc_trap.h"
        \\#include <string>
        \\
        \\LCC_TRAP(0x30, cxxhello)
        \\{
        \\    std::string word = "hi";
        \\    ctx->reg[0] = (unsigned short)word.size();
        \\}
    );
    try writeFixture(io, test_dir ++ "/cxx.asm",
        \\.ORIG x3000
        \\
        \\    cxxhello
        \\    halt
        \\
        \\.END
        \\
    );
    defer cleanup(io, .{ .files = &.{ test_dir ++ "/cxxset.cpp", test_dir ++ "/cxx.asm", test_dir ++ "/cxx.out" } });

    var out_buf: [128]u8 = undefined;
    const out = try outPath(&out_buf, "cxx.out");
    const result = try runLcc(alloc, io, &.{ lcc_exe, "-traps", test_dir ++ "/cxxset.cpp", "-o", out, test_dir ++ "/cxx.asm" });
    try std.testing.expectEqual(@as(u8, 0), result.code);
}

test "C++ runtime flag is added once" {
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cxx = trapsets.cxxRuntimeFlag();
    const other: []const u8 = if (std.mem.eql(u8, cxx, "-lc++")) "-lstdc++" else "-lc++";

    // time.cpp is C++ but does not declare a runtime
    var ts = try trapsets.load(alloc, io, &.{"src/runtime/sets/time.cpp"});
    defer ts.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), countFlag(ts.link_flags.items, cxx));

    // a C++ set that declares the platform runtime itself is not doubled
    const declared_src = try std.fmt.allocPrint(alloc, "LCC_LINK({s})\nLCC_TRAP(0x30, cxxflag) {{}}\n", .{cxx});
    try writeFixture(io, test_dir ++ "/declcpp.cpp", declared_src);
    defer cleanup(io, .{ .files = &.{test_dir ++ "/declcpp.cpp"} });
    var dup = try trapsets.load(alloc, io, &.{test_dir ++ "/declcpp.cpp"});
    defer dup.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), countFlag(dup.link_flags.items, cxx));

    // an alternative runtime in LCC_LINK suppresses the default
    const alt_src = try std.fmt.allocPrint(alloc, "LCC_LINK({s})\nLCC_TRAP(0x30, cxxalt) {{}}\n", .{other});
    try writeFixture(io, test_dir ++ "/stdcpp.cpp", alt_src);
    defer cleanup(io, .{ .files = &.{test_dir ++ "/stdcpp.cpp"} });
    var alt = try trapsets.load(alloc, io, &.{test_dir ++ "/stdcpp.cpp"});
    defer alt.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), countFlag(alt.link_flags.items, cxx));

    // plain C sets stay clean
    try writeFixture(io, test_dir ++ "/plain.c", "LCC_TRAP(0x30, plainflag) {}\n");
    defer cleanup(io, .{ .files = &.{test_dir ++ "/plain.c"} });
    var c = try trapsets.load(alloc, io, &.{test_dir ++ "/plain.c"});
    defer c.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), countFlag(c.link_flags.items, cxx));
}

test "generate traps header writes the ABI" {
    requireLcc(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    defer cleanup(io, .{ .files = &.{trapsets.trap_header_name} });
    const result = try runLcc(arena.allocator(), io, &.{ lcc_exe, "-generate-traps-header" });
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const header = try std.Io.Dir.cwd().readFileAlloc(io, trapsets.trap_header_name, arena.allocator(), .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, header, "lcc_trap_ctx") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "LCC_TRAP") != null);
}

test "trap sets work with dynamic linking" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try writeFixture(io, test_dir ++ "/dynset.cpp",
        \\#include "lcc_trap.h"
        \\#include <cstdio>
        \\#include <string>
        \\
        \\LCC_TRAP(0x30, dynhello)
        \\{
        \\    std::string word = "CXX";
        \\    std::printf("%s\n", word.c_str());
        \\    ctx->reg[0] = 0;
        \\}
        \\
    );
    try writeFixture(io, test_dir ++ "/dyn.asm",
        \\.ORIG x3000
        \\
        \\    dynhello
        \\    halt
        \\
        \\.END
        \\
    );
    defer cleanup(io, .{ .files = &.{
        test_dir ++ "/dynset.cpp",
        test_dir ++ "/dyn.asm",
        test_dir ++ "/dyn_set",
        "liblc3.dylib",
        "liblc3.so",
    } });

    var out_buf: [128]u8 = undefined;
    const out = try outPath(&out_buf, "dyn_set");
    const compile = try runLcc(alloc, io, &.{ lcc_exe, "-o", out, "-dynamic", "-traps", test_dir ++ "/dynset.cpp", test_dir ++ "/dyn.asm" });
    try std.testing.expectEqual(@as(u8, 0), compile.code);

    const run = try execWithStdin(alloc, io, &.{out}, "1\n");
    try std.testing.expectEqual(@as(u8, 0), run.exit);
    try std.testing.expectEqualStrings("CXX\n", run.stdout);
}

test "standard trap override works with dynamic linking" {
    requireLcc(std.testing.io);
    try ensureTestDir(std.testing.io);
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try writeFixture(io, test_dir ++ "/ovrdyn.c", "LCC_TRAP(0x26, putn) {}\n");
    defer cleanup(io, .{ .files = &.{
        test_dir ++ "/ovrdyn.c",
        test_dir ++ "/override_dyn",
        "liblc3.dylib",
        "liblc3.so",
    } });

    var out_buf: [128]u8 = undefined;
    const out = try outPath(&out_buf, "override_dyn");
    const compile = try runLcc(alloc, io, &.{ lcc_exe, "-o", out, "-dynamic", "-traps", test_dir ++ "/ovrdyn.c", "examples/subsubroutine.asm" });
    try std.testing.expectEqual(@as(u8, 0), compile.code);

    const run = try execWithStdin(alloc, io, &.{out}, "1\n");
    try std.testing.expectEqual(@as(u8, 0), run.exit);
    try std.testing.expectEqualStrings("", run.stdout);
}
