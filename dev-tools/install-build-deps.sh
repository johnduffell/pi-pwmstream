#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# install-build-deps: installs everything `make check-all` needs on a Debian 13 arm64 machine: the
# build and lint packages, then the pinned kernel headers (via fetch-kernel-headers.sh --install).
# When to use: once when setting up a development machine. The devcontainer and CI run it too.
set -eu
cd "$(dirname "$0")/.."

if [ "$(id -u)" = 0 ]; then
	sudo=
else
	command -v sudo >/dev/null || { echo "Need root or sudo to install packages." >&2; exit 1; }
	sudo=sudo
fi
$sudo apt-get update
$sudo apt-get install -y --no-install-recommends \
	build-essential device-tree-compiler python3 kmod curl ca-certificates openssh-client \
	sparse shellcheck cppcheck dkms lintian
sh dev-tools/fetch-kernel-headers.sh --install
