<!-- SPDX-License-Identifier: Apache-2.0 -->

# User guide

Reference for installing, using and removing `pwmstream`. For a quick start and troubleshooting see
the [README](https://github.com/johnduffell/pi-pwmstream/blob/main/README.md). Developers: see the
[development guide](https://github.com/johnduffell/pi-pwmstream/blob/main/docs/development.md).
Programmers writing their own client: see the
[ABI reference](https://github.com/johnduffell/pi-pwmstream/blob/main/docs/abi.md).

The driver streams a packed bit pattern out of **GPIO18 (header pin 12)** using PWM0 and a
kernel-allocated DMA channel, repeating it until stopped. It needs exclusive use of PWM0, GPIO18 and
one DMA channel. It is experimental: see the warning in the README before connecting anything.

## Compatibility policy

Supported: Raspberry Pi 3 B/B+ (BCM2837), Raspberry Pi OS Debian 13 arm64.

| Kernel                      | Behaviour                                                      |
| --------------------------- | -------------------------------------------------------------- |
| `6.18.50+rpt-rpi-v8`        | Reviewed and hardware-tested baseline                          |
| `6.18.N+rpt-rpi-v8`, N > 50 | Accepted; the probe logs that it is newer than the last review |
| Anything else               | Rejected at probe unless `allow_unreviewed=1`                  |
| Other boards                | Always rejected (the override does not apply)                  |

6.18.50 is the first release with strict pinctrl, which stops other GPIO users while the pin is
muxed to PWM; earlier 6.18 releases lack that protection.

The check runs before the driver maps registers or allocates DMA. It is a maintenance compromise,
not source attestation: patch releases normally keep the internal kernel APIs the driver relies on,
but Linux does not guarantee that. An accepted kernel other than 6.18.50 is **not
hardware-qualified** until the hardware tests have been run on it (see
[Extending the supported kernel range](https://github.com/johnduffell/pi-pwmstream/blob/main/docs/development.md#extending-the-supported-kernel-range)).

**Override:** `allow_unreviewed=1` accepts any kernel on a supported board and logs a warning (DMA,
clock and pin assumptions are then unverified; use a test-safe setup). Set it with
`options pwmstream allow_unreviewed=1` in `/etc/modprobe.d/` or `pwmstream.allow_unreviewed=1` on
the kernel command line. The preflight needs `PWMSTREAM_ALLOW_UNREVIEWED=1`. DKMS cannot use the
override (see [Kernel updates](#kernel-updates)); it applies to manual builds only.

## Install

### Debian package (recommended)

The install and enable commands are in the README quickstart. In more detail:

- Installing the package builds the module through DKMS but enables nothing.
- `pwmstream-enable` is the only step that edits `config.txt` (a backup is kept). It refuses to
  continue if audio, `dtoverlay=pwm`, `audremap` or I2S would conflict with PWM0/GPIO18. `--dry-run`
  previews; `--disable` plus a reboot reverses it.
- Before enabling, stop anything else that touches the pin or PWM block: pigpio, rpi_ws281x, the old
  PWM overlay, and any `/dev/mem` or `/dev/gpiomem` user. Linux cannot stop raw register access.

### Manual install (no package)

For a Pi without the package route. Do not combine with the package: if `updates/pwmstream.ko*`
exists, run `sudo make uninstall` first.

```sh
sudo apt install build-essential device-tree-compiler "linux-headers-$(uname -r)"
make all W=1                # unprivileged
sudo make preflight         # read-only: board, kernel, headers, PWM binding, audio, raw-memory users
sudo make install           # re-runs preflight; installs module, CLI and overlay; runs depmod
```

Then add to `/boot/firmware/config.txt` and reboot:

```ini
dtparam=audio=off
dtoverlay=pwmstream
```

Installing never edits boot configuration, reboots, or starts hardware. After the reboot check that
`/sys/bus/platform/devices/3f20c000.pwm/driver` resolves to `pwmstream` and `/dev/pwmstream0`
exists. Older layouts use `BOOT_OVERLAYS=/boot/overlays` with `make install` and `make uninstall`.

### Access

The package installs a udev rule that gives the `gpio` group read/write access (`0660`) to
`/dev/pwmstream0`. The default Raspberry Pi OS user is already in that group, which also grants raw
`/dev/gpiomem` access, so only add trusted users (`sudo usermod -aG gpio USER`, then log in again).
The device is never world-writable. Manual installs don't get the rule and the device stays
root-only (`0600`): use `sudo`, or copy `packaging/60-pwmstream.rules` to `/etc/udev/rules.d/`.

## Using the CLI

```sh
pwmstream-cli run sample.bin                 # default 50 Mbit/s
pwmstream-cli run sample.bin 25000000        # bit/s
pwmstream-cli status                         # read-only observer
```

`run` uploads the sample, starts output and **keeps the controlling descriptor open**. Ctrl-C,
SIGTERM, SIGHUP, `quit` or process exit stops output. There is deliberately no start-and-exit
command. While `run` is active, type these on its stdin: `status`, `stop`, `rate 25000000`, `start`,
`quit` (stop before changing the rate). A fault seen by the periodic status check ends `run` with
failure; start a new `run` after fixing the cause. `-d DEVICE` overrides the device path.

**Sample files** contain chronological bytes, MSB first within each byte, 4 to 1,048,576 bytes and a
multiple of four. `12 34 56 78` is the word `0x12345678`, bit 31 first. `AA AA AA AA` is an
alternating pattern; `FF FF 00 00` is 16 ticks high then 16 low. The pattern repeats without
padding. Do not pre-reverse bytes.

**Rates** are 0.1 to 100 Mbit/s, default 50. Rates above 50 are experimental. The achieved rate
comes from the clock framework and may be rounded; `status` shows both requested and actual (the
[ABI reference](https://github.com/johnduffell/pi-pwmstream/blob/main/docs/abi.md#errors-and-limits)
has the exact limits). Tick spacing is only guaranteed uniform at integer-derived rates, so check
jitter-sensitive rates on a scope.

`status` is a snapshot of driver state, not a measurement. `running` does not prove the pin is
producing a healthy waveform.

## Kernel updates

DKMS rebuilds the module for every installed in-range kernel, pulling in matching headers. Kernels
outside the range are skipped (DKMS status 77), so they never break `apt upgrade`; a kernel hook
prints a warning, and `pwmstream-cli` prints a "driver not loaded" hint if `/dev/pwmstream0` is
missing. If an update installs an unsupported kernel, keep the previous kernel selectable, then
install a newer package release after the range has been reviewed. Do not rename or copy a `.ko` to
get around the check. Reboot after a package upgrade if the module is loaded (open descriptors block
unload).

## Remove

`apt remove` while the overlay is still enabled keeps the overlay and warns, so run
`sudo pwmstream-enable --disable` and reboot first. Audio and PWM overlays are not restored
automatically; decide ownership for the next use yourself.

Manual installs: `sh uninstall.sh` previews, `sudo make uninstall` removes the module, CLI and
overlay for the running kernel (it refuses while the module is loaded or the overlay is active).
Remove the `dtoverlay=pwmstream` line and reboot first. It does not touch DKMS or package files.

## Behaviour and limits

- Stopped, the pin is an **input with pull-down** (high impedance, not a driven-low interlock);
  running, it is ALT5.
- STOP and the final close are abrupt, not at a word or sample boundary. Shutdown stops output;
  suspend stops it and latches `EHOSTDOWN` (no automatic restart).
- Faults are checked roughly every 20 ms and stop output, but this is **not bounded-latency fault
  containment**: a bad waveform may already have been emitted.
- Full fault, stress, suspend and electrical qualification has not been done.

How these behaviours are implemented is in the
[design notes](https://github.com/johnduffell/pi-pwmstream/blob/main/docs/design.md#start-stop-and-fault-handling).
