#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
# All mocks/artifacts live under the project and are removed on exit.
work="$PWD/.harness-check-$$"
mkdir "$work"
trap 'rc=$?; if [[ -n ${runner:-} ]]; then kill -TERM "$runner" 2>/dev/null || true; wait "$runner" || true; fi; if ((rc)) && [[ -f $work/output ]]; then cat "$work/output" >&2; fi; rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
mkdir -p "$work/source/tests" "$work/source/dev-tools" "$work/bin"
cp Makefile pwmstream.c pwmstream.h pwmstream-cli.c pwmstream-overlay.dts \
    check-install.sh install-state.sh uninstall.sh README.md "$work/source/"
cp dev-tools/deploy.sh dev-tools/test.sh "$work/source/dev-tools/"
cp tests/base.dts tests/overlay.sh tests/preflight.sh tests/remote-build.sh \
    tests/pwmstream-test.c tests/harness.sh tests/install.sh "$work/source/tests/"
export MOCK_LOG="$work/commands" MOCK_STAGE="$work/remote-stage"
export PATH="$work/bin:$PATH"
cat > "$work/bin/ssh" <<'MOCK'
#!/bin/bash
set -eu
printf 'ssh %s\n' "$*" >> "$MOCK_LOG"
case "$2" in
    'sh -s -- '*)
        cat >/dev/null
        if [[ ${MOCK_BAD_PATH:-0} == 1 ]]; then
            echo "/bad path/'"
        else
            echo "$MOCK_STAGE"
        fi ;;
    *)
        [[ ${MOCK_FAIL_REMOTE:-0} != 1 ]] || exit 1
        if [[ $* == *'bash dev-tools/test.sh --abi --hardware'* ]]; then
            read -r input
            [[ $input == harness-input ]]
            [[ ${MOCK_FAIL_TEST:-0} != 1 ]]
        fi ;;
esac
MOCK
cat > "$work/bin/scp" <<'MOCK'
#!/bin/bash
printf 'scp %s\n' "$*" >> "$MOCK_LOG"
[[ ${MOCK_FAIL_COPY:-0} != 1 ]]
MOCK
chmod +x "$work/bin/ssh" "$work/bin/scp"
cd "$work/source"
reject() {
    if "$@" > "$work/output" 2>&1; then
        echo "Unexpected success: $*" >&2
        exit 1
    fi
}
bash dev-tools/deploy.sh > "$work/output" 2>&1
grep -q "remote-build.sh 'build'" "$MOCK_LOG"
! grep -q "remote-build.sh 'install'" "$MOCK_LOG"
! grep -q 'bash dev-tools/test.sh' "$MOCK_LOG"
! grep -Eq 'scp .*(\.ko|\.dSYM|pwmstream-cli |pwmstream-test )' "$MOCK_LOG"
grep -q 'scp tests/pwmstream-test.c ' "$MOCK_LOG"
bash dev-tools/deploy.sh --install-reload > "$work/output" 2>&1
grep -q "remote-build.sh 'install'" "$MOCK_LOG"
! grep -q 'bash dev-tools/test.sh' "$MOCK_LOG"
: > "$MOCK_LOG"
echo harness-input > "$work/input"
bash dev-tools/deploy.sh --install-reload --test < "$work/input" > "$work/output" 2>&1
grep -q "ssh -t .*sudo -n bash dev-tools/test.sh --abi --hardware && sudo -n bash dev-tools/test.sh --scope --hardware" "$MOCK_LOG"
[[ $(grep -c "remote-build.sh 'install'" "$MOCK_LOG") == 1 ]]
! grep -q 'dev-tools/test.sh --lifecycle' "$MOCK_LOG"
: > "$MOCK_LOG"
bash dev-tools/deploy.sh --install-reload --test --lifecycle < "$work/input" > "$work/output" 2>&1
grep -q 'dev-tools/test.sh --abi --hardware && sudo -n bash dev-tools/test.sh --lifecycle --hardware && sudo -n bash dev-tools/test.sh --scope --hardware' "$MOCK_LOG"
MOCK_FAIL_TEST=1 reject bash dev-tools/deploy.sh --install-reload --test < "$work/input"
MOCK_FAIL_TEST=1 reject bash dev-tools/deploy.sh --install-reload --test --lifecycle < "$work/input"
: > "$MOCK_LOG"
reject bash dev-tools/deploy.sh --test
reject bash dev-tools/deploy.sh --lifecycle
reject bash dev-tools/deploy.sh --install-reload --lifecycle
reject bash dev-tools/deploy.sh --host '-bad'
reject bash dev-tools/deploy.sh --destination '~/bad/../path'
reject bash dev-tools/deploy.sh --destination '~/bad path'
reject bash dev-tools/deploy.sh --host 'host;id'
reject bash dev-tools/deploy.sh --destination '$(id)'
reject bash dev-tools/deploy.sh --host
[[ ! -s $MOCK_LOG ]]
MOCK_BAD_PATH=1 reject bash dev-tools/deploy.sh
! grep -q '^scp ' "$MOCK_LOG"
: > "$MOCK_LOG"
MOCK_FAIL_COPY=1 reject bash dev-tools/deploy.sh --install-reload --test
! grep -q 'remote-build.sh' "$MOCK_LOG"
! grep -q 'bash dev-tools/test.sh' "$MOCK_LOG"
: > "$MOCK_LOG"
MOCK_FAIL_REMOTE=1 reject bash dev-tools/deploy.sh --install-reload --test
! grep -q 'bash dev-tools/test.sh' "$MOCK_LOG"
MOCK_FAIL_REMOTE=1 reject bash dev-tools/deploy.sh --install-reload --test --lifecycle
! grep -q 'bash dev-tools/test.sh' "$MOCK_LOG"
reject bash dev-tools/test.sh --scope
reject bash dev-tools/test.sh --extended100M
reject bash dev-tools/test.sh --lifecycle
reject bash dev-tools/test.sh --lifecycle --scope --hardware

