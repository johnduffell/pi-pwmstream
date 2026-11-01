<!-- SPDX-License-Identifier: Apache-2.0 -->

# Development guide

For contributors and maintainers. Installing and using the driver is in [usage.md](usage.md); the
contributing rules are in [CONTRIBUTING.md](../CONTRIBUTING.md).

Everything here uses the scripts in `dev-tools/` and the checks in `tests/`. None of it ships in the
`.deb`.

## Hardware-free checks

Which setup to use:

| Your machine                         | Route                                                                                                                                                    |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| arm64 Linux, or an Apple Silicon Mac | The devcontainer (below), then `make check-all`                                                                                                          |
| x86 Linux, Intel Mac or Windows      | The devcontainer under arm64 emulation (untested), or the Pi route                                                                                       |
| Any machine with a Pi 3              | `dev-tools/deploy.sh` builds and tests on the Pi; see [Testing on a Pi](#testing-on-a-pi). Needs only `ssh` and bash, but skips the hardware-free checks |

No Pi is needed to build the module. You need a Debian 13 arm64 environment with the pinned kernel
headers. The easiest option is the optional [devcontainer](../.devcontainer/README.md), which sets
this up for you. Otherwise, on any Debian 13 arm64 machine:

```sh
sudo apt-get install -y --no-install-recommends build-essential device-tree-compiler python3 kmod \
  openssh-client sparse shellcheck cppcheck dkms lintian
sh dev-tools/fetch-kernel-headers.sh --install
```

```sh
make help        # list targets, production vs development
make check-all   # every check below; this is what CI runs
```

| Target            | Checks                                                                                                |
| ----------------- | ----------------------------------------------------------------------------------------------------- |
| `check`           | Builds the CLI and native test client with strict warnings; ABI layout, rate parser and CLI selftests |
| `check-install`   | Install/uninstall scripts against mock files: gates reject before any write                           |
| `check-harness`   | Deploy/test scripts against mocked `ssh`/`scp`: gating, failure propagation, cleanup                  |
| `check-preflight` | Preflight gate against synthetic paths, including the real `bcm2835-pwm` binding                      |
| `check-overlay`   | Overlay replaces exactly one PWM node and keeps its `reg` (fixture, not a bootable board)             |
| `check-kbuild`    | Builds the module with `W=1` against the pinned headers and checks vermagic                           |
| `check-static`    | sparse, shellcheck, `gcc -fanalyzer`, cppcheck (needs those tools)                                    |
| `check-package`   | Builds the `.deb`; lintian, a scratch DKMS build, the kernel-range matrix, `pwmstream-enable` logic   |

`dev-tools/fetch-kernel-headers.sh --install` downloads the headers pinned in
`dev-tools/kernels.txt`, verifies their SHA-256 and installs them. Update the pins together with a
compatibility review, never to an unreviewed kernel.
`make module KDIR=/path/to/configured/kernel/build` builds against another tree; macOS cannot build
Linux modules and its ioctl encodings differ, so rebuild the CLI on Linux. `make deb` builds the
package into `dist/pwmstream_<version>_arm64.deb` (it needs `dtc`).

These checks prove the code builds and the scripts behave. They do not load the module or touch
hardware.

## Testing on a Pi

Use a test-safe Pi you own, running the pinned kernel with the overlay already enabled (install the
package first, see [usage.md](usage.md)). Pi-side tests are never run by CI.

```sh
bash dev-tools/deploy.sh --host user@raspberrypi                                   # build only
bash dev-tools/deploy.sh --host user@raspberrypi --install-reload                  # also replace the loaded module
bash dev-tools/deploy.sh --host user@raspberrypi --install-reload --test           # also run ABI and scope tests
bash dev-tools/deploy.sh --host user@raspberrypi --install-reload --test --lifecycle   # plus unbind/rebind
```

`deploy.sh` copies an explicit source list to a fresh `~/code/pi-pwmstream/runs/build-UTC-PID` on
the Pi (`--destination` changes the base), checks SHA-256, verifies the kernel, headers and
architecture, builds with `W=1` and runs the hardware-free tests. It never installs packages, edits
boot files or reboots. The log reports the module's `srcversion` and hashes, and whether the built
module matches the loaded one. A build-only run leaves the loaded driver untouched.

`--install-reload` needs password-free `sudo -n`. It builds and validates first, then unloads and
installs the module (an open controller or observer makes the unload fail; nothing is force-removed
or killed). Failure after unload leaves output stopped with no automatic rollback. It does not
update the installed CLI or overlay.

`--test` runs `dev-tools/test.sh --abi --hardware` then `--scope --hardware` over `ssh -t`. Run it
from an interactive terminal: the scope sequence waits for you to press Enter at each case. The
scripts can also be run by hand in the run directory printed by `deploy.sh`:

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

- **ABI** (`--abi --hardware`): incomplete and short uploads, `ENOSPC`, invalid CONFIG and RATE,
  competing writers, observer permissions, busy errors, start/stop/restart, descriptor sharing and
  final close, child exit without cleanup, and large (64 KiB) uploads in unaligned chunks.
- **Scope** (`--scope --hardware`): `FFFF0000` at 1 and 50 Mbit/s, then `FFFF0000 FF000000` at 1
  Mbit/s (16 high, 16 low, 8 high, 24 low microseconds, 64 us wrap). Enter records only that you
  acknowledged a case; **you** judge the waveform. These patterns do not prove jitter, electrical
  quality or safety.
- **Lifecycle** (`--lifecycle`): unbinds and rebinds the PWM device with open descriptors; checks
  `ENODEV` on stale descriptors and that a fresh stream works. It rebinds on failure or signal.

All tests stop and close only their own controller. SIGKILL cannot run cleanup (kernel final-close
then applies). Clock/allocation fault injection, stress, suspend, shutdown, process-kill and
electrical qualification are **not** covered.

## Higher bit rates

The default is 50 Mbit/s; the rate limits and what could limit the pin are in
[design.md](design.md#rates-and-limits). To try a candidate rate (62.5, ~83.3, 100 Mbit/s), step up
with `status`, `stop`, `rate N`, `start`, watch for errors for at least a minute, and stop and
collect logs if quality deteriorates. Scope bandwidth and probe loading limit the measured amplitude
and shape.

## Remaining acceptance testing

Smoke tests have passed (binding, short patterns, clock changes, ABI, lifecycle, package install and
removal). Still outstanding before claiming qualification:

1. First-bit and word-order capture on a loaded scope or logic analyser using asymmetric words,
   including one-word buffers, joins and full-buffer wrap.
2. Independent measurement of tick spacing and jitter at 50 MHz and slower integer rates.
3. Kill, suspend, shutdown and hot-unbind with open handles, and long CPU/memory/IO stress with
   waveform-continuity checks.
4. Fault injection for DMA, FIFO, clock and allocation failures; unload/reload with lockdep or KASAN
   where available.
5. Electrical qualification of the idle and active pin. Rates above 100 Mbit/s need a separate
   review.

## Extending the supported kernel range

The driver only loads on kernels it has been reviewed against, so a new kernel needs evidence from
real hardware before it is listed as supported. There are two cases.

**A newer patch release of the supported series** (for example `6.18.55+rpt-rpi-v8`) is already
accepted: the probe logs that it is newer than the last review, and no code change is needed to use
it. What helps is evidence that it works. Do steps 1 to 4 below on a Pi running it, then report the
result in an issue or PR. To move the reviewed baseline, also do step 5.

**A new series or variant** (for example `6.19.x`, or a 2712 kernel) is rejected until the range is
widened, which needs the full process.

1. **Review the kernel source.** Diff the files the driver depends on between the reviewed tag and
   the new one, and check that each contract in [design.md](design.md#kernel-dependencies) still
   holds: `bcm2835-dma.c` (slave address, termination, cyclic transfers), `pwm-bcm2835.c`,
   `pinctrl-bcm2835.c` (strict pin ownership), `kernel/dma/mapping.c` and `direct.h` (DMA mapping),
   the clock driver, and the `bcm2710.dtsi` address translation. The source references at the end of
   design.md give the starting points. Never bypass the probe checks to make it load.
2. **Build against the new headers.** Add the kernel's header packages to `dev-tools/kernels.txt`
   (`RELEASE`, `PACKAGE_VERSION` and one `SHA256 path` line per package) and run
   `sh dev-tools/fetch-kernel-headers.sh --install && make check-kbuild`. Take each SHA-256 from the
   archive's `Packages` index over HTTPS, or from `sha256sum` of the downloaded `.deb` files. The
   build must be clean with `W=1`, and the vermagic must match the kernel.
3. **Test on a Pi running that kernel.** Install the package, then run
   `bash dev-tools/deploy.sh --host user@raspberrypi --install-reload --test --lifecycle` from an
   interactive terminal, with a scope on pin 12 (see [Testing on a Pi](#testing-on-a-pi)). All ABI
   checks must pass and the scope cases must show the expected waveforms at 1 and 50 Mbit/s.
4. **Check the installed package.** Rebuild the `.deb`, install it on the Pi, reboot, and confirm
   `dkms status` shows the module built for the new kernel and `pwmstream-cli run` works as a normal
   user. Run `pwmstream-report` and keep the output.
5. **Update the range and baseline.** These places hard-code the kernel version, so change them
   together:
   - `pwmstream.c`: `PS_REVIEWED_RELEASE`, `PS_MIN_PATCH` and `ps_release_supported()`.
   - `preflight.sh`, `packaging/pwmstream-enable`, `packaging/postinst`, `dev-tools/test.sh` and
     `dev-tools/remote-build.sh`: the range check and its message.
   - `packaging/dkms.conf.in` (`BUILD_EXCLUSIVE_KERNEL`) and `packaging/kernel-hook`: the range
     patterns, plus the package description in `packaging/build-deb.sh`.
   - `tests/package.sh`, `tests/preflight.sh` and `tests/harness.sh`: the range cases and mock
     kernel strings. Add cases on both sides of every new boundary.
   - `README.md`, `docs/usage.md` and the design notes: the supported range and reviewed baseline.
   - `VERSION`: bump it, because the supported range changed.
6. **Run `make check-all`.** It must pass with the new range, then open the PR with the evidence:
   the `uname -r` output, the `pwmstream-report` output, the test results and what you saw on the
   scope.

## Releases

Push a tag `vX.Y.Z` equal to `VERSION`; CI builds and publishes `pwmstream_X.Y.Z_arm64.deb`.
