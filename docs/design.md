<!-- SPDX-License-Identifier: Apache-2.0 -->

# Design

How `pwmstream` turns the Raspberry Pi 3B+ PWM block into a hardware-clocked bit-pattern generator,
and what we know about the hardware it relies on. Install and use: [usage.md](usage.md). Interface:
[abi.md](abi.md). Build and test: [development.md](development.md). Links to external references
point to the [Sources](#sources).

**Target:** Raspberry Pi 3B+ on Debian 13 with kernel `6.18.50+rpt-rpi-v8`. The driver is
experimental: short patterns have been checked on a scope up to a nominal 100 Mbit/s (see
[Validation status](#validation-status)); sustained-load reliability and electrical quality are not
qualified.

## Overview

The driver repeats a user-supplied bit pattern out of one pin, with no CPU involvement while it
runs. The numbers in the diagram are used in the headings below:

```text
 (1) sample file -> (2) /dev/pwmstream0 -> (3) DMA buffer -> (4) DMA ring -> (5) PWM FIFO -> (6) serializer -> (7) GPIO18
                        write()             (coherent)         (cyclic)       (DREQ-paced)     (32 bits/word)      (pin 12)
                                                                                                    ^
                                                                                              (8) PWM clock
                                                                                                    ^
                                                                                       (9) clock source (crystal -> PLLD)
```

| Block                                      | What it is                                        |
| ------------------------------------------ | ------------------------------------------------- |
| [1. Sample file](#1-sample-file)           | The bit pattern supplied by the user              |
| [2. Character device](#2-character-device) | The driver's user interface and owner of state    |
| [3. DMA buffer](#3-dma-buffer)             | Kernel memory the DMA engine reads from           |
| [4. DMA ring](#4-dma-ring)                 | A cyclic DMA transfer that loops over the buffer  |
| [5. PWM FIFO](#5-pwm-fifo)                 | The PWM block's eight-word input queue            |
| [6. Serializer](#6-serializer)             | Shifts each FIFO word out one bit per clock tick  |
| [7. GPIO18](#7-gpio18-the-pin)             | The output pin                                    |
| [8. PWM clock](#8-pwm-clock)               | Sets the bit rate                                 |
| [9. Clock source](#9-clock-source)         | The crystal and PLL the PWM clock is divided from |

The usage model is: **stop, upload a packed sample, set the bit rate, start, and repeat in hardware
until stopped.** After start only hardware moves data, so nothing timing-sensitive depends on
user-space scheduling. The sections below follow the data from the pin back to the file. Each says
what the block is in the hardware, how Linux exposes it, and what the driver does. How the blocks
are started, stopped and monitored together is in
[Start, stop and fault handling](#start-stop-and-fault-handling).

## The blocks

### 7. GPIO18 (the pin)

**Hardware.** The Pi 3B+ uses the **Broadcom BCM2837B0** (quad Cortex-A53). It is not a Pi 4
(BCM2711) or Pi 5 (RP1) platform, but its PWM, clock and DMA peripherals belong to the BCM2835
family, which is why Linux drivers use `bcm2835` names ([Pi 3B+ spec], [BCM2835 manual],
[pwm-bcm2835]). PWM0 can be routed to two pins:

| GPIO   | Header pin | Function   |
| ------ | ---------- | ---------- |
| GPIO18 | 12         | ALT5, PWM0 |
| GPIO12 | 32         | ALT0, PWM0 |

These are alternatives for the same channel, not independent streams. The onboard analogue audio
uses both PWM channels, so audio conflicts with the driver, and ownership must cover the PWM block
and its clock, not just the pin ([PWM overlay]).

**Linux.** Pin muxing goes through pinctrl. The Raspberry Pi 6.18.50 kernel sets strict pinctrl,
which stops other GPIO users while the pin is muxed to PWM.

**Driver.** It uses GPIO18 and holds no GPIO descriptor (one would prevent the switch to ALT5).
Stopped, the pin is an input with pull-down; running, it is ALT5. A pre-existing GPIO owner makes
the switch fail, and boot-time pinctrl selection can change the pin before probe completes, so
existing pin users must be removed before applying the overlay. Pinctrl lookup failures keep their
original errno, including deferred probe.

### 6. Serializer

**Hardware.** The PWM block can serialize FIFO words instead of generating period/duty PWM. Channel
1 is configured for serializer mode (`MODE1`), FIFO consumption (`USEF1`) and a range of 32 bits
(`RNG1`), then enabled with `PWEN1` ([BCM2835 manual], chapter 9). With range 32, each FIFO word is
emitted **most-significant bit first**: word 0 bit 31 … bit 0, then word 1, and so on. Only one
channel may consume the FIFO; if both do, data is split between them.

**Linux.** The standard `pwm-bcm2835` driver only exposes period, duty and enable, so it cannot
stream a packed pattern ([pwm-bcm2835]). `pwmstream` replaces it for this block through a
device-tree overlay rather than binding both, and the platform driver name `bcm2835-pwm` is part of
what the probe checks.

**Driver.** It uses channel 1 only, with range 32, and leaves channel 2, repeat-last, inversion and
mark/space off.

**Sample format.** The upload format is chronological bytes, most-significant bit first within each
byte. The driver converts each four-byte group to the native 32-bit word the FIFO expects; on a
little-endian Pi, copying the bytes unchanged would reverse the order within each word.

| Native FIFO word       | At 50 Mbit/s                                  |
| ---------------------- | --------------------------------------------- |
| `0xAAAAAAAA` repeated  | Alternating bits: 25 MHz square wave          |
| `0xFFFF0000` repeated  | 16 ticks high, 16 low: 1.5625 MHz square wave |
| Asymmetric known words | Check bit order and word/buffer boundaries    |

### 8. PWM clock

**Hardware.** The clock sets the serializer's tick. Use **bit rate** for serializer ticks and
**waveform frequency** for the repeating signal:

```text
tick duration       = 1 / actual_bit_rate
buffer duration     = buffer_bits / actual_bit_rate
waveform frequency  = cycles_in_buffer * actual_bit_rate / buffer_bits
fastest square wave = actual_bit_rate / 2
```

The Raspberry Pi device tree sets the PWM clock to **50 MHz**, giving a 20 ns tick (the standard PWM
driver rejects periods under two cycles; [Pi device tree], [pwm-bcm2835]). The clock is a divider
(`CM_PWMCTL` and `CM_PWMDIV` in the clock manager) on a parent chosen from the
[clock source](#9-clock-source): 12-bit integer plus 12-bit fractional divide, so
`bit rate = parent rate / divisor`. What rates are possible, and what limits them, is in
[Rates and limits](#rates-and-limits).

| Bit rate   | Tick  | Alternating-bit square | DMA payload rate | Eight-word FIFO duration |
| ---------- | ----- | ---------------------- | ---------------- | ------------------------ |
| 50 Mbit/s  | 20 ns | 25 MHz                 | 6.25 MB/s        | 5.12 us                  |
| 100 Mbit/s | 10 ns | 50 MHz                 | 12.5 MB/s        | 2.56 us                  |

**Linux.** The common clock framework (CCF) provides the rate: a client requests one and reads back
what it got. The PWM divider can be fractional, which modulates bit spacing, so integer division is
preferable ([BCM2835 manual], chapter 6; [clk-bcm2835]).

**Driver.** It requests a rate, reads back the result and reports both. It never retunes a shared
PLL or writes clock registers, and it keeps a CCF exclusive-rate reference across rate changes. That
protects the rate against other CCF consumers, but not against firmware or raw register users.
Changing the rate also changes the delta-sigma oversampling ratio if the sample was generated for a
particular rate, so fidelity must be reconsidered. The valid range and rounding rules are in
[abi.md](abi.md#errors-and-limits).

### 9. Clock source

**Hardware.** The PWM clock is divided down from a parent selected by the clock manager's peripheral
mux. The mux offers ground, the 19.2 MHz crystal (`xosc`), two debug inputs, and the peripheral taps
of three PLLs (`plla_per`, `pllc_per`, `plld_per`) plus `pllh_aux` ([clk-bcm2835]). On the reviewed
kernel the PWM clock uses `plld_per`. Read from `/sys/kernel/debug/clk/clk_summary` on a Pi 3B+
running 6.18.50 (rates are set by firmware and can differ on other firmware or configurations):

```text
osc 19.2 MHz -> plld 2000 MHz (x~104) -> plld_per 500 MHz (/4) -> pwm 50 MHz (/10) -> 3f20c000.pwm
```

PLLD has other outputs and `plld_per` has other consumers, so they share this source:

| Clock       | Rate      | Used by                                     |
| ----------- | --------- | ------------------------------------------- |
| `plld_per`  | 500 MHz   | Parent of the clocks below                  |
| `uart`      | 48 MHz    | The PL011 serial port (`3f201000.serial`)   |
| `gp1`       | 24 MHz    | General-purpose clock 1; no kernel consumer |
| `hsm`       | 163.7 MHz | HDMI state machine; unused when idle        |
| `plld_core` | 500 MHz   | SDRAM clock                                 |
| `plld_dsi*` | 7.8 MHz   | Display (DSI) outputs; idle                 |

The other PLLs serve other blocks and are not PWM sources on this setup: `pllc` (2.4 GHz) feeds the
VPU clock (400 MHz: I2C, SD card, mini UART) and `emmc`; `plla` feeds the video blocks; `pllb` feeds
the ARM cores; `pllh` feeds HDMI pixels.

**Linux.** The clock driver registers these as CCF clocks, and the device tree assigns the PWM clock
its 50 MHz rate. Firmware also configures the PLLs and can change clocks outside the kernel's view.

**Driver.** It does not choose a parent, and never retunes a PLL, because that would change the UART
and every other `plld_per` consumer. It only requests a PWM clock rate from the divider. Its
exclusive-rate hold shows as a protect count on `pwm`, `plld_per` and `plld`, so other CCF users
cannot retune that chain while the stream runs; firmware and raw register writes are not covered.

#### Rates and limits

**Rate steps.** The PWM divider is 12.12 fixed point (12-bit integer, 12-bit fraction), with a
minimum divisor of 2 ([clk-bcm2835]). The bit rate is `parent / divisor` with the divisor in steps
of 1/4096, so the step between neighbouring rates grows with the rate:

```text
rate step ≈ bit_rate² / (parent × 4096) ≈ bit_rate² / 2.05e12 Hz      (parent 500 MHz)
```

| Bit rate   | Divisor | Step between rates | Relative step |
| ---------- | ------- | ------------------ | ------------- |
| 1 Mbit/s   | 500     | 0.5 Hz             | 0.5 ppm       |
| 10 Mbit/s  | 50      | 49 Hz              | 4.9 ppm       |
| 25 Mbit/s  | 20      | 305 Hz             | 12 ppm        |
| 50 Mbit/s  | 10      | 1.2 kHz            | 24 ppm        |
| 100 Mbit/s | 5       | 4.9 kHz            | 49 ppm        |

The step is computed from the source; it has not been measured on a Pi. What the driver does with a
requested rate:

- The request is a whole number of Hz (`u32`), which is finer than the divider step above about 1.4
  Mbit/s, so the divider, not the ABI, sets the resolution there.
- The clock driver picks the divisor by truncating `parent × 4096 / request`, so the actual rate is
  at or slightly above the request, within one step. It is **not** rejected for differing from the
  request: `actual_hz` reports the result, and the driver only checks that the rounded rate is in
  its 100 kHz to 100 MHz range (plus the 1 Hz tolerance).
- Readback carries the parent's own rounding: the 500,000,006 Hz `plld_per` is why a 50 Mbit/s
  request reads back as 50,000,000 and 100 Mbit/s as 100,000,001 (see
  [Validation status](#validation-status)).
- The result is a long-term average. The fractional part is produced by MASH dithering, which
  modulates individual bit widths. This matters only to a receiver that looks at single bits; an
  output low-pass filter averages it out.
- The driver's 100 MHz ceiling is a policy, not a divider limit: with a 500 MHz parent the hardware
  would accept ÷4 (125 Mbit/s) and ÷2 (250 Mbit/s), but the driver rejects them with `ERANGE`.
  Raising the ceiling is a deliberate change that needs the scope and fault-flag tests described
  below.
- The PWM clock has no restricted parent list (unlike the PCM clock), and the clock framework picks
  whichever parent gives the closest rate. In principle a request can therefore move the clock to
  the 19.2 MHz crystal (for rates up to 9.6 Mbit/s) or another PLL tap, instead of staying on
  `plld_per`; PLLC is skipped on BCM2835-family SoCs unless it is already the parent. This follows
  from the source and has **not** been observed on a Pi, so check the parent with `clk_summary`
  after setting a low rate.

**Hitting a requested frequency.** The loop length and the bit rate together set the waveform
frequency: `f = cycles × bit_rate / loop_bits`, and the loop must be a multiple of 32 bits (see
[3. DMA buffer](#3-dma-buffer)). The driver never promises the requested frequency; it reports
`actual_hz`, and a frontend should do the same with the frequency it achieved. In order of
preference:

1. **Whole-bit period, trimmed clock.** Choose an integer period `N` near `bit_rate / f`, tile it to
   a multiple of 32 bits, then trim the bit rate until `f` is met. Every cycle is identical, so the
   spectrum is clean. At high rates, search several nearby periods for the one whose required rate
   lands closest to a divider step.
2. **Fractional period for the leftover error.** A period of `a/b` bits (lowest terms) needs an
   `a`-bit pattern holding `b` cycles, tiled to `lcm(a, 32)` bits, at most `32 × a` (so `a` up to
   about 262,000 in 1 MiB). Around a 50-bit period that resolves about 0.0002 bit, finer than the
   clock step. The cost is that cycles alternate between neighbouring whole-bit lengths, so each
   edge is placed to the nearest bit (up to one tick, 20 ns at 50 Mbit/s) and the error repeats at
   the beat rate. That adds spurs near the carrier that an output filter only partly removes.
3. **Otherwise report the achieved frequency**, and its error, computed from `actual_hz`; a frontend
   may refuse when the error exceeds a tolerance the user set.

The buffer is rarely the limit: whole-bit periods up to about 260,000 bits tile exactly, and lower
bit rates give finer clock steps. Fine fractions of long periods are where capacity runs out.

The clock tree does not set a hard upper limit. The practical limit is whichever of these fails
first, and none has been measured above 100 Mbit/s:

| Stage              | What limits the rate                                                                                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Clock manager      | The divider's maximum output and the PLL's clock quality; no documented PWM maximum was found. Fractional division adds jitter                                                                    |
| FIFO and DMA       | Bandwidth is small (12.5 MB/s at 100 Mbit/s), but the eight-word FIFO lasts only 2.56 us, so service latency, bus contention and DREQ timing set the underrun margin. Doubling the rate halves it |
| Serializer         | Shifts one bit per clock, so it follows the clock; the manual quotes no separate limit                                                                                                            |
| GPIO pad           | Output drive strength and slew-rate settings and the pad's own rise and fall time; the driver leaves the pad defaults unchanged (not verified)                                                    |
| Board and receiver | Trace and cable capacitance, termination, and the receiver's bandwidth. A 100 Mbit/s alternating pattern is a 50 MHz square wave and was already less clean on the scope                          |

A rate that the clock framework accepts is therefore not proof that it works. The most likely first
limits are the pad and board (waveform quality) and FIFO service latency (underruns). Establishing
the true ceiling needs scope and fault-flag tests above 100 Mbit/s, with the driver ceiling raised
for the test.

### 5. PWM FIFO

**Hardware.** The FIFO holds **eight 32-bit words** and raises a DMA request (DREQ) when it needs
data. Status flags report empty, full, gap and bus errors ([BCM2835 manual]). The repeat-last-word
option is not waveform looping: it only repeats the last word when the FIFO starves, and can hide
bad output. The DMA ring does the looping.

**Driver.** DREQ threshold is 8 and panic 4, with a 4-byte width and a maximum burst of 1. The FIFO
is cleared before start. Startup waits for it to be **not empty**, not full (see
[FIFO priming](#fifo-priming)). The sticky error bits are polled by the fault monitor.

### 4. DMA ring

**Hardware and Linux.** The shared DMA controller moves data from memory to the FIFO address, paced
by DREQ. The Raspberry Pi `bcm2835-dma` driver implements `DMA_CYCLIC`: it builds hardware control
blocks and links the last back to the first, so no CPU resubmission is needed ([bcm2835-dma]).
`pwmstream` is a DMAengine client, not a controller driver: it requests a channel, configures a
memory-to-peripheral transfer, prepares the cyclic descriptor and starts it ([DMAengine client
docs]).

**Driver.** There are no per-word or per-loop interrupts and no CPU refill. DMA starts at word zero,
so there is no CPU pre-fill duplication.

- **Addresses.** The slave config uses the **CPU resource address** plus FIFO offset `0x18`:
  `bcm2835-dma` calls `dma_map_resource()`, which applies `phys_to_dma()`, and `bcm2710.dtsi`
  translates CPU `0x3f20c018` to bus `0x7e20c018`. Passing the bus address would translate twice.
  Probe verifies the board, controller, DREQ 5, raw DT address, resource, DMA range and a balanced
  map/unmap of the FIFO address. CPU mappings, peripheral bus addresses and DMA addresses are
  different concepts on this board, so addresses come from device tree and the DMA API, never
  hard-coded ([Pi device tree], [DMA API HOWTO]).
- **Stopping.** STOP calls `dmaengine_terminate_sync()` before anything else is touched (see
  [Start, stop and fault handling](#start-stop-and-fault-handling)). The provider aborts and resets
  the channel; that remains a provider contract, not hardware verification.

### 3. DMA buffer

**Linux.** Buffers come from the kernel DMA API: a JVM array or direct buffer is not automatically
DMA-addressable, and coherent allocation does not remove every ordering requirement ([DMA API
HOWTO]).

**Driver.** Coherent sample storage is allocated on `dmaengine_get_dma_device(chan)`, not the PWM
platform device, and must fit in 32 bits. The shared DMA controller's mask is not changed. Storage
is bounded (at most 1 MiB staging plus 1 MiB coherent) because large coherent allocations can fail.
The 1 MiB figure is an arbitrary, conservative compromise, not a hardware limit: it is far below the
DMA engine's transfer-length limit and the 4 GiB address limit. Larger sizes have not been tried;
the real ceiling depends on how large a contiguous coherent allocation succeeds on a running Pi.

**Sizing.** At 50 Mbit/s a 1 MiB buffer loops every 167.77216 ms. A buffer should hold a whole
number of waveform cycles so that no padding distorts the waveform; for example, sixteen 50-bit
cycles occupy 800 bits (100 bytes) and make a 1 MHz waveform. Repeating an arbitrary fragment may
add a periodic artefact at the buffer rate, which is a waveform-generation concern separate from DMA
looping.

**Loop length.** The length is a multiple of four bytes (32 bits), the FIFO word, so the loop cannot
end on an arbitrary bit. Any whole-bit period `N` is still exact: tile it to a multiple of
`lcm(N, 32)` bits (at most `32 × N`, so 50 bits needs 800). That fits 1 MiB (8,388,608 bits) for any
period up to about 260,000 bits. Non-integer periods need either a trimmed bit rate or a longer
fractional pattern; see [Hitting a requested frequency](#rates-and-limits).

### 2. Character device

**Interface.** `/dev/pwmstream0` gives an owner file descriptor, serialises operations and takes a
binary upload. Sysfs is built for small text attributes, and separate rate/buffer/enable files would
race between processes, so it was not used ([sysfs docs]). The full contract is in [abi.md](abi.md).

**Lifecycle.**

```text
stopped -> upload complete sample + set rate -> configured
configured -> start -> running (loops until stopped)
running -> stop -> configured
configured -> replace sample and/or rate -> configured
```

Sample and rate changes are rejected while running rather than modifying live DMA memory, and
seamless replacement is out of scope. The driver validates size, alignment, rate and a complete
upload before starting, keeps the active sample immutable, and stops when the controlling file
descriptor closes. There is one controller at a time; other processes may observe status only.

**Access.** A udev rule gives group `gpio` read/write access, so no `/dev/mem`, raw DMA access or
`sudo` is needed. Nothing is world-writable.

**Locking and lifetime.** A mutex serialises upload, ioctls, the monitor and removal. Open
descriptors hold a reference to a non-devm state object; unbind marks it dead, stops, frees quiesced
resources and deregisters the miscdevice, after which descriptors fail without touching freed
resources. Module ownership blocks ordinary unload while descriptors remain.

### 1. Sample file

A raw binary file: chronological bytes, MSB first, 4 bytes to 1 MiB and a multiple of four. The
format and how it becomes FIFO words are in [6. Serializer](#6-serializer); the CLI usage is in
[usage.md](usage.md#using-the-cli).

## Start, stop and fault handling

**Start** brings the blocks up in this order:

1. Convert the whole staged sample into the DMA buffer (3) and issue a DMA write barrier.
2. Clear the FIFO (5) and configure the serializer (6) for range 32.
3. Start the DMA ring (4) **while PWM consumption is disabled**, so it primes the FIFO.
4. Wait up to 100 ms for the FIFO to become non-empty, or for a PWM error.
5. Mux the pin (7) to ALT5 and enable channel 1.

If priming fails, START times out and stops. It never enables an empty FIFO.

**Stop** disables PWM consumption and DREQ, then calls `dmaengine_terminate_sync()` **before**
clearing the FIFO or touching DMA memory, and attempts the idle pin state even if termination fails.
If termination errors, sample memory is retained and configure/rate/start are blocked until a STOP
succeeds. After a failed final-close termination, new controllers get `EIO`; unbind retries and, if
that also fails, retains the DMA allocation and channel until reboot. Cleanup failures are logged
without overwriting the original errno in status. Shutdown stops output; suspend stops it and
latches `EHOSTDOWN`; nothing restarts after resume.

**Monitoring.** A delayed work item checks the sticky FIFO, gap and bus bits and the DMAengine
status about every 20 ms, and status ioctls check too; errors latch and stop output synchronously.
The provider's `tx_status` mostly reports cookie and residue, not raw DMA error bits, hence
`DMA_LIMITED`. There is no independent progress watchdog, bit-level fidelity proof or automatic
recovery.

## Kernel dependencies

The driver depends on behaviour of the reviewed downstream kernel (6.18.50). Other kernels or DMA
providers need review, and the probe checks must not be bypassed to make probing succeed. When
supporting a new kernel (see [development.md](development.md#extending-the-supported-kernel-range)),
re-check:

| Behaviour relied on                                                                       | Used by                            |
| ----------------------------------------------------------------------------------------- | ---------------------------------- |
| Strict pinctrl and `function_is_gpio` in BCM2835 pinctrl                                  | [7. GPIO18](#7-gpio18-the-pin)     |
| Platform driver `bcm2835-pwm` and its DT binding                                          | [6. Serializer](#6-serializer)     |
| CCF rate requests and exclusive-rate references on the PWM clock                          | [8. PWM clock](#8-pwm-clock)       |
| PWM clock parent (`plld_per`) and its 50 MHz device-tree rate                             | [9. Clock source](#9-clock-source) |
| `bcm2835_dma_xlate`, `bcm2835_dma_prep_dma_cyclic`, termination, `tx_status`              | [4. DMA ring](#4-dma-ring)         |
| `dma_map_resource()` applying `phys_to_dma()`, and the `bcm2710.dtsi` address translation | [4. DMA ring](#4-dma-ring)         |
| DMA mask and coherent allocation on the DMA device                                        | [3. DMA buffer](#3-dma-buffer)     |

The pinned source references are under [Sources](#sources).

## Validation status

Checked on a Pi 3B+ with a scope, using short patterns and no reported driver errors unless noted.

| Pattern             | Rate                   | Result                                                      |
| ------------------- | ---------------------- | ----------------------------------------------------------- |
| `FFFF0000`          | 1 Mbit/s               | 31.25 kHz, 50% duty                                         |
| `FFFF0000`          | 50 Mbit/s              | 1.5625 MHz, 50% duty                                        |
| Alternating bits    | 50 Mbit/s              | 25 MHz square wave                                          |
| `FFFF0000 FF000000` | 1 Mbit/s               | 16 high, 16 low, 8 high, 24 low microseconds                |
| `FFFF0000`          | 62.5 and ~83.33 Mbit/s | Expected waveform                                           |
| Alternating bits    | 100 Mbit/s             | ~50 MHz square wave, less clean; scope or GPIO not isolated |
| ABI and lifecycle   | Hardware tests         | Pass (see [development.md](development.md#testing-on-a-pi)) |

A 100 MHz request reads back as 100,000,001 Hz, which the driver accepts (1 Hz of upper-bound
rounding). Readback is not a frequency measurement. Nothing above the manual's nominal 100 MHz is
planned.

**Not done:** sustained-load, jitter and electrical qualification; CPU, memory and I/O load tests;
suspend; fault injection of the DMA termination path.

## FIFO priming

Startup waits for the FIFO to be **not empty**, not full. The first implementation waited for FULL,
and timed out after 100 ms at 1 Mbit/s with the FIFO partly filled (status neither EMPTY nor FULL,
no errors). The manual does not require a full FIFO before enabling transmission, and DMA does prime
a FIFO whose channel is disabled, so the driver starts the ring with PWM consumption disabled, waits
for non-empty (or a PWM error, with a 100 ms timeout) and only then enables the channel. If you
change this sequence, expect this failure first.

## Sources

Sources describe hardware and particular code versions; they do not identify the exact
kernel/configuration installed on the target Pi.

**Reviewed kernel source.** Package
[linux_6.18.50-1+rpt1.dsc](https://archive.raspberrypi.com/debian/pool/main/l/linux/linux_6.18.50-1+rpt1.dsc)
(version `1:6.18.50-1+rpt1`) corresponds to Linux commit
[`cff533ae`](https://github.com/raspberrypi/linux/commit/cff533aec2fa601846766b32ff57204e0a61bed7)
(`stable_20260911`), per the
[packaging changelog commit](https://github.com/RPi-Distro/linux-packaging/commit/57beb6cc27d4a9e7997413e1213e6d7f4a346c03).
Its Raspberry Pi patch sets `function_is_gpio` and `.strict = true` in BCM2835 pinctrl. Files at
that commit that the implementation relies on:
[`bcm2835-dma.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/drivers/dma/bcm2835-dma.c)
(`bcm2835_dma_xlate`, `bcm2835_dma_prep_dma_cyclic`, termination, `tx_status`),
[`kernel/dma/mapping.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/kernel/dma/mapping.c)
and
[`direct.h`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/kernel/dma/direct.h)
(`dma_map_resource()` to `phys_to_dma()`),
[`bcm2710.dtsi`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/arch/arm/boot/dts/broadcom/bcm2710.dtsi),
[`pinctrl-bcm2835.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/drivers/pinctrl/bcm/pinctrl-bcm2835.c),
[`pwm-bcm2835.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/drivers/pwm/pwm-bcm2835.c)
(platform driver name `bcm2835-pwm`) and
[`bcm2835-i2s.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/sound/soc/bcm/bcm2835-i2s.c)
(an in-tree client that passes the resource physical FIFO address to this provider).

- [Pi 3B+ spec]: BCM2837B0 and board features.
- [BCM2835 manual]: chapter 9, pp.138-146: PWM, FIFO, serializer, DMA controls and status; chapter
  4: DMA control blocks; chapter 6: general-purpose clock discussion.
- [pwm-bcm2835] and [Pi device tree]: conventional PWM operations and the assigned 50 MHz clock.
- [PWM overlay]: pin functions and analogue-audio conflict.
- [bcm2835-dma]: `bcm2835_dma_prep_dma_cyclic`, cyclic descriptor linkage, and capability
  registration.
- [DMAengine client docs]: channel allocation, slave transfers, cyclic preparation, and termination.
- [DMA API HOWTO]: DMA addresses, coherent allocation, and memory ordering.
- [sysfs docs]: small text attributes and access modes.
- [clk-bcm2835]: clock tree, PWM clock registration, divider constraints and rate handling.

[Pi 3B+ spec]: https://www.raspberrypi.com/products/raspberry-pi-3-model-b-plus/
[BCM2835 manual]: https://datasheets.raspberrypi.com/bcm2835/bcm2835-peripherals.pdf
[pwm-bcm2835]: https://github.com/torvalds/linux/blob/master/drivers/pwm/pwm-bcm2835.c
[Pi device tree]:
  https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm/boot/dts/broadcom/bcm283x.dtsi
[PWM overlay]:
  https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm/boot/dts/overlays/pwm-overlay.dts
[bcm2835-dma]: https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/dma/bcm2835-dma.c
[DMAengine client docs]: https://docs.kernel.org/driver-api/dmaengine/client.html
[DMA API HOWTO]: https://docs.kernel.org/core-api/dma-api-howto.html
[sysfs docs]: https://docs.kernel.org/filesystems/sysfs.html
[clk-bcm2835]: https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/clk/bcm/clk-bcm2835.c
