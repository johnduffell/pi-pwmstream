<!-- SPDX-License-Identifier: Apache-2.0 -->

# User guide

How to install, use, upgrade and remove `pwmstream`. Developers: see [development.md](https://github.com/johnduffell/pi-pwmstream/blob/main/docs/development.md).
Programmers writing their own client: see [abi.md](https://github.com/johnduffell/pi-pwmstream/blob/main/docs/abi.md).

The driver streams a packed bit pattern out of **GPIO18 (header pin 12)** using PWM0 and a
kernel-allocated DMA channel, repeating it until stopped. It needs exclusive use of PWM0, GPIO18 and
one DMA channel.

**Supported:** Raspberry Pi 3 B/B+ (BCM2837), Raspberry Pi OS Debian 13 arm64,
kernel `6.18.N+rpt-rpi-v8` with N >= 50.

**Status:** experimental. Short-pattern output has been checked on a scope at 1, 50, 62.5,
~83.3 and nominal 100 Mbit/s; sustained-load, jitter and electrical quality are not qualified.
GPIO is 3.3 V logic, not a protected instrument output: use a high-impedance, test-safe load, never a
50-ohm scope termination.

## Compatibility policy

| Kernel | Behaviour |
| --- | --- |
| `6.18.50+rpt-rpi-v8` | Reviewed and hardware-tested baseline |
| `6.18.N+rpt-rpi-v8`, N > 50 | Accepted; the probe logs that it is newer than the last review |
| Anything else | Rejected at probe unless `allow_unreviewed=1` |
| Other boards | Always rejected (the override does not apply) |

6.18.50 is the first release with strict pinctrl, which stops other GPIO users while the pin is
muxed to PWM; earlier 6.18 releases lack that protection.

The check runs before the driver maps registers or allocates DMA. It is a maintenance compromise,
not source attestation: patch releases normally keep the internal kernel APIs the driver relies on,
but Linux does not guarantee that. An accepted kernel other than 6.18.50 is **not
hardware-qualified** until you run the hardware tests on it
([development guide](https://github.com/johnduffell/pi-pwmstream/blob/main/docs/development.md#testing-on-a-pi)).

**Override:** `allow_unreviewed=1` accepts any kernel on a supported board and logs a warning (DMA,
clock and pin assumptions are then unverified; use a test-safe setup). Set it with
`options pwmstream allow_unreviewed=1` in `/etc/modprobe.d/` or `pwmstream.allow_unreviewed=1` on the
kernel command line. The preflight needs `PWMSTREAM_ALLOW_UNREVIEWED=1`. DKMS cannot use the override
(see [Kernel updates](#kernel-updates)); it applies to manual builds only.

## Install

### Debian package (recommended)

```sh
sudo apt install ./pwmstream_<version>_arm64.deb   # pulls in dkms and the Pi kernel headers
sudo pwmstream-enable                              # preflight, installs the overlay, edits config.txt
sudo reboot
pwmstream-cli status
```

Installing the package builds the module through DKMS but enables nothing. `pwmstream-enable` is the
only step that edits `config.txt` (a backup is kept). It refuses to continue if audio, `dtoverlay=pwm`,
`audremap` or I2S would conflict with PWM0/GPIO18. `--dry-run` previews; `--disable` plus a reboot
reverses it.

Before enabling, stop anything else that touches the pin or PWM block: pigpio, rpi_ws281x, the old
PWM overlay, and any `/dev/mem` or `/dev/gpiomem` user. Linux cannot stop raw register access.

Build the package yourself with `make deb` (needs `dtc`; output in `dist/`).

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

The package installs a udev rule (`/usr/lib/udev/rules.d/60-pwmstream.rules`) that gives the `gpio`
group read/write access (`0660`) to `/dev/pwmstream0`. The default Raspberry Pi OS user is already in
that group, which also grants raw `/dev/gpiomem` access, so only add trusted users
(`sudo usermod -aG gpio USER`, then log in again). The device is never world-writable. Manual installs
don't get the rule and the device stays root-only (`0600`): use `sudo`, or copy the rule from `packaging/`.

## Using the CLI

```sh
pwmstream-cli run sample.bin                 # default 50,000,000 bit/s
pwmstream-cli run sample.bin 25000000
pwmstream-cli status                         # read-only observer
```

`run` uploads the sample, starts output and **keeps the controlling descriptor open**. Ctrl-C,
SIGTERM, SIGHUP, `quit` or process exit stops output. There is deliberately no start-and-exit command.
While `run` is active, type these on its stdin: `status`, `stop`, `rate 25000000`, `start`, `quit`
(stop before changing the rate). A fault seen by the periodic status check ends `run` with failure;
start a new `run` after fixing the cause. `-d DEVICE` overrides the device path.

**Sample files** contain chronological bytes, MSB first within each byte, 4 to 1,048,576 bytes and a
multiple of four. `12 34 56 78` is the word `0x12345678`, bit 31 first. `AA AA AA AA` is an
alternating pattern; `FF FF 00 00` is 16 ticks high then 16 low. The pattern repeats without padding.
Do not pre-reverse bytes.

**Rates** are 100 kHz to 100 MHz, default 50 MHz. Rates above 50 MHz are experimental. The achieved
rate comes from the clock framework and may be rounded (a 100 MHz request reads back 100,000,001 Hz,
which is allowed); `status` shows both requested and actual. The PWM clock can use fractional
division, so tick spacing is only guaranteed uniform at integer-derived rates. Check jitter-sensitive
rates on a scope.

`status` is a snapshot of driver state, not a measurement. `running` does not prove the pin is
producing a healthy waveform.

## Kernel updates

DKMS rebuilds the module for every installed in-range kernel, pulling in matching headers.
Kernels outside the range are skipped (DKMS status 77), so they never break `apt upgrade`; a kernel
hook prints a warning, and `pwmstream-cli` prints a "driver not loaded" hint if `/dev/pwmstream0` is
missing. If an update installs an unsupported kernel, keep the previous kernel selectable, then
install a newer package release after the range has been reviewed. Do not rename or copy a `.ko` to
get around the check.

Package upgrades are `sudo apt install ./pwmstream_<new>_arm64.deb`; reboot if the module is loaded
(open descriptors block unload).

## Remove

```sh
sudo pwmstream-enable --disable && sudo reboot      # stop using the overlay
sudo apt remove pwmstream                           # remove the module; config.txt is left alone
sudo apt purge pwmstream                            # also removes the overlay file (once not enabled)
```

`apt remove` while the overlay is still enabled keeps the overlay and warns. Audio and PWM overlays
are not restored automatically; decide ownership for the next use yourself.

Manual installs: `sh uninstall.sh` previews, `sudo make uninstall` removes the module, CLI and overlay
for the running kernel (it refuses while the module is loaded or the overlay is active). Remove the
`dtoverlay=pwmstream` line and reboot first. It does not touch DKMS or package files.

`sh install-state.sh` is a read-only snapshot (installed files, loaded module, overlay, PWM binding,
audio, relevant `config.txt` lines); attach it to bug reports.

## Failure behaviour and limits

* Stopped, the pin is an **input with pull-down** (high impedance, not a driven-low interlock);
  running, it is ALT5. Remove any other user of GPIO18 before enabling the overlay.
* STOP and the final close are abrupt, not a word or sample boundary. Open descriptors keep the module
  loaded; shutdown stops output; suspend stops it and latches `EHOSTDOWN` (no automatic restart).
* A monitor checks PWM FIFO/gap/bus errors and DMA status roughly every 20 ms and stops on error. This
  is **not bounded-latency fault containment**: a bad waveform may already have been emitted, and the
  DMA provider does not report every hardware error.
* If DMA termination ever fails, the driver keeps the sample memory and channel until reboot rather
  than freeing memory a DMA engine might still read. This path has not been fault-injected.
* Full fault, stress, suspend and electrical qualification has not been done.

How these behaviours are implemented is in [design.md](https://github.com/johnduffell/pi-pwmstream/blob/main/docs/design.md#implementation-notes).

## Licence

`pwmstream.c` is **Apache-2.0 OR GPL-2.0-only**; everything else is Apache-2.0. See
[LICENSE](https://github.com/johnduffell/pi-pwmstream/blob/main/LICENSE). `MODULE_LICENSE("GPL")` is for kernel integration, not the full licence statement.
