/*
 * time trap set for lcc (x30-x31)
 *
 *   x30 time  (R1, R0) = current Unix time in seconds, high word in R1
 *   x31 sleep sleep for R0 milliseconds
 */

#include <chrono>
#include <ctime>
#include <thread>

#include "lc3_trap.h"

#define WORD_MASK 0xFFFF
#define WORD_SHIFT 16

LC3_TRAP(0x30, time)
{
	const unsigned long long secs = static_cast<unsigned long long>(
		std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())
	);
	ctx->reg[0] = static_cast<unsigned short>(secs & WORD_MASK);
	ctx->reg[1] = static_cast<unsigned short>((secs >> WORD_SHIFT) & WORD_MASK);
}

LC3_TRAP(0x31, sleep)
{
	std::this_thread::sleep_for(std::chrono::milliseconds(ctx->reg[0]));
}
