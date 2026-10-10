/*
 * syscall trap set for lcc (x50-x56)
 *
 * File descriptors 0, 1, and 2 are stdin, stdout, and stderr.
 * Paths are null terminated strings with one character per word.
 * Buffers hold one byte per word.
 * Every trap sets the condition codes negative when the call failed, positive
 * when it succeeded.
 *
 *   x50 open    R0 = path address, R1 = mode (0 read, 1 create, 2 append)
 *               R0 = fd, or -1
 *
 *   x51 close   R0 = fd
 *               R0 = 0, or -1
 *
 *   x52 read    R0 = fd, R1 = buffer address, R2 = count
 *               R0 = bytes read (0 at end of file), or -1
 *
 *   x53 write   R0 = fd, R1 = buffer address, R2 = count
 *               R0 = bytes written, or -1
 *
 *   x54 seek    R0 = fd, R1 = offset low word, R2 = offset high word, R3 = whence (0 set, 1 current, 2 end)
 *               R0 = new offset low word, R1 = new offset high word, or -1
 *
 *   x55 size    R0 = fd
 *               R0 = size low word, R1 = size high word, or -1
 *
 *   x56 remove  R0 = path address
 *               R0 = 0, or -1
 */

#include <sys/stat.h>

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#include "lc3_trap.h"

#define BYTE_MASK 0xFF
#define WORD_MASK 0xFFFF
#define PATH_CAP 4096
#define IO_CHUNK 512
#define OPEN_MODE 0644
#define WORD_SHIFT 16

/* records a successful call: result in R0, positive condition codes */
static void pass(lc3_trap_ctx *ctx, unsigned short result)
{
	ctx->reg[0] = result;
	*ctx->cc = 1;
}

/* records a failed call: -1 in R0, negative condition codes */
static void fail(lc3_trap_ctx *ctx)
{
	ctx->reg[0] = (unsigned short)-1;
	*ctx->cc = (unsigned short)-1;
}

/* copies a null terminated string out of memory, low byte per word */
static int fetch_path(const lc3_trap_ctx *ctx, unsigned short addr, char *out)
{
	for (unsigned long i = 0; i < PATH_CAP; i++)
	{
		unsigned char c = ctx->memory[(unsigned short)(addr + i)] & BYTE_MASK;
		out[i] = (char)c;
		if (c == '\0')
		{
			return 0;
		}
	}
	return -1;
}

/* reads up to count bytes from fd into memory, one byte per word */
static int fetch_bytes(const lc3_trap_ctx *ctx, int fd, unsigned short addr, unsigned short count)
{
	char buf[IO_CHUNK];
	unsigned short done = 0;
	while (done < count)
	{
		unsigned short want = count - done;
		if (want > IO_CHUNK)
		{
			want = IO_CHUNK;
		}
		ssize_t got = read(fd, buf, want);
		if (got < 0)
		{
			return done > 0 ? (int)done : -1;
		}
		if (got == 0)
		{
			break;
		}
		for (ssize_t i = 0; i < got; i++)
		{
			ctx->memory[(unsigned short)(addr + done + i)] = (unsigned char)buf[i];
		}
		done = (unsigned short)(done + got);
		if ((unsigned short)got < want)
		{
			break;
		}
	}
	return (int)done;
}

/* writes count bytes from memory, one byte per word, to fd */
static int put_bytes(const lc3_trap_ctx *ctx, int fd, unsigned short addr, unsigned short count)
{
	char buf[IO_CHUNK];
	unsigned short sent = 0;
	while (sent < count)
	{
		unsigned short want = count - sent;
		if (want > IO_CHUNK)
		{
			want = IO_CHUNK;
		}
		for (unsigned short i = 0; i < want; i++)
		{
			buf[i] = (char)(ctx->memory[(unsigned short)(addr + sent + i)] & BYTE_MASK);
		}
		ssize_t wrote = write(fd, buf, want);
		if (wrote <= 0)
		{
			return sent > 0 ? (int)sent : -1;
		}
		sent = (unsigned short)(sent + wrote);
		if ((unsigned short)wrote < want)
		{
			break;
		}
	}
	return (int)sent;
}

LC3_TRAP(0x50, open)
{
	char path[PATH_CAP];
	if (fetch_path(ctx, ctx->reg[0], path) != 0)
	{
		fail(ctx);
		return;
	}

	int flags;
	switch (ctx->reg[1])
	{
		case 0:
			flags = O_RDONLY;
			break;
		case 1:
			flags = O_WRONLY | O_CREAT | O_TRUNC;
			break;
		case 2:
			flags = O_WRONLY | O_CREAT | O_APPEND;
			break;
		default:
			fail(ctx);
			return;
	}

	int fd = open(path, flags, OPEN_MODE);
	if (fd < 0)
	{
		fail(ctx);
		return;
	}
	pass(ctx, (unsigned short)fd);
}

LC3_TRAP(0x51, close)
{
	if (close((int)ctx->reg[0]) < 0)
	{
		fail(ctx);
		return;
	}
	pass(ctx, 0);
}

LC3_TRAP(0x52, read)
{
	int done = fetch_bytes(ctx, (int)ctx->reg[0], ctx->reg[1], ctx->reg[2]);
	if (done < 0)
	{
		fail(ctx);
		return;
	}
	pass(ctx, (unsigned short)done);
}

LC3_TRAP(0x53, write)
{
	int sent = put_bytes(ctx, (int)ctx->reg[0], ctx->reg[1], ctx->reg[2]);
	if (sent < 0)
	{
		fail(ctx);
		return;
	}
	pass(ctx, (unsigned short)sent);
}

LC3_TRAP(0x54, seek)
{
	int whence;
	switch (ctx->reg[3])
	{
		case 0:
			whence = SEEK_SET;
			break;
		case 1:
			whence = SEEK_CUR;
			break;
		case 2:
			whence = SEEK_END;
			break;
		default:
			fail(ctx);
			return;
	}

	uint32_t bits = ((uint32_t)ctx->reg[2] << WORD_SHIFT) | (uint32_t)ctx->reg[1];
	off_t at = lseek((int)ctx->reg[0], (off_t)(int32_t)bits, whence);
	if (at == (off_t)-1)
	{
		fail(ctx);
		return;
	}
	ctx->reg[1] = (unsigned short)(((uint64_t)at >> WORD_SHIFT) & WORD_MASK);
	pass(ctx, (unsigned short)((uint64_t)at & WORD_MASK));
}

LC3_TRAP(0x55, size)
{
	struct stat info;
	if (fstat((int)ctx->reg[0], &info) != 0)
	{
		fail(ctx);
		return;
	}
	ctx->reg[1] = (unsigned short)(((uint64_t)info.st_size >> WORD_SHIFT) & WORD_MASK);
	pass(ctx, (unsigned short)((uint64_t)info.st_size & WORD_MASK));
}

LC3_TRAP(0x56, remove)
{
	char path[PATH_CAP];
	if (fetch_path(ctx, ctx->reg[0], path) != 0)
	{
		fail(ctx);
		return;
	}
	if (remove(path) < 0)
	{
		fail(ctx);
		return;
	}
	pass(ctx, 0);
}
