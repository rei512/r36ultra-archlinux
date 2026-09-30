// SPDX-License-Identifier: MIT
/*
 * r36u-joyd - analog sticks and a pointer for the R36Ultra.
 *
 * The four analog axes share a single SARADC input (channel 1). Two GPIOs on
 * gpio2 select which one is connected, measured on the device 2026-09-23:
 *
 *   B7(15) C0(16)  axis      one end   centre   other end
 *     0      0     left X    left 826    491    right  37
 *     1      0     left Y    up   915    516    down  105
 *     1      1     right X   left  45    515    right 850
 *     0      1     right Y   up   169    508    down  901
 *
 * gpio2 B3 (line 11), which the BSP also lists, has no effect on the readings
 * and is left alone. The BSP does the same multiplexing inside its out-of-tree
 * "micro,gamepad" driver; mainline's adc-joystick assumes one ADC channel per
 * axis, so this daemon does it in userspace instead and publishes:
 *
 *   - "R36Ultra sticks": the four axes, as a gamepad
 *   - "R36Ultra pointer": the left stick as a mouse, with A and B as the
 *     buttons (read from the kernel's gpio-keys device)
 *
 * Nothing here is board-specific beyond the table above and the defaults.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define GPIO_CHIP	"/dev/gpiochip2"
#define GPIO_SEL_B7	15
#define GPIO_SEL_C0	16
#define ADC_DEFAULT	"/sys/bus/iio/devices/iio:device0/in_voltage1_raw"
#define KEYS_NAME	"gpio-keys-gamepad"

#define ABS_MAX_VAL	32767
#define DEADZONE	3500	/* of ABS_MAX_VAL; the sticks rest a few counts off centre */
#define SETTLE_US	500	/* after switching the mux, before reading the ADC */
#define PERIOD_US	10000	/* one pass over the four axes */
#define POINTER_SPEED	14	/* pixels per pass at full deflection */

struct axis {
	const char *name;
	int sel_b7, sel_c0;
	int neg, mid, pos;	/* raw values at -ABS_MAX_VAL, 0 and +ABS_MAX_VAL */
	int code;		/* ABS_* */
};

/* Order: the pointer uses axes[0] and axes[1]. */
static struct axis axes[] = {
	{ "left X",  0, 0, 826, 491,  37, ABS_X  },
	{ "left Y",  1, 0, 915, 516, 105, ABS_Y  },
	{ "right X", 1, 1,  45, 515, 850, ABS_RX },
	{ "right Y", 0, 1, 169, 508, 901, ABS_RY },
};
#define NAXES ((int)(sizeof(axes) / sizeof(axes[0])))

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int xioctl(int fd, unsigned long req, void *arg, const char *what)
{
	if (ioctl(fd, req, arg) < 0) {
		fprintf(stderr, "%s: %s\n", what, strerror(errno));
		return -1;
	}
	return 0;
}

/* The two select lines, as one line request so they change together. */
static int gpio_open(void)
{
	struct gpio_v2_line_request req = {
		.offsets = { GPIO_SEL_B7, GPIO_SEL_C0 },
		.num_lines = 2,
		.consumer = "r36u-joyd",
		.config = {
			.flags = GPIO_V2_LINE_FLAG_OUTPUT,
			.num_attrs = 0,
		},
	};
	int chip = open(GPIO_CHIP, O_RDWR | O_CLOEXEC);

	if (chip < 0) {
		fprintf(stderr, "open %s: %s\n", GPIO_CHIP, strerror(errno));
		return -1;
	}
	if (xioctl(chip, GPIO_V2_GET_LINE_IOCTL, &req, "request gpio lines") < 0) {
		close(chip);
		return -1;
	}
	close(chip);
	return req.fd;
}

static int gpio_select(int fd, int b7, int c0)
{
	struct gpio_v2_line_values vals = {
		.bits = (b7 ? 1ULL << 0 : 0) | (c0 ? 1ULL << 1 : 0),
		.mask = 0x3,
	};

	return xioctl(fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &vals, "set gpio lines");
}

static int adc_read(int fd)
{
	char buf[32];
	ssize_t n = pread(fd, buf, sizeof(buf) - 1, 0);

	if (n <= 0)
		return -1;
	buf[n] = '\0';
	return atoi(buf);
}

static int scale(const struct axis *a, int raw)
{
	long v, from = raw - a->mid;

	if ((a->pos > a->mid && raw >= a->mid) || (a->pos < a->mid && raw <= a->mid))
		v = (long)ABS_MAX_VAL * from / (a->pos - a->mid);
	else
		v = -(long)ABS_MAX_VAL * from / (a->neg - a->mid);

	if (v > ABS_MAX_VAL)
		v = ABS_MAX_VAL;
	if (v < -ABS_MAX_VAL)
		v = -ABS_MAX_VAL;
	/* Rescale what is outside the deadzone, so the axis still reaches its ends. */
	if (v > DEADZONE)
		v = (v - DEADZONE) * ABS_MAX_VAL / (ABS_MAX_VAL - DEADZONE);
	else if (v < -DEADZONE)
		v = (v + DEADZONE) * ABS_MAX_VAL / (ABS_MAX_VAL - DEADZONE);
	else
		v = 0;
	return (int)v;
}

