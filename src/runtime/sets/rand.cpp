/*
 * seed and rand trap set for lcc (x40-x41)
 *
 *   x40 seed R0 = seed for the generator
 *   x41 rand R0 = next pseudo random 16 bits
 */

#include <random>

#include "lcc_trap.h"

static std::mt19937 generator(std::random_device {}()); // NOLINT(misc-use-anonymous-namespace, cert-err58-cpp)

LCC_TRAP(0x40, seed)
{
	unsigned int seed = ctx->reg[0];

	if (seed == 0)
	{
		seed = std::random_device {}();
	}

	generator.seed(seed);
}

LCC_TRAP(0x41, rand)
{
	unsigned int result = generator();

	ctx->reg[0] = (unsigned short)result;
}
