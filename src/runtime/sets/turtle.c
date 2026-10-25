
/*
 * turtle trap set for lcc (x60-x64)
 *
 * Implements a basic version of Turtle Graphics with a cursor on a Cartesian
 * plane.
 *
 * Draws into a character grid rendered in the terminal using ANSI colours.
 *
 * The turtle starts at the center, facing right, with the pen down. Positive
 * turns rotate counterclockwise. Negative movement goes backwards.
 *
 * Once something has been drawn, the finished picture is held on screen until
 * a key is pressed.
 *
 *   x60 move  R0 = signed distance
 *   x61 turn  R0 = signed degrees
 *   x62 pen   R0 = 0 up, nonzero down
 *   x63 color R0 = colour index (0-15)
 *   x64 width R0 = stroke thickness
 *   x65 dims  R0 = columns, R1 = rows of the drawing area
 *   x66 jump  R0 = column, R1 = row, an absolute move
 */

#include <sys/ioctl.h>

#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "lc3_trap.h"

#define MAX_COLS 240
#define MAX_ROWS 100

#define DEFAULT_COLS 80
#define DEFAULT_ROWS 24
#define DEFAULT_COLOR 7 // black

#define BYTE_MASK 0xFF
#define NIBBLE_MASK 0x0F

#define FULL_TURN 360.0
#define HALF_TURN 180.0
#define CELL_RATIO 2

#define MOVE_SLEEP_MS 10
#define MS_PER_SECOND 1000
#define NS_PER_MS 1000000L

#define RESTORE_SIGNAL_COUNT 2

typedef struct
{
	char glyph;
	unsigned char color;
} turtle_cell;

static turtle_cell grid[MAX_ROWS][MAX_COLS];

static int grid_cols = DEFAULT_COLS;
static int grid_rows = DEFAULT_ROWS - 1;

static double turtle_x;
static double turtle_y;
static double heading;

static int pen_down = 1;
static unsigned char pen_color = DEFAULT_COLOR;
static int pen_width = 1;

static int terminal_enabled;
static int restore_armed;
static int drew;

/*
 * ANSI color codes
 * r, g, b, y, m, c, w, k, R, G, B, Y, M, C, W, K
 */
static const int ansi_colors[16] = {
	30, 31, 32, 33, 34, 35, 36, 37, 90, 91, 92, 93, 94, 95, 96, 97
};

/* signals whose previous handlers must be preserved */
static const int restore_signals[RESTORE_SIGNAL_COUNT] = {
	SIGINT, SIGTERM
};

static void (*previous_handlers[RESTORE_SIGNAL_COUNT])(int);

/* terminal restore bytes */
static const char restore_text[] = "\x1b[0m\x1b[?25h\x1b[?1049l";

/* writes an escape sequence to the terminal */
static void sequence(const char *text)
{
	(void)fputs(text, stdout);
	(void)fflush(stdout);
}

/* restores the terminal when the program exits normally */
static void restore_terminal(void)
{
	if (restore_armed)
	{
		sequence(restore_text);
		restore_armed = 0;
		terminal_enabled = 0;
	}
}

/* restores the terminal, then hands the signal to the previous handler */
static void on_signal(int sig)
{
	if (restore_armed)
	{
		(void)write(STDOUT_FILENO, restore_text, sizeof(restore_text) - 1);
	}

	for (int i = 0; i < RESTORE_SIGNAL_COUNT; i++)
	{
		if (restore_signals[i] == sig)
		{
			void (*previous)(int) = previous_handlers[i];

			if (previous != SIG_DFL && previous != SIG_IGN && previous != NULL)
			{
				previous(sig);
				return;
			}
			break;
		}
	}

	(void)signal(sig, SIG_DFL);
	(void)raise(sig);
}

