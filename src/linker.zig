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
    lib_path: []const u8,
) LinkError!void {
    const clang = findClang(gpa, io, environ_map) orelse return error.ClangNotFound;
    defer gpa.free(clang);

    var argv: [20][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = clang;
    argc += 1;
    if (triple) |t| {
        argv[argc] = "-target";
        argv[argc + 1] = t;
        argc += 2;
    }
    // one section per function so the linker can drop unused trap routines
    argv[argc] = "-ffunction-sections";
    argv[argc + 1] = "-fdata-sections";
    argc += 2;
    argv[argc] = object_path;
    argc += 1;

    if (dynamic) {
        // link against liblc3 shared library
        // search in: -lib-path, ., /usr/local/lib
        var lib_flag_buf: [256]u8 = undefined;
        const local_flag = std.fmt.bufPrint(&lib_flag_buf, "-L/usr/local/lib", .{}) catch return error.LinkFailed;
        if (lib_path.len > 0 and !std.mem.eql(u8, lib_path, ".")) {
            var user_flag_buf: [256]u8 = undefined;
            const user_flag = std.fmt.bufPrint(&user_flag_buf, "-L{s}", .{lib_path}) catch return error.LinkFailed;
            argv[argc] = user_flag;
            argc += 1;
        }
        argv[argc] = "-L.";
        argc += 1;
        argv[argc] = local_flag;
        argc += 1;
        argv[argc] = "-llc3";
        argc += 1;

        // embed rpath so the runtime loader finds liblc3 without LD_LIBRARY_PATH
        var rpath_buf: [256]u8 = undefined;
        if (lib_path.len > 0 and !std.mem.eql(u8, lib_path, ".")) {
            const rpath = std.fmt.bufPrint(&rpath_buf, "-Wl,-rpath,{s}", .{lib_path}) catch return error.LinkFailed;
            argv[argc] = rpath;
            argc += 1;
        }
        if (isDarwin(triple)) {
            argv[argc] = "-Wl,-rpath,@loader_path";
        } else {
            argv[argc] = "-Wl,-rpath,$ORIGIN";
        }
        argc += 1;
        argv[argc] = "-Wl,-rpath,/usr/local/lib";
        argc += 1;
    } else {
        argv[argc] = runtime_path;
        argc += 1;
    }

    argv[argc] = "-o";
    argv[argc + 1] = output_path;
    argv[argc + 2] = gcFlag(triple);
    argc += 3;

    if (!isDarwin(triple)) {
        argv[argc] = "-no-pie";
        argc += 1;
    }

    var child = std.process.spawn(io, .{
        .argv = argv[0..argc],
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

/// generates the liblc3 shared library from the embedded runtime source
pub fn generateLib(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: ?*const std.process.Environ.Map,
    source_path: []const u8,
    output_path: []const u8,
    triple: ?[]const u8,
) LinkError!void {
    const clang = findClang(gpa, io, environ_map) orelse return error.ClangNotFound;
    defer gpa.free(clang);

    var argv: [10][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = clang;
    argc += 1;
    if (triple) |t| {
        argv[argc] = "-target";
        argv[argc + 1] = t;
        argc += 2;
    }
    argv[argc] = "-shared";
    argc += 1;
    argv[argc] = "-fPIC";
    argc += 1;
    argv[argc] = source_path;
    argc += 1;
    argv[argc] = "-o";
    argv[argc + 1] = output_path;
    argc += 2;

    var child = std.process.spawn(io, .{
        .argv = argv[0..argc],
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
    if (triple) |t|
        return std.mem.indexOf(u8, t, "darwin") != null or
            std.mem.indexOf(u8, t, "macos") != null or
            std.mem.indexOf(u8, t, "ios") != null;
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

    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch {
        gpa.free(path);
        return null;
    };

    return path;
}