static int uinput_open(const char *name, bool pointer)
{
	struct uinput_setup setup = { .id = { .bustype = BUS_HOST }, };
	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);

	if (fd < 0) {
		fprintf(stderr, "open /dev/uinput: %s\n", strerror(errno));
		return -1;
	}
	snprintf(setup.name, sizeof(setup.name), "%s", name);

	if (pointer) {
		int keys[] = { BTN_LEFT, BTN_RIGHT };

		if (xioctl(fd, UI_SET_EVBIT, (void *)EV_REL, "EV_REL") < 0 ||
		    xioctl(fd, UI_SET_RELBIT, (void *)REL_X, "REL_X") < 0 ||
		    xioctl(fd, UI_SET_RELBIT, (void *)REL_Y, "REL_Y") < 0 ||
		    xioctl(fd, UI_SET_EVBIT, (void *)EV_KEY, "EV_KEY") < 0)
			goto fail;
		for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
			if (xioctl(fd, UI_SET_KEYBIT, (void *)(long)keys[i], "key") < 0)
				goto fail;
	} else {
		if (xioctl(fd, UI_SET_EVBIT, (void *)EV_ABS, "EV_ABS") < 0)
			goto fail;
		for (int i = 0; i < NAXES; i++) {
			struct uinput_abs_setup abs = {
				.code = axes[i].code,
				.absinfo = {
					.minimum = -ABS_MAX_VAL,
					.maximum = ABS_MAX_VAL,
					.fuzz = 64,
				},
			};

			if (xioctl(fd, UI_ABS_SETUP, &abs, "UI_ABS_SETUP") < 0)
				goto fail;
		}
	}
	if (xioctl(fd, UI_DEV_SETUP, &setup, "UI_DEV_SETUP") < 0 ||
	    xioctl(fd, UI_DEV_CREATE, NULL, "UI_DEV_CREATE") < 0)
		goto fail;
	return fd;
fail:
	close(fd);
	return -1;
}

static void emit(int fd, int type, int code, int value)
{
	struct input_event ev = { .type = type, .code = code, .value = value };

	if (write(fd, &ev, sizeof(ev)) != sizeof(ev))
		fprintf(stderr, "write uinput: %s\n", strerror(errno));
}

/* The buttons stay with the kernel's gpio-keys device; find it by name. */
static int keys_open(void)
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
		if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 &&
		    !strcmp(name, KEYS_NAME)) {
			closedir(d);
			return fd;
		}
		close(fd);
	}
	closedir(d);
	return -1;
}

int main(int argc, char **argv)
{
	const char *adc_path = ADC_DEFAULT;
	bool verbose = false;
	int gpio, adc, pad, ptr, keys, opt;

	while ((opt = getopt(argc, argv, "a:vh")) != -1) {
		switch (opt) {
		case 'a':
			adc_path = optarg;
			break;
		case 'v':
			verbose = true;	/* print raw and scaled values, for recalibration */
			break;
		default:
			fprintf(stderr, "usage: %s [-a <in_voltageN_raw>] [-v]\n", argv[0]);
			return opt == 'h' ? 0 : 1;
		}
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	adc = open(adc_path, O_RDONLY | O_CLOEXEC);
	if (adc < 0) {
		fprintf(stderr, "open %s: %s\n", adc_path, strerror(errno));
		return 1;
	}
	gpio = gpio_open();
	if (gpio < 0)
		return 1;
	pad = uinput_open("R36Ultra sticks", false);
	ptr = uinput_open("R36Ultra pointer", true);
	if (pad < 0 || ptr < 0)
		return 1;
	keys = keys_open();	/* optional: without it the pointer has no buttons */
	if (keys < 0)
		fprintf(stderr, "note: %s not found, pointer buttons disabled\n", KEYS_NAME);

	while (!stop) {
		int scaled[NAXES];
		struct input_event ev;

		for (int i = 0; i < NAXES; i++) {
			int raw;

			if (gpio_select(gpio, axes[i].sel_b7, axes[i].sel_c0) < 0)
				return 1;
			usleep(SETTLE_US);
			raw = adc_read(adc);
			if (raw < 0) {
				fprintf(stderr, "read %s: %s\n", adc_path, strerror(errno));
				return 1;
			}
			scaled[i] = scale(&axes[i], raw);
			emit(pad, EV_ABS, axes[i].code, scaled[i]);
			if (verbose)
				printf("%-8s raw=%4d -> %6d%s", axes[i].name, raw,
				       scaled[i], i == NAXES - 1 ? "\n" : "  ");
		}
		emit(pad, EV_SYN, SYN_REPORT, 0);
		if (verbose)
			fflush(stdout);

		/* A and B become the pointer's buttons; everything else stays as it is. */
		while (keys >= 0 && read(keys, &ev, sizeof(ev)) == sizeof(ev)) {
			if (ev.type != EV_KEY || ev.value > 1)
				continue;
			if (ev.code == BTN_EAST)
				emit(ptr, EV_KEY, BTN_LEFT, ev.value);
			else if (ev.code == BTN_SOUTH)
				emit(ptr, EV_KEY, BTN_RIGHT, ev.value);
			else
				continue;
			emit(ptr, EV_SYN, SYN_REPORT, 0);
		}

		/* Left stick moves the pointer, squared so small movements stay slow. */
		{
			long dx = (long)scaled[0] * scaled[0] / ABS_MAX_VAL * POINTER_SPEED /
				  ABS_MAX_VAL;
			long dy = (long)scaled[1] * scaled[1] / ABS_MAX_VAL * POINTER_SPEED /
				  ABS_MAX_VAL;

			if (scaled[0] < 0)
				dx = -dx;
			if (scaled[1] < 0)
				dy = -dy;
			if (dx || dy) {
				if (dx)
					emit(ptr, EV_REL, REL_X, (int)dx);
				if (dy)
					emit(ptr, EV_REL, REL_Y, (int)dy);
				emit(ptr, EV_SYN, SYN_REPORT, 0);
			}
		}
		usleep(PERIOD_US - NAXES * SETTLE_US);
	}

	ioctl(pad, UI_DEV_DESTROY);
	ioctl(ptr, UI_DEV_DESTROY);
	return 0;
}
