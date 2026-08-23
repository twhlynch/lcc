//! clang invocation for the link step

const std = @import("std");

pub const LinkError = error{ ClangNotFound, LinkFailed };

/// install locations for clang not on PATH
const candidate_dirs = [_][]const u8{
    "/opt/homebrew/opt/llvm/bin",
    "/usr/local/opt/llvm/bin",
};

/// links object_path and runtime_path into output_path
/// diagnostics from clang are inherited
pub fn link(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    object_path: []const u8,
    runtime_path: []const u8,
    output_path: []const u8,
) LinkError!void {
    const clang = findClang(gpa, io, environ_map) orelse return error.ClangNotFound;
    defer gpa.free(clang);

    var child = std.process.spawn(io, .{
        .argv = &.{ clang, object_path, runtime_path, "-o", output_path },
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.LinkFailed;

    const term = child.wait(io) catch return error.LinkFailed;

    switch (term) {
        .exited => |code| if (code != 0) return error.LinkFailed,
        else => return error.LinkFailed,
    }
}

fn findClang(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: ?*const std.process.Environ.Map,
) ?[]u8 {
    if (environ_map) |map| {
        if (map.get("PATH")) |path| {
            var dirs = std.mem.splitScalar(u8, path, ':');
            while (dirs.next()) |dir| {
                if (findIn(gpa, io, dir)) |found|
                    return found;
            }
        }
    }

    for (candidate_dirs) |dir| {
        if (findIn(gpa, io, dir)) |found|
            return found;
    }

    return null;
}

fn findIn(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/clang", .{dir}) catch return null;
    errdefer gpa.free(path);

    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        gpa.free(path);
        return null;
    };

    return path;
}
