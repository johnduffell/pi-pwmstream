/* SPDX-License-Identifier: Apache-2.0 */
/*
 * pwmstream-test: native test client for the pwmstream ABI. --selftest checks ABI layout and
 * parsing with no device (run by `make check`); the other modes need the loaded driver on a Pi and
 * emit waveforms. Started by dev-tools/test.sh; see docs/development.md.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../pwmstream.h"

_Static_assert(sizeof(struct pwmstream_config) == 16, "config ABI");
_Static_assert(sizeof(struct pwmstream_rate) == 16, "rate ABI");
_Static_assert(sizeof(struct pwmstream_status) == 64, "status ABI");
_Static_assert(offsetof(struct pwmstream_status, last_error) == 24, "status ABI");

static const char *device = "/dev/pwmstream0";
static int controller = -1, observer = -1;
static unsigned int checks;
static volatile sig_atomic_t interrupted;
static int needs_rebind;
static const char *platform_device = "3f20c000.pwm";

static int binding(int bind)
{
	const char *path = bind ? "/sys/bus/platform/drivers/pwmstream/bind" :
				 "/sys/bus/platform/drivers/pwmstream/unbind";
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	int saved, ret;
	ssize_t written;

	if (fd < 0)
		return -1;
	written = write(fd, platform_device, strlen(platform_device));
	ret = written == (ssize_t)strlen(platform_device) ? 0 : -1;
	saved = written < 0 ? errno : EIO;
	if (close(fd) < 0 && !ret)
		return -1;
	if (ret)
		errno = saved;
	return ret;
}

static void signal_handler(int signo)
{
	interrupted = signo;
}

static int cleanup(void)
{
	int failed = 0;

	if (controller >= 0) {
		if (ioctl(controller, PWMSTREAM_STOP) < 0 && errno != ENODEV) {
			perror("cleanup STOP (final close still attempted)");
			failed = 1;
		}
		if (close(controller) < 0) {
			perror("cleanup controller close");
			failed = 1;
		}
		controller = -1;
	}
	if (observer >= 0) {
		close(observer);
		observer = -1;
	}
	if (needs_rebind) {
		fprintf(stderr, "Attempting recovery rebind of pwmstream/%s\n", platform_device);
		if (binding(1) < 0) {
			perror("recovery rebind; device may remain unbound");
			failed = 1;
		} else {
			needs_rebind = 0;
		}
	}
	return failed;
}

static void at_exit(void)
{
	(void)cleanup();
}

static void fail(const char *what, int line)
{
	fprintf(stderr, "FAIL line %d: %s (errno=%d: %s)\n",
		line, what, errno, strerror(errno));
	exit(1);
}

static void check_signal(void)
{
	if (interrupted) {
		fprintf(stderr, "Interrupted by signal %d; closing only our controller\n",
			(int)interrupted);
		exit(128 + interrupted);
	}
}

#define CHECK(expr) do { \
	check_signal(); \
	if (!(expr)) fail(#expr, __LINE__); \
	++checks; \
	check_signal(); \
} while (0)
#define ERROR(expr, expected) do { \
	check_signal(); \
	errno = 0; \
	if ((expr) != -1 || errno != (expected)) fail(#expr " -> " #expected, __LINE__); \
	++checks; \
	check_signal(); \
} while (0)

static struct pwmstream_status status(void)
{
	struct pwmstream_status s = {0};
	size_t i;

	CHECK(ioctl(observer, PWMSTREAM_STATUS, &s) == 0);
	CHECK(s.version == PWMSTREAM_ABI_VERSION);
	CHECK(s.flags & PWMSTREAM_F_DMA_LIMITED);
	for (i = 0; i < sizeof(s.reserved) / sizeof(s.reserved[0]); ++i)
		CHECK(s.reserved[i] == 0);
	return s;
}

static void print_status(struct pwmstream_status s)
{
	printf("status flags=0x%" PRIx32 " upload=%" PRIu32 "/%" PRIu32
	       " requested=%" PRIu32 " actual=%" PRIu32 " last_error=%" PRId32
	       " pwm_errors=0x%" PRIx32 " dma=%" PRIu32 " residue=%" PRIu32 "\n",
	       s.flags, s.uploaded_bytes, s.sample_bytes, s.requested_hz,
	       s.actual_hz, s.last_error, s.pwm_errors, s.dma_status, s.dma_residue);
}

static void healthy(int running)
{
	struct pwmstream_status s = status();

	print_status(s);
	CHECK(!!(s.flags & PWMSTREAM_F_RUNNING) == running);
	CHECK(s.flags & PWMSTREAM_F_CONTROLLER);
	CHECK(s.flags & PWMSTREAM_F_CLOCK_READY);
	CHECK(s.flags & PWMSTREAM_F_CONFIG_READY);
	CHECK(s.last_error == 0 && s.pwm_errors == 0);
	CHECK(s.actual_hz >= PWMSTREAM_MIN_HZ &&
	      s.actual_hz <= PWMSTREAM_MAX_HZ + 1U);
	if (running) {
		CHECK(s.flags & PWMSTREAM_F_COMPLETE);
		CHECK(s.uploaded_bytes == s.sample_bytes);
		CHECK(s.dma_status == 1); /* Linux DMA_IN_PROGRESS, not edge verification. */
	} else {
		CHECK(s.dma_status == 0);
		CHECK(s.dma_residue == 0);
	}
}

