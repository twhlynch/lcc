//! lcc LC-3 to LLVM compiler

const std = @import("std");

const usage =
    \\Usage: lcc [options] <input.asm>
    \\
    \\Options:
    \\  -o <file>     Output executable path
    \\  -O<N>         Optimisation level, 0-3
    \\  -h, --help    Show this help
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.writeAll(usage);
    try out.flush();

    return 0;
}
