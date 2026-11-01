#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Read-only checks. No unbinding, clock changes, or hardware commands.
set -eu
fail=0
error() { printf 'ERROR: %s\n' "$*" >&2; fail=1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
case "${1:-}" in
	"") build_only=0; no_headers=0 ;;
	--build-only) build_only=1; no_headers=0 ;;
	--no-headers) build_only=0; no_headers=1 ;;
	*) echo "Usage: $0 [--build-only|--no-headers]" >&2; exit 2 ;;
esac

if [ "$(uname -s)" != Linux ]; then
	echo "Installation is supported only on the target Raspberry Pi Linux." >&2
	exit 1
fi
if [ ! -r /proc/device-tree/compatible ] ||
   ! tr '\000' '\n' < /proc/device-tree/compatible |
	grep -qx 'raspberrypi,3-model-b-plus'; then
	error "This initial driver is restricted to Raspberry Pi 3B+."
fi
if [ ! -r /proc/device-tree/compatible ] ||
   ! tr '\000' '\n' < /proc/device-tree/compatible | grep -qx 'brcm,bcm2837'; then
	error "Expected BCM2837 device-tree compatibility."
fi
if [ "$(uname -m)" != aarch64 ]; then
	error "The reviewed target is aarch64."
fi
release=$(uname -r)
patch=
case "$release" in
	6.18.*+rpt-rpi-v8)
		patch=${release#6.18.}
		patch=${patch%+rpt-rpi-v8}
		case "$patch" in '' | *[!0-9]*) patch= ;; esac ;;
esac
if [ -n "$patch" ] && [ "$patch" -ge 50 ] 2>/dev/null; then
	[ "$release" = 6.18.50+rpt-rpi-v8 ] ||
		warn "Kernel $release is in the supported 6.18.N (N>=50) range; last reviewed 6.18.50."
elif [ "${PWMSTREAM_ALLOW_UNREVIEWED:-}" = 1 ]; then
	warn "UNREVIEWED kernel $release: the module also needs allow_unreviewed=1; DMA, clock and pin assumptions are unverified."
else
	error "Supported kernels are 6.18.N+rpt-rpi-v8 with N>=50 (reviewed: 6.18.50). For anything else set PWMSTREAM_ALLOW_UNREVIEWED=1 here and allow_unreviewed=1 on the module, at your own risk."
fi
kdir=${KDIR:-/lib/modules/$release/build}
if [ "$no_headers" -eq 1 ]; then
	:
elif [ ! -f "$kdir/Makefile" ]; then
	error "Install matching kernel headers: missing $kdir/Makefile."
elif ! built=$(make -s -C "$kdir" kernelrelease); then
	error "Could not read headers' kernel release."
elif [ "$built" != "$release" ]; then
	error "Headers release $built differs from running kernel $release."
fi
if [ "$build_only" -eq 1 ]; then
	[ "$fail" -eq 0 ] || exit 1
	echo "Build identity/headers checks passed; ownership has NOT been checked. Do not enable hardware."
	exit 0
fi
for driver in /sys/bus/platform/drivers/bcm2835-pwm/*pwm*; do
	[ -L "$driver" ] || continue
	error "Standard PWM driver still owns $driver; remove its overlay and reboot first."
done
pwm=/sys/bus/platform/devices/3f20c000.pwm
if [ -L "$pwm/driver" ]; then
	owner=$(basename "$(readlink "$pwm/driver")")
	case "$owner" in
		bcm2835-pwm) error "Standard PWM driver owns $pwm; remove its overlay and reboot first." ;;
		pwmstream) ;;
		*) error "Unexpected PWM owner: $owner at $pwm; investigate." ;;
	esac
fi
dma=/sys/bus/platform/devices/3f007000.dma-controller
if [ ! -L "$dma/driver" ] ||
   [ "$(basename "$(readlink "$dma/driver")")" != bcm2835-dma ]; then
	error "Expected 3f007000.dma-controller bound to bcm2835-dma."
fi
if [ ! -r "$dma/of_node/compatible" ] ||
   ! tr '\000' '\n' < "$dma/of_node/compatible" | grep -qx 'brcm,bcm2835-dma'; then
	error "Expected DMA compatible brcm,bcm2835-dma."
fi
if [ -d /sys/module/snd_bcm2835 ]; then
	# A loaded module alone is harmless; analogue (PWM) audio output is not.
	headphones=$(cat /sys/module/snd_bcm2835/parameters/enable_headphones 2>/dev/null || echo unknown)
	if [ "$headphones" != N ]; then
		error "snd_bcm2835 is loaded with enable_headphones=$headphones; disable onboard analogue audio (dtparam=audio=off) and reboot."
	elif grep -qi headphones /proc/asound/cards 2>/dev/null; then
		error "An analogue Headphones sound card is registered; disable onboard analogue audio and reboot."
	else
		warn "snd_bcm2835 is loaded but analogue headphones are disabled and no such card exists; not treated as PWM ownership."
	fi
fi
for config in /boot/firmware/config.txt /boot/config.txt; do
	[ -r "$config" ] || continue
	echo "Review $config and all included files/model sections:"
	grep -nE '^[[:space:]]*(dtoverlay=.*(pwm|audremap|i2s|spi1)|dtparam=audio)' \
		"$config" || true
done
if command -v fuser >/dev/null 2>&1; then
	if fuser /dev/mem /dev/gpiomem >/dev/null 2>&1; then
		error "A process has /dev/mem or /dev/gpiomem open; investigate before installing."
	fi
else
	warn "fuser unavailable; independently check direct-register users."
fi
warn "Unprivileged checks cannot exclude all raw-memory, firmware, pin, or clock users."
warn "Explicitly stop pigpio/rpi_ws281x/old GUI and audit GPIO18, PWM audio, and included boot config."
warn "Do not install or test with an electrically unsafe load attached."
if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "Read-only checks passed; administrator review and physical validation are still required."
