/*
 * seed and rand trap set for lcc (x40-x41)
 *
 *   x40 seed R0 = seed for the generator
 *   x41 rand R0 = next pseudo random 16 bits
 *
 * Implementation in rand.zig
 */

#include "lcc_trap.h"

LCC_TRAP(0x40, seed);
LCC_TRAP(0x41, rand);

// clang-format off
LCC_LINK(src/runtime/sets/rand.o)
// clang-format on