static void configure(unsigned int bytes, unsigned int hz)
{
	struct pwmstream_config cfg = {PWMSTREAM_ABI_VERSION, bytes, hz, 0};
	struct pwmstream_status s;

	CHECK(ioctl(controller, PWMSTREAM_CONFIG, &cfg) == 0);
	s = status();
	CHECK(s.sample_bytes == bytes && s.uploaded_bytes == 0);
	CHECK(s.requested_hz == (hz ? hz : PWMSTREAM_DEFAULT_HZ));
	CHECK(!(s.flags & PWMSTREAM_F_COMPLETE));
	healthy(0);
}

static void unchanged(struct pwmstream_status before)
{
	struct pwmstream_status after = status();

	CHECK(after.flags == before.flags);
	CHECK(after.sample_bytes == before.sample_bytes);
	CHECK(after.uploaded_bytes == before.uploaded_bytes);
	CHECK(after.requested_hz == before.requested_hz);
	CHECK(after.actual_hz == before.actual_hz);
	CHECK(after.last_error == before.last_error);
	CHECK(after.pwm_errors == before.pwm_errors);
	CHECK(after.dma_status == before.dma_status);
	CHECK(after.dma_residue == before.dma_residue);
}

static void acquire(void)
{
	CHECK((controller = open(device, O_RDWR | O_CLOEXEC)) >= 0);
}

static void wait_tick(void)
{
	int ret = poll(NULL, 0, 250);

	check_signal();
	CHECK(ret == 0);
	healthy(1);
}

static void large_sample(void)
{
	const size_t length = 64U * 1024U;
	unsigned char *bytes = malloc(length);
	struct pwmstream_status s;
	size_t offset;
	int cycle, tick;

	CHECK(bytes != NULL);
	for (offset = 0; offset < length; offset += 4) {
		bytes[offset] = bytes[offset + 1] = 0xff;
		bytes[offset + 2] = bytes[offset + 3] = 0;
	}
	configure(length, 1000000);
	for (offset = 0; offset < length;) {
		size_t amount = length - offset;

		if (amount > 4093)
			amount = 4093;
		CHECK(write(controller, bytes + offset, amount) == (ssize_t)amount);
		offset += amount;
	}
	s = status();
	CHECK(s.uploaded_bytes == length && (s.flags & PWMSTREAM_F_COMPLETE));
	for (cycle = 0; cycle < 2; ++cycle) {
		CHECK(ioctl(controller, PWMSTREAM_START) == 0);
		/* 750 ms exceeds the 524.288 ms nominal buffer duration. */
		for (tick = 0; tick < 3; ++tick)
			wait_tick();
		CHECK(ioctl(controller, PWMSTREAM_STOP) == 0);
		healthy(0);
	}
	/* Replace both a completed large sample and an incomplete upload. */
	configure(8, 1000000);
	CHECK(write(controller, bytes, 3) == 3);
	configure(4, 1000000);
	ERROR(ioctl(controller, PWMSTREAM_START), ENODATA);
	CHECK(write(controller, bytes, 4) == 4);
	CHECK(ioctl(controller, PWMSTREAM_START) == 0);
	wait_tick();
	CHECK(ioctl(controller, PWMSTREAM_STOP) == 0);
	healthy(0);
	free(bytes);
}

