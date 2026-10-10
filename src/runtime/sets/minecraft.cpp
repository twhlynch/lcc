/*
 * Minecraft trap set for lcc (x28-x2D)
 *
 * Bridges the mcpp C++ API through the lcc trap ABI.
 * Conventions match the common Minecraft trap implementations:
 *
 *   x28 chat  R0 = address of a null terminated message in memory
 *   x29 getp  (R0, R1, R2) = player x, y, z
 *   x2A setp  player x, y, z = (R0, R1, R2)
 *   x2B getb  R3 = block id at (R0, R1, R2)
 *   x2C setb  block at (R0, R1, R2) = id in R3
 *   x2D geth  R1 = height at (R0, R2)
 *
 * Coordinates cross the ABI as signed values stored in LC-3 words.
 */

#include <mcpp/mcpp.h>

#include <cstdint>
#include <string>

#include "lc3_trap.h"

#define BYTE_MASK 0xFF
#define MEMORY_SIZE 65536

// clang-format off
LC3_LINK(-L/usr/local/lib, -lmcpp)
// clang-format on

namespace {

mcpp::MinecraftConnection *connection = nullptr;

mcpp::MinecraftConnection *ensure_connection()
{
	if (connection == nullptr)
	{
		connection = new mcpp::MinecraftConnection();
	}
	return connection;
}

short word_to_coord(unsigned short word)
{
	return static_cast<short>(word);
}

} // namespace

LC3_TRAP(0x28, chat)
{
	std::string message;
	unsigned short address = ctx->reg[0];
	for (int i = 0; i < MEMORY_SIZE; i++)
	{
		unsigned short word = ctx->memory[address];
		if (word == 0x0000)
		{
			break;
		}
		message.push_back(static_cast<char>(word & BYTE_MASK));
		address = static_cast<unsigned short>(address + 1);
	}
	ensure_connection()->postToChat({message});
}

LC3_TRAP(0x29, getp)
{
	mcpp::Coordinate pos = ensure_connection()->getPlayerPosition();
	ctx->reg[0] = static_cast<unsigned short>(pos.x);
	ctx->reg[1] = static_cast<unsigned short>(pos.y);
	ctx->reg[2] = static_cast<unsigned short>(pos.z);
}

LC3_TRAP(0x2A, setp)
{
	ensure_connection()->setPlayerPosition({
		word_to_coord(ctx->reg[0]),
		word_to_coord(ctx->reg[1]),
		word_to_coord(ctx->reg[2]),
	});
}

LC3_TRAP(0x2B, getb)
{
	mcpp::Coordinate at = {
		word_to_coord(ctx->reg[0]),
		word_to_coord(ctx->reg[1]),
		word_to_coord(ctx->reg[2]),
	};
	ctx->reg[3] = static_cast<unsigned short>(ensure_connection()->getBlock(at).id & BYTE_MASK);
}

LC3_TRAP(0x2C, setb)
{
	mcpp::Coordinate at = {
		word_to_coord(ctx->reg[0]),
		word_to_coord(ctx->reg[1]),
		word_to_coord(ctx->reg[2]),
	};
	ensure_connection()->setBlock(at, {static_cast<uint8_t>(ctx->reg[3] & BYTE_MASK), 0});
}

LC3_TRAP(0x2D, geth)
{
	mcpp::Coordinate2D at = {
		word_to_coord(ctx->reg[0]),
		word_to_coord(ctx->reg[2]),
	};
	ctx->reg[1] = static_cast<unsigned short>(ensure_connection()->getHeight(at));
}
