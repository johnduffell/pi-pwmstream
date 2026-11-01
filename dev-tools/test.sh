#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
mode=--abi
hardware=
extended=
lifecycle=
while (($#)); do
    case "$1" in
        --abi|--scope) mode=$1 ;;
        --hardware) hardware=--hardware ;;
        --extended100M) extended=--extended100M ;;
        --lifecycle) lifecycle=--lifecycle ;;
        --help)
            echo "Usage: bash dev-tools/test.sh [--abi|--scope] [--hardware] [--extended100M] [--lifecycle]"
            echo "Default: read-only ABI observer. Scope/mutating ABI require --hardware."
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ -z $lifecycle || ( -n $hardware && $mode == --abi && -z $extended ) ]] ||
    { echo "--lifecycle requires --hardware and excludes scope/extended" >&2; exit 2; }
[[ $mode != --scope || -n $hardware ]] ||
    { echo "Scope requires --hardware" >&2; exit 2; }
[[ -z $extended || ( $mode == --scope && -n $hardware ) ]] ||
    { echo "--extended100M requires --scope --hardware" >&2; exit 2; }
[[ $(uname -s) == Linux && $(uname -m) == aarch64 &&
   $(uname -r) =~ ^6\.18\.([0-9]+)\+rpt-rpi-v8$ && ${BASH_REMATCH[1]} -ge 50 ]] ||
    { echo "Run on a supported Pi kernel (6.18.N+rpt-rpi-v8, N>=50)" >&2; exit 1; }
mkdir -p .harness-artifacts
log=".harness-artifacts/test-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir "$log"
child=
signal_code=0
interrupted() {
    signal_code=$1
    if [[ -n $child ]]; then
        trap '' INT TERM HUP
        # Only our own unreaped native child, never a name/group/process search.
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" || true
        child=
        exit "$signal_code"
    fi
}
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
trap 'interrupted 129' HUP
diagnostics() {
    rc=$?
    if ((rc)); then
        # No implicit privilege escalation. Invoke the whole runner with sudo
        # when administrator-only device/log access is intended.
        journalctl -k -n 60 --no-pager > "$log/kernel.log" 2>&1 || true
        echo "FAILED ($rc); report and kernel journal tail: $log" >&2
    fi
}
trap diagnostics EXIT
# Keep the runner in the foreground shell so a signal sent to the runner
# itself can be forwarded to its child. Process substitution does not own stdin.
exec > >(tee "$log/report.log") 2>&1
uname -a
if [[ -f SOURCES.sha256 ]]; then
    sha256sum -c SOURCES.sha256
else
    echo "No deployment manifest; identifying local sources:"
    sha256sum pwmstream.c pwmstream.h tests/pwmstream-test.c Makefile
fi
if [[ -f BUILD.sha256 ]]; then sha256sum -c BUILD.sha256; fi
make abi-test
sha256sum pwmstream-test
args=("$mode")
[[ -z $hardware ]] || args+=("$hardware")
[[ -z $extended ]] || args+=("$extended")
[[ -z $lifecycle ]] || args+=("$lifecycle")
((signal_code == 0)) || exit "$signal_code"
# Explicit stdin duplication preserves the interactive terminal for this
# background child even in a non-job-control shell.
./pwmstream-test "${args[@]}" <&0 &
child=$!
((signal_code == 0)) || interrupted "$signal_code"
result=0
wait "$child" || result=$?
child=
((result == 0)) || exit "$result"
echo "Report: $log/report.log"
