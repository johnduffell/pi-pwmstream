#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build the module against the pinned installed headers in a scratch copy and
# verify its identity. Hardware-free: no load, no device access, no install.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release=$(sed -n 's/^RELEASE=//p' "$here/dev-tools/kernels.txt")
kdir=${KDIR:-/usr/src/linux-headers-$release}

if [ ! -f "$kdir/Makefile" ]; then
	echo "Missing headers $kdir; run: sh dev-tools/fetch-kernel-headers.sh --install" >&2
	exit 1
fi
built=$(make -s -C "$kdir" kernelrelease)
[ "$built" = "$release" ] ||
	{ echo "Headers release $built differs from pinned $release." >&2; exit 1; }

# Kernel was built by this compiler; a different one risks an incompatible module.
kernel_cc=$(sed -n 's/^#define CONFIG_CC_VERSION_TEXT "\(.*\)"$/\1/p' "$kdir/include/generated/autoconf.h")
kernel_cc=${kernel_cc#*(}
local_cc=$(${CC_FOR_MODULE:-gcc} --version | head -n 1)
local_cc=${local_cc#*(}
[ -n "$kernel_cc" ] && [ "$kernel_cc" = "$local_cc" ] ||
	{ echo "Compiler differs from the kernel's: kernel '$kernel_cc', local '$local_cc'." >&2
	  echo "Image drift: pin or install the matching gcc before trusting a module build." >&2
	  exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cp "$here/Makefile" "$here/pwmstream.c" "$here/pwmstream.h" "$work/"
make -C "$work" module W=1 KDIR="$kdir" >"$work/build.log" 2>&1 ||
	{ cat "$work/build.log" >&2; echo "Module build failed." >&2; exit 1; }
if grep -qi 'warning' "$work/build.log"; then
	cat "$work/build.log" >&2
	echo "Module build produced warnings." >&2
	exit 1
fi

vermagic=$(modinfo -F vermagic "$work/pwmstream.ko")
case "$vermagic" in
	"$release SMP preempt mod_unload modversions aarch64") ;;
	*) echo "Unexpected vermagic: $vermagic" >&2; exit 1 ;;
esac
echo "Module builds against $release: vermagic OK, srcversion $(modinfo -F srcversion "$work/pwmstream.ko")"
echo "Compare with 'modinfo -F srcversion pwmstream' on the Pi after deployment; not a hardware test."
