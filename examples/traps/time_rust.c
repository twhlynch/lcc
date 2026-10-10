/*
 * time trap set for lcc (x30-x31)
 *
 *   x30 time  (R1, R0) = current Unix time in seconds, high word in R1
 *   x31 sleep sleep for R0 milliseconds
 *
 * Implementation in time_rust.rs
 *
 *   lcc examples/time.asm -traps examples/traps/time_rust.c
 */

#include "lc3_trap.h"

LC3_TRAP(0x30, time);
LC3_TRAP(0x31, sleep);

// clang-format off
LC3_LINK(libtime_rust.a)
// clang-format on
