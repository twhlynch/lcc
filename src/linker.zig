//! clang invocation for the link step

const std = @import("std");

pub const LinkError = error{ ClangNotFound, LinkFailed };

/// install locations for clang not on PATH
const candidate_dirs = [_][]const u8{
    "/opt/homebrew/opt/llvm/bin",
    "/usr/local/opt/llvm/bin",
};

/// links object_path and runtime_path into output_path
/// triple is passed to clang for cross compilation when given
/// when dynamic, links against liblc3 instead of the runtime source
pub fn link(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    object_path: []const u8,
    runtime_path: []const u8,
    triple: ?[]const u8,
    output_path: []const u8,
    dynamic: bool,
    lib_path: ?[]const u8,
) LinkError!void {
    const clang = findClang(gpa, io, environ_map) orelse {
        return error.ClangNotFound;
    };
    defer gpa.free(clang);

    var args = std.ArrayList([]const u8).empty;
    defer {
        for (args.items) |item| {
            if (std.mem.startsWith(u8, item, "-Wl,-rpath,")) {
                gpa.free(item);
            }
        }
        args.deinit(gpa);
    }

    addTarget(&args, gpa, triple) catch {
        return error.LinkFailed;
    };

    args.appendSlice(gpa, &.{
        "-ffunction-sections", "-fdata-sections", object_path,
    }) catch {
        return error.LinkFailed;
    };

    if (dynamic) {
        addDynamicRuntime(&args, gpa, io, lib_path) catch {
            return error.LinkFailed;
        };
    } else {
        args.append(gpa, runtime_path) catch {
            return error.LinkFailed;
        };
    }

    args.appendSlice(gpa, &.{
        "-o",
        output_path,
        gcFlag(triple),
    }) catch {
        return error.LinkFailed;
    };

    if (!isDarwin(triple)) {
        args.append(gpa, "-no-pie") catch {
            return error.LinkFailed;
        };
    }

    try runClang(io, gpa, clang, args.items);
}

/// generates the liblc3 shared library from the embedded runtime source
pub fn generateLib(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    source_path: []const u8,
    output_path: []const u8,
    triple: ?[]const u8,
) LinkError!void {
    const clang = findClang(gpa, io, environ_map) orelse {
        return error.ClangNotFound;
    };
    defer gpa.free(clang);

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(gpa);

    addTarget(&args, gpa, triple) catch {
        return error.LinkFailed;
    };

    args.appendSlice(gpa, &.{
        "-shared", "-fPIC",
    }) catch {
        return error.LinkFailed;
    };

    if (isDarwin(triple)) {
        args.appendSlice(gpa, &.{
            "-install_name", "@rpath/liblc3.dylib",
        }) catch {
            return error.LinkFailed;
        };
    }

    args.appendSlice(gpa, &.{
        source_path, "-o", output_path,
    }) catch {
        return error.LinkFailed;
    };

    try runClang(io, gpa, clang, args.items);
}

fn addTarget(
    args: *std.ArrayList([]const u8),
    gpa: std.mem.Allocator,
    triple: ?[]const u8,
) !void {
    if (triple) |t| {
        try args.appendSlice(gpa, &.{ "-target", t });
    }
}

fn addDynamicRuntime(
    args: *std.ArrayList([]const u8),
    gpa: std.mem.Allocator,
    io: std.Io,
    lib_path: ?[]const u8,
) !void {
    if (lib_path) |path| {
        try args.appendSlice(gpa, &.{ "-L", path });
    }

    try args.appendSlice(gpa, &.{
        "-L", ".", "-L", "/usr/local/lib", "-llc3",
    });

    // embed rpaths so dyld/ld.so can find liblc3 without LD_LIBRARY_PATH
    // use absolute paths: relative rpaths are not resolved by dyld on macOS
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
    const cwd = if (cwd_len > 0) cwd_buf[0..cwd_len] else ".";

    // rpath order mirrors link search order: lib_path, cwd, /usr/local/lib
    if (lib_path) |path| {
        const abs = try std.fs.path.join(gpa, &.{ cwd, path });
        defer gpa.free(abs);
        const rpath = try std.fmt.allocPrint(gpa, "-Wl,-rpath,{s}", .{abs});
        try args.append(gpa, rpath);
    }
    {
        const rpath = try std.fmt.allocPrint(gpa, "-Wl,-rpath,{s}", .{cwd});
        try args.append(gpa, rpath);
    }
    {
        const rpath = try gpa.dupe(u8, "-Wl,-rpath,/usr/local/lib");
        try args.append(gpa, rpath);
    }
}

fn runClang(
    io: std.Io,
    gpa: std.mem.Allocator,
    clang: []const u8,
    args: []const []const u8,
) LinkError!void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);

    argv.append(gpa, clang) catch {
        return error.LinkFailed;
    };
    argv.appendSlice(gpa, args) catch {
        return error.LinkFailed;
    };

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.log.err("failed to spawn clang: {s}", .{@errorName(err)});
        return error.LinkFailed;
    };

    const term = child.wait(io) catch {
        child.kill(io);
        _ = child.wait(io) catch {};
        return error.LinkFailed;
    };

    switch (term) {
        .exited => |code| if (code != 0) {
            std.log.err("clang exited with code {d}", .{code});
            return error.LinkFailed;
        },
        .signal => |sig| {
            std.log.err("clang killed by signal {d}", .{sig});
            return error.LinkFailed;
        },
        else => |term_type| {
            std.log.err("clang terminated: {s}", .{@tagName(term_type)});
            return error.LinkFailed;
        },
    }
}

/// linker flag that strips unreferenced sections
fn gcFlag(triple: ?[]const u8) []const u8 {
    return if (isDarwin(triple)) "-Wl,-dead_strip" else "-Wl,--gc-sections";
}

fn isDarwin(triple: ?[]const u8) bool {
    if (triple) |t| {
        return std.mem.indexOf(u8, t, "darwin") != null or
            std.mem.indexOf(u8, t, "macos") != null;
    }
    return @import("builtin").os.tag.isDarwin();
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
                if (findIn(gpa, io, dir)) |found| {
                    return found;
                }
            }
        }
    }

    for (candidate_dirs) |dir| {
        if (findIn(gpa, io, dir)) |found| {
            return found;
        }
    }

    return null;
}

fn findIn(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/clang", .{dir}) catch {
        return null;
    };

    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch {
        gpa.free(path);
        return null;
    };

    return path;
}
