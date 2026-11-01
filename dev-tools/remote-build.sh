#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Runs on the Pi (copied there by deploy.sh): checks the kernel and headers, builds and tests the
# module, and with "install" replaces the loaded module. See docs/development.md.
set -euo pipefail
# Non-interactive SSH sessions may omit Debian's administrative tool paths.
export PATH="$PATH:/usr/sbin:/sbin"
[[ $# == 1 && ( $1 == build || $1 == install ) ]] || exit 2
action=$1
diagnostics() {
    rc=$?
    if ((rc)); then
        echo "Build/deployment failed ($rc); no further changes attempted." >&2
        if [[ $action == install ]]; then
            sudo -n journalctl -k -n 60 --no-pager || true
        else
            journalctl -k -n 60 --no-pager || true
        fi
    fi
}
trap diagnostics EXIT
command -v modinfo >/dev/null ||
    { echo "Missing modinfo: install the kmod package on the Pi, then retry." >&2; exit 1; }
if [[ $action == install ]]; then
    sudo -n true ||
        { echo "Install/reload requires non-interactive sudo access; no module changes attempted." >&2; exit 1; }
fi
sha256sum -c SOURCES.sha256
[[ $(uname -s) == Linux && $(uname -m) == aarch64 &&
   $(uname -r) =~ ^6\.18\.([0-9]+)\+rpt-rpi-v8$ && ${BASH_REMATCH[1]} -ge 50 ]] ||
    { echo "Expected aarch64 Linux 6.18.N+rpt-rpi-v8, N>=50" >&2; exit 1; }
KDIR="/lib/modules/$(uname -r)/build"
export KDIR
echo "Kernel: $(uname -a)"
echo "Kernel build source: $(readlink -f "$KDIR")"
echo "Kernel headers release: $(make -s -C "$KDIR" kernelrelease)"
[[ $(make -s -C "$KDIR" kernelrelease) == "$(uname -r)" ]]
dpkg-query -W -f='${Package} ${Version}\n' "linux-headers-$(uname -r)"
make check-build
make module W=1
make check check-overlay check-preflight check-install
[[ $(modinfo -F vermagic ./pwmstream.ko) == "$(uname -r) "* ]]
sha256sum pwmstream.ko pwmstream-cli pwmstream-test > BUILD.sha256
cat BUILD.sha256
echo "Built module source identifier: $(modinfo -F srcversion ./pwmstream.ko)"
if [[ -r /sys/module/pwmstream/srcversion ]]; then
    echo "Currently loaded source identifier: $(cat /sys/module/pwmstream/srcversion)"
fi
if [[ $action == build ]]; then
    echo "BUILD ONLY: installed module and device untouched."
    exit 0
fi
# No force, no process killing. Even idle observers prevent ordinary removal.
# The build and every validation above MUST succeed before this point.
echo "Explicit install/reload requested; close all controllers/observers first."
sudo -n modprobe -r pwmstream
sudo -n make -C "$KDIR" M="$PWD" modules_install
sudo -n depmod -a "$(uname -r)"
sudo -n modprobe pwmstream
[[ -c /dev/pwmstream0 ]]
if [[ -r /sys/module/pwmstream/srcversion ]]; then
    built_source=$(modinfo -F srcversion ./pwmstream.ko)
    loaded_source=$(cat /sys/module/pwmstream/srcversion)
    echo "Reloaded source identifier: $loaded_source"
    [[ -n $built_source && $built_source == "$loaded_source" ]] ||
        { echo "Loaded module source identifier differs from this build" >&2; exit 1; }
else
    echo "Loaded kernel does not expose srcversion; loaded-source identity unverified."
fi
echo "Reloaded module; no waveform started. Overlay and boot files untouched."
