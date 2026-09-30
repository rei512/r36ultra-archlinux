// SPDX-License-Identifier: MIT
/*
 * r36u-status - what the R36Ultra's inputs, battery and LEDs are doing.
 *
 * Two shapes of the same state:
 *
 *   (default)  one line every 200 ms on stdout, for sway's bar
 *              (bar { status_command /usr/local/bin/r36u-status })
 *   -f         a full-screen view in a terminal: every button and axis, and
 *              r/g/b toggle the LEDs, q quits
 *   -p NAME    exit 0 if that button (A, SELECT, FN ...) is held right now and
 *              1 if it is not, so that a script can act on it. The GUI's
 *              autostart uses this to stay at the shell when a button is held
 *              during boot.
 *
 * Inputs come from the kernel's gpio-keys device and from the sticks that
 * r36u-joyd publishes (see r36u_joyd.c); the battery from the RK817 charger
 * driver; the LEDs from gpio-leds.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#define KEYS_NAME	"gpio-keys-gamepad"
#define STICKS_NAME	"R36Ultra sticks"
#define VOLKEYS_NAME	"adc-keys"	/* the volume keys, on SARADC channel 2 */
#define TICK_MS		200
#define BATTERY_EVERY	25	/* ticks between /sys reads: the values crawl */

struct button {
	int code;
	const char *name;
};

/* The board's buttons, in the order they are drawn. */
static const struct button buttons[] = {
	{ BTN_DPAD_UP, "UP" }, { BTN_DPAD_DOWN, "DOWN" },
	{ BTN_DPAD_LEFT, "LEFT" }, { BTN_DPAD_RIGHT, "RIGHT" },
	{ BTN_EAST, "A" }, { BTN_SOUTH, "B" }, { BTN_NORTH, "X" }, { BTN_WEST, "Y" },
	{ BTN_TL, "L1" }, { BTN_TR, "R1" }, { BTN_TL2, "L2" }, { BTN_TR2, "R2" },
	{ BTN_SELECT, "SEL" }, { BTN_START, "START" }, { BTN_MODE, "FN" },
	{ BTN_THUMBL, "L3" }, { BTN_THUMBR, "R3" },
	{ KEY_VOLUMEUP, "VOL+" }, { KEY_VOLUMEDOWN, "VOL-" },
};
#define NBUTTONS ((int)(sizeof(buttons) / sizeof(buttons[0])))

static const struct { int code; const char *name; } axes[] = {
	{ ABS_X, "LX" }, { ABS_Y, "LY" }, { ABS_RX, "RX" }, { ABS_RY, "RY" },
};
#define NAXES ((int)(sizeof(axes) / sizeof(axes[0])))

static const char *led_colors[] = { "red", "green", "blue" };
#define NLEDS ((int)(sizeof(led_colors) / sizeof(led_colors[0])))

static bool pressed[NBUTTONS];
static int axis_value[NAXES];
static char led_path[NLEDS][320];
static int led_on[NLEDS];
static char battery_dir[320];
static int battery_pct = -1;
static char battery_state[64] = "?";

static volatile sig_atomic_t stop;
static struct termios saved_term;
static bool term_saved;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int read_file(const char *path, char *buf, size_t len)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	ssize_t n;

	if (fd < 0)
		return -1;
	n = read(fd, buf, len - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = '\0';
	buf[strcspn(buf, "\n")] = '\0';
	return 0;
}

/* evdev device with this exact name, or -1. */
static int open_input(const char *want)
{
	char path[sizeof(((struct dirent *)0)->d_name) + 16], name[128];
	struct dirent *de;
	DIR *d = opendir("/dev/input");

	if (!d)
		return -1;
	while ((de = readdir(d))) {
		int fd;

		if (strncmp(de->d_name, "event", 5))
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 && !strcmp(name, want)) {
			closedir(d);
			return fd;
		}
		close(fd);
	}
	closedir(d);
	return -1;
}

static void find_leds(void)
{
	struct dirent *de;
	DIR *d = opendir("/sys/class/leds");

	if (!d)
		return;
	while ((de = readdir(d)))
		for (int i = 0; i < NLEDS; i++)
			if (!led_path[i][0] && strstr(de->d_name, led_colors[i]))
				snprintf(led_path[i], sizeof(led_path[i]),
					 "/sys/class/leds/%s/brightness", de->d_name);
	closedir(d);
}

