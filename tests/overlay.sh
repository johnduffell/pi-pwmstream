#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
set -eu
# Run from the repository root. Never use a system temporary directory.
work=.overlay-check
mkdir "$work"
trap 'rm -f "$work/base.dtb" "$work/merged.dtb"; rmdir "$work"' EXIT HUP INT TERM
"${DTC:-dtc}" -Wno-unit_address_vs_reg -@ -I dts -O dtb -o "$work/base.dtb" tests/base.dts
fdtoverlay -i "$work/base.dtb" -o "$work/merged.dtb" pwmstream.dtbo
node=/soc/pwm@7e20c000
test "$(fdtget "$work/merged.dtb" "$node" compatible)" = pixel,bcm2837-pwmstream
test "$(fdtget "$work/merged.dtb" "$node" status)" = okay
test "$(fdtget -t x "$work/merged.dtb" "$node" reg)" = "7e20c000 28"
test "$(fdtget "$work/merged.dtb" "$node" pinctrl-names)" = "default active"
test "$(fdtget -t x "$work/merged.dtb" "$node" dmas | awk '{print $2}')" = 5
test "$(fdtget -l "$work/merged.dtb" /soc | grep -c '^pwm@')" = 1
echo "Overlay replaces exactly one PWM node and preserves its resource: OK"
