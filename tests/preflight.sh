#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
set -eu
# Exercise a copy against synthetic paths; never inspect/change host hardware.
work="$PWD/.preflight-check"
mkdir "$work"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin" "$work/dev" "$work/proc/device-tree" "$work/headers" \
	"$work/sys/bus/platform/drivers/bcm2835-pwm" \
	"$work/sys/bus/platform/devices/3f007000.dma-controller/of_node"
sed -e "s|/proc/|$work/proc/|g" -e "s|/sys/|$work/sys/|g" \
	-e "s|/boot/|$work/boot/|g" -e "s|/dev/|$work/dev/|g" \
	check-install.sh > "$work/check.sh"
cat > "$work/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
	-s) echo Linux ;;
	-m) echo "${TEST_ARCH:-aarch64}" ;;
	-r) echo "${TEST_RELEASE:-6.18.50+rpt-rpi-v8}" ;;
esac
EOF
cat > "$work/bin/make" <<'EOF'
#!/bin/sh
echo "${TEST_HEADERS:-6.18.50+rpt-rpi-v8}"
EOF
cat > "$work/bin/fuser" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" KDIR="$work/headers"
touch "$KDIR/Makefile"
printf 'raspberrypi,3-model-b-plus\000brcm,bcm2837\000' > "$work/proc/device-tree/compatible"
dma="$work/sys/bus/platform/devices/3f007000.dma-controller"
ln -s ../../drivers/bcm2835-dma "$dma/driver"
printf 'brcm,bcm2835-dma\000' > "$dma/of_node/compatible"
pass() { sh "$work/check.sh" "$@" > "$work/output" 2>&1; }
reject() {
	if pass "$@"; then
		echo "Unexpected preflight success" >&2
		exit 1
	fi
}
pass --build-only
pass
(export TEST_RELEASE=6.18.49+rpt-rpi-v8 TEST_HEADERS=6.18.49+rpt-rpi-v8; reject --build-only)
(export TEST_RELEASE=6.18.51+rpt-rpi-v8 TEST_HEADERS=6.18.51+rpt-rpi-v8; pass --build-only)
grep -q 'supported 6.18.N' "$work/output"
(export TEST_RELEASE=6.18.100+rpt-rpi-v8 TEST_HEADERS=6.18.100+rpt-rpi-v8; pass)
(export TEST_RELEASE=6.19.0+rpt-rpi-v8 TEST_HEADERS=6.19.0+rpt-rpi-v8; reject --build-only)
(export TEST_RELEASE=6.18.50 TEST_HEADERS=6.18.50; reject --build-only)
(export TEST_RELEASE=6.18.60+rpt-rpi-2712 TEST_HEADERS=6.18.60+rpt-rpi-2712; reject --build-only)
(export TEST_RELEASE=6.18.5x+rpt-rpi-v8 TEST_HEADERS=6.18.5x+rpt-rpi-v8; reject --build-only)
(export TEST_RELEASE=6.19.0+rpt-rpi-v8 TEST_HEADERS=6.19.0+rpt-rpi-v8 PWMSTREAM_ALLOW_UNREVIEWED=1; pass --build-only)
grep -q 'UNREVIEWED' "$work/output"
(export TEST_ARCH=armv7l; reject --build-only)
(export TEST_RELEASE=6.18.50+rpt-rpi-v8 TEST_HEADERS=6.18.51+rpt-rpi-v8; reject --build-only)
(export TEST_RELEASE=6.18.51+rpt-rpi-v8 TEST_HEADERS=6.18.50+rpt-rpi-v8; reject --build-only)
printf 'raspberrypi,3-model-b\000brcm,bcm2837\000' > "$work/proc/device-tree/compatible"
reject --build-only
grep -q 'restricted to Raspberry Pi 3B+' "$work/output"
printf 'raspberrypi,3-model-b-plus\000brcm,bcm2711\000' > "$work/proc/device-tree/compatible"
reject --build-only
grep -q 'Expected BCM2837' "$work/output"
printf 'raspberrypi,3-model-b-plus\000brcm,bcm2837\000' > "$work/proc/device-tree/compatible"
printf 'brcm,bcm2711-dma\000' > "$dma/of_node/compatible"
reject
grep -q 'Expected DMA compatible' "$work/output"
printf 'brcm,bcm2835-dma\000' > "$dma/of_node/compatible"
pass
snd="$work/sys/module/snd_bcm2835"
mkdir -p "$snd/parameters" "$work/proc/asound"
printf 'vc4hdmi [vc4-hdmi]\n' > "$work/proc/asound/cards"
printf 'N\n' > "$snd/parameters/enable_headphones"
pass
grep -q 'not treated as PWM ownership' "$work/output"
printf 'Y\n' > "$snd/parameters/enable_headphones"
reject
grep -q 'enable_headphones=Y' "$work/output"
rm "$snd/parameters/enable_headphones"
reject
grep -q 'enable_headphones=unknown' "$work/output"
printf 'N\n' > "$snd/parameters/enable_headphones"
printf ' 1 [Headphones     ]: bcm2835_headpho - bcm2835 Headphones\n' >> "$work/proc/asound/cards"
reject
grep -q 'Headphones sound card' "$work/output"
rm -r "$snd" "$work/proc/asound"
pass
owner="$work/sys/bus/platform/drivers/bcm2835-pwm/3f20c000.pwm"
ln -s ../../devices/3f20c000.pwm "$owner"
pass --build-only
reject
grep -q 'Standard PWM driver still owns' "$work/output"
rm "$owner"
rm "$dma/driver"
reject
grep -q 'bound to bcm2835-dma' "$work/output"
echo "Preflight release/headers, actual PWM binding, audio ownership and DMA checks: OK"
