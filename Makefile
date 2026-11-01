# SPDX-License-Identifier: Apache-2.0
# Build entry point; `make help` lists the targets. Under kbuild (KERNELRELEASE set) this file only
# names the module.
ifneq ($(KERNELRELEASE),)
obj-m := pwmstream.o
else
KDIR ?= /lib/modules/$(shell uname -r)/build
CC ?= cc
CFLAGS ?= -O2 -g
DTC ?= dtc
BOOT_OVERLAYS ?= /boot/firmware/overlays

define HELP
Production (what ships):
  make all               module (needs kernel headers), pwmstream-cli and the overlay
  make deb               build dist/pwmstream_<version>_arm64.deb (DKMS package)
  make install           manual install on a Pi (see docs/usage.md); make uninstall previews/removes
Development and CI (no hardware):
  make check-all         every check below; needs the pinned kernel headers (dev-tools/fetch-kernel-headers.sh)
  make check             ABI/CLI self-tests; also check-install check-harness check-preflight check-overlay
  make check-kbuild      build the module against the pinned headers; check-static: sparse, shellcheck, cppcheck
  make check-package     build the .deb and validate it (lintian, scratch DKMS build, kernel range)
Hardware: dev-tools/deploy.sh and dev-tools/test.sh (see docs/development.md).
endef
export HELP

.DEFAULT_GOAL := all
.PHONY: help check-all all module cli abi-test overlay check check-harness check-overlay check-preflight check-install check-build check-kbuild check-static check-package deb preflight install uninstall clean

help:
	@printf '%s\n' "$$HELP"

check-all: check check-install check-harness check-preflight check-overlay check-kbuild check-static check-package

all: module cli overlay

module:
	@test -f "$(KDIR)/Makefile" || { echo "Missing configured kernel headers: $(KDIR)" >&2; exit 1; }
	$(MAKE) -C "$(KDIR)" M="$(CURDIR)" modules

cli: pwmstream-cli
pwmstream-cli: pwmstream-cli.c pwmstream.h
	$(CC) $(CFLAGS) -std=c11 -Wall -Wextra -Werror -o $@ pwmstream-cli.c

abi-test: pwmstream-test
pwmstream-test: tests/pwmstream-test.c pwmstream.h
	$(CC) $(CFLAGS) -std=c11 -Wall -Wextra -Werror -o $@ tests/pwmstream-test.c

overlay: pwmstream.dtbo
pwmstream.dtbo: pwmstream-overlay.dts
	$(DTC) -@ -I dts -O dtb -o $@ $<

deb: cli overlay
	sh packaging/build-deb.sh

check-package: deb
	bash tests/package.sh

check: cli abi-test
	./pwmstream-cli --selftest
	./pwmstream-test --selftest
	@! ./pwmstream-test --scope 2>/dev/null
	@! ./pwmstream-test --extended100M 2>/dev/null
	@! ./pwmstream-test --lifecycle 2>/dev/null
	@! ./pwmstream-test --lifecycle --scope --hardware 2>/dev/null
	@! ./pwmstream-cli run ignored -1 2>/dev/null
	@! ./pwmstream-cli run ignored 100000001 2>/dev/null

check-overlay: overlay
	DTC="$(DTC)" sh ./tests/overlay.sh

check-preflight:
	sh ./tests/preflight.sh

check-harness:
	bash ./tests/harness.sh

check-install:
	sh ./tests/install.sh
	sh ./tests/report.sh

check-build:
	KDIR="$(KDIR)" sh ./preflight.sh --build-only

# Pi-free: builds in a scratch copy against the pinned headers from dev-tools/kernels.txt.
check-kbuild:
	sh ./tests/kbuild.sh

check-static:
	sh ./tests/static.sh

preflight:
	KDIR="$(KDIR)" sh ./preflight.sh

# Deliberately does not edit config.txt, load the module, or change hardware.
install: preflight
	@test "$$(id -u)" = 0 || { echo "Installation requires administrator privileges" >&2; exit 1; }
	@test -d "$(BOOT_OVERLAYS)" || { echo "Set BOOT_OVERLAYS to the firmware overlay directory" >&2; exit 1; }
	@for artifact in pwmstream.ko pwmstream.dtbo pwmstream-cli; do \
		test -s "$$artifact" || { echo "Missing $$artifact; run make all W=1 as an unprivileged user first" >&2; exit 1; }; \
	done
	@test "$$(modinfo -F vermagic ./pwmstream.ko | cut -d ' ' -f 1)" = "$$(uname -r)" || \
		{ echo "Built module does not match the running kernel; rebuild before installing" >&2; exit 1; }
	$(MAKE) -C "$(KDIR)" M="$(CURDIR)" modules_install
	depmod -a
	install -m 0644 pwmstream.dtbo "$(BOOT_OVERLAYS)/pwmstream.dtbo"
	install -m 0755 pwmstream-cli /usr/local/bin/pwmstream-cli
	@echo "Now review docs/usage.md and explicitly edit boot config, then reboot; no hardware was enabled here."

uninstall:
	BOOT_OVERLAYS="$(BOOT_OVERLAYS)" sh ./uninstall.sh --remove

clean:
	rm -rf pwmstream-cli pwmstream-test pwmstream.dtbo dist *.dSYM
	@if test -f "$(KDIR)/Makefile"; then $(MAKE) -C "$(KDIR)" M="$(CURDIR)" clean; fi
endif
