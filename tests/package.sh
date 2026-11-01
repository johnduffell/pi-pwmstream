#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Hardware-free package checks: deb contents, lintian, unprivileged DKMS build
# against the pinned headers, the supported-range matrix, and pwmstream-enable.
set -euo pipefail
cd "$(dirname "$0")/.."
release=6.18.50+rpt-rpi-v8
kdir=${KDIR:-/lib/modules/$release/build}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
checks=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); }

deb=$(sh packaging/build-deb.sh "$work/out")
[ -f "$deb" ] || fail "no deb built"
dpkg-deb -x "$deb" "$work/root"
dpkg-deb -e "$deb" "$work/ctl"
ok

for f in usr/bin/pwmstream-cli usr/bin/pwmstream-report usr/sbin/pwmstream-enable usr/lib/pwmstream/preflight \
	usr/share/pwmstream/pwmstream.dtbo usr/src/pwmstream-"$(cat VERSION)"/{pwmstream.c,pwmstream.h,Kbuild,dkms.conf} \
	usr/share/doc/pwmstream/copyright usr/share/doc/pwmstream/usage.md etc/kernel/postinst.d/zz-pwmstream \
	usr/lib/udev/rules.d/60-pwmstream.rules; do
	[ -e "$work/root/$f" ] || fail "package lacks $f"
	ok
done
grep -q '^SUBSYSTEM=="misc", KERNEL=="pwmstream0", GROUP="gpio", MODE="0660"$' \
	"$work/root/usr/lib/udev/rules.d/60-pwmstream.rules" || fail "udev rule content"
ok
[ "$(dpkg-deb -f "$deb" Architecture)" = arm64 ] || fail "architecture"
dpkg-deb -f "$deb" Depends | grep -q 'dkms (>= 3.0)' || fail "dkms dependency"
for s in postinst prerm postrm; do
	sh -n "$work/ctl/$s" || fail "$s syntax"
	grep -q '@VERSION@' "$work/ctl/$s" && fail "$s has unsubstituted version"
	ok
done
grep -q '@VERSION@' "$work/root/usr/src/pwmstream-$(cat VERSION)/dkms.conf" && fail "dkms.conf version"
if command -v lintian >/dev/null; then
	lintian --fail-on error "$deb" >/dev/null || { lintian "$deb" >&2; fail "lintian errors"; }
	ok
fi

# Reproducible build.
second=$(sh packaging/build-deb.sh "$work/out2")
cmp -s "$deb" "$second" || fail "package build is not reproducible"
ok

# DKMS: build in scratch trees against the pinned headers; no root, no install.
src="$work/root/usr/src"
dk=(--dkmstree "$work/tree" --sourcetree "$src" --installtree "$work/inst")
mkdir -p "$work/tree" "$work/inst"
dkms "${dk[@]}" add -m pwmstream -v "$(cat VERSION)" >/dev/null
dkms "${dk[@]}" build -m pwmstream -v "$(cat VERSION)" -k "$release" --kernelsourcedir "$kdir" >/dev/null
ko=$(find "$work/tree" -name 'pwmstream.ko*' | head -1)
[ -n "$ko" ] || fail "DKMS produced no module"
modinfo -F vermagic "$ko" | grep -q "^$release " || fail "DKMS vermagic"
ok
if [ -f pwmstream.ko ]; then
	[ "$(modinfo -F srcversion "$ko")" = "$(modinfo -F srcversion ./pwmstream.ko)" ] ||
		fail "DKMS srcversion differs from the in-tree build"
	ok
fi

# Supported-range matrix: DKMS must skip (77) rather than fail unsupported kernels,
# and the kernel hook must warn for exactly the same set. In-range kernels pass the
# exclusion test and then stop at the missing headers (21).
for k in 6.18.50+rpt-rpi-v8 6.18.51+rpt-rpi-v8 6.18.99+rpt-rpi-v8 6.18.100+rpt-rpi-v8 6.18.250+rpt-rpi-v8 \
	6.18.49+rpt-rpi-v8 6.18.5+rpt-rpi-v8 6.18.0+rpt-rpi-v8 6.19.0+rpt-rpi-v8 6.12.62+rpt-rpi-v8 \
	6.18.50+rpt-rpi-2712 6.18.50 6.18.5x+rpt-rpi-v8 6.18.60+rpt-rpi-v8-extra; do
	case $k in
	6.18.50+rpt-rpi-v8 | 6.18.51+rpt-rpi-v8 | 6.18.99+rpt-rpi-v8 | 6.18.100+rpt-rpi-v8 | 6.18.250+rpt-rpi-v8) want_in=1 ;;
	*) want_in=0 ;;
	esac
	if [ "$k" = "$release" ]; then
		rc=0
	else
		dkms "${dk[@]}" build -m pwmstream -v "$(cat VERSION)" -k "$k" >/dev/null 2>&1 && rc=0 || rc=$?
	fi
	if [ "$want_in" -eq 1 ]; then
		[ "$rc" -ne 77 ] || fail "DKMS excluded supported kernel $k"
	else
		[ "$rc" -eq 77 ] || fail "DKMS did not skip unsupported kernel $k (rc=$rc)"
	fi
	hook=$("$work/root/etc/kernel/postinst.d/zz-pwmstream" "$k" 2>&1 >/dev/null) || fail "hook failed the kernel install for $k"
	if [ "$want_in" -eq 1 ]; then
		[ -z "$hook" ] || fail "hook warned for supported kernel $k"
	else
		case $k in
		*rpt-rpi-v8 | *2712) [ -n "$hook" ] || fail "hook silent for unsupported kernel $k" ;;
		esac
	fi
	ok
