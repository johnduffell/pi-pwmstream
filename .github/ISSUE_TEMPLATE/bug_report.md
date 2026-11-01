---
name: Bug report
about: Driver, install or waveform problem on a Raspberry Pi
labels: bug
---
<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Do not report problems with other PWM/DMA users running at the same time (pigpio, rpi_ws281x, PWM audio). -->

**Board and OS:** (e.g. Pi 3B+, Raspberry Pi OS Debian 13 aarch64)
**Kernel (`uname -r`):**
**Driver version (git commit or release):**
**Install state:** output of `pwmstream-report` (or `sh install-state.sh` in a source checkout)
**What you did and what you expected:**
**Logs:** `sudo journalctl -k | grep -i pwmstream`, `pwmstream-cli` output
**Measurement setup:** instrument, probe, load, bit rate, pattern (if a waveform issue)
