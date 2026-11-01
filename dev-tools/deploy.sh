#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "Usage: bash dev-tools/deploy.sh [--host user@raspberrypi] [--destination ~/code/pi-pwmstream] [--install-reload [--test [--lifecycle]]]"
    echo "Default: copy explicit sources to a fresh directory and build only. No tests emit output."
    echo "--test: after install/reload, run hardware ABI then interactive scope tests remotely; emits waves."
    echo "--lifecycle: with --test, also unbind/rebind with open descriptors before scope tests."
}
host=user@raspberrypi
destination='~/code/pi-pwmstream'
action=build
run_tests=0
lifecycle=0
while (($#)); do
    case "$1" in
        --host|--destination)
            (($# >= 2)) || { usage >&2; exit 2; }
            case "$1" in --host) host=$2 ;; *) destination=$2 ;; esac
            shift 2 ;;
        --install-reload) action=install; shift ;;
        --test) run_tests=1; shift ;;
        --lifecycle) lifecycle=1; shift ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ $run_tests == 0 || $action == install ]] ||
    { echo "--test requires --install-reload; hardware tests emit output." >&2; exit 2; }
[[ $lifecycle == 0 || $run_tests == 1 ]] ||
    { echo "--lifecycle requires --install-reload --test" >&2; exit 2; }
# Deliberately support only simple SSH names and space-free absolute or ~/ paths.
# All values embedded in remote commands must also be safe single-quoted literals.
[[ $host != -* && $host != *[!a-zA-Z0-9_.@-]* && -n $host ]] ||
    { echo "Unsupported SSH host" >&2; exit 2; }
safe_path() {
    [[ -n $1 && $1 != *[!a-zA-Z0-9_./~-]* &&
       $1 != *'/../'* && $1 != */.. && $1 != *'/./'* &&
       $1 != */. && $1 != / && $1 != '~/' &&
       ( $1 == /* || $1 == '~/'* ) ]]
}
safe_path "$destination" || { echo "Unsupported destination path" >&2; exit 2; }
id="build-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p .harness-artifacts
mkdir ".harness-artifacts/$id"
artifacts="$PWD/.harness-artifacts/$id"
sources=(Makefile pwmstream.c pwmstream.h pwmstream-cli.c pwmstream-overlay.dts
    check-install.sh install-state.sh uninstall.sh README.md dev-tools/deploy.sh dev-tools/test.sh
    tests/base.dts tests/overlay.sh tests/preflight.sh tests/remote-build.sh
    tests/pwmstream-test.c tests/harness.sh tests/install.sh)
if command -v shasum >/dev/null; then
    shasum -a 256 "${sources[@]}" > "$artifacts/SOURCES.sha256"
elif command -v sha256sum >/dev/null; then
    sha256sum "${sources[@]}" > "$artifacts/SOURCES.sha256"
else
    echo "Need existing shasum or sha256sum; no dependencies installed" >&2
    exit 1
fi
create_stage() {
    # Keep the heredoc outside $(...) for macOS Bash 3.2 parsing.
    ssh "$host" "sh -s -- '$destination' '$id'" <<'REMOTE'
set -eu
case "$1" in '~/'*) base="$HOME/${1#\~/}" ;; *) base=$1 ;; esac
stage="$base/runs/$2"
case "$stage" in *[!a-zA-Z0-9_./-]*) echo "Unsupported remote HOME/path" >&2; exit 2 ;; esac
mkdir -p "$base/runs"
mkdir "$stage"
mkdir "$stage/tests" "$stage/dev-tools"
printf '%s\n' "$stage"
REMOTE
}
deploy() {
    # Resolve ~ using the remote HOME, not the Mac user's home.
    remote=$(create_stage)
    safe_path "$remote" && [[ $remote == /* ]] ||
        { echo "Invalid remote staging response" >&2; return 1; }
    echo "Remote source/build directory: $remote"
    for source in "${sources[@]}"; do
        scp "$source" "$host:$remote/$source"
    done
    scp "$artifacts/SOURCES.sha256" "$host:$remote/SOURCES.sha256"
    if [[ $action == install ]]; then
        ssh -t "$host" "cd '$remote' && bash tests/remote-build.sh '$action'"
    else
        ssh "$host" "cd '$remote' && bash tests/remote-build.sh '$action'"
    fi
    echo "Sources and build retained: $host:$remote"
    if [[ $run_tests == 1 ]]; then
        echo "Explicit hardware tests requested: ABI, then interactive scope. Output will be emitted."
        lifecycle_command=
        if [[ $lifecycle == 1 ]]; then
            echo "Lifecycle opt-in: driver will be unbound/rebound with open descriptors."
            lifecycle_command=" && sudo -n bash dev-tools/test.sh --lifecycle --hardware"
        fi
        ssh -t "$host" "cd '$remote' && sudo -n bash dev-tools/test.sh --abi --hardware$lifecycle_command && sudo -n bash dev-tools/test.sh --scope --hardware"
    else
        echo "Next (interactive, not run by deployment):"
        echo "  ssh -t $host \"cd '$remote' && bash dev-tools/test.sh --abi\""
        echo "  ssh -t $host \"cd '$remote' && sudo -n bash dev-tools/test.sh --abi --hardware\""
        echo "  ssh -t $host \"cd '$remote' && sudo -n bash dev-tools/test.sh --scope --hardware\""
    fi
}
echo "Local manifest/logs: $artifacts"
deploy 2>&1 | tee "$artifacts/deploy.log"
