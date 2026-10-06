//! trap set loading: scans LCC_TRAP declarations and builds the tables
//! shared by the parser, codegen, and link steps

const std = @import("std");
const elk = @import("elk.zig");

/// the trap ABI header, force-included when compiling runtime and sets
pub const trap_header = @embedFile("runtime/lcc_trap.h");

/// the header's fixed file name: -iquote, -generate-traps-header and
/// #include "lcc_trap.h" in set sources all depend on it
pub const trap_header_name = "lcc_trap.h";

/// a C identifier or linker flag; null terminated for LLVM and spawn
pub const Symbol = [:0]const u8;

/// one loaded trap set
pub const Set = struct {
    /// source file path, also its identity on the command line
    path: []const u8,
    /// source text; decl aliases point into it, so it stays alive until deinit
    source: []const u8,
    /// source file extension (.c, .cpp, ...); used to detect C++ sets
    ext: []const u8,
    /// declared handlers, in source order
    decls: std.ArrayList(Decl) = .empty,
    /// flags from LCC_LINK
    link_flags: std.ArrayList([]const u8) = .empty,
    /// generated handler symbols (lcc_trap_<alias>)
    symbols: std.ArrayList(Symbol) = .empty,

    pub fn deinit(set: *Set, gpa: std.mem.Allocator) void {
        for (set.symbols.items) |symbol| gpa.free(symbol);
        set.symbols.deinit(gpa);
        set.decls.deinit(gpa);
        for (set.link_flags.items) |flag| gpa.free(flag);
        set.link_flags.deinit(gpa);
        gpa.free(set.source);
    }
};

/// one LCC_TRAP(vect, alias) declaration
pub const Decl = struct {
    vect: u8,
    alias: []const u8,
    line: usize,
};

/// trap tables and sources produced from the -traps flag
pub const Table = struct {
    /// parser table: aliases per vector
    traps: elk.Traps,
    /// codegen table: symbol per vector
    symbols: [256]?Symbol,
    /// loaded sets, in command-line order
    sets: std.ArrayList(Set) = .empty,
    /// merged LCC_LINK flags from every set, plus -lc++ when a C++ set loads
    link_flags: std.ArrayList([]const u8) = .empty,

    pub fn deinit(table: *Table, gpa: std.mem.Allocator) void {
        for (table.sets.items) |*set| set.deinit(gpa);
        table.sets.deinit(gpa);
        table.link_flags.deinit(gpa);
    }
};

/// symbol per vector for the standard trap set
const standard_symbols: [256]?Symbol = blk: {
    var map: [256]?Symbol = @splat(null);
    map[0x20] = "lc3_getc";
    map[0x21] = "lc3_out";
    map[0x22] = "lc3_puts";
    map[0x23] = "lc3_in";
    map[0x24] = "lc3_putsp";
    map[0x25] = "lc3_halt";
    map[0x26] = "lc3_putn";
    map[0x27] = "lc3_reg";
    break :blk map;
};

/// the standard table, used when no -traps flag is given
pub fn standard() Table {
    return .{
        .traps = elk.standard_traps,
        .symbols = standard_symbols,
    };
}

pub const LoadError = error{ InvalidTrapSet, OutOfMemory };

