<!-- SPDX-License-Identifier: Apache-2.0 -->

# pi-pwmstream

**Send your own repeating bit patterns out of a Raspberry Pi pin at up to 50 Mbit/s.**

`pwmstream` is a Linux driver that efficiently plays a repeating bit pattern from a file out of
GPIO18 (header pin 12), clocked by the Pi's PWM hardware and fed by DMA, so the CPU is not involved
in clocking out the bits. Use it for custom digital waveforms, test signals, and as the output stage
for pattern or signal generators. Rates run from 0.1 Mbit/s to a nominal 100 Mbit/s; 50 Mbit/s is
the default.

> **Experimental.** Short test patterns have been checked on a scope. Long-run reliability and
> electrical signal quality have not been qualified. GPIO18 is a 3.3 V logic pin, not a protected
> instrument output: use a high-impedance, test-safe load and never connect a 50-ohm scope
> termination.

## Is this for you?

You need:

- a **Raspberry Pi 3 B or 3 B+** (other boards are not supported),
- **Raspberry Pi OS (Debian 13, 64-bit)** with a `6.18.N+rpt-rpi-v8` kernel where N is 50 or higher.
  Check with `uname -r`,
- **GPIO18 and the PWM hardware to yourself.** The driver takes over PWM0 and the Pi's PWM audio
  output stops working. Don't use it together with pigpio, rpi_ws281x, I2S audio or `dtoverlay=pwm`.

If that fits, read on. If you want a ready-made waveform generator with a UI, that is a separate
project planned, built on top of this driver.

## Get running in five minutes