static void abi_hardware(void)
{
	const unsigned char bytes[12] = {
		0xff, 0xff, 0, 0, 0xff, 0, 0, 0, 0xaa, 0xaa, 0xaa, 0xaa
	};
	struct pwmstream_config cfg;
	struct pwmstream_rate rate = {PWMSTREAM_ABI_VERSION, 1000000, {0, 0}};
	struct pwmstream_status before, s;
	unsigned int invalid_sizes[] = {0, 1, 3, 5, PWMSTREAM_MAX_BYTES + 4U};
	size_t i;
	int shared;

	acquire(); /* EBUSY means leave the existing owner alone and fail. */
	ERROR(open(device, O_WRONLY | O_CLOEXEC), EBUSY);
	ERROR(ioctl(observer, PWMSTREAM_STOP), EPERM);
	ERROR(ioctl(observer, PWMSTREAM_START), EPERM);
	ERROR(ioctl(observer, PWMSTREAM_CONFIG, &rate), EPERM);
	ERROR(ioctl(observer, PWMSTREAM_RATE, &rate), EPERM);
	ERROR(ioctl(controller, _IO('P', 0x7f)), ENOTTY);
	ERROR(lseek(controller, 0, SEEK_SET), ESPIPE);
	ERROR(write(controller, bytes, 1), EINVAL);
	ERROR(ioctl(controller, PWMSTREAM_START), ENODATA);
	CHECK(ioctl(controller, PWMSTREAM_STOP) == 0);
	configure(8, 0);
	CHECK(write(controller, bytes, 1) == 1);
	s = status();
	CHECK(s.uploaded_bytes == 1 && !(s.flags & PWMSTREAM_F_COMPLETE));
	ERROR(ioctl(controller, PWMSTREAM_START), ENODATA);
	before = status();
	for (i = 0; i < sizeof(invalid_sizes) / sizeof(invalid_sizes[0]); ++i) {
		cfg = (struct pwmstream_config){PWMSTREAM_ABI_VERSION, invalid_sizes[i], 0, 0};
		ERROR(ioctl(controller, PWMSTREAM_CONFIG, &cfg), EINVAL);
		unchanged(before);
	}
	cfg = (struct pwmstream_config){PWMSTREAM_ABI_VERSION + 1, 8, 0, 0};
	ERROR(ioctl(controller, PWMSTREAM_CONFIG, &cfg), EINVAL);
	unchanged(before);
	cfg.version = PWMSTREAM_ABI_VERSION;
	cfg.reserved = 1;
	ERROR(ioctl(controller, PWMSTREAM_CONFIG, &cfg), EINVAL);
	unchanged(before);
	cfg.reserved = 0;
	cfg.rate_hz = PWMSTREAM_MIN_HZ - 1U;
	ERROR(ioctl(controller, PWMSTREAM_CONFIG, &cfg), ERANGE);
	unchanged(before);
	cfg.rate_hz = PWMSTREAM_MAX_HZ + 1U;
	ERROR(ioctl(controller, PWMSTREAM_CONFIG, &cfg), ERANGE);
	unchanged(before);
	rate.version++;
	ERROR(ioctl(controller, PWMSTREAM_RATE, &rate), EINVAL);
	rate.version = PWMSTREAM_ABI_VERSION;
	for (i = 0; i < 2; ++i) {
		rate.reserved[i] = 1;
		ERROR(ioctl(controller, PWMSTREAM_RATE, &rate), EINVAL);
		rate.reserved[i] = 0;
	}
	rate.rate_hz = PWMSTREAM_MAX_HZ + 1U;
	ERROR(ioctl(controller, PWMSTREAM_RATE, &rate), ERANGE);
	rate.rate_hz = PWMSTREAM_MIN_HZ - 1U;
	ERROR(ioctl(controller, PWMSTREAM_RATE, &rate), ERANGE);
	rate.rate_hz = 0;
	ERROR(ioctl(controller, PWMSTREAM_RATE, &rate), ERANGE);
	unchanged(before);
	CHECK(write(controller, bytes + 1, 2) == 2);
	CHECK(write(controller, bytes + 3, sizeof(bytes) - 3) == 5);
	ERROR(write(controller, bytes, 1), ENOSPC);
	CHECK(write(controller, bytes, 0) == 0);
	s = status();
	CHECK(s.uploaded_bytes == 8 && (s.flags & PWMSTREAM_F_COMPLETE));
	rate.rate_hz = PWMSTREAM_MIN_HZ;
	CHECK(ioctl(controller, PWMSTREAM_RATE, &rate) == 0);
	s = status();
	CHECK(s.requested_hz == PWMSTREAM_MIN_HZ && s.uploaded_bytes == 8);
	CHECK(s.flags & PWMSTREAM_F_COMPLETE);
	healthy(0);
	rate.rate_hz = 1000000;
	CHECK(ioctl(controller, PWMSTREAM_RATE, &rate) == 0);
	s = status();
	CHECK(s.requested_hz == 1000000 && s.uploaded_bytes == 8);
	healthy(0);
	before = s;
	cfg.rate_hz = PWMSTREAM_MAX_HZ + 1U;
	ERROR(ioctl(controller, PWMSTREAM_CONFIG, &cfg), ERANGE);
	unchanged(before);
	CHECK(ioctl(controller, PWMSTREAM_START) == 0);
	wait_tick();
	ERROR(ioctl(controller, PWMSTREAM_START), EBUSY);
	ERROR(ioctl(controller, PWMSTREAM_CONFIG, &cfg), EBUSY);
	ERROR(ioctl(controller, PWMSTREAM_RATE, &rate), EBUSY);
	ERROR(write(controller, bytes, 1), EBUSY);
	ERROR(ioctl(controller, _IO('P', 0x7f)), EBUSY);
	ERROR(ioctl(observer, PWMSTREAM_STOP), EPERM);
	healthy(1);
	CHECK(ioctl(controller, PWMSTREAM_STOP) == 0);
	CHECK(ioctl(controller, PWMSTREAM_STOP) == 0);
	healthy(0);
	CHECK(ioctl(controller, PWMSTREAM_START) == 0);
	wait_tick();
	/* The final descriptor, not each dup close, owns playback lifetime. */
	CHECK((shared = dup(controller)) >= 0);
	CHECK(close(controller) == 0);
	controller = shared;
	healthy(1);
	CHECK(close(controller) == 0); /* Final close must stop and free sample. */
	controller = -1;
	s = status();
	CHECK(!(s.flags & (PWMSTREAM_F_RUNNING | PWMSTREAM_F_CONTROLLER |
			  PWMSTREAM_F_COMPLETE | PWMSTREAM_F_CONFIG_READY)));
	CHECK(s.sample_bytes == 0 && s.uploaded_bytes == 0);
	CHECK(s.dma_status == 0 && s.dma_residue == 0);
	acquire();
	ERROR(ioctl(controller, PWMSTREAM_START), ENODATA);
	configure(4, 0);
	CHECK(write(controller, bytes, 4) == 4);
	CHECK(ioctl(controller, PWMSTREAM_START) == 0);
	wait_tick();
	CHECK(ioctl(controller, PWMSTREAM_STOP) == 0);
	healthy(0);
	/* Fork without a controller so only child exit can release its sample. */
	CHECK(close(controller) == 0);
	controller = -1;
	{
		pid_t child = fork();
		int child_status, result;

		CHECK(child >= 0);
		if (!child) {
			acquire();
			configure(4, 1000000);
			CHECK(write(controller, bytes, 4) == 4);
			CHECK(ioctl(controller, PWMSTREAM_START) == 0);
			wait_tick();
			_exit(0);
		}
		do {
			result = waitpid(child, &child_status, 0);
		} while (result < 0 && errno == EINTR);
		CHECK(result == child);
		CHECK(WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0);
	}
	s = status();
	CHECK(!(s.flags & (PWMSTREAM_F_RUNNING | PWMSTREAM_F_CONTROLLER |
			  PWMSTREAM_F_COMPLETE | PWMSTREAM_F_CONFIG_READY)));
	CHECK(s.sample_bytes == 0 && s.uploaded_bytes == 0);
	CHECK(s.dma_status == 0 && s.dma_residue == 0);
	acquire();
	configure(4, 1000000);
	CHECK(write(controller, bytes, 4) == 4);
	CHECK(ioctl(controller, PWMSTREAM_START) == 0);
	wait_tick();
	CHECK(ioctl(controller, PWMSTREAM_STOP) == 0);
	healthy(0);
	large_sample();
}