/* holds the finished drawing on screen until a key is pressed */
static void wait_for_exit(void)
{
	// nothing was drawn or there is no terminal
	if (!terminal_enabled || !drew || !isatty(STDIN_FILENO))
	{
		return;
	}

	(void)fflush(stdout);

	unsigned char byte;
	(void)read(STDIN_FILENO, &byte, 1);
}

/* arms terminal restoration the first time the terminal state is changed */
static void arm_restore_screen(void)
{
	if (restore_armed)
	{
		return;
	}

	restore_armed = 1;
	(void)atexit(restore_terminal);
	// registered last so it runs first
	(void)atexit(wait_for_exit);

	for (int i = 0; i < RESTORE_SIGNAL_COUNT; i++)
	{
		struct sigaction ours;
		struct sigaction previous;

		memset(&ours, 0, sizeof(ours));
		(void)sigemptyset(&ours.sa_mask);
		ours.sa_handler = on_signal;
		ours.sa_flags = 0;

		if (sigaction(restore_signals[i], &ours, &previous) == 0)
		{
			previous_handlers[i] = previous.sa_handler;
		}
		else
		{
			previous_handlers[i] = SIG_DFL;
		}
	}
}

/* prints the finished grid without ANSI escape codes */
static void turtle_print(void)
{
	if (terminal_enabled || !drew)
	{
		return;
	}

	for (int y = 0; y < grid_rows; y++)
	{
		for (int x = 0; x < grid_cols; x++)
		{
			char glyph = grid[y][x].glyph;
			(void)putchar(glyph != '\0' ? glyph : ' ');
		}

		if (y + 1 < grid_rows)
		{
			(void)putchar('\n');
		}
	}
}

/* initialises the grid and turtle on startup */
__attribute__((constructor)) static void turtle_init(void)
{
	memset(grid, 0, sizeof(grid));

	if (isatty(STDOUT_FILENO))
	{
		struct winsize ws;

		if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0)
		{
			if (ws.ws_col > 0)
			{
				grid_cols = ws.ws_col;
			}
			if (ws.ws_row > 1)
			{
				// leave the last row to avoid scrolling
				grid_rows = ws.ws_row - 1;
			}
		}

		if (grid_cols > MAX_COLS)
		{
			grid_cols = MAX_COLS;
		}
		if (grid_rows > MAX_ROWS)
		{
			grid_rows = MAX_ROWS;
		}
		if (grid_cols < 1)
		{
			grid_cols = 1;
		}
		if (grid_rows < 1)
		{
			grid_rows = 1;
		}

		arm_restore_screen();
		terminal_enabled = 1;
		sequence("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
	}
	else
	{
		(void)atexit(turtle_print);
	}

	int logical_cols = grid_cols / CELL_RATIO;
	turtle_x = (double)(logical_cols - 1) / 2 * CELL_RATIO; // NOLINT(readability-magic-numbers)
	turtle_y = (grid_rows - 1) / 2.0;						// NOLINT(readability-magic-numbers)
	heading = 0.0;
}

/* plots one cell, clipping coordinates to the drawing area */
static void turtle_plot(int x, int y)
{
	if (x < 0 || x >= grid_cols || y < 0 || y >= grid_rows)
	{
		return;
	}

	grid[y][x].glyph = '#';
	grid[y][x].color = pen_color;
	drew = 1;
}

/* draws a stroke at the current thickness */
static void turtle_brush(int x, int y)
{
	int columns = pen_width * CELL_RATIO;
	int left = (columns - 1) / 2;
	int right = columns / 2;
	int top = (pen_width - 1) / 2;
	int bottom = pen_width / 2;

	for (int dx = -left; dx <= right; dx++)
	{
		for (int dy = -top; dy <= bottom; dy++)
		{
			turtle_plot(x + dx, y + dy);
		}
	}
}

