/* SPDX-License-Identifier: Apache-2.0 */
/*
 * pwmstream-cli: command-line client for /dev/pwmstream0. `status` is a read-only observer; `run
 * SAMPLE [BIT_RATE_HZ]` uploads a pattern file, starts output and holds the controlling
 * descriptor until stopped, with interactive stop/start/rate/quit commands. Installed as
 * /usr/bin/pwmstream-cli. See docs/usage.md.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "pwmstream.h"

_Static_assert(sizeof(struct pwmstream_config) == 16, "config ABI");
_Static_assert(sizeof(struct pwmstream_rate) == 16, "rate ABI");
_Static_assert(sizeof(struct pwmstream_status) == 64, "status ABI");

static volatile sig_atomic_t exiting;

struct command_input {
	char line[128];
	size_t used;
	int discarding;
};

/* Report overflow once; never interpret the suffix of a rejected line. */
static int input_byte(struct command_input *input, char ch)
{
	if (ch == '\n') {
		int complete = !input->discarding;

		input->line[input->used] = '\0';
		input->used = 0;
		input->discarding = 0;
		return complete;
	}
	if (input->discarding)
		return 0;
	if (ch == '\0' || input->used + 1 == sizeof(input->line)) {
		input->used = 0;
		input->discarding = 1;
		return -1;
	}
	input->line[input->used++] = ch;
	return 0;
}

static int monotonic_ms(uint64_t *now)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
		return -1;
	*now = (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
	return 0;
}

static int status_timeout(uint64_t now, uint64_t deadline)
{
	if (now >= deadline)
		return 0;
	return deadline - now > 1000 ? 1000 : (int)(deadline - now);
}

static void interrupted(int signo)
{
	(void)signo;
	exiting = 1;
}

static void usage(const char *program)
{
	fprintf(stderr,
		"Usage: %s [-d /dev/pwmstream0] status\n"
		"       %s [-d /dev/pwmstream0] run SAMPLE [BIT_RATE_HZ]\n"
		"       %s --selftest\n"
		"run holds the controlling fd until SIGINT/SIGTERM or 'quit'.\n"
		"Commands: status, stop, start, rate HZ (stopped only), quit.\n",
		program, program, program);
}

static int parse_rate(const char *text, uint32_t *rate)
{
	char *end;
	unsigned long value;

	if (!text[0] || text[0] < '0' || text[0] > '9')
		return -1;
	errno = 0;
	value = strtoul(text, &end, 10);
	if (errno || *end || value < PWMSTREAM_MIN_HZ ||
	    value > PWMSTREAM_MAX_HZ)
		return -1;
	*rate = (uint32_t)value;
	return 0;
}

static int show_status(int fd, int print)
{
	struct pwmstream_status status = {0};

	if (ioctl(fd, PWMSTREAM_STATUS, &status) < 0)
		return -1;
	if (status.version != PWMSTREAM_ABI_VERSION) {
		errno = EPROTO;
		return -1;
	}
	if (print || status.last_error)
		printf("%s upload=%" PRIu32 "/%" PRIu32
		       " requested=%" PRIu32 "Hz actual=%" PRIu32
		       "Hz error=%" PRId32 " pwm_errors=0x%" PRIx32
		       " dma_status=%" PRIu32 " residue=%" PRIu32
		       " config_ready=%s flags=0x%" PRIx32 "\n",
		       status.flags & PWMSTREAM_F_RUNNING ? "running" : "stopped",
		       status.uploaded_bytes, status.sample_bytes,
		       status.requested_hz, status.actual_hz,
		       status.last_error, status.pwm_errors,
		       status.dma_status, status.dma_residue,
		       status.flags & PWMSTREAM_F_CONFIG_READY ? "yes" : "no",
		       status.flags);
	if (status.last_error) {
		errno = -status.last_error;
		return -1;
	}
	return 0;
}

