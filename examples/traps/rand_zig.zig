//! seed and rand trap set for lcc (x40-x41)
//!
//!   x40 seed R0 = seed for the generator
//!   x41 rand R0 = next pseudo random 16 bits
//!
//!   zig build-obj -OReleaseFast rand_zig.zig -femit-bin=rand_zig.o
//!

const std = @import("std");

const Ctx = extern struct {
    memory: [*]u16,
    reg: [*]u16,
    pc: u16,
    cc: [*]u16,
};

/// xoshiro outputs all zeros when seeded with zero
const fallback_seed = 0x9E3779B9;

var prng: std.Random.DefaultPrng = .init(fallback_seed);

export fn lc3_trap_seed(ctx: *Ctx) void {
    const seed: u64 = if (ctx.reg[0] == 0) fallback_seed else ctx.reg[0];
    prng = .init(seed);
}

export fn lc3_trap_rand(ctx: *Ctx) void {
    ctx.reg[0] = prng.random().int(u16);
}