# Exercise remote build/reload ordering without invoking real kernel tools/sudo.
cat > "$work/bin/tool" <<'MOCK'
#!/bin/bash
set -eu
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$MOCK_LOG"
case "$name" in
    uname)
        case "$1" in
            -s) echo Linux ;; -m) echo aarch64 ;;
            -r) echo 6.18.50+rpt-rpi-v8 ;; *) echo mock-kernel ;;
        esac ;;
    make)
        case "$*" in
            *kernelrelease*) echo 6.18.50+rpt-rpi-v8 ;;
            'module W=1') [[ ${MOCK_FAIL_BUILD:-0} != 1 ]] ;;
        esac ;;
    modinfo)
        case "$*" in
            *vermagic*) echo '6.18.50+rpt-rpi-v8 SMP preempt mod_unload aarch64' ;;
            *) echo mocked-srcversion ;;
        esac ;;
    sudo)
        case "$*" in
            '-n true') [[ ${MOCK_DENY_SUDO:-0} != 1 ]] ;;
            '-n modprobe -r pwmstream') exit 1 ;; # Ordinary busy removal.
        esac ;;
    *) : ;;
esac
MOCK
chmod +x "$work/bin/tool"
for tool in uname make modinfo sudo dpkg-query sha256sum readlink journalctl; do
    ln -s tool "$work/bin/$tool"
done
: > "$MOCK_LOG"
(
    command() {
        if [[ ${1:-} == -v && ${2:-} == modinfo ]]; then return 1; fi
        builtin command "$@"
    }
    export -f command
    reject bash tests/remote-build.sh build
    grep -q 'Missing modinfo' "$work/output"
    ! grep -q '^make ' "$MOCK_LOG"
    ! grep -q '^sudo ' "$MOCK_LOG"
)
: > "$MOCK_LOG"
bash tests/remote-build.sh build > "$work/output" 2>&1
grep -q '^make module W=1$' "$MOCK_LOG"
! grep -q '^sudo ' "$MOCK_LOG"
: > "$MOCK_LOG"
MOCK_DENY_SUDO=1 reject bash tests/remote-build.sh install
grep -q 'requires non-interactive sudo' "$work/output"
! grep -q '^make ' "$MOCK_LOG"
! grep -q '^sudo -n modprobe' "$MOCK_LOG"
: > "$MOCK_LOG"
MOCK_FAIL_BUILD=1 reject bash tests/remote-build.sh install
! grep -q '^sudo -n modprobe -r ' "$MOCK_LOG"
: > "$MOCK_LOG"
reject bash tests/remote-build.sh install
grep -q '^sudo -n modprobe -r pwmstream$' "$MOCK_LOG"
! grep -q 'modules_install' "$MOCK_LOG"
! grep -q '^sudo -n modprobe pwmstream$' "$MOCK_LOG"
! grep -q '^sudo -v' "$MOCK_LOG"

# A signal sent only to the runner must stop its own child, preserving stdin.
cat > pwmstream-test <<'MOCK'
#!/bin/bash
set -eu
trap 'echo native-stopped >> "$MOCK_LOG"; exit 143' TERM
read -r input
[[ $input == harness-input ]]
echo native-ready >> "$MOCK_LOG"
while :; do sleep 1; done
MOCK
chmod +x pwmstream-test
echo harness-input > "$work/input"
bash dev-tools/test.sh --abi --hardware < "$work/input" > "$work/output" 2>&1 &
runner=$!
for ((attempt = 0; attempt < 100; ++attempt)); do
    if grep -q '^native-ready$' "$MOCK_LOG"; then break; fi
    sleep 0.1
done
grep -q '^native-ready$' "$MOCK_LOG"
kill -TERM "$runner"
result=0
wait "$runner" || result=$?
runner=
[[ $result == 143 ]]
grep -q '^native-stopped$' "$MOCK_LOG"
echo "PASS: mocked deploy/test gates, failure propagation, remote test stdin, runner signal cleanup."
