#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Hardware-free static analysis: sparse on the module (pinned headers), shellcheck,
# gcc -fanalyzer and cppcheck on the userspace C. No Pi, load or install.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$here"
release=$(sed -n 's/^RELEASE=//p' dev-tools/kernels.txt)
kdir=${KDIR:-/usr/src/linux-headers-$release}

missing=
for tool in gcc sparse shellcheck cppcheck; do
	command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
	echo "Missing tools:$missing (sudo apt-get install -y sparse shellcheck cppcheck)" >&2
	exit 1
fi
[ -f "$kdir/Makefile" ] ||
	{ echo "Missing headers $kdir; run: sh dev-tools/fetch-kernel-headers.sh --install" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

echo "sparse (kernel module, W=1 C=2)"
cp Makefile pwmstream.c pwmstream.h "$work/"
make -C "$kdir" M="$work" C=2 W=1 modules >"$work/sparse.log" 2>&1 ||
	{ cat "$work/sparse.log" >&2; echo "Module build failed." >&2; exit 1; }
if grep -Ei 'warning|error' "$work/sparse.log" >&2; then
	echo "sparse/compiler findings above." >&2
	exit 1
fi

echo "shellcheck"
shellcheck -S warning ./*.sh tests/*.sh packaging/build-deb.sh packaging/pwmstream-enable packaging/kernel-hook packaging/postinst packaging/prerm packaging/postrm

echo "gcc -fanalyzer (userspace C)"
for src in pwmstream-cli.c tests/pwmstream-test.c; do
	# The test client's fd-leak report is a known false positive: its ERROR()
	# macro expects open() to fail and fail() exits if it succeeds.
	extra=
	[ "$src" != tests/pwmstream-test.c ] || extra=-Wno-analyzer-fd-leak
	# shellcheck disable=SC2086
	gcc -std=c11 -O2 -Wall -Wextra -Werror -fanalyzer $extra -I. -c "$src" -o /dev/null
done

echo "cppcheck (userspace C)"
cppcheck --enable=warning,performance,portability --error-exitcode=1 --quiet --suppress=normalCheckLevelMaxBranches -I. \
	pwmstream-cli.c tests/pwmstream-test.c
echo "Static analysis passed. This does not replace hardware or lockdep/KASAN testing."