static void find_battery(void)
{
	char path[384], type[32];
	struct dirent *de;
	DIR *d = opendir("/sys/class/power_supply");

	if (!d)
		return;
	while ((de = readdir(d))) {
		if (de->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path), "/sys/class/power_supply/%s/type", de->d_name);
		if (read_file(path, type, sizeof(type)) == 0 && !strcmp(type, "Battery")) {
			snprintf(battery_dir, sizeof(battery_dir),
				 "/sys/class/power_supply/%s", de->d_name);
			break;
		}
	}
	closedir(d);
}

static void update_battery(void)
{
	char path[384], buf[64];

	if (!battery_dir[0]) {
		find_battery();
		if (!battery_dir[0])
			return;
	}
	snprintf(path, sizeof(path), "%s/capacity", battery_dir);
	if (read_file(path, buf, sizeof(buf)) == 0)
		battery_pct = atoi(buf);
	snprintf(path, sizeof(path), "%s/status", battery_dir);
	if (read_file(path, buf, sizeof(buf)) == 0)
		snprintf(battery_state, sizeof(battery_state), "%s", buf);
}

static void update_leds(void)
{
	char buf[32];

	for (int i = 0; i < NLEDS; i++)
		if (led_path[i][0] && read_file(led_path[i], buf, sizeof(buf)) == 0)
			led_on[i] = atoi(buf) > 0;
}

static void set_led(int i, int on)
{
	int fd;

	if (!led_path[i][0])
		return;
	fd = open(led_path[i], O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return;
	if (write(fd, on ? "1\n" : "0\n", 2) < 0) {
		/* a LED that will not switch is not worth failing over */
	}
	close(fd);
	led_on[i] = on;
}

static int button_index(const char *name)
{
	for (int i = 0; i < NBUTTONS; i++)
		if (!strcasecmp(buttons[i].name, name))
			return i;
	return -1;
}

/*
 * Current state of the buttons this device has, so the display is right before
 * the first press. Only its own codes, since the buttons are spread over two
 * devices (gpio-keys and the volume keys on the ADC).
 */
static void sync_buttons(int fd)
{
	unsigned long has[(KEY_MAX + 8 * sizeof(long)) / (8 * sizeof(long))] = { 0 };
	unsigned long down[(KEY_MAX + 8 * sizeof(long)) / (8 * sizeof(long))] = { 0 };
	const int word = 8 * sizeof(long);

	if (fd < 0 || ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(has)), has) < 0 ||
	    ioctl(fd, EVIOCGKEY(sizeof(down)), down) < 0)
		return;
	for (int i = 0; i < NBUTTONS; i++) {
		int c = buttons[i].code;

		if (has[c / word] >> (c % word) & 1)
			pressed[i] = down[c / word] >> (c % word) & 1;
	}
}

static void handle_input(int fd)
{
	struct input_event ev;

	while (fd >= 0 && read(fd, &ev, sizeof(ev)) == sizeof(ev)) {
		if (ev.type == EV_KEY) {
			for (int i = 0; i < NBUTTONS; i++)
				if (buttons[i].code == ev.code && ev.value < 2)
					pressed[i] = ev.value;
		} else if (ev.type == EV_ABS) {
			for (int i = 0; i < NAXES; i++)
				if (axes[i].code == ev.code)
					axis_value[i] = ev.value;
		}
	}
}

static bool down(int code)
{
	for (int i = 0; i < NBUTTONS; i++)
		if (buttons[i].code == code)
			return pressed[i];
	return false;
}

/*
 * The bar line is always the same width: every label is always present and only
 * its colour changes, so the battery reading does not move around when a button
 * is held. sway renders this as pango markup (pango_markup enabled).
 */
static void bar_label(int code, const char *label)
{
	printf("<span foreground='%s'>%s</span> ", down(code) ? "#ffffff" : "#4a4a4a", label);
}

/* Short, fixed-width names: the full words would not fit and would be cut. */
static const char *battery_short(void)
{
	if (!strcmp(battery_state, "Charging"))
		return "CHG";
	if (!strcmp(battery_state, "Discharging"))
		return "BAT";
	if (!strcmp(battery_state, "Full"))
		return "FULL";
	if (!strcmp(battery_state, "Not charging"))
		return "IDLE";
	return "?";
}

