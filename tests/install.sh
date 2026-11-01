#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Checks that make install/uninstall gate before writing anything, using mock files and a mock
# preflight. Never touches the host.
set -eu
work="$PWD/.install-check-$$"
mkdir "$work"
# rc is assigned inside the trap string.
# shellcheck disable=SC2154
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ -f "$work/output" ]; then cat "$work/output" >&2; fi; rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/headers" "$work/overlays"
cp Makefile "$work/Makefile"
sed -e "s|/lib/modules/|$work/lib/modules/|g" \
	-e "s|/boot/|$work/boot/|g" -e "s|/usr/local/|$work/usr/local/|g" \
	-e "s|/sys/|$work/sys/|g" uninstall.sh > "$work/uninstall.sh"
export INSTALL_LOG="$work/commands"
cat > "$work/preflight.sh" <<'MOCK'
#!/bin/sh
echo preflight >> "$INSTALL_LOG"
test "${FAIL_PREFLIGHT:-0}" = 0
MOCK
cat > "$work/headers/Makefile" <<'MOCK'
.PHONY: modules_install modules
modules_install:
	@echo modules_install >> "$(INSTALL_LOG)"
modules:
	@echo unexpected-build >> "$(INSTALL_LOG)"
	@exit 1
MOCK
cat > "$work/bin/tool" <<'MOCK'
#!/bin/sh
case "${0##*/}" in
	id) echo "${INSTALL_UID:-0}" ;;
	uname) case "$1" in -s) echo Linux ;; *) echo test-kernel ;; esac ;;
	modinfo) echo "${MODULE_RELEASE:-test-kernel} SMP" ;;
	install|depmod) echo "${0##*/} $*" >> "$INSTALL_LOG" ;;
esac
MOCK
chmod +x "$work/bin/tool"
for tool in id uname modinfo install depmod; do
	ln -s tool "$work/bin/$tool"
done
export PATH="$work/bin:$PATH"
cd "$work"
run() {
	make install KDIR="$work/headers" BOOT_OVERLAYS="${TEST_OVERLAYS:-$work/overlays}" > "$work/output" 2>&1
}
reject() {
	if run; then
		echo "Unexpected installation success" >&2
		exit 1
	fi
	! grep -Eq '^(modules_install|install |depmod |unexpected-build)' "$INSTALL_LOG"
}
for artifact in pwmstream.ko pwmstream.dtbo pwmstream-cli; do
	echo fixture > "$artifact"
done
(export FAIL_PREFLIGHT=1; reject)
(export INSTALL_UID=1000; reject)
(export MODULE_RELEASE=wrong-kernel; reject)
(export TEST_OVERLAYS="$work/missing-overlays"; reject)
for artifact in pwmstream.ko pwmstream.dtbo pwmstream-cli; do
	mv "$artifact" "$artifact.saved"
	reject
	mv "$artifact.saved" "$artifact"
done
run
grep -q '^modules_install$' "$INSTALL_LOG"
grep -q '^depmod -a$' "$INSTALL_LOG"
grep -q '^install -m 0644 pwmstream.dtbo ' "$INSTALL_LOG"
grep -q '^install -m 0755 pwmstream-cli /usr/local/bin/pwmstream-cli$' "$INSTALL_LOG"
! grep -q unexpected-build "$INSTALL_LOG"
mkdir -p "$work/lib/modules/test-kernel/updates" \
	"$work/lib/modules/other-kernel/updates" "$work/boot/firmware/overlays" \
	"$work/usr/local/bin" "$work/sys/module"
module="$work/lib/modules/test-kernel/updates/pwmstream.ko"
other="$work/lib/modules/other-kernel/updates/pwmstream.ko"
echo fixture > "$module"
echo preserve > "$other"
echo fixture > "$work/boot/firmware/overlays/pwmstream.dtbo"
echo fixture > "$work/usr/local/bin/pwmstream-cli"
unset BOOT_OVERLAYS
sh uninstall.sh > "$work/output" 2>&1
test -f "$module"
deny_remove() {
	if sh uninstall.sh --remove > "$work/output" 2>&1; then
		echo "Unexpected uninstall success" >&2
		exit 1
	fi
	test -f "$module"
}
(export INSTALL_UID=1000; deny_remove)
mkdir "$work/sys/module/pwmstream"
deny_remove
rmdir "$work/sys/module/pwmstream"
mkdir -p "$work/sys/bus/platform/devices/3f20c000.pwm/of_node"
compatible="$work/sys/bus/platform/devices/3f20c000.pwm/of_node/compatible"
printf 'pwmstream,bcm2837-pwmstream\000' > "$compatible"
deny_remove
rm "$compatible"
sh uninstall.sh --remove > "$work/output" 2>&1
test ! -e "$module"
test ! -e "$work/boot/firmware/overlays/pwmstream.dtbo"
test ! -e "$work/usr/local/bin/pwmstream-cli"
test -f "$other"
sh uninstall.sh --remove > "$work/output" 2>&1
echo "PASS: install prerequisites/no-build; uninstall preview, busy/boot gates, exact removal and repeat."
