/*
 * native LC-3 runtime
 *
 * implements the standard trap vectors x20-x25 as C functions linked into
 * every lcc-compiled executable
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lcc_trap.h"

#if defined(__unix__) || defined(__APPLE__)
#define LCC_POSIX 1
#include <errno.h>
#include <signal.h>
#include <termios.h>
#include <unistd.h>
#endif

#define BYTE_BITS 8
#define MEMORY_SIZE 0x10000
#define REGISTER_COUNT 8
#define BYTE_MASK 0xFF
#define ASCII_LIMIT 128
#define SIGNAL_EXIT_BASE 128

/* tracks whether the last output byte was a newline */
static int at_newline = 1;

static void finish_newline(void);

/* lcc_set_args stores argc/argv, read_byte walks them */
static int arg_argc = 0;
static char **arg_argv = NULL;
static int arg_i = 1;
static int arg_pos = 0;

void lcc_set_args(int argc, char *argv[])
{
	arg_argc = argc;
	arg_argv = argv;
	arg_i = 1;
	arg_pos = 0;
}

#if defined(LCC_POSIX)
/* original terminal settings, restored on exit */
static struct termios saved_termios;
static int tty_restore_pending = 0;

static void restore_terminal(void);
static void interrupted(int sig);
#endif

/*
 * input is read one char at a time
 */
__attribute__((constructor)) static void runtime_init(void)
{
	(void)atexit(finish_newline);

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
				(void)atexit(restore_terminal);
			}
		}
	}

	// tidy up when a signal ends the program
	(void)signal(SIGINT, interrupted);
	(void)signal(SIGTERM, interrupted);
#endif
}

#if defined(LCC_POSIX)
static void restore_terminal(void)
{
	if (tty_restore_pending)
	{
		(void)tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
		tty_restore_pending = 0;
	}
}

static void interrupted(int sig)
{
	restore_terminal();
	_exit(SIGNAL_EXIT_BASE + sig);
}
#endif

static int read_byte(void)
{
	(void)fflush(stdout);

	/* walk argv[1..] inserting spaces between args */
	if (arg_i < arg_argc)
	{
		char *arg = arg_argv[arg_i];
		int c = (unsigned char)arg[arg_pos];
		/* return the current char if valid */
		if (c != '\0')
		{
			arg_pos++;
			return c;
		}
		/* advance to next arg, emit separating space */
		arg_i++;
		arg_pos = 0;
		if (arg_i < arg_argc)
		{
			return ' ';
		}
	}

	return getchar();
}

static void emit(unsigned char c)
{
	(void)putchar(c);
	at_newline = c == '\n';
}

void lc3_getc(lcc_trap_ctx *ctx)
{
	int c = read_byte();
	if (c == EOF)
	{
		exit(1);
	}
	ctx->reg[0] = (unsigned short)c;
}

void lc3_out(lcc_trap_ctx *ctx)
{
	emit(ctx->reg[0] & BYTE_MASK);
	(void)fflush(stdout);
}

void lc3_puts(lcc_trap_ctx *ctx)
{
	unsigned short address = ctx->reg[0];
	for (int i = 0; i < MEMORY_SIZE; i++)
	{
		unsigned short word = ctx->memory[address];
		if (word == 0x0000)
		{
			break;
		}

		unsigned char c = word & BYTE_MASK;
		emit(c);

		address = (unsigned short)(address + 1);
	}
	(void)fflush(stdout);
}

void lc3_in(lcc_trap_ctx *ctx)
{
	int c;

	if (!at_newline)
	{
		emit('\n');
	}
	(void)fputs("Input> ", stdout);
	at_newline = 0;

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

	ctx->reg[0] = (unsigned short)c;
}

void lc3_putsp(lcc_trap_ctx *ctx)
{
	unsigned short address = ctx->reg[0];
	for (int i = 0; i < MEMORY_SIZE; i++)
	{
		unsigned short word = ctx->memory[address];
		if (word == 0x0000)
		{
			break;
		}

		unsigned char low = word & BYTE_MASK;
		unsigned char high = word >> BYTE_BITS;

		emit(low);
		emit(high);

		address = (unsigned short)(address + 1);
	}
	(void)fflush(stdout);
}

void lc3_halt(lcc_trap_ctx *ctx)
{
	(void)ctx;
	(void)fflush(stdout);
	exit(0);
}

void lc3_putn(lcc_trap_ctx *ctx)
{
	(void)printf("%u", (unsigned int)ctx->reg[0]);
	(void)fflush(stdout);
	at_newline = 0;
}

void lc3_reg(lcc_trap_ctx *ctx)
{
	// clang-format off
	static const char *const ascii[ASCII_LIMIT] = {
		"NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL",
		" BS", " HT", " LF", " VT", " FF", " CR", " SO", " SI",
		"DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB",
		"CAN", " EM", "SUB", "ESC", " FS", " GS", " RS", " US",
		" SP", " ! ", " \" ", " # ", " $ ", " % ", " & ", " ' ",
		" ( ", " ) ", " * ", " + ", " , ", " - ", " . ", " / ",
		" 0 ", " 1 ", " 2 ", " 3 ", " 4 ", " 5 ", " 6 ", " 7 ",
		" 8 ", " 9 ", " : ", " ; ", " < ", " = ", " > ", " ? ",
		" @ ", " A ", " B ", " C ", " D ", " E ", " F ", " G ",
		" H ", " I ", " J ", " K ", " L ", " M ", " N ", " O ",
		" P ", " Q ", " R ", " S ", " T ", " U ", " V ", " W ",
		" X ", " Y ", " Z ", " [ ", " \\ ", " ] ", " ^ ", " _ ",
		" ` ", " a ", " b ", " c ", " d ", " e ", " f ", " g ",
		" h ", " i ", " j ", " k ", " l ", " m ", " n ", " o ",
		" p ", " q ", " r ", " s ", " t ", " u ", " v ", " w ",
		" x ", " y ", " z ", " { ", " | ", " } ", " ~ ", "DEL",
	};
	// clang-format on

	if (!at_newline)
	{
		(void)putchar('\n');
		at_newline = 1;
	}

	const char *cc_str;
	if ((short)*ctx->cc < 0)
	{
		cc_str = "NEGATIVE";
	}
	else if (*ctx->cc == 0)
	{
		cc_str = "  ZERO  ";
	}
	else
	{
		cc_str = "POSITIVE";
	}

	(void)printf("+----------------------------------+\n");
	(void)printf("|       hex      int    uint   chr |\n");
	for (int i = 0; i < REGISTER_COUNT; i++)
	{
		unsigned short r = ctx->reg[i];
		const char *ch = (r < ASCII_LIMIT) ? ascii[r] : "---";
		(void)printf("| R%d  x%04X  %+7d  %6u   %s |\n", i, (unsigned int)r, (short)r, (unsigned int)r, ch);
	}
	(void)printf("+----------------+-----------------+\n");
	(void)printf("|    PC x%04X    |   CC %s   |\n", (unsigned int)ctx->pc, cc_str);
	(void)printf("+----------------+-----------------+\n");
	(void)fflush(stdout);
}

/*
 * like the emulator, output is left on a fresh line: a missing trailing
 * newline is added when the program terminates by any means
 */
static void finish_newline(void)
{
	if (!at_newline)
	{
		(void)putchar('\n');
	}
	(void)fflush(stdout);
}