static void print_bar_line(void)
{
	static const char *led_lit[NLEDS] = { "#ff4040", "#40ff40", "#4080ff" };
	char pct[8];

	/* Left aligned, but a fixed width, so nothing to its right moves. */
	snprintf(pct, sizeof(pct), "%d%%", battery_pct);
	printf("BAT %-4s %-4s │ LED ", pct, battery_short());
	for (int i = 0; i < NLEDS; i++)
		printf("<span foreground='%s'>%c</span>",
		       led_on[i] ? led_lit[i] : "#4a4a4a", "RGB"[i]);
	printf(" │ ");
	bar_label(BTN_DPAD_LEFT, "←");
	bar_label(BTN_DPAD_UP, "↑");
	bar_label(BTN_DPAD_DOWN, "↓");
	bar_label(BTN_DPAD_RIGHT, "→");
	printf("│ ");
	bar_label(BTN_EAST, "A");
	bar_label(BTN_SOUTH, "B");
	bar_label(BTN_NORTH, "X");
	bar_label(BTN_WEST, "Y");
	printf("│ ");
	bar_label(BTN_TL, "L1");
	bar_label(BTN_TL2, "L2");
	bar_label(BTN_TR, "R1");
	bar_label(BTN_TR2, "R2");
	bar_label(BTN_THUMBL, "L3");
	bar_label(BTN_THUMBR, "R3");
	printf("│ ");
	bar_label(BTN_SELECT, "SEL");
	bar_label(BTN_START, "START");
	bar_label(BTN_MODE, "FN");
	bar_label(KEY_VOLUMEDOWN, "V-");
	bar_label(KEY_VOLUMEUP, "V+");
	printf("\n");
	fflush(stdout);
}

/* Pressed buttons are shown in reverse video, so nothing shifts sideways. */
static void key(int code, const char *label)
{
	printf("%s%s%s", down(code) ? "\033[7m" : "", label, down(code) ? "\033[0m" : "");
}

#define STICK_W 19	/* interior of a stick box, in cells */
#define STICK_H 9

/* One row of a stick box: the dot sits where the axes point. */
static void stick_row(int row, int x, int y, bool clicked)
{
	int dot_col = (x + 32767) * (STICK_W - 1) / 65534;
	int dot_row = (y + 32767) * (STICK_H - 1) / 65534;

	putchar('|');
	for (int c = 0; c < STICK_W; c++) {
		if (c == dot_col && row == dot_row)
			printf("%s*%s", clicked ? "\033[7m" : "", clicked ? "\033[0m" : "");
		else if (c == STICK_W / 2 && row == STICK_H / 2)
			putchar('+');
		else
			putchar(' ');
	}
	putchar('|');
}

/* The device as it is held: shoulders on top, D-pad left, buttons right. */
static void draw_full(void)
{
	static const char *led_name[NLEDS] = { "red", "green", "blue" };

	printf("\033[H\033[2J");
	printf("  R36Ultra                        battery %3d%%  %-12s\n",
	       battery_pct, battery_state);
	printf("  ----------------------------------------------------------------\n\n");

	printf("  LED   ");
	for (int i = 0; i < NLEDS; i++)
		printf("%s%s%s  ", led_on[i] ? "\033[7m" : "", led_name[i],
		       led_on[i] ? "\033[0m" : "");
	printf("      volume  ");
	key(KEY_VOLUMEDOWN, "VOL-");
	printf("  ");
	key(KEY_VOLUMEUP, "VOL+");
	printf("\n\n");

	printf("    ");
	key(BTN_TL2, "L2");
	printf("                                                  ");
	key(BTN_TR2, "R2");
	printf("\n    ");
	key(BTN_TL, "L1");
	printf("                                                  ");
	key(BTN_TR, "R1");
	printf("\n\n");

	printf("          ");
	key(BTN_DPAD_UP, "^");
	printf("                                        ");
	key(BTN_NORTH, "X");
	printf("\n       ");
	key(BTN_DPAD_LEFT, "<");
	printf("  +  ");
	key(BTN_DPAD_RIGHT, ">");
	printf("                                ");
	key(BTN_WEST, "Y");
	printf("       ");
	key(BTN_EAST, "A");
	printf("\n          ");
	key(BTN_DPAD_DOWN, "v");
	printf("                                        ");
	key(BTN_SOUTH, "B");
	printf("\n\n");

	printf("                    ");
	key(BTN_SELECT, "SELECT");
	printf("    ");
	key(BTN_MODE, "FN");
	printf("    ");
	key(BTN_START, "START");
	printf("\n\n");

	printf("     left stick                          right stick\n");
	printf("     +-------------------+               +-------------------+\n");
	for (int row = 0; row < STICK_H; row++) {
		printf("     ");
		stick_row(row, axis_value[0], axis_value[1], down(BTN_THUMBL));
		printf("               ");
		stick_row(row, axis_value[2], axis_value[3], down(BTN_THUMBR));
		putchar('\n');
	}
	printf("     +-------------------+               +-------------------+\n");
	printf("     ");
	key(BTN_THUMBL, "L3");
	printf("  x %+6d  y %+6d        ", axis_value[0], axis_value[1]);
	key(BTN_THUMBR, "R3");
	printf("  x %+6d  y %+6d\n\n", axis_value[2], axis_value[3]);

	printf("     r / g / b : toggle LED     q : quit\n");
	fflush(stdout);
}

