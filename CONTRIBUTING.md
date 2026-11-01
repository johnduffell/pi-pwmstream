<!-- SPDX-License-Identifier: Apache-2.0 -->

# Contributing

Contributions are welcome, and getting started is easy: all you need is a computer. Most changes
(docs, the CLI, scripts, packaging, tests) can be built and checked without a Pi, and the checks
take a few minutes. You only need a Pi 3B+ (and ideally a scope) to test the driver itself.

Good ways to help:

- Try it on a new kernel and report what you see
  ([Supporting a newer kernel](#supporting-a-newer-kernel)).
- Improve the docs, tests or tooling.
- Fix a bug or add a feature. For anything big, open an issue first so we can agree the approach.

## Overview

| Path                                                                     | What it is                                                                                                                                                |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pwmstream.c`, `pwmstream.h`, `pwmstream-cli.c`, `pwmstream-overlay.dts` | The kernel module, its ABI header, the CLI and the device-tree overlay                                                                                    |
| `packaging/`, `VERSION`                                                  | The DKMS `.deb`                                                                                                                                           |
| `preflight.sh`, `pwmstream-report.sh`, `uninstall.sh`, `Makefile`        | Manual install, preflight and diagnostics (`pwmstream-report.sh` ships as `pwmstream-report`)                                                             |
| `dev-tools/`, `tests/`, `.devcontainer/`                                 | Development only: Pi deploy and test scripts, test suites, dev environment                                                                                |
| `docs/`                                                                  | [User guide](docs/usage.md), [ABI reference](docs/abi.md), [development guide](docs/development.md), [design notes and hardware research](docs/design.md) |

This repository is the driver only. A separate frontend repository will build on the versioned ABI
in `pwmstream.h`. `make help` lists the build and check targets.

## Getting started

1. Fork and clone the repository.
2. Set up a build environment. Either:
   - **Devcontainer (easiest):** open the repository in an IDE that supports devcontainers and
     reopen it in the container. See [.devcontainer/README.md](.devcontainer/README.md).
   - **Without it:** on any Debian 13 arm64 machine, install the build tools and kernel headers as
     described in [docs/development.md](docs/development.md#hardware-free-checks), which also covers
     other machines.
3. Make your change on a branch.
4. Run the checks. They need no hardware:

   ```sh
   make check-all
   ```

5. Open a pull request. CI runs the same `make check-all` on an arm64 runner, so it should pass
   there if it passes for you.

If your change affects the driver's behaviour, say how you tested it, and on which kernel and Pi.
Pi-side tests are manual: see [Testing on a Pi](docs/development.md#testing-on-a-pi).

## Ground rules

- **Hardware safety.** The driver drives GPIO18 directly and owns PWM0 and its DMA channel. Never
  test with an electrically unsafe load attached, never stop other PWM/DMA users by guessing, and
  don't relax the kernel-release or ownership guards without a reviewed justification. Installation
  never edits boot settings silently. Don't describe smoke tests as full qualification.
- **Licensing.** `pwmstream.c` is `Apache-2.0 OR GPL-2.0-only`; everything else is Apache-2.0. Keep
  SPDX headers on new files and don't copy GPL-only code into Apache-2.0-only files.

## Reporting bugs

Use the [issue template](../../issues/new?template=bug_report.md). Include your kernel, board, the
`pwmstream-report` output and logs. Please try the latest release first.

## Supporting a newer kernel

If a Pi OS update brings a kernel outside the supported range, open an issue with your `uname -r`
output, or better still send a pull request following the steps in
[docs/development.md](docs/development.md#extending-the-supported-kernel-range). Hardware results
from a Pi running that kernel are the most valuable evidence.

## Releases

Maintainers publish a release by pushing a tag `vX.Y.Z` equal to `VERSION`; CI builds and publishes
the `.deb`.
