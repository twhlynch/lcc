//! thin wrapper around elk

const std = @import("std");
const elk = @import("elk");

// re-export used elk symbols
pub const Air = elk.Air;
pub const Instruction = Air.Instruction;
pub const Source = elk.Source;
pub const Traps = elk.Traps;
pub const Policies = elk.Policies;
pub const reporting = elk.reporting;

/// standard traps only
pub const standard_traps: Traps = .registerSets(&.{
    Traps.Standard,
});

/// baseline policies
pub const standard_policies: Policies = .none;

/// assemble an in-memory source into elk.Air
pub fn assemble(
    gpa: std.mem.Allocator,
    source: Source,
    traps: *const Traps,
    policies: Policies,
    reporter: *reporting.Primary,
) (error{ AssemblyFailed, OutOfMemory })!Air {
    reporter.options.policies = policies;

    var air: Air = .init();
    errdefer air.deinit(gpa);

    var parser = elk.Parser.new(traps, source, reporter) catch
        return error.AssemblyFailed;

    try parser.parseAir(gpa, &air);
    if (reporter.getLevel() == .err)
        return error.AssemblyFailed;

    parser.resolveLabelReferences(&air);
    if (reporter.getLevel() == .err)
        return error.AssemblyFailed;

    return air;
}
