/*
 * terminal trap set for lcc (x40-x45)
 *
 * Screen control and key decoding for full screen programs. Screen traps
 * emit the usual ANSI escape sequences. Key codes returned by `key`:
 *
 *   x00-x7F  bytes as read, with Enter normalised to x0A (terminals send
 *            CR or LF) and Backspace normalised to x08 (BS or DEL)
 *   x1B      Escape: reported once the following byte arrives; unless it
 *            starts a sequence, that byte is kept for the next read
 *   x0100    arrow up      ESC [ A
 *   x0101    arrow down    ESC [ B
 *   x0102    arrow right   ESC [ C
 *   x0103    arrow left    ESC [ D
 *   x0104    delete        ESC [ 3 ~
 *
 * Unknown escape sequences are swallowed and the next key is read. Keys
 * read through the runtime's getc, so command line arguments arrive
 * before stdin and end of input ends the program, exactly like getc.
 *
 *   x40 clear  -                        clear the screen
 *   x41 home   -                        cursor to row 1, column 1
 *   x42 goto   R0 = row, R1 = column    cursor to a 1-based cell
 *   x43 alt    R0 = 0 enter, 1 leave    alternate screen buffer
 *   x44 cur    R0 = 0 hide, 1 show      cursor visibility
 *   x45 key    -                        R0 = next key code
 */

#include <stdio.h>

#include "lcc_trap.h"

/* the runtime's getc shared argv-first input stream */
extern void lc3_getc(lcc_trap_ctx *ctx);

#define ESC_CHAR 0x1B
#define KEY_UP 0x100
#define KEY_DOWN 0x101
#define KEY_RIGHT 0x102
#define KEY_LEFT 0x103
#define KEY_DELETE 0x104
#define BACKSPACE_CHAR 0x08
#define DELETE_CHAR 0x7F
#define NEWLINE_CHAR 0x0A
#define RETURN_CHAR 0x0D
#define CSI_PARAM_CAP 8
#define CSI_PARAM_MIN 0x20
#define CSI_PARAM_MAX 0x3F
#define CURSOR_SEQUENCE_CAP 32

/* one byte read ahead while decoding, delivered to the next read */
static int pending_byte = -1;

/* writes an escape sequence to the terminal */
static void sequence(const char *text)
{
	(void)fputs(text, stdout);
	(void)fflush(stdout);
}

/* next byte from the read ahead slot or the runtime's input stream */
static int take_byte(lcc_trap_ctx *ctx)
{
	if (pending_byte >= 0)
	{
		int c = pending_byte;
		pending_byte = -1;
		return c;
	}
	lc3_getc(ctx);
	return (int)ctx->reg[0];
}

/* Enter as x0A whatever the terminal sent, Backspace as x08 */
static int normalize(int c)
{
	if (c == RETURN_CHAR)
	{
		return NEWLINE_CHAR;
	}
	if (c == DELETE_CHAR)
	{
		return BACKSPACE_CHAR;
	}
	return c;
}

/* decodes one ESC [ sequence: a key code, or -1 when unknown */
static int read_csi(lcc_trap_ctx *ctx)
{
	int c = take_byte(ctx);
	if (c == 'A')
	{
		return KEY_UP;
	}
	if (c == 'B')
	{
		return KEY_DOWN;
	}
	if (c == 'C')
	{
		return KEY_RIGHT;
	}
	if (c == 'D')
	{
		return KEY_LEFT;
	}

	// parameter bytes, then the final byte of the sequence
	char param[CSI_PARAM_CAP];
	int count = 0;
	while (c >= CSI_PARAM_MIN && c <= CSI_PARAM_MAX)
	{
		if (count < CSI_PARAM_CAP)
		{
			param[count] = (char)c;
		}
		count++;
		c = take_byte(ctx);
	}

	if (c == '~' && count == 1 && param[0] == '3')
	{
		return KEY_DELETE;
	}
	return -1;
}

LCC_TRAP(0x40, clear)
{
	(void)ctx;
	sequence("\x1b[2J");
}

LCC_TRAP(0x41, home)
{
	(void)ctx;
	sequence("\x1b[1;1H");
}

LCC_TRAP(0x42, goto)
{
	char cell[CURSOR_SEQUENCE_CAP];
	(void)snprintf(cell, sizeof(cell), "\x1b[%u;%uH", (unsigned int)ctx->reg[0], (unsigned int)ctx->reg[1]);
	sequence(cell);
}

LCC_TRAP(0x43, alt)
{
	sequence(ctx->reg[0] == 0 ? "\x1b[?1049h" : "\x1b[?1049l");
}

LCC_TRAP(0x44, cur)
{
	sequence(ctx->reg[0] == 0 ? "\x1b[?25l" : "\x1b[?25h");
}

LCC_TRAP(0x45, key)
{
	for (;;)
	{
		int c = take_byte(ctx);
		if (c != ESC_CHAR)
		{
			ctx->reg[0] = (unsigned short)normalize(c);
			return;
		}

		// the byte after Escape decides the key
		int next = take_byte(ctx);
		if (next == '[')
		{
			int found = read_csi(ctx);
			if (found >= 0)
			{
				ctx->reg[0] = (unsigned short)found;
				return;
			}
			continue;
		}

		// Escape then a plain byte
		// deliver Escape now and keep the byte for the next read
		pending_byte = next;
		ctx->reg[0] = ESC_CHAR;
		return;
	}
}
