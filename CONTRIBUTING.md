<!-- SPDX-License-Identifier: Apache-2.0 -->

# Contributing

Licensing: `pwmstream.c` is `Apache-2.0 OR GPL-2.0-only`; everything else is
Apache-2.0. Keep SPDX headers on new files and do not copy GPL-only code into
Apache-2.0-only files.

## Checks (no hardware needed)

In the devcontainer (Debian 13 aarch64, pinned kernel headers):

```sh
make check-all   # everything below, no hardware; `make help` lists the targets
```

That runs `check check-install check-harness check-preflight check-overlay check-kbuild check-static check-package`
(ABI/CLI, install scripts, deploy harness, preflight, overlay, a kernel build against the pinned headers,
sparse/shellcheck/cppcheck, and the `.deb` with lintian and a scratch DKMS build).

CI (`.github/workflows/ci.yml`) runs `make check-all` on an arm64 runner in a `debian:13` container; pushing a tag `vX.Y.Z` matching `VERSION` publishes the `.deb` as a release. This repository is the driver only; the frontend lives in its own repository and depends on the versioned ABI in `pwmstream.h`.

Hardware checks never run in CI. Use `dev-tools/deploy.sh` and `dev-tools/test.sh` against a Pi you own, and read [docs/development.md](docs/development.md) first.

## Hardware safety

This driver drives GPIO18 directly and owns PWM0 and its DMA channel. Never install or
test with an electrically unsafe load attached, never stop other PWM/DMA users by
guessing, and do not relax the kernel-release or ownership guards without a reviewed
justification. Pi-side install, uninstall and waveform tests are explicit and manual;
installation never edits boot settings silently. Do not describe smoke tests as full
qualification.

Report bugs using the issue template (kernel, board, `pwmstream-report` or `install-state.sh` output, logs).

## Repository layout

| Path | What it is |
| --- | --- |
| `pwmstream.c`, `pwmstream.h`, `pwmstream-cli.c`, `pwmstream-overlay.dts` | Production: the kernel module, its ABI header, the CLI and the device-tree overlay |
| `packaging/`, `VERSION` | Production: the DKMS `.deb` |
| `check-install.sh`, `install-state.sh`, `uninstall.sh`, `Makefile` | Production: manual install, preflight and diagnostics |
| `dev-tools/`, `tests/`, `.devcontainer/` | Development only: Pi deploy and test scripts, test suites, dev environment |
| `docs/` | [User guide](docs/usage.md), [ABI reference](docs/abi.md), [development guide](docs/development.md), [design notes and hardware research](docs/design.md) |

`make help` lists the build and check targets; `make deb` builds `dist/pwmstream_<version>_arm64.deb`.

## Supporting a newer kernel

The supported range is deliberately narrow. If a Pi OS update brings a kernel outside it, open an issue
with the `uname -r` output, or send a pull request following the steps in
[docs/development.md](docs/development.md#extending-the-supported-kernel-range). Hardware results from
a Pi running that kernel are the most valuable evidence.

## Releases

Push a tag `vX.Y.Z` equal to `VERSION`; CI builds and publishes the `.deb`. A separate frontend
repository will build on the versioned ABI in `pwmstream.h`.
