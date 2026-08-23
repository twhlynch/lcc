/*
 * native LC-3 runtime
 *
 * implements the standard trap vectors x20-x25 as C functions linked into
 * every lcc-compiled executable
 */

#include <stdio.h>
#include <stdlib.h>

#if defined(__unix__) || defined(__APPLE__)
#define LCC_POSIX 1
#include <errno.h>
#include <termios.h>
#include <unistd.h>
#endif

/* tracks whether the last output byte was a newline */
static int at_newline = 1;

static void finish_newline(void);

#if defined(LCC_POSIX)
/* original terminal settings, restored on exit */
static struct termios saved_termios;
static int tty_restore_pending = 0;

static void restore_terminal(void);
#endif

/*
 * input is read one char at a time
 */
__attribute__((constructor)) static void runtime_init(void)
{
	atexit(finish_newline);

#if defined(LCC_POSIX)
	int istty = isatty(STDIN_FILENO);
	if (istty)
	{
		if (tcgetattr(STDIN_FILENO, &saved_termios) == 0)
		{
			struct termios raw = saved_termios;
			raw.c_lflag &= ~(tcflag_t)(ICANON | ECHO);
			if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0)
			{
				tty_restore_pending = 1;
				atexit(restore_terminal);
			}
		}
	}
#endif
}

#if defined(LCC_POSIX)
static void restore_terminal(void)
{
	if (tty_restore_pending)
	{
		tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
		tty_restore_pending = 0;
	}
}
#endif

static int read_byte(void)
{
	fflush(stdout);
	return getchar();
}

static void emit(unsigned char c)
{
	putchar(c);
	at_newline = c == '\n';
}

unsigned short lc3_getc(void)
{
	int c = read_byte();
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

	c = read_byte();
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

/*
 * like the emulator, output is left on a fresh line: a missing trailing
 * newline is added when the program terminates by any means
 */
static void finish_newline(void)
{
	if (!at_newline)
	{
		putchar('\n');
	}
}
