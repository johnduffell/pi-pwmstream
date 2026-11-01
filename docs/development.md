<!-- SPDX-License-Identifier: Apache-2.0 -->

# Development guide

For contributors and maintainers. Installing and using the driver is in [usage.md](usage.md); the
contributing rules are in [CONTRIBUTING.md](../CONTRIBUTING.md).

Everything here uses the scripts in `dev-tools/` and the checks in `tests/`. None of it ships in the
`.deb`.

## Hardware-free checks

Work in the devcontainer (Debian 13 aarch64). It fetches the pinned kernel headers on creation, so no
Pi is needed to build the module.

```sh
make help        # list targets, production vs development
make check-all   # every check below; this is what CI runs
```

| Target | Checks |
| --- | --- |
| `check` | Builds the CLI and native test client with strict warnings; ABI layout, rate parser and CLI selftests |
| `check-install` | Install/uninstall scripts against mock files: gates reject before any write |
| `check-harness` | Deploy/test scripts against mocked `ssh`/`scp`: gating, failure propagation, cleanup |
| `check-preflight` | Preflight gate against synthetic paths, including the real `bcm2835-pwm` binding |
| `check-overlay` | Overlay replaces exactly one PWM node and keeps its `reg` (fixture, not a bootable board) |
| `check-kbuild` | Builds the module with `W=1` against the pinned headers and checks vermagic |
| `check-static` | sparse, shellcheck, `gcc -fanalyzer`, cppcheck (needs those tools) |
| `check-package` | Builds the `.deb`; lintian, a scratch DKMS build, the kernel-range matrix, `pwmstream-enable` logic |

`dev-tools/fetch-kernel-headers.sh --install` downloads the headers pinned in `dev-tools/kernels.txt`,
verifies their SHA-256 and installs them. Update the pins together with a compatibility review, never to
an unreviewed kernel. `make module KDIR=/path/to/configured/kernel/build` builds against another tree;
macOS cannot build Linux modules and its ioctl encodings differ, so rebuild the CLI on Linux.

These checks prove the code builds and the scripts behave. They do not load the module or touch hardware.

## Testing on a Pi

Use a test-safe Pi you own, running the pinned kernel with the overlay already enabled (install the
package first, see [usage.md](usage.md)). Pi-side tests are never run by CI.

```sh
bash dev-tools/deploy.sh --host user@raspberrypi                                   # build only
bash dev-tools/deploy.sh --host user@raspberrypi --install-reload                  # also replace the loaded module
bash dev-tools/deploy.sh --host user@raspberrypi --install-reload --test           # also run ABI and scope tests
bash dev-tools/deploy.sh --host user@raspberrypi --install-reload --test --lifecycle   # plus unbind/rebind
```

`deploy.sh` copies an explicit source list to a fresh `~/code/pi-pwmstream/runs/build-UTC-PID` on the Pi
(`--destination` changes the base), checks SHA-256, verifies the kernel, headers and architecture,
builds with `W=1` and runs the hardware-free tests. It never installs packages, edits boot files or
reboots. The log reports the module's `srcversion` and hashes, and whether the built module matches the
loaded one. A build-only run leaves the loaded driver untouched.

`--install-reload` needs password-free `sudo -n`. It builds and validates first, then unloads and
installs the module (an open controller or observer makes the unload fail; nothing is force-removed or
killed). Failure after unload leaves output stopped with no automatic rollback. It does not update the
installed CLI or overlay.

`--test` runs `dev-tools/test.sh --abi --hardware` then `--scope --hardware` over `ssh -t`. Run it from
an interactive terminal: the scope sequence waits for you to press Enter at each case. The scripts can
also be run by hand in the run directory printed by `deploy.sh`:

```sh
bash dev-tools/test.sh --abi                        # read-only status check
sudo bash dev-tools/test.sh --abi --hardware        # mutating; emits waveforms
sudo bash dev-tools/test.sh --scope --hardware      # interactive scope cases
sudo bash dev-tools/test.sh --scope --hardware --extended100M   # optional nominal 100 Mbit/s case
sudo bash dev-tools/test.sh --lifecycle --hardware  # unbind/rebind with open descriptors
```

Reports go to `.harness-artifacts/` in the run directory. SSH hosts, paths and destinations are
restricted to simple characters; there is no `eval`.

### What the tests cover

* **ABI** (`--abi --hardware`): incomplete and short uploads, `ENOSPC`, invalid CONFIG and RATE, competing
  writers, observer permissions, busy errors, start/stop/restart, descriptor sharing and final close,
  child exit without cleanup, and large (64 KiB) uploads in unaligned chunks.
* **Scope** (`--scope --hardware`): `FFFF0000` at 1 and 50 Mbit/s, then `FFFF0000 FF000000` at 1 Mbit/s
  (16 high, 16 low, 8 high, 24 low microseconds, 64 us wrap). Enter records only that you acknowledged a
  case; **you** judge the waveform. These patterns do not prove jitter, electrical quality or safety.
* **Lifecycle** (`--lifecycle`): unbinds and rebinds the PWM device with open descriptors; checks
  `ENODEV` on stale descriptors and that a fresh stream works. It rebinds on failure or signal.

All tests stop and close only their own controller. SIGKILL cannot run cleanup (kernel final-close then
applies). Clock/allocation fault injection, stress, suspend, shutdown, process-kill and electrical
qualification are **not** covered.

## Higher bit rates

The default stays at 50 Mbit/s. Rates up to a nominal 100 Mbit/s have been seen to work for short
patterns; nothing above is planned. When trying a candidate rate (62.5, ~83.3, 100 Mbit/s), increase
step by step with `status`, `stop`, `rate N`, `start`, watching for errors for at least a minute, and
stop and collect logs if quality deteriorates. For `FF FF 00 00` the output frequency is
`actual_rate / 32`; for alternating bits it is `actual_rate / 2`. Scope bandwidth and probe loading
limit measured amplitude and shape.

## Remaining acceptance testing

Smoke tests have passed (binding, short patterns, clock changes, ABI, lifecycle, package install and
removal). Still outstanding before claiming qualification:

1. First-bit and word-order capture on a loaded scope or logic analyser using asymmetric words, including
   one-word buffers, joins and full-buffer wrap.
2. Independent measurement of tick spacing and jitter at 50 MHz and slower integer rates.
3. Kill, suspend, shutdown and hot-unbind with open handles, and long CPU/memory/IO stress with
   waveform-continuity checks.
4. Fault injection for DMA, FIFO, clock and allocation failures; unload/reload with lockdep or KASAN where
   available.
5. Electrical qualification of the idle and active pin. Rates above 100 Mbit/s need a separate review.

## Extending the supported kernel range

1. Review the DMA slave-address, termination, clock and pin-ownership contracts on the new kernel (see
   [design.md](design.md#implementation-notes)).
2. Add its headers to `dev-tools/kernels.txt` and build with `W=1`.
3. Run the hardware regression and scope checks on a Pi.
4. Update `PS_MIN_PATCH`/`ps_release_supported()` in `pwmstream.c`, the preflight, `packaging/dkms.conf.in`
   and the docs together, and bump `VERSION`.

## Releases

Push a tag `vX.Y.Z` equal to `VERSION`; CI builds and publishes `pwmstream_X.Y.Z_arm64.deb`.
