#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Manual-install removal: previews by default, --remove deletes the module, CLI and overlay for the
# running kernel. Does not touch DKMS or package files.
set -eu
remove=0
case "${1:-}" in
	"") ;;
	--remove) remove=1 ;;
	*) echo "Usage: sh uninstall.sh [--remove] (default: preview only)" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || exit 2
[ "$(uname -s)" = Linux ] || { echo "Run on the target Pi Linux." >&2; exit 1; }
release=$(uname -r)
case "$release" in
	""|*[!a-zA-Z0-9._+-]*) echo "Unsupported kernel release path" >&2; exit 1 ;;
esac
overlays=${BOOT_OVERLAYS:-/boot/firmware/overlays}
case "$overlays" in
	/boot/firmware/overlays|/boot/overlays) ;;
	*) echo "BOOT_OVERLAYS must be /boot/firmware/overlays or /boot/overlays" >&2; exit 1 ;;
esac
if [ "$remove" -eq 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "Removal requires administrator privileges." >&2; exit 1; }
	command -v depmod >/dev/null ||
		{ echo "Missing depmod; install kmod before removal." >&2; exit 1; }
	[ ! -d /sys/module/pwmstream ] ||
		{ echo "pwmstream is loaded; close clients and unload normally before removal." >&2; exit 1; }
	compatible=/sys/bus/platform/devices/3f20c000.pwm/of_node/compatible
	if [ -r "$compatible" ] && tr '\000' '\n' < "$compatible" | grep -qx 'pwmstream,bcm2837-pwmstream'; then
		echo "Boot overlay is active; remove dtoverlay=pwmstream from boot configuration and reboot first." >&2
		exit 1
	fi
fi
# Only exact filenames installed by this project; no directory deletion.
for file in \
	"/lib/modules/$release/updates/pwmstream.ko" \
	"/lib/modules/$release/updates/pwmstream.ko.xz" \
	"/lib/modules/$release/updates/pwmstream.ko.zst" \
	"/lib/modules/$release/updates/pwmstream.ko.gz" \
	"/lib/modules/$release/extra/pwmstream.ko" \
	"/lib/modules/$release/extra/pwmstream.ko.xz" \
	"/lib/modules/$release/extra/pwmstream.ko.zst" \
	"/lib/modules/$release/extra/pwmstream.ko.gz" \
	"$overlays/pwmstream.dtbo" /usr/local/bin/pwmstream-cli
do
	if [ -e "$file" ] || [ -L "$file" ]; then
		[ ! -d "$file" ] || { echo "Refusing directory: $file" >&2; exit 1; }
		printf 'Remove: %s\n' "$file"
		if [ "$remove" -eq 1 ]; then rm -- "$file"; fi
	fi
done
if [ "$remove" -eq 1 ]; then
	depmod -a "$release"
	echo "Removed current-kernel project files; boot configuration and user/group rules unchanged."
else
	echo "Preview only. Remove boot overlay and reboot, then use --remove as administrator."
fi
