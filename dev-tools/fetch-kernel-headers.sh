#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Download and verify the pinned Raspberry Pi kernel header packages.
# Default: download and verify only. --install also installs them with apt
# (administrator privileges); apt resolves Debian dependencies such as
# gcc-14-for-host. Does not touch the Pi, boot settings or hardware.
set -eu
install=0
case "${1:-}" in
	"") ;;
	--install) install=1 ;;
	*) echo "Usage: sh dev-tools/fetch-kernel-headers.sh [--install]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || exit 2
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pins=${KERNEL_PINS:-$here/kernels.txt}
cache=${HEADERS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pwmstream-kernel-headers}

[ "$(uname -s)" = Linux ] || { echo "Run on Linux." >&2; exit 1; }
[ "$(dpkg --print-architecture 2>/dev/null)" = arm64 ] ||
	{ echo "Pinned packages are arm64 Debian packages; an arm64 Debian host is required." >&2; exit 1; }
for tool in curl sha256sum; do
	command -v "$tool" >/dev/null || { echo "Missing $tool." >&2; exit 1; }
done

base=$(sed -n 's/^BASE=//p' "$pins")
release=$(sed -n 's/^RELEASE=//p' "$pins")
case "$base" in https://*) ;; *) echo "BASE must be an https URL." >&2; exit 1 ;; esac
[ -n "$release" ] || { echo "RELEASE missing from $pins." >&2; exit 1; }

mkdir -p "$cache"
debs=
while read -r sum path; do
	case "$sum" in
		""|\#*|*=*) continue ;;
	esac
	case "$sum$path" in
		*[!0-9a-zA-Z/._+:-]*) echo "Unsafe pin entry: $path" >&2; exit 1 ;;
	esac
	[ "${#sum}" -eq 64 ] || { echo "Bad SHA256 for $path." >&2; exit 1; }
	file=$cache/$(basename "$path")
	if ! { [ -f "$file" ] && printf '%s  %s\n' "$sum" "$file" | sha256sum -c --status; }; then
		echo "Downloading $(basename "$path")"
		curl -fsSL --retry 3 -o "$file.part" "$base/$path"
		mv "$file.part" "$file"
		printf '%s  %s\n' "$sum" "$file" | sha256sum -c --status ||
			{ rm -f "$file"; echo "SHA256 mismatch for $path; file discarded." >&2; exit 1; }
	fi
	debs="$debs $file"
done < "$pins"
[ -n "$debs" ] || { echo "No packages listed in $pins." >&2; exit 1; }
echo "Verified pinned packages for $release in $cache"

if [ "$install" -eq 1 ]; then
	if [ "$(id -u)" = 0 ]; then
		sudo=
	else
		command -v sudo >/dev/null || { echo "Need root or sudo to install." >&2; exit 1; }
		sudo=sudo
	fi
	# shellcheck disable=SC2086
	$sudo apt-get install -y --no-install-recommends $debs
	echo "Installed. Build check: make check-kbuild"
fi