static void enter(const char *prompt, int running)
{
	printf("%s\n", prompt);
	fflush(stdout);
	for (;;) {
		struct pollfd pfd = {STDIN_FILENO, POLLIN, 0};
		char ch;
		int ready = poll(&pfd, 1, 250);

		check_signal();
		CHECK(ready >= 0);
		if (running)
			healthy(1);
		if (ready) {
			CHECK(!(pfd.revents & (POLLERR | POLLNVAL)));
			CHECK(read(STDIN_FILENO, &ch, 1) == 1); /* EOF aborts, never passes. */
			if (ch == '\n')
				break;
		}
	}
}

static void scope_case(const unsigned char *bytes, unsigned int length,
		       unsigned int hz, const char *description)
{
	struct pwmstream_status s;

	configure(length, hz);
	CHECK(write(controller, bytes, length) == (ssize_t)length);
	s = status();
	printf("\nSCOPE: %s\n", description);
	printf("Clock readback tick %.6f ns; whole sample %.6f us. Not a measurement.\n",
	       1e9 / s.actual_hz, length * 8e6 / s.actual_hz);
	enter("Arm capture if needed. Enter STARTS output; Ctrl-C aborts.", 0);
	CHECK(ioctl(controller, PWMSTREAM_START) == 0);
	enter("Observe/record timing, bit order and wrap. Enter acknowledges observation and STOPS; Ctrl-C fails.", 1);
	CHECK(ioctl(controller, PWMSTREAM_STOP) == 0);
	healthy(0);
	puts("Operator acknowledged observation; physical correctness NOT automatically verified.");
}

