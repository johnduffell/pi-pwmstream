<!-- SPDX-License-Identifier: Apache-2.0 -->

# ABI reference (version 1)

The interface to `/dev/pwmstream0`, defined in [`pwmstream.h`](../pwmstream.h). Use the supplied header
and macros; ioctl numbers differ between operating systems. For normal playback use
[`pwmstream-cli`](usage.md#using-the-cli) instead.

Structures use fixed-width **native-endian** 32-bit fields, no pointers, no `long`/`size_t` and no
implicit padding, so a 32-bit client works on a 64-bit kernel. All reserved fields must be zero. Sample
byte order is separate from field endianness (see the sample format in the user guide).

## Operations

| Operation | Semantics |
| --- | --- |
| `PWMSTREAM_CONFIG` | 16 bytes: version, sample_bytes, rate_hz, reserved. Stopped only. Allocates new buffers and resets the upload to zero. Rate 0 selects 50 MHz. The previous sample is replaced only if configuration succeeds. |
| `write(fd, bytes, n)` | Appends to the configured sample, in any chunk size; may accept fewer than `n` bytes. No seek or `pwrite`. Not allowed while playing. |
| `PWMSTREAM_RATE` | 16 bytes: version, rate_hz, reserved[2]. Stopped only. Keeps the sample and upload. Rate must be nonzero. Success clears `last_error`. |
| `PWMSTREAM_START` | No argument. Needs a complete upload and a working clock. Already running: `EBUSY`. Incomplete or missing sample: `ENODATA`. |
| `PWMSTREAM_STOP` | No argument. Idempotent. Disables output and synchronously terminates DMA; keeps the sample and any error for inspection. A latched error still needs a successful RATE or CONFIG before START. |
| `PWMSTREAM_STATUS` | 64 bytes: version, flags, sample_bytes, uploaded_bytes, requested_hz, actual_hz, signed last_error, pwm_errors, dma_status, dma_residue, reserved[6]. A snapshot, never a frequency measurement. |

## Ownership

`open(O_RDWR)` or `open(O_WRONLY)` claims the single controller; further writers get `EBUSY`. Any number
of `O_RDONLY` descriptors may query status but cannot change hardware (`EPERM`). `dup`/`fork` share one
controller. The final close stops output and discards the sample, so a new controller must configure
and upload again. The `CONTROLLER` status flag means *some* controller exists. There is no read, mmap,
poll or live sample replacement.

## Errors and limits

* `CONFIG` rejects bad size, version or reserved fields with `EINVAL`; allocation can fail with `ENOMEM`.
* Samples are 4 to 1,048,576 bytes and a multiple of four. Storage is at most 1 MiB staging plus 1 MiB
  DMA-coherent (a replacement can briefly double it). Staging may be virtually contiguous; the DMA
  buffer must be physically contiguous and below 4 GiB.
* Excess writes return a short count up to the remaining length, then `ENOSPC`. A fault in user memory
  gives a short write, or `EFAULT` if nothing was copied. A partial upload cannot start.
* Unknown commands return `ENOTTY` when stopped; a removed device returns `ENODEV`.
* Rates are 100 kHz to 100 MHz. The driver checks the request, the clock framework's rounded rate before
  changing anything, and the actual rate afterwards; the actual rate may exceed 100 MHz by at most 1 Hz.
  Rates above 50 MHz are experimental and not a validated operating range.
* A failed hardware clock change leaves `actual_hz` as the read-back, `requested_hz` at the last success
  and `last_error` negative. The clock is left disabled and START is blocked until RATE or CONFIG
  succeeds. The clock rate itself is not rolled back.

## Status flags

`RUNNING`, `COMPLETE` (upload complete), `CONTROLLER`, `CLOCK_READY`, `DMA_LIMITED` (the provider cannot
report raw DMA errors, so error detection is partial), and `CONFIG_READY` (bit 5): a sample is
configured, the clock is enabled, no blocking error is latched, and DMA is running or confirmed stopped.
Clients should ignore unknown flag bits.

| State or outcome | Sample / upload | Readiness | Error |
| --- | --- | --- | --- |
| No CONFIG yet, or after final close | None | `CONFIG_READY` clear | Previous diagnostic kept |
| Successful CONFIG | New, empty | `CLOCK_READY`, `CONFIG_READY` set | Cleared |
| Successful RATE | Kept | `CLOCK_READY`; `CONFIG_READY` if a sample exists | Cleared |
| Validation or allocation failure | Kept | Unchanged | ioctl fails; latched error unchanged |
| Hardware rate or enable failure | Kept | Both clear | Latched; retry RATE or CONFIG |
| Successful STOP | Kept | Depends on existing error | Existing error kept |
| Playback fault, startup fault or suspend | Kept | `CONFIG_READY` clear | Fault or `EHOSTDOWN` latched |

`pwm_errors` latches PWM status bits 2..8 (FIFO write/read, channel gaps, bus error). `dma_status` uses
the DMAengine values COMPLETE=0, IN_PROGRESS=1, PAUSED=2, ERROR=3; after a stop it is COMPLETE with zero
residue, meaning the DMA has stopped, not that a waveform finished. `last_error` is zero or a negative
errno; STATUS itself can succeed while reporting a failed stream.
