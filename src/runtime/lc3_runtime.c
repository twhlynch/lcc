/*
 * native LC-3 runtime
 *
 * implements the standard trap vectors x20-x25 as C functions linked into
 * every lcc-compiled executable
 */

#include <stdio.h>
#include <stdlib.h>

/* tracks whether the last output byte was a newline */
static int at_newline = 1;

static void emit(unsigned char c)
{
	putchar(c);
	at_newline = c == '\n';
}

unsigned short lc3_getc(void)
{
	int c = getchar();
	if (c == EOF)
	{
		exit(1);
	}
	return (unsigned short)c;
}

void lc3_out(unsigned short word)
{
	emit(word & 0xFF);
	fflush(stdout);
}

void lc3_puts(const unsigned short *memory, unsigned short address)
{
	for (;;)
	{
		unsigned char c = memory[address++] & 0xFF;
		if (c == 0x00)
		{
			break;
		}
		emit(c);
	}
	fflush(stdout);
}

unsigned short lc3_in(void)
{
	int c;

	if (!at_newline)
	{
		emit('\n');
	}
	fputs("Input> ", stdout);
	fflush(stdout);

	c = getchar();
	if (c == EOF)
	{
		exit(1);
	}

	emit((unsigned char)c);
	if (!at_newline)
	{
		emit('\n');
	}

	return (unsigned short)c;
}

void lc3_putsp(const unsigned short *memory, unsigned short address)
{
	for (;;)
	{
		unsigned short word = memory[address++];
		unsigned char low = word & 0xFF;
		unsigned char high = word >> 8;
		if (low == 0x00)
		{
			break;
		}
		emit(low);
		if (high == 0x00)
		{
			break;
		}
		emit(high);
	}
	fflush(stdout);
}

void lc3_halt(void)
{
	fflush(stdout);
	exit(0);
}