static int upload(int fd, const char *path, uint32_t rate)
{
	struct pwmstream_config cfg = {PWMSTREAM_ABI_VERSION, 0, rate, 0};
	struct stat st;
	unsigned char buffer[16384];
	size_t remaining;
	int source, result = -1;

	source = open(path, O_RDONLY | O_CLOEXEC);
	if (source < 0)
		return -1;
	if (fstat(source, &st) < 0)
		goto out;
	if (!S_ISREG(st.st_mode) || st.st_size <= 0 ||
	    st.st_size > PWMSTREAM_MAX_BYTES || st.st_size % 4) {
		errno = EINVAL;
		goto out;
	}
	cfg.sample_bytes = (uint32_t)st.st_size;
	if (ioctl(fd, PWMSTREAM_CONFIG, &cfg) < 0)
		goto out;
	remaining = cfg.sample_bytes;
	while (remaining && !exiting) {
		size_t offset = 0;
		size_t want = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
		ssize_t got = read(source, buffer, want);

		if (got < 0 && errno == EINTR)
			continue;
		if (got <= 0) {
			if (!got)
				errno = EIO;
			goto out;
		}
		while (offset < (size_t)got && !exiting) {
			ssize_t sent = write(fd, buffer + offset, (size_t)got - offset);

			if (sent < 0 && errno == EINTR)
				continue;
			if (sent <= 0) {
				if (!sent)
					errno = EIO;
				goto out;
			}
			offset += (size_t)sent;
		}
		remaining -= (size_t)got;
	}
	if (exiting) {
		errno = EINTR;
		goto out;
	}
	/* Detect a file growing during upload; a shrinking file is caught above. */
	{
		ssize_t extra;
		do {
			extra = read(source, buffer, 1);
		} while (extra < 0 && errno == EINTR && !exiting);
		if (extra != 0) {
			if (extra > 0)
				errno = EFBIG;
			goto out;
		}
	}
	result = 0;
out:
	{
		int saved = errno;
		close(source);
		errno = saved;
	}
	return result;
}

static void command(int fd, char *line)
{
	size_t len = strlen(line);
	int ret = 0;

	if (len && line[len - 1] == '\r')
		line[len - 1] = '\0';
	if (!strcmp(line, "quit"))
		exiting = 1;
	else if (!strcmp(line, "status"))
		ret = show_status(fd, 1);
	else if (!strcmp(line, "stop"))
		ret = ioctl(fd, PWMSTREAM_STOP);
	else if (!strcmp(line, "start"))
		ret = ioctl(fd, PWMSTREAM_START);
	else if (!strncmp(line, "rate ", 5)) {
		struct pwmstream_rate rate = {PWMSTREAM_ABI_VERSION, 0, {0, 0}};

		if (parse_rate(line + 5, &rate.rate_hz) < 0) {
			fprintf(stderr, "Invalid rate\n");
			return;
		}
		ret = ioctl(fd, PWMSTREAM_RATE, &rate);
	} else if (*line) {
		fprintf(stderr, "Commands: status, stop, start, rate HZ, quit\n");
	}
	if (ret < 0)
		perror("command");
}