done

# pwmstream-enable against a fake firmware directory and stub preflight.
enable="$work/root/usr/sbin/pwmstream-enable"
fake="$work/boot"
mkdir -p "$fake/overlays" "$work/lib" "$work/stubs"
printf '#!/bin/sh\nexit 0\n' > "$work/lib/preflight"
printf '#!/bin/sh\necho /stub\n' > "$work/stubs/modinfo"
chmod +x "$work/lib/preflight" "$work/stubs/modinfo"
export PWMSTREAM_BOOT_DIR="$fake" PWMSTREAM_LIBDIR="$work/lib" PWMSTREAM_SHAREDIR="$work/root/usr/share/pwmstream" PWMSTREAM_MODINFO="$work/stubs/modinfo"
printf 'dtparam=audio=off\ndtoverlay=vc4-kms-v3d\n' > "$fake/config.txt"
before=$(sha256sum < "$fake/config.txt")
"$enable" --dry-run >/dev/null
[ "$before" = "$(sha256sum < "$fake/config.txt")" ] || fail "dry-run changed config.txt"
[ ! -e "$fake/overlays/pwmstream.dtbo" ] || fail "dry-run installed the overlay"
ok
"$enable" >/dev/null
grep -q '^dtoverlay=pwmstream$' "$fake/config.txt" || fail "enable did not add the overlay"
cmp -s "$fake/overlays/pwmstream.dtbo" "$work/root/usr/share/pwmstream/pwmstream.dtbo" || fail "overlay not installed"
ls "$fake"/config.txt.pwmstream-*.bak >/dev/null || fail "no backup"
ok
"$enable" >/dev/null
[ "$(grep -c '^dtoverlay=pwmstream$' "$fake/config.txt")" -eq 1 ] || fail "enable is not idempotent"
ok
"$enable" --disable >/dev/null
grep -q '^dtoverlay=pwmstream' "$fake/config.txt" && fail "disable left the overlay active"
grep -q 'dtoverlay=vc4-kms-v3d' "$fake/config.txt" || fail "disable damaged other lines"
ok
for bad in 'dtparam=audio=on' 'dtoverlay=pwm,pin=18' 'dtoverlay=audremap'; do
	printf 'dtparam=audio=off\n%s\n' "$bad" > "$fake/config.txt"
	if "$enable" >/dev/null 2>&1; then fail "enable accepted conflicting $bad"; fi
	grep -q '^dtoverlay=pwmstream' "$fake/config.txt" && fail "enable edited config despite $bad"
	ok
done

# postrm keeps the overlay while config.txt enables it (also via a /boot alias) and removes it otherwise.
postrm="$work/ctl/postrm"
mkdir -p "$work/alias"
ln -s "$fake/overlays" "$work/alias/overlays"
printf 'dtoverlay=pwmstream\n' > "$fake/config.txt"
echo x > "$fake/overlays/pwmstream.dtbo"
PWMSTREAM_BOOT_DIR="$fake" sh "$postrm" remove 2>/dev/null
[ -f "$fake/overlays/pwmstream.dtbo" ] || fail "postrm removed an enabled overlay"
ok
PWMSTREAM_BOOT_DIR="$work/alias" sh "$postrm" remove 2>/dev/null
[ -f "$fake/overlays/pwmstream.dtbo" ] || fail "postrm removed the overlay through an unreadable-config alias"
ok
printf 'dtparam=audio=off\n' > "$fake/config.txt"
PWMSTREAM_BOOT_DIR="$fake" sh "$postrm" purge 2>/dev/null
[ ! -e "$fake/overlays/pwmstream.dtbo" ] || fail "postrm kept an unreferenced overlay"
ok
echo "PASS: $checks package checks."