static void scope(int extended)
{
	const unsigned char square[] = {0xff, 0xff, 0, 0};
	const unsigned char asymmetric[] = {0xff, 0xff, 0, 0, 0xff, 0, 0, 0};
	const unsigned char alternating[] = {0xaa, 0xaa, 0xaa, 0xaa};

	CHECK(isatty(STDIN_FILENO));
	acquire();
	scope_case(square, sizeof(square), 1000000,
		   "FFFF0000 @ 1 Mbit/s: 16 us high / 16 us low; 31.25 kHz.");
	scope_case(square, sizeof(square), PWMSTREAM_DEFAULT_HZ,
		   "FFFF0000 @ 50 Mbit/s: 320 ns high / 320 ns low; 1.5625 MHz.");
	scope_case(asymmetric, sizeof(asymmetric), 1000000,
		   "FFFF0000 FF000000 @ 1 Mbit/s: 16H/16L/8H/24L us; 64 us wrap.");
	if (extended)
		scope_case(alternating, sizeof(alternating), PWMSTREAM_MAX_HZ,
			   "EXPERIMENTAL AAAAAAAA @ 100 Mbit/s: 10 ns high/low; nominal 50 MHz.");
}

static void lifecycle(void)
{
	const unsigned char bytes[] = {0xff, 0xff, 0, 0};
	struct pwmstream_status s;
	char owner[128];
	ssize_t length;
	int old_controller, old_observer;

	CHECK(geteuid() == 0);
	length = readlink("/sys/bus/platform/devices/3f20c000.pwm/driver",
			  owner, sizeof(owner) - 1);
	CHECK(length > 0 && length < (ssize_t)sizeof(owner) - 1);
	owner[length] = '\0';
	CHECK(strrchr(owner, '/') && !strcmp(strrchr(owner, '/') + 1, "pwmstream"));
	puts("LIFECYCLE: explicitly unbinding/rebinding PWM; output and device will disappear.");
	acquire();
	configure(4, 1000000);
	CHECK(write(controller, bytes, sizeof(bytes)) == (ssize_t)sizeof(bytes));
	CHECK(ioctl(controller, PWMSTREAM_START) == 0);
	wait_tick();
	/* Set before writing so interrupted unbind still attempts recovery. */
	needs_rebind = 1;
	CHECK(binding(0) == 0);
	ERROR(ioctl(observer, PWMSTREAM_STATUS, &s), ENODEV);
	ERROR(ioctl(controller, PWMSTREAM_STOP), ENODEV);
	ERROR(ioctl(controller, PWMSTREAM_START), ENODEV);
	ERROR(write(controller, bytes, sizeof(bytes)), ENODEV);
	CHECK(binding(1) == 0);
	needs_rebind = 0;
	/* A new binding must not revive descriptors belonging to the old one. */
	ERROR(ioctl(observer, PWMSTREAM_STATUS, &s), ENODEV);
	ERROR(ioctl(controller, PWMSTREAM_START), ENODEV);
	old_observer = observer;
	old_controller = controller;
	CHECK((observer = open(device, O_RDONLY | O_CLOEXEC)) >= 0);
	acquire();
	s = status();
	CHECK(s.sample_bytes == 0 && s.uploaded_bytes == 0);
	CHECK(!(s.flags & (PWMSTREAM_F_RUNNING | PWMSTREAM_F_COMPLETE |
			  PWMSTREAM_F_CONFIG_READY)));
	ERROR(ioctl(controller, PWMSTREAM_START), ENODATA);
	/* Closing stale descriptors must not stop the new controller. */
	configure(4, 1000000);
	CHECK(write(controller, bytes, sizeof(bytes)) == (ssize_t)sizeof(bytes));
	CHECK(ioctl(controller, PWMSTREAM_START) == 0);
	CHECK(close(old_controller) == 0);
	CHECK(close(old_observer) == 0);
	wait_tick();
	CHECK(ioctl(controller, PWMSTREAM_STOP) == 0);
	healthy(0);
}