static void raw_mode(void)
{
	struct termios t;

	if (tcgetattr(STDIN_FILENO, &saved_term) < 0)
		return;
	term_saved = true;
	t = saved_term;
	t.c_lflag &= ~(ICANON | ECHO);
	t.c_cc[VMIN] = 0;
	t.c_cc[VTIME] = 0;
	tcsetattr(STDIN_FILENO, TCSANOW, &t);
}

static void restore_term(void)
{
	if (term_saved)
		tcsetattr(STDIN_FILENO, TCSANOW, &saved_term);
	printf("\033[?25h\n");	/* cursor back on */
	fflush(stdout);
}

int main(int argc, char **argv)
{
	bool full = argc > 1 && !strcmp(argv[1], "-f");
	const char *ask = (argc > 2 && !strcmp(argv[1], "-p")) ? argv[2] : NULL;
	int keys, sticks, volkeys, ticks = 0;

	if (argc > 1 && !full && !ask) {
		fprintf(stderr,
			"usage: %s [-f | -p BUTTON]\n"
			"  -f         full-screen view\n"
			"  -p BUTTON  exit 0 if BUTTON is held now (A, SELECT, FN, ...)\n",
			argv[0]);
		return 2;
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	keys = open_input(KEYS_NAME);
	sticks = open_input(STICKS_NAME);	/* absent until r36u-joyd runs */
	volkeys = open_input(VOLKEYS_NAME);
	find_leds();
	find_battery();
	sync_buttons(keys);
	sync_buttons(volkeys);

	if (ask) {
		int i = button_index(ask);

		if (i < 0) {
			fprintf(stderr, "unknown button: %s\n", ask);
			return 2;
		}
		return pressed[i] ? 0 : 1;
	}
	update_leds();
	update_battery();

	if (full) {
		raw_mode();
		printf("\033[?25l");	/* hide the cursor while it redraws */
	}

	while (!stop) {
		struct pollfd fds[4];
		int nfds = 0;

		if (keys >= 0)
			fds[nfds++] = (struct pollfd){ .fd = keys, .events = POLLIN };
		if (sticks >= 0)
			fds[nfds++] = (struct pollfd){ .fd = sticks, .events = POLLIN };
		if (volkeys >= 0)
			fds[nfds++] = (struct pollfd){ .fd = volkeys, .events = POLLIN };
		if (full)
			fds[nfds++] = (struct pollfd){ .fd = STDIN_FILENO, .events = POLLIN };
		poll(fds, nfds, TICK_MS);

		handle_input(keys);
		handle_input(sticks);
		handle_input(volkeys);

		if (full) {
			char c;

			while (read(STDIN_FILENO, &c, 1) == 1) {
				if (c == 'q')
					stop = 1;
				for (int i = 0; i < NLEDS; i++)
					if (c == led_colors[i][0])
						set_led(i, !led_on[i]);
			}
		}

		if (ticks++ % BATTERY_EVERY == 0) {
			update_battery();
			update_leds();
		}
		if (full)
			draw_full();
		else
			print_bar_line();
	}

	if (full)
		restore_term();
	return 0;
}
