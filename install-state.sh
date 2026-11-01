#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Read-only inventory of the pwmstream installation on the running Pi.
# No sudo, unbinding, module (un)loading or device access. Output is stable
# so snapshots taken before/after a step can be compared with diff.
# Override BOOT_DIR to inspect a non-default firmware directory.
set -u
PATH="$PATH:/usr/sbin:/sbin"
release=$(uname -r)
hash_of() { sha256sum "$1" 2>/dev/null | cut -d ' ' -f 1; }

echo "== kernel =="
echo "release: $release"
echo "machine: $(uname -m)"
if [ -r /proc/device-tree/model ]; then
	echo "model: $(tr -d '\000' < /proc/device-tree/model)"
fi

echo "== package =="
echo "pwmstream package: $(dpkg-query -W -f '${Version}' pwmstream 2>/dev/null || echo 'not installed')"
if command -v dkms >/dev/null 2>&1; then
	dkms status 2>/dev/null | grep pwmstream || echo "dkms: no pwmstream entries"
else
	echo "dkms: not installed"
fi

echo "== module files in /lib/modules/$release =="
found=0
for f in $(find "/lib/modules/$release" -name 'pwmstream.ko*' 2>/dev/null | sort); do
	found=1
	echo "file: $f"
	echo "  sha256: $(hash_of "$f")"
	echo "  srcversion: $(modinfo -F srcversion "$f" 2>/dev/null || echo unreadable)"
	echo "  vermagic: $(modinfo -F vermagic "$f" 2>/dev/null || echo unreadable)"
done
[ "$found" -eq 1 ] || echo "none"
echo "modprobe resolves: $(modinfo -n pwmstream 2>/dev/null || echo none)"
other=$(find /lib/modules -name 'pwmstream.ko*' -not -path "/lib/modules/$release/*" 2>/dev/null | sort)
echo "other kernels' copies: ${other:-none}"

echo "== loaded state =="
if [ -d /sys/module/pwmstream ]; then
	echo "loaded: yes"
	echo "  srcversion: $(cat /sys/module/pwmstream/srcversion 2>/dev/null || echo unreadable)"
	echo "  refcnt: $(cat /sys/module/pwmstream/refcnt 2>/dev/null || echo unreadable)"
else
	echo "loaded: no"
fi
if [ -c /dev/pwmstream0 ]; then
	echo "device node: /dev/pwmstream0 present ($(stat -c '%U:%G %a' /dev/pwmstream0))"
else
	echo "device node: absent"
fi
if [ -d /sys/module/snd_bcm2835 ]; then
	echo "snd_bcm2835: loaded (enable_headphones=$(cat /sys/module/snd_bcm2835/parameters/enable_headphones 2>/dev/null || echo unknown))"
else
	echo "snd_bcm2835: not loaded"
fi
echo "sound cards: $(cat /proc/asound/cards 2>/dev/null | tr '\n' ' ' | tr -s ' ')"

echo "== PWM binding =="
pwm=/sys/bus/platform/devices/3f20c000.pwm
if [ -e "$pwm" ]; then
	if [ -L "$pwm/driver" ]; then
		echo "3f20c000.pwm driver: $(basename "$(readlink "$pwm/driver")")"
	else
		echo "3f20c000.pwm driver: unbound"
	fi
	if [ -r "$pwm/of_node/compatible" ]; then
		echo "3f20c000.pwm compatible: $(tr '\000' ' ' < "$pwm/of_node/compatible")"
	fi
else
	echo "3f20c000.pwm: not present"
fi

echo "== boot overlay and boot configuration =="
boot=${BOOT_DIR:-}
if [ -z "$boot" ]; then
	if [ -d /boot/firmware ]; then boot=/boot/firmware; else boot=/boot; fi
fi
echo "boot directory: $boot"
dtbo=$boot/overlays/pwmstream.dtbo
if [ -f "$dtbo" ]; then
	echo "overlay: $dtbo sha256 $(hash_of "$dtbo")"
else
	echo "overlay: absent ($dtbo)"
fi
config=$boot/config.txt
if [ -r "$config" ]; then
	echo "$config relevant lines (includes/model sections not followed):"
	grep -nE '^[[:space:]]*(dtoverlay|dtparam=audio|include)' "$config" || echo "  none"
	echo "$config sha256: $(hash_of "$config")"
else
	echo "$config: unreadable or absent"
fi

echo "== installed CLI =="
found=0
for cli in /usr/bin/pwmstream-cli /usr/local/bin/pwmstream-cli; do
	if [ -f "$cli" ]; then
		found=1
		echo "cli: $cli sha256 $(hash_of "$cli")"
	fi
done
[ "$found" -eq 1 ] || echo "cli: absent"