int main(int argc, char **argv)
{
	struct sigaction sa = {0};
	int hardware = 0, scope_mode = 0, extended = 0, selftest = 0, lifecycle_mode = 0, i;

	(void)setvbuf(stdout, NULL, _IOLBF, 0);
	for (i = 1; i < argc; ++i) {
		if (!strcmp(argv[i], "--abi"))
			scope_mode = 0;
		else if (!strcmp(argv[i], "--scope"))
			scope_mode = 1;
		else if (!strcmp(argv[i], "--hardware"))
			hardware = 1;
		else if (!strcmp(argv[i], "--lifecycle"))
			lifecycle_mode = 1;
		else if (!strcmp(argv[i], "--extended100M"))
			extended = 1;
		else if (!strcmp(argv[i], "--selftest"))
			selftest = 1;
		else {
			fprintf(stderr, "Usage: %s [--abi|--scope|--lifecycle] [--hardware] [--extended100M] [--selftest]\n", argv[0]);
			return 2;
		}
	}
	if ((scope_mode && !hardware) || (extended && (!scope_mode || !hardware)) ||
	    (lifecycle_mode && (!hardware || scope_mode || extended)) ||
	    (selftest && (scope_mode || hardware || extended || lifecycle_mode))) {
		fprintf(stderr, "Scope/lifecycle require --hardware; lifecycle excludes scope/extended; selftest must stand alone\n");
		return 2;
	}
	if (selftest) {
		CHECK(PWMSTREAM_DEFAULT_HZ == 50000000U);
		CHECK(PWMSTREAM_MAX_HZ == 100000000U);
#ifdef __linux__
		CHECK(_IOC_SIZE(PWMSTREAM_CONFIG) == sizeof(struct pwmstream_config));
		CHECK(_IOC_SIZE(PWMSTREAM_RATE) == sizeof(struct pwmstream_rate));
		CHECK(_IOC_SIZE(PWMSTREAM_STATUS) == sizeof(struct pwmstream_status));
#else
		CHECK(IOCPARM_LEN(PWMSTREAM_CONFIG) == sizeof(struct pwmstream_config));
		CHECK(IOCPARM_LEN(PWMSTREAM_RATE) == sizeof(struct pwmstream_rate));
		CHECK(IOCPARM_LEN(PWMSTREAM_STATUS) == sizeof(struct pwmstream_status));
#endif
		puts("PASS: native ABI layout/encoding/constants only; no device opened.");
		return 0;
	}
#ifndef __linux__
	fprintf(stderr, "Runtime tests require native Linux ioctl encodings. Use --selftest on a non-Linux host.\n");
	return 2;
#endif
	CHECK(atexit(at_exit) == 0);
	sa.sa_handler = signal_handler;
	CHECK(sigemptyset(&sa.sa_mask) == 0);
	CHECK(sigaction(SIGINT, &sa, NULL) == 0);
	CHECK(sigaction(SIGTERM, &sa, NULL) == 0);
	CHECK(sigaction(SIGHUP, &sa, NULL) == 0);
	CHECK(sigaction(SIGPIPE, &sa, NULL) == 0);
	CHECK((observer = open(device, O_RDONLY | O_CLOEXEC)) >= 0);
	print_status(status());
	if (lifecycle_mode)
		lifecycle();
	else if (scope_mode)
		scope(extended);
	else if (hardware)
		abi_hardware();
	else
		puts("Read-only observer only; use --abi --hardware for mutating integration checks.");
	CHECK(cleanup() == 0);
	printf("PASS: %u software checks (%s); no automatic physical waveform verdict.\n",
	       checks, lifecycle_mode ? "unbind/rebind lifecycle" :
	       scope_mode ? "scope operator acknowledgements" :
	       hardware ? "hardware ABI" : "read-only ABI");
	return 0;
}