/* rasterises a line with Bresenhams algorithm */
static void turtle_line(int x0, int y0, int x1, int y1)
{
	int dx = abs(x1 - x0);
	int dy = abs(y1 - y0);
	int sx = x0 < x1 ? 1 : -1;
	int sy = y0 < y1 ? 1 : -1;
	int err = dx - dy;

	for (;;)
	{
		turtle_brush(x0, y0);

		if (x0 == x1 && y0 == y1)
		{
			break;
		}

		int e2 = 2 * err;

		if (e2 > -dy)
		{
			err -= dy;
			x0 += sx;
		}
		if (e2 < dx)
		{
			err += dx;
			y0 += sy;
		}
	}
}

/* redraws the grid */
static void turtle_render(void)
{
	if (!terminal_enabled)
	{
		return;
	}

	(void)fputs("\x1b[H", stdout);

	int current_color = -1;

	for (int y = 0; y < grid_rows; y++)
	{
		for (int x = 0; x < grid_cols; x++)
		{
			turtle_cell *cell = &grid[y][x];

			if (cell->glyph == '\0')
			{
				if (current_color != -1)
				{
					(void)fputs("\x1b[0m", stdout);
					current_color = -1;
				}
				(void)putchar(' ');
				continue;
			}

			if (current_color != cell->color)
			{
				(void)printf("\x1b[%dm", ansi_colors[cell->color]);
				current_color = cell->color;
			}

			(void)putchar(cell->glyph);
		}

		if (current_color != -1)
		{
			(void)fputs("\x1b[0m", stdout);
			current_color = -1;
		}

		if (y + 1 < grid_rows)
		{
			(void)putchar('\n');
		}
	}

	(void)fflush(stdout);
}

/* pause for a short delay */
static void turtle_sleep()
{
	if (!terminal_enabled)
	{
		return;
	}

	struct timespec delay;
	delay.tv_sec = MOVE_SLEEP_MS / MS_PER_SECOND;
	delay.tv_nsec = (long)(MOVE_SLEEP_MS % MS_PER_SECOND) * NS_PER_MS;
	(void)nanosleep(&delay, NULL);
}

LC3_TRAP(0x60, move)
{
	int distance = (int)(short)ctx->reg[0];
	double radians = heading * M_PI / HALF_TURN;

	double next_x = turtle_x + (distance * cos(radians) * CELL_RATIO);
	double next_y = turtle_y - (distance * sin(radians));

	if (pen_down)
	{
		turtle_line(
			(int)lround(turtle_x),
			(int)lround(turtle_y),
			(int)lround(next_x),
			(int)lround(next_y)
		);
	}

	turtle_x = next_x;
	turtle_y = next_y;

	turtle_render();
	turtle_sleep();
}

LC3_TRAP(0x61, turn)
{
	int angle = (int)(short)ctx->reg[0];

	heading = fmod(heading + angle, FULL_TURN);
	if (heading < 0.0)
	{
		heading += FULL_TURN;
	}

	turtle_sleep();
}

LC3_TRAP(0x62, pen)
{
	pen_down = ctx->reg[0] != 0;
}

LC3_TRAP(0x63, color)
{
	pen_color = (unsigned char)(ctx->reg[0] & NIBBLE_MASK);
}

LC3_TRAP(0x64, width)
{
	pen_width = (short)ctx->reg[0];
	if (pen_width < 1)
	{
		pen_width = 1;
	}
}

LC3_TRAP(0x65, dims)
{
	ctx->reg[0] = (unsigned short)(grid_cols / CELL_RATIO);
	ctx->reg[1] = (unsigned short)grid_rows;
}

LC3_TRAP(0x66, jump)
{
	double next_x = (double)(short)ctx->reg[0] * CELL_RATIO;
	double next_y = (double)(short)ctx->reg[1];
	double dx = next_x - turtle_x;
	double dy = next_y - turtle_y;

	if (pen_down)
	{
		turtle_line(
			(int)lround(turtle_x),
			(int)lround(turtle_y),
			(int)lround(next_x),
			(int)lround(next_y)
		);
	}

	turtle_x = next_x;
	turtle_y = next_y;

	turtle_render();
	turtle_sleep();
}
