---
name: Bug report
about: Driver, install or waveform problem on a Raspberry Pi
labels: bug
---

<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Do not report problems with other PWM/DMA users running at the same time (pigpio, rpi_ws281x, PWM audio). -->

**Board and OS:** (e.g. Pi 3B+, Raspberry Pi OS Debian 13 aarch64)

**Kernel (`uname -r`):**

**Driver version (release or git commit):** (please try the latest release first)

**Install state:** output of `pwmstream-report` (or `sh pwmstream-report.sh` in a source checkout). It
refuses to run on an outdated release unless you add `--force`.

**What you did and what you expected:**

**Logs:** `sudo journalctl -k | grep -i pwmstream`, `pwmstream-cli` output

**Measurement setup:** instrument, probe, load, bit rate, pattern (if a waveform issue)