**1. Install.** Download `pwmstream_<version>_arm64.deb` from the
[latest release](https://github.com/johnduffell/pi-pwmstream/releases/latest), then:

```sh
sudo apt install ./pwmstream_<version>_arm64.deb
```

This pulls in DKMS and the kernel headers, and builds the module for your kernel. It changes nothing
else on your system.

**2. Enable.**

```sh
sudo pwmstream-enable
sudo reboot
```

`pwmstream-enable` checks for conflicts (analogue audio, `dtoverlay=pwm`, I2S and so on), installs
the overlay, and adds `dtoverlay=pwmstream` to `/boot/firmware/config.txt` after making a backup.
Add `--dry-run` first if you want to see what it will do.

**3. See a test signal.** Make a 4-byte pattern (16 ticks high, 16 low) and play it at 1 Mbit/s:

```sh
printf '\377\377\000\000' > square.bin
pwmstream-cli run square.bin 1000000
```

The package gives the `gpio` group (which the default Pi user is in) access to the device, so `sudo`
isn't needed. If you get `Permission denied`, see the troubleshooting table.

A scope or logic analyser on pin 12 (and ground) now shows a **31.25 kHz square wave**: the 32-bit
pattern repeats every 32 microseconds. Press Ctrl-C to stop. In a second terminal,
`pwmstream-cli status` shows what the driver is doing.

**Pattern files** are raw bytes, sent most-significant bit first, repeating forever. They must be a
multiple of 4 bytes, from 4 bytes to 1 MiB. For example `AA AA AA AA` gives alternating bits, so at
50 Mbit/s (the default rate) it makes a 25 MHz square wave. While `pwmstream-cli run` is active you
can type `status`, `stop`, `rate 25000000`, `start` or `quit`. If you ask for a rate the clock can't
hit exactly, `status` shows both the requested and the actual rate.

## Keeping it working

- **Kernel updates are handled for you.** When `apt upgrade` installs a newer supported kernel, DKMS
  rebuilds the module automatically. Reboot as usual.
- **Unsupported kernels are skipped, not broken.** If a kernel falls outside the supported range,
  the upgrade still succeeds and prints a warning; the driver just won't load on that kernel.
  Install the next `pwmstream` release when it appears, or help get the kernel added: it takes a Pi
  and a scope, and the steps are in
  [Extending the supported kernel range](docs/development.md#extending-the-supported-kernel-range).
  You can also [open an issue](CONTRIBUTING.md#supporting-a-newer-kernel) with your `uname -r`.
- **Upgrading the driver:** `sudo apt install ./pwmstream_<newer>_arm64.deb`, then reboot.
- **Turning it off:** `sudo pwmstream-enable --disable`, reboot. This hands PWM0/GPIO18 back. Your
  `config.txt` backups are kept next to it.
- **Removing it:** `sudo apt remove pwmstream` removes the module and leaves `config.txt` alone;
  `sudo apt purge pwmstream` also removes the overlay file (disable first).

## Troubleshooting

First run `pwmstream-report`. It prints a read-only summary of the package, module, overlay and boot
settings; it is also what to attach to a bug report. It first checks GitHub (its only network
access) for a newer release and stops if yours is out of date, since the problem may already be
fixed: update, or run `pwmstream-report --force` to print the report anyway. If the check can't run
(offline, no release), it says so and carries on.

| Symptom                                      | Likely cause and fix                                                                                                                                                                                                           |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/dev/pwmstream0: No such file or directory` | The driver isn't loaded. Run `dkms status` (it should show `pwmstream ... installed` for your `uname -r`), run `sudo pwmstream-enable` if you haven't, and reboot. Then `sudo journalctl -k \| grep pwmstream` for the reason. |
| `dkms status` shows nothing for this kernel  | The running kernel is outside the supported range (`uname -r` must be `6.18.N+rpt-rpi-v8`, N >= 50) or its headers are missing: `sudo apt install linux-headers-rpi-v8`.                                                       |
| `Permission denied`                          | Your user isn't in the `gpio` group (`groups` to check). Run `sudo usermod -aG gpio $USER` and log in again, or use `sudo`.                                                                                                    |
| `Device or resource busy`                    | Another `pwmstream-cli run` (or your own program) already controls the output. Close it. `pwmstream-cli status` still works.                                                                                                   |
| `pwmstream-enable` lists conflicting lines   | Those `config.txt` settings use PWM0 or GPIO18 (analogue audio, `dtoverlay=pwm`, `audremap`, I2S). Disable them, then rerun.                                                                                                   |
| Enabled, rebooted, but the driver won't bind | Something else owns the pin or PWM block (pigpio, rpi_ws281x, another overlay). Stop it, and check the kernel log.                                                                                                             |
| Command runs but there's no signal           | Measure pin 12 against a ground pin, with a high-impedance probe. Check `pwmstream-cli status` for errors. Remember the pin is only driven while a `run` is active; otherwise it floats with a pull-down.                      |

Still stuck?
[Open an issue](https://github.com/johnduffell/pi-pwmstream/issues/new?template=bug_report.md) and
include the `pwmstream-report` output, `sudo journalctl -k | grep -i pwmstream`, and what you
measured. Please don't report problems that happen while pigpio, rpi_ws281x or PWM audio are running
at the same time.

More detail (compatibility policy, manual install, failure behaviour) is in the
[user guide](docs/usage.md).

## Developing and contributing

Contributions are welcome, and **all you need is a computer**. The devcontainer (Debian 13, arm64)
builds the kernel module against pinned Pi kernel headers and runs a full hardware-free check suite,
which is the same one CI runs, so you can fix bugs, improve docs or add support for a newer kernel
without owning a Pi. If you do have a Pi 3, you can also run the hardware tests on it.

Found a bug or want something added?
[Open an issue](https://github.com/johnduffell/pi-pwmstream/issues), or send a pull request.
[CONTRIBUTING.md](CONTRIBUTING.md) has the setup, the repository layout, how to run the checks and
Pi tests, licensing and the hardware-safety rules.

## Licence

[Apache-2.0](LICENSE). The kernel module `pwmstream.c` is dual-licensed **Apache-2.0 OR
GPL-2.0-only** for GPL-compatible kernel integration. This does not change Linux's own licensing.
