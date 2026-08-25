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
#endif

static int read_byte(void)
{
	(void)fflush(stdout);
	return getchar();
}

static void emit(unsigned char c)
{
	(void)putchar(c);
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
	(void)fflush(stdout);
}

void lc3_puts(const unsigned short *memory, unsigned short address)
{
	for (int i = 0; i <= 0xFFFF; i++)
	{
		unsigned char c = memory[address] & 0xFF;
		if (c == 0x00)
		{
			break;
		}
		emit(c);
		address = (unsigned short)(address + 1);
	}
	(void)fflush(stdout);
}

unsigned short lc3_in(void)
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

	return (unsigned short)c;
}

void lc3_putsp(const unsigned short *memory, unsigned short address)
{
	for (int i = 0; i <= 0xFFFF; i++)
	{
		unsigned short word = memory[address];
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
		address = (unsigned short)(address + 1);
	}
	(void)fflush(stdout);
}

void lc3_halt(void)
{
	(void)fflush(stdout);
	exit(0);
}

void lc3_putn(unsigned short word)
{
	if (!at_newline)
	{
		(void)putchar('\n');
		at_newline = 1;
	}
	(void)printf("%u\n", (unsigned int)word);
	(void)fflush(stdout);
}

void lc3_reg(
	unsigned short r0,
	unsigned short r1,
	unsigned short r2,
	unsigned short r3,
	unsigned short r4,
	unsigned short r5,
	unsigned short r6,
	unsigned short r7,
	unsigned short pc,
	unsigned short cc
)
{
	// clang-format off
	static const char *const ascii[128] = {
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
	if ((short)cc < 0)
	{
		cc_str = "NEGATIVE";
	}
	else if (cc == 0)
	{
		cc_str = "  ZERO  ";
	}
	else
	{
		cc_str = "POSITIVE";
	}

	unsigned short regs[8] = {r0, r1, r2, r3, r4, r5, r6, r7};
	(void)printf("+----------------------------------+\n");
	(void)printf("|       hex      int    uint   chr |\n");
	for (int i = 0; i < 8; i++)
	{
		unsigned short r = regs[i];
		const char *ch = (r < 128) ? ascii[r] : "---";
		(void)printf("| R%d  x%04X  %+7d  %6u   %s |\n", i, (unsigned int)r, (short)r, (unsigned int)r, ch);
	}
	(void)printf("+----------------+-----------------+\n");
	(void)printf("|    PC x%04X    |   CC %s   |\n", (unsigned int)pc, cc_str);
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