static int run(int fd, const char *path, uint32_t rate)
{
	struct command_input input = {0};
	uint64_t now, deadline;
	int reading = 1;

	if (upload(fd, path, rate) < 0)
		return -1;
	if (exiting) {
		errno = EINTR;
		return -1;
	}
	if (ioctl(fd, PWMSTREAM_START) < 0)
		return -1;
	if (show_status(fd, 1) < 0)
		return -1;
	if (monotonic_ms(&now) < 0)
		return -1;
	deadline = now + 1000;
	fprintf(stderr, "Holding controller; Ctrl-C stops. Type status/stop/start/rate HZ/quit.\n");
	while (!exiting) {
		struct pollfd pfd = {STDIN_FILENO, POLLIN, 0};
		int ready;

		if (monotonic_ms(&now) < 0)
			return -1;
		ready = poll(&pfd, reading ? 1 : 0, status_timeout(now, deadline));
		if (ready < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (reading && ready && (pfd.revents & (POLLIN | POLLHUP))) {
			char ch;
			ssize_t n = read(STDIN_FILENO, &ch, 1);

			if (n == 0)
				reading = 0; /* EOF does not relinquish the controller. */
			else if (n > 0) {
				int complete = input_byte(&input, ch);

				if (complete > 0)
					command(fd, input.line);
				else if (complete < 0)
					fprintf(stderr, "Command too long or contains NUL; discarded through newline\n");
			} else if (errno != EINTR)
				return -1;
		}
		if (reading && (pfd.revents & (POLLERR | POLLNVAL))) {
			errno = EIO;
			return -1;
		}
		if (monotonic_ms(&now) < 0)
			return -1;
		if (!exiting && now >= deadline) {
			if (show_status(fd, 0) < 0)
				return -1;
			deadline = now + 1000;
		}
	}
	return ioctl(fd, PWMSTREAM_STOP);
}

static int selftest(void)
{
	uint32_t rate;
	uint64_t now;
	struct command_input input = {0};
	size_t i;

	if (parse_rate("50000000", &rate) || rate != PWMSTREAM_DEFAULT_HZ ||
	    !parse_rate("0", &rate) || !parse_rate("-1", &rate) ||
	    parse_rate("62500000", &rate) || rate != 62500000U ||
	    parse_rate("100000000", &rate) || rate != PWMSTREAM_MAX_HZ ||
	    !parse_rate("100000001", &rate) || !parse_rate("100000junk", &rate) ||
	    !parse_rate("99999999999999999999999999999", &rate) ||
	    parse_rate("100000", &rate))
		return EXIT_FAILURE;
	for (i = 0; i < sizeof(input.line) - 1; ++i)
		if (input_byte(&input, 'x'))
			return EXIT_FAILURE;
	if (input_byte(&input, '\n') != 1 ||
	    strlen(input.line) != sizeof(input.line) - 1)
		return EXIT_FAILURE;
	for (i = 0; i < sizeof(input.line) - 1; ++i)
		if (input_byte(&input, 'x'))
			return EXIT_FAILURE;
	if (input_byte(&input, 'x') != -1)
		return EXIT_FAILURE;
	for (i = 0; i < strlen("quit"); ++i)
		if (input_byte(&input, "quit"[i]))
			return EXIT_FAILURE;
	for (i = 0; i < 512; ++i)
		if (input_byte(&input, 'x'))
			return EXIT_FAILURE;
	if (input_byte(&input, '\n') != 0)
		return EXIT_FAILURE;
	for (i = 0; i < strlen("status\r"); ++i)
		if (input_byte(&input, "status\r"[i]))
			return EXIT_FAILURE;
	if (input_byte(&input, '\n') != 1 || strcmp(input.line, "status\r") ||
	    input_byte(&input, '\0') != -1 ||
	    input_byte(&input, '\n') != 0 ||
	    status_timeout(100, 1100) != 1000 ||
	    status_timeout(1099, 1100) != 1 ||
	    status_timeout(1100, 1100) != 0 ||
	    status_timeout(2000, 1100) != 0 ||
	    status_timeout(0, UINT64_MAX) != 1000)
		return EXIT_FAILURE;
	for (i = 0; i < 1000; ++i)
		if (status_timeout(100 + i, 1100) != (int)(1000 - i))
			return EXIT_FAILURE;
	if (input_byte(&input, '\n') != 1 || input.line[0] ||
	    monotonic_ms(&now) < 0)
		return EXIT_FAILURE;
	puts("ABI sizes, rate parser, command framing and polling deadlines: OK (no device access)");
	return EXIT_SUCCESS;
}

static void open_failed(const char *device)
{
	int saved = errno;

	perror(device);
	if (saved == ENOENT)
		fputs("The driver is not loaded or not enabled. Check: "
		      "journalctl -k | grep pwmstream; dkms status; "
		      "see the README troubleshooting section.\n", stderr);
}

int main(int argc, char **argv)
{
	const char *device = "/dev/pwmstream0";
	struct sigaction action;
	uint32_t rate = PWMSTREAM_DEFAULT_HZ;
	int index = 1, fd, ret, saved;

	if (argc == 2 && !strcmp(argv[1], "--selftest"))
		return selftest();
	if (argc > 3 && !strcmp(argv[index], "-d")) {
		device = argv[index + 1];
		index += 2;
	}
	if (index >= argc)
		goto invalid;
	if (strcmp(argv[index], "status") && strcmp(argv[index], "run"))
		goto invalid;
	if (!strcmp(argv[index], "status")) {
		if (argc - index != 1)
			goto invalid;
		fd = open(device, O_RDONLY | O_CLOEXEC);
		if (fd < 0) {
			open_failed(device);
			return EXIT_FAILURE;
		}
		ret = show_status(fd, 1);
	} else {
		if (argc - index < 2 || argc - index > 3 ||
		    (argc - index == 3 && parse_rate(argv[index + 2], &rate)))
			goto invalid;
		memset(&action, 0, sizeof(action));
		action.sa_handler = interrupted;
		sigemptyset(&action.sa_mask);
		if (sigaction(SIGINT, &action, NULL) ||
		    sigaction(SIGTERM, &action, NULL) ||
		    sigaction(SIGHUP, &action, NULL)) {
			perror("sigaction");
			return EXIT_FAILURE;
		}
		fd = open(device, O_RDWR | O_CLOEXEC);
		if (fd < 0) {
			open_failed(device);
			return EXIT_FAILURE;
		}
		ret = run(fd, argv[index + 1], rate);
	}
	saved = errno;
	/* Final close is the kernel-enforced stop, even on an error path. */
	if (close(fd) < 0 && !ret) {
		perror("close");
		return EXIT_FAILURE;
	}
	if (ret < 0) {
		errno = saved;
		perror("pwmstream");
		return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
invalid:
	usage(argv[0]);
	return EXIT_FAILURE;
}