/// load every -traps spec into one table. collision rules:
/// a set may override a standard trap only by keeping its alias; a vector
/// or alias claimed by another set is an error.
pub fn load(gpa: std.mem.Allocator, io: std.Io, specs: []const []const u8) LoadError!Table {
    var table = standard();
    errdefer table.deinit(gpa);

    const Claim = struct { alias: []const u8, owner: ?[]const u8 };
    var claims: [256]?Claim = @splat(null);
    for (table.traps.entries, 0..) |entry, vect| {
        if (entry.alias) |alias| {
            claims[vect] = .{ .alias = alias, .owner = null };
        }
    }

    for (specs) |spec| {
        var set = try loadSet(gpa, io, spec);
        errdefer set.deinit(gpa);

        for (table.sets.items) |loaded| {
            if (std.mem.eql(u8, loaded.path, set.path)) {
                std.log.err("trap set '{s}' is loaded twice", .{set.path});
                return error.InvalidTrapSet;
            }
        }

        for (set.decls.items) |decl| {
            if (claims[decl.vect]) |claim| {
                if (claim.owner) |owner| {
                    if (std.mem.eql(u8, owner, set.path)) {
                        std.log.err("{s}:{d}: duplicate declaration of trap x{X:02}", .{ set.path, decl.line, decl.vect });
                        return error.InvalidTrapSet;
                    }
                    std.log.err(
                        "{s}:{d}: trap x{X:02} already provided by trap set '{s}'",
                        .{ set.path, decl.line, decl.vect, owner },
                    );
                    return error.InvalidTrapSet;
                }
                if (!std.mem.eql(u8, claim.alias, decl.alias)) {
                    std.log.err(
                        "{s}:{d}: trap x{X:02} is the standard '{s}' trap; '{s}' cannot redeclare it as '{s}'",
                        .{ set.path, decl.line, decl.vect, claim.alias, set.path, decl.alias },
                    );
                    return error.InvalidTrapSet;
                }
                // same alias: the set wins over the standard implementation
            } else {
                // vector is free, but the alias must be globally unique or
                // the parser would silently match the first one
                for (table.traps.entries, 0..) |entry, vect| {
                    if (entry.alias) |other| {
                        if (std.mem.eql(u8, other, decl.alias)) {
                            std.log.err(
                                "{s}:{d}: trap alias '{s}' is already used by trap x{X:02}",
                                .{ set.path, decl.line, decl.alias, vect },
                            );
                            return error.InvalidTrapSet;
                        }
                    }
                }
            }

            table.traps.entries[decl.vect] = .{ .alias = decl.alias, .callback = null };
            const symbol = try std.fmt.allocPrintSentinel(gpa, "lcc_trap_{s}", .{decl.alias}, 0);
            errdefer gpa.free(symbol);
            try set.symbols.append(gpa, symbol);
            table.symbols[decl.vect] = symbol;
            claims[decl.vect] = .{ .alias = decl.alias, .owner = set.path };
        }

        try table.link_flags.appendSlice(gpa, set.link_flags.items);
        try table.sets.append(gpa, set);
    }

    // lcc invokes clang, not clang++; the driver links the C++ runtime only
    // when asked, so any C++ set gets the platform runtime (libc++ on macOS,
    // libstdc++ elsewhere) unless the set declared one
    var needs_cxx = false;
    for (table.sets.items) |set| {
        if (isCxxExt(set.ext)) needs_cxx = true;
    }
    if (needs_cxx and !declaredCxxRuntime(table.link_flags.items)) {
        try table.link_flags.append(gpa, cxxRuntimeFlag());
    }

    return table;
}

/// read a source file path and scan it for declarations
fn loadSet(gpa: std.mem.Allocator, io: std.Io, spec: []const u8) LoadError!Set {
    const ext = std.fs.path.extension(spec);
    if (!validSetExt(ext)) {
        std.log.err("trap set '{s}': expected a .c or .cpp source file", .{spec});
        return error.InvalidTrapSet;
    }

    const source = std.Io.Dir.cwd().readFileAlloc(io, spec, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.log.err("cannot read trap set '{s}' (expected a source file)", .{spec});
            return error.InvalidTrapSet;
        },
    };

    var set: Set = .{ .path = spec, .source = source, .ext = ext };
    errdefer set.deinit(gpa);

    var line: usize = 1;
    var i: usize = 0;
    while (i < source.len) {
        i = skipTrivia(source, i, &line);
        if (i >= source.len) break;

        const c = source[i];
        if (c == '#') {
            // preprocessor lines are skipped so wrapper macros such as
            // #define CHAT() LCC_TRAP(0x30, chat) do not register twice
            while (i < source.len) {
                if (source[i] == '\\' and i + 1 < source.len and source[i + 1] == '\n') {
                    i += 2;
                    line += 1;
                    continue;
                }
                if (source[i] == '\n') break;
                i += 1;
            }
        } else if (c == '"' or c == '\'') {
            i = skipQuoted(source, i);
        } else if (isIdentStart(c)) {
            const start = i;
            i += 1;
            while (i < source.len and isIdentCont(source[i])) i += 1;
            const ident = source[start..i];
            if (std.mem.eql(u8, ident, "LCC_TRAP") or std.mem.eql(u8, ident, "LCC_LINK")) {
                i = try scanMacro(gpa, &set, ident, source, i, &line);
            }
        } else {
            i += 1;
        }
    }

    return set;
}

