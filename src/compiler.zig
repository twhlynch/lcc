//! compiler pipeline

const std = @import("std");
pub const elk = @import("elk.zig");

pub const Error = error{
    AssemblyFailed,
} || std.Io.Dir.RealPathFileError || std.Io.Dir.ReadFileAllocError;

/// program elk ir and source
pub const Program = struct {
    air: elk.Air,
    source: elk.Source,
    text: []const u8,

    pub fn deinit(program: *Program, gpa: std.mem.Allocator) void {
        program.air.deinit(gpa);
        gpa.free(program.text);
        if (program.source.path) |path| gpa.free(path);
    }
};

/// read an assembly file, parse it with elk
/// diagnostics are reported through the provided reporter
pub fn assembleFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    reporter: *elk.reporting.Primary,
) Error!Program {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try std.Io.Dir.cwd().realPathFile(io, path, &path_buffer);
    const resolved_path = path_buffer[0..length];

    const text = try std.Io.Dir.cwd().readFileAlloc(
        io,
        resolved_path,
        gpa,
        .unlimited,
    );
    errdefer gpa.free(text);

    // keep the path alive for diagnostics
    const owned_path = try gpa.dupe(u8, resolved_path);
    errdefer gpa.free(owned_path);

    const source: elk.Source = .{ .text = text, .path = owned_path };
    reporter.source = source;

    var air = try elk.assemble(
        gpa,
        source,
        &elk.standard_traps,
        elk.standard_policies,
        reporter,
    );
    errdefer air.deinit(gpa);

    return .{ .air = air, .source = source, .text = text };
}
