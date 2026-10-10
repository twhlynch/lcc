/*
 * seed and rand trap set for lcc (x40-x41)
 *
 *   x40 seed R0 = seed for the generator
 *   x41 rand R0 = next pseudo random 16 bits
 *
 * Implementation in rand_zig.zig
 *
 *   lcc examples/rand.asm -traps examples/traps/rand_zig.c
 */

#include "lc3_trap.h"

LC3_TRAP(0x40, seed);
LC3_TRAP(0x41, rand);

// clang-format off
LC3_LINK(rand_zig.o)
// clang-format on