fn validSetExt(ext: []const u8) bool {
    return std.mem.eql(u8, ext, ".c") or isCxxExt(ext);
}

/// true for C++ set extensions; set.ext comes from std.fs.path.extension
fn isCxxExt(ext: []const u8) bool {
    const cxx = [_][]const u8{ ".cpp", ".cc", ".cxx" };
    for (cxx) |candidate| {
        if (std.mem.eql(u8, ext, candidate)) return true;
    }
    return false;
}

/// the C++ runtime clang links by default on this platform
pub fn cxxRuntimeFlag() []const u8 {
    return if (@import("builtin").os.tag.isDarwin()) "-lc++" else "-lstdc++";
}

/// true when LCC_LINK already names a C++ runtime
fn declaredCxxRuntime(flags: []const []const u8) bool {
    for (flags) |flag| {
        if (std.mem.eql(u8, flag, "-lc++") or std.mem.eql(u8, flag, "-lstdc++")) return true;
    }
    return false;
}

/// scan a LCC_TRAP/LCC_LINK invocation starting at ident_end; returns the
/// index after the call, or ident_end when the identifier is not called
fn scanMacro(
    gpa: std.mem.Allocator,
    set: *Set,
    ident: []const u8,
    source: []const u8,
    ident_end: usize,
    line: *usize,
) LoadError!usize {
    const macro_line = line.*;
    var i = skipTrivia(source, ident_end, line);
    if (i >= source.len or source[i] != '(') return ident_end;
    i += 1;

    var args: [16][]const u8 = undefined;
    var count: usize = 0;
    var depth: usize = 1;
    var arg_start = i;
    var closed = false;
    while (i < source.len) {
        i = skipTrivia(source, i, line);
        if (i >= source.len) break;

        const c = source[i];
        if (c == '(') {
            depth += 1;
            i += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                try pushArg(set, &args, &count, source[arg_start..i], macro_line);
                i += 1;
                closed = true;
                break;
            }
            i += 1;
        } else if (c == ',' and depth == 1) {
            try pushArg(set, &args, &count, source[arg_start..i], macro_line);
            i += 1;
            arg_start = i;
        } else if (c == '"' or c == '\'') {
            i = skipQuoted(source, i);
        } else {
            i += 1;
        }
    }
    if (!closed) {
        std.log.err("{s}:{d}: unterminated macro invocation", .{ set.path, macro_line });
        return error.InvalidTrapSet;
    }

    if (std.mem.eql(u8, ident, "LCC_TRAP")) {
        try addTrapDecl(gpa, set, macro_line, args[0..count]);
    } else {
        try addLinkFlags(gpa, set, macro_line, args[0..count]);
    }
    return i;
}

/// stores one parsed macro argument, bounded by the fixed argument array
fn pushArg(
    set: *Set,
    args: *[16][]const u8,
    count: *usize,
    value: []const u8,
    macro_line: usize,
) LoadError!void {
    if (count.* >= args.len) {
        std.log.err("{s}:{d}: too many arguments", .{ set.path, macro_line });
        return error.InvalidTrapSet;
    }
    args[count.*] = value;
    count.* += 1;
}

fn addTrapDecl(
    gpa: std.mem.Allocator,
    set: *Set,
    macro_line: usize,
    args: []const []const u8,
) LoadError!void {
    if (args.len != 2) {
        std.log.err("{s}:{d}: LCC_TRAP expects (vector, alias)", .{ set.path, macro_line });
        return error.InvalidTrapSet;
    }
    const vect_text = std.mem.trim(u8, args[0], " \t\r\n");
    const vect = parseVector(vect_text) orelse {
        std.log.err("{s}:{d}: invalid trap vector '{s}' (expected 0-255, decimal or 0x hex)", .{ set.path, macro_line, vect_text });
        return error.InvalidTrapSet;
    };
    const alias = std.mem.trim(u8, args[1], " \t\r\n");
    if (!validAlias(alias)) {
        std.log.err("{s}:{d}: invalid trap alias '{s}' (must contain only lowercase letters a-z)", .{ set.path, macro_line, alias });
        return error.InvalidTrapSet;
    }
    try set.decls.append(gpa, .{ .vect = vect, .alias = alias, .line = macro_line });
}

