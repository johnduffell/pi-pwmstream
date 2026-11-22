<!-- SPDX-License-Identifier: Apache-2.0 -->

# ABI reference (version 1)

The interface to `/dev/pwmstream0`, defined in [`pwmstream.h`](../pwmstream.h). Use the supplied
header and macros; ioctl numbers differ between operating systems. For normal playback use
[`pwmstream-cli`](usage.md#using-the-cli) instead.

Structures use fixed-width **native-endian** 32-bit fields, no pointers, no `long`/`size_t` and no
implicit padding, so a 32-bit client works on a 64-bit kernel. All reserved fields must be zero.
Pattern byte order is separate from field endianness (see the pattern format in the user guide).

## Operations

| Operation             | Semantics                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PWMSTREAM_CONFIG`    | 32 bytes: version, channels, pattern_bytes, bit_rate_hz, reserved[4]. `channels` is a bitmask; only 1 (channel 1) is supported, and `write()` uploads to channel 1. `pattern_bytes` is per channel. `bit_rate_hz` 0 keeps the current bit rate (50 Mbit/s after open). Stopped only. Allocates new buffers and resets the upload to zero. The previous pattern is replaced only if configuration succeeds. |
| `write(fd, bytes, n)` | Appends to the configured pattern, in any chunk size; may accept fewer than `n` bytes. No seek or `pwrite`. Not allowed while playing.                                                                                                                                                                                                                                                                     |
| `PWMSTREAM_BIT_RATE`  | 16 bytes: version, bit_rate_hz, reserved[2]. Stopped only. Keeps the pattern and upload. The bit rate must be nonzero. Success clears `last_error`.                                                                                                                                                                                                                                                        |
| `PWMSTREAM_START`     | 16 bytes: version, flags, reserved[2]. `flags` must be 0, meaning repeat until stopped. Needs a complete upload and a working clock. Already running: `EBUSY`. Incomplete or missing pattern: `ENODATA`.                                                                                                                                                                                                   |
| `PWMSTREAM_STOP`      | No argument. Idempotent. Disables output and synchronously terminates DMA; keeps the pattern and any error for inspection. A latched error still needs a successful BIT_RATE or CONFIG before START.                                                                                                                                                                                                       |
| `PWMSTREAM_STATUS`    | 96 bytes: version, flags, pattern_bytes, uploaded_bytes, requested_bit_rate_hz, actual_bit_rate_hz, signed last_error, pwm_errors, dma_status, dma_residue, channels (reads 1), reserved[13] (zero). A snapshot, never a frequency measurement.                                                                                                                                                            |

## Ownership

`open(O_RDWR)` or `open(O_WRONLY)` claims the single controller; further writers get `EBUSY`. Any
number of `O_RDONLY` descriptors may query status but cannot change hardware (`EPERM`). `dup`/`fork`
share one controller. The final close stops output and discards the pattern, so a new controller
must configure and upload again. The `CONTROLLER` status flag means _some_ controller exists. There
is no read, mmap, `poll()` or live pattern replacement; `poll()` is unsupported and will be added
only when a feature needs it.

## Errors and limits

- `CONFIG` rejects bad size, version, `channels` (0, or any bit other than channel 1) or non-zero
  reserved fields with `EINVAL`; `START` rejects non-zero `flags` or reserved fields the same way.
  Allocation can fail with `ENOMEM`.
- Patterns are 4 to 1,048,576 bytes and a multiple of four. Storage is at most 1 MiB staging plus 1
  MiB DMA-coherent (a replacement can briefly double it). Staging may be virtually contiguous; the
  DMA buffer must be physically contiguous and below 4 GiB. The 1 MiB maximum
  (`PWMSTREAM_MAX_PATTERN_BYTES`) is an arbitrary, conservative choice, not a hardware limit; larger
  values have not been tried (see [design.md](design.md#3-dma-buffer)).
- Excess writes return a short count up to the remaining length, then `ENOSPC`. A fault in user
  memory gives a short write, or `EFAULT` if nothing was copied. A partial upload cannot start.
- Unknown commands return `ENOTTY` when stopped; a removed device returns `ENODEV`.
- Bit rates are 100 kHz to 100 MHz. The driver checks the request, the clock framework's rounded
  rate before changing anything, and the actual rate afterwards; the actual rate may exceed 100 MHz
  by at most 1 Hz. Rates above 50 MHz are experimental and not a validated operating range.
- A failed hardware clock change leaves `actual_bit_rate_hz` as the read-back,
  `requested_bit_rate_hz` at the last success and `last_error` negative. The clock is left disabled
  and START is blocked until BIT_RATE or CONFIG succeeds. The clock rate itself is not rolled back.

## Status flags

`RUNNING`, `UPLOAD_COMPLETE`, `CONTROLLER`, `CLOCK_READY`, `DMA_LIMITED` (the provider cannot report
raw DMA errors, so error detection is partial), and `CONFIG_READY` (bit 5): a pattern is configured,
the clock is enabled, no blocking error is latched, and DMA is running or confirmed stopped. Clients
should ignore unknown flag bits.

| State or outcome                         | Pattern / upload | Readiness                                         | Error                                |
| ---------------------------------------- | ---------------- | ------------------------------------------------- | ------------------------------------ |
| No CONFIG yet, or after final close      | None             | `CONFIG_READY` clear                              | Previous diagnostic kept             |
| Successful CONFIG                        | New, empty       | `CLOCK_READY`, `CONFIG_READY` set                 | Cleared                              |
| Successful BIT_RATE                      | Kept             | `CLOCK_READY`; `CONFIG_READY` if a pattern exists | Cleared                              |
| Validation or allocation failure         | Kept             | Unchanged                                         | ioctl fails; latched error unchanged |
| Hardware rate or enable failure          | Kept             | Both clear                                        | Latched; retry BIT_RATE or CONFIG    |
| Successful STOP                          | Kept             | Depends on existing error                         | Existing error kept                  |
| Playback fault, startup fault or suspend | Kept             | `CONFIG_READY` clear                              | Fault or `EHOSTDOWN` latched         |

`pwm_errors` latches PWM status bits 2..8 (FIFO write/read, channel gaps, bus error). `dma_status`
uses the DMAengine values COMPLETE=0, IN_PROGRESS=1, PAUSED=2, ERROR=3; after a stop it is COMPLETE
with zero residue, meaning the DMA has stopped, not that a waveform finished. `last_error` is zero
or a negative errno; STATUS itself can succeed while reporting a failed stream.

## Sizes and extension rules

Each structure is padded to leave room for fields that are foreseen but not implemented, rounded up
to a multiple of 8 bytes. The ABI version stays 1 while changes follow these rules.

| Structure  | Size | Room for                                                                          |
| ---------- | ---- | --------------------------------------------------------------------------------- |
| `config`   | 32 B | Per-channel pattern sizes and bit rates, a second channel, a one-shot count       |
| `start`    | 16 B | Start flags such as one-shot, a per-channel mask                                  |
| `bit_rate` | 16 B | A channel selector                                                                |
| `status`   | 96 B | Per-channel upload and error state, a one-shot completion count, further counters |

- Reserved fields and unassigned flag bits must be written as zero; the driver returns `EINVAL` for
  anything else, so a client can never get a silent no-op from a newer feature.
- Unassigned ioctl numbers return `ENOTTY`, and clients ignore unknown status flag bits.
- "Stopped only" and similar `EBUSY` rules may later be relaxed (a failing call may start to
  succeed), never the reverse.
- The device node name and permissions do not change with the ABI.
