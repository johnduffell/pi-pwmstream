#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build pwmstream_<version>_arm64.deb with plain dpkg-deb. Usage: build-deb.sh [outdir]
# Needs a built pwmstream-cli and pwmstream.dtbo (make cli overlay); no kernel headers.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
out=${1:-$root/dist}
version=$(cat "$root/VERSION")
epoch=${SOURCE_DATE_EPOCH:-1767225600}
export SOURCE_DATE_EPOCH="$epoch"
pkg=pwmstream
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"
for f in pwmstream-cli pwmstream.dtbo; do
	[ -f "$root/$f" ] || { echo "Missing $f; run: make cli overlay" >&2; exit 1; }
done
install -d "$stage/DEBIAN" "$stage/usr/src/$pkg-$version" "$stage/usr/bin" "$stage/usr/sbin" \
	"$stage/usr/lib/$pkg" "$stage/usr/share/$pkg" "$stage/usr/share/doc/$pkg" \
	"$stage/etc/kernel/postinst.d" "$stage/usr/lib/udev/rules.d"
install -m 0644 "$root/pwmstream.c" "$root/pwmstream.h" "$here/Kbuild" "$stage/usr/src/$pkg-$version/"
sed "s/@VERSION@/$version/" "$here/dkms.conf.in" > "$stage/usr/src/$pkg-$version/dkms.conf"
chmod 0644 "$stage/usr/src/$pkg-$version/dkms.conf"
install -m 0755 -s "$root/pwmstream-cli" "$stage/usr/bin/pwmstream-cli"
install -m 0755 "$root/pwmstream-report.sh" "$stage/usr/bin/pwmstream-report"
install -m 0755 "$here/pwmstream-enable" "$stage/usr/sbin/pwmstream-enable"
install -m 0755 "$root/preflight.sh" "$stage/usr/lib/$pkg/preflight"
install -m 0644 "$root/pwmstream.dtbo" "$stage/usr/share/$pkg/pwmstream.dtbo"
install -m 0644 "$here/60-pwmstream.rules" "$stage/usr/lib/udev/rules.d/60-pwmstream.rules"
install -m 0755 "$here/kernel-hook" "$stage/etc/kernel/postinst.d/zz-pwmstream"
echo /etc/kernel/postinst.d/zz-pwmstream > "$stage/DEBIAN/conffiles"
install -m 0644 "$root/README.md" "$root/docs/usage.md" "$stage/usr/share/doc/$pkg/"
install -m 0644 "$here/copyright" "$stage/usr/share/doc/$pkg/copyright"
printf '%s (%s) stable; urgency=low\n\n  * Release %s.\n\n -- %s  %s\n' \
	"$pkg" "$version" "$version" "John Duffell <noreply@users.noreply.github.com>" \
	"$(date -u -d "@$epoch" '+%a, %d %b %Y %H:%M:%S +0000')" | gzip -9n > "$stage/usr/share/doc/$pkg/changelog.gz"
for s in postinst prerm postrm; do
	sed "s/@VERSION@/$version/g" "$here/$s" > "$stage/DEBIAN/$s"
	chmod 0755 "$stage/DEBIAN/$s"
done
size=$(du -sk --exclude=DEBIAN "$stage" | cut -f1)
cat > "$stage/DEBIAN/control" <<CTL
Package: $pkg
Version: $version
Architecture: arm64
Maintainer: John Duffell <noreply@users.noreply.github.com>
Installed-Size: $size
Depends: libc6, dkms (>= 3.0), kmod, linux-headers-rpi-v8 | raspberrypi-kernel-headers
Section: kernel
Priority: optional
Homepage: https://github.com/johnduffell/pi-pwmstream
Description: PWM/DMA bitstream output driver for Raspberry Pi 3 (DKMS)
 Streams a user-supplied bit pattern out of GPIO18 (PWM0) using DMA at up to
 50 Mbit/s. Supports Raspberry Pi OS kernels 6.18.N+rpt-rpi-v8 (N >= 50) on
 the Pi 3B+ only. The module is built by DKMS for each installed kernel.
 Nothing is enabled by installing this package: run pwmstream-enable
 explicitly, then reboot.
CTL
find "$stage" -exec touch -h -d "@$epoch" {} +
mkdir -p "$out"
dpkg-deb --build --root-owner-group -Zxz "$stage" "$out/${pkg}_${version}_arm64.deb" >/dev/null
echo "$out/${pkg}_${version}_arm64.deb"