fn addLinkFlags(
    gpa: std.mem.Allocator,
    set: *Set,
    macro_line: usize,
    args: []const []const u8,
) LoadError!void {
    if (args.len == 0) {
        std.log.err("{s}:{d}: LCC_LINK expects at least one flag", .{ set.path, macro_line });
        return error.InvalidTrapSet;
    }
    const dir = std.fs.path.dirname(set.path);
    for (args) |arg| {
        var flag = std.mem.trim(u8, arg, " \t\r\n");
        if (flag.len >= 2 and (flag[0] == '"' or flag[0] == '\'') and flag[flag.len - 1] == flag[0]) {
            flag = flag[1 .. flag.len - 1];
        }
        if (flag.len == 0) {
            std.log.err("{s}:{d}: empty flag in LCC_LINK", .{ set.path, macro_line });
            return error.InvalidTrapSet;
        }
        const resolved = try resolveLinkPath(gpa, dir, flag);
        set.link_flags.append(gpa, resolved) catch |err| {
            gpa.free(resolved);
            return err;
        };
    }
}

/// resolves a LCC_LINK argument against dir, the set file's own directory:
/// bare paths and relative -L values are joined to it, flags and absolute
/// paths pass through unchanged. dir is null for a set named without one.
fn resolveLinkPath(gpa: std.mem.Allocator, dir: ?[]const u8, flag: []const u8) LoadError![]const u8 {
    if (dir) |set_dir| {
        if (std.mem.startsWith(u8, flag, "-L") and flag.len > "-L".len) {
            const value = stripDotSlash(flag["-L".len..]);
            if (value.len > 0 and !std.fs.path.isAbsolute(value)) {
                const joined = try std.fs.path.join(gpa, &.{ set_dir, value });
                defer gpa.free(joined);
                return std.fmt.allocPrint(gpa, "-L{s}", .{joined});
            }
        } else if (!std.mem.startsWith(u8, flag, "-") and !std.fs.path.isAbsolute(flag)) {
            const value = stripDotSlash(flag);
            if (value.len > 0) return std.fs.path.join(gpa, &.{ set_dir, value });
        }
    }
    return gpa.dupe(u8, flag);
}

fn stripDotSlash(path: []const u8) []const u8 {
    var result = path;
    while (std.mem.startsWith(u8, result, "./")) result = result["./".len..];
    return result;
}

fn parseVector(text: []const u8) ?u8 {
    if (text.len == 0) return null;
    const value = if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X"))
        std.fmt.parseInt(i32, text[2..], 16) catch return null
    else
        std.fmt.parseInt(i32, text, 10) catch return null;
    if (value < 0 or value > 255) return null;
    return @intCast(value);
}

/// elk only accepts all-lowercase alpha aliases for trap mnemonics
fn validAlias(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (c < 'a' or c > 'z') return false;
    }
    return true;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// skips whitespace and comments, counting newlines; returns the index of
/// the first significant character
fn skipTrivia(source: []const u8, start: usize, line: *usize) usize {
    var i = start;
    while (i < source.len) {
        const c = source[i];
        if (c == '\n') {
            line.* += 1;
            i += 1;
        } else if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
        } else if (c == '/' and i + 1 < source.len and (source[i + 1] == '/' or source[i + 1] == '*')) {
            i = skipComment(source, i, line);
        } else {
            break;
        }
    }
    return i;
}

/// skips a comment starting at i; returns the index after it, counting
/// newlines inside block comments
fn skipComment(source: []const u8, i: usize, line: *usize) usize {
    var j = i + 2;
    if (source[i + 1] == '/') {
        while (j < source.len and source[j] != '\n') j += 1;
        return j;
    }
    while (j < source.len) : (j += 1) {
        if (source[j] == '\n') line.* += 1;
        if (source[j] == '*' and j + 1 < source.len and source[j + 1] == '/') return j + 2;
    }
    return j;
}

/// skip a quoted literal; returns the index after it, or the index of an
/// unterminated newline so the caller can rescan and count it from there
fn skipQuoted(source: []const u8, start: usize) usize {
    const quote = source[start];
    var i = start + 1;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c == '\\' and i + 1 < source.len) {
            i += 1;
            continue;
        }
        if (c == quote) return i + 1;
        if (c == '\n') return i;
    }
    return i;
}
