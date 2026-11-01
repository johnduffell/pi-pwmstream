<!-- SPDX-License-Identifier: Apache-2.0 -->

# Raspberry Pi 3B+ PWM serializer and cyclic DMA research

Research recorded on 20 October 2026, updated 21 October with initial Pi
startup diagnostics. An experimental driver is implemented; sustained
short-buffer playback has now been observed up to nominal 100 Mbit/s.
Sustained-load reliability and physical waveform quality are not qualified.

**Target:** Raspberry Pi 3B+ on Debian 13 with kernel `6.18.50+rpt-rpi-v8`. Install and use:
[usage.md](usage.md). Build and test: [development.md](development.md). The
[implementation notes](#implementation-notes) and the reviewed kernel source references are at the end.

## Initial hardware findings: FIFO priming

The Pi has now booted `6.18.50+rpt-rpi-v8`. The driver binds, reports a
50 MHz default clock, and leaves output stopped. The first playback test
used a four-byte `FF FF 00 00` sample at a requested/read-back 1 Mbit/s.
Startup timed out after 100 ms while waiting for FIFO FULL.

The diagnostic snapshot, captured before cleanup, was:

```text
ret=-110 ctl=0x22 sta=0x0 dmac=0x80000408 rng1=32
dma_status=1 residue=0 sample_bytes=4 actual_hz=1000000
```

According to the peripheral manual [2, pp.142-145]:

- `ctl=0x22` selects serializer and FIFO use, with the channel disabled.
  The FIFO is writable while the channel is disabled.
- Status bit 1 is EMPTY and bit 0 is FULL. `sta=0` therefore reports neither
  empty nor full, with no PWM error flags: consistent with partial priming.
- DMAC exposes configurable request thresholds. The manual does not require
  waiting for FULL before enabling transmission.

DMAengine status 1 is IN_PROGRESS; it does not prove continuing transfer
progress. Zero residue on this tiny cyclic buffer does not establish FIFO
occupancy. The exact reason filling stopped short of FULL is not yet known.
The observed nonempty FIFO nevertheless contradicts the earlier suspicion
that a disabled channel necessarily prevents all DMA priming.

Startup order is therefore our own design: DMAengine's cyclic API describes
repeated transfers, not a PWM FIFO-full startup requirement.

**Implemented correction:** wait for FIFO **not empty**, or a PWM error,
before enabling the channel. Retain the 100 ms timeout, explicit error
checks, pre-cleanup diagnostics, and existing cleanup. DMA still primes from
sample word zero while transmission is disabled; no CPU prefill, buffer
rotation, or speculative early consumption is introduced.

This removes an unjustified startup condition. It does not prove adequate
FIFO headroom, correct first-bit timing, or uninterrupted playback. Repeat
the 1 Mbit/s test, check the expected 31.25 kHz/50% signal, then exercise
stop/restart and inspect error status before testing faster rates.

## Conclusions

**Playback update, 21 October:** after changing startup to wait for nonempty,
the user observed the expected 31.25 kHz/50% output at 1 Mbit/s, 1.5625 MHz/50%
and 25 MHz alternating output at 50 Mbit/s, and correct two-word asymmetric
playback at 1 Mbit/s. Status reported no errors. Sustained-load testing remains
outstanding. The software ceiling is now experimentally 100 Mbit/s, with the
default retained at 50 Mbit/s.

**Higher-clock update:** the user subsequently observed the expected
`FFFF0000` waveform at 62.5 and approximately 83.333333 Mbit/s with no
reported errors. A 100 MHz request returned 100,000,001 Hz from the clock
framework and was rejected by the driver's strict actual-rate ceiling,
before playback. The driver now permits exactly 1 Hz of upper-bound
readback rounding while retaining the 100 MHz request ceiling. With this
correction, the user observed an approximately 50 MHz square wave from
alternating bits, with no reported errors. Its shape was less clean at this
frequency; scope/probe limitations versus GPIO fidelity were not isolated.
Readback is not a frequency measurement. The experiment stops here; no
requests above the manual's nominal 100 MHz point are planned.

The intended interface is exactly: **disable, upload a packed sample buffer,
set its playback bit rate, enable, and repeat in hardware until disabled**.
Scala or another unprivileged application can operate it if an administrator
has installed the driver and granted access to its interface.

A kernel driver can own the hardware, allocate DMA-capable memory, and use
DMAengine cyclic transfers to feed the PWM serializer. Small text controls
fit sysfs, but a character device is a better fit for uploading the binary
sample buffer and managing exclusive ownership.

The bit rate need not be fixed at 50 MHz. That is our established operating
point, not proof of a hardware maximum. An adjustable clock should be part
of the interface, with requested and actual rates reported separately.
Higher rates are candidates for validation, not guaranteed simply because
DMA has enough average bandwidth.

## 1. The Pi 3B+ chipset and relevant peripherals

The Pi 3B+ uses the **Broadcom BCM2837B0**, with a quad-core Cortex-A53 CPU.
It is not a Pi 4 BCM2711 or a Pi 5 RP1-based GPIO platform. The relevant
peripherals belong to the BCM2835-family design, which explains the
`bcm2835` names in Linux PWM, clock, and DMA drivers. [1][2][3]

The BCM2835 peripheral manual documents the PWM block's serializer, FIFO,
and DMA-request facilities. It is useful for these shared peripherals, but
does not mean every BCM2835 address or platform assumption can be copied
unchanged onto a Pi 3B+. In particular, CPU mappings, peripheral bus addresses,
and DMA addresses are different concepts. A driver should obtain resources
from device tree and the DMA API rather than hard-code userspace addresses.
[2][3][7]

PWM0 can be routed to:

| GPIO numbering | Header pin | Pin function |
| --- | --- | --- |
| GPIO18 | 12 | ALT5, PWM0 |
| GPIO12 | 32 | ALT0, PWM0 |

These are alternate routes for the same channel, not independent streams.
The Raspberry Pi PWM overlay documents the pin functions and warns that
onboard analogue audio uses both PWM channels. Exclusive ownership must
cover the PWM block and clock, not just the selected GPIO. [4]

## 2. Serializer operation

The PWM block can serialize FIFO words instead of generating conventional
period/duty PWM. For one output, configure channel 1 for serializer mode
(`MODE1`), FIFO consumption (`USEF1`), and a range of 32 bits (`RNG1`).
Enable it with `PWEN1`. [2, chapter 9]

The FIFO holds **eight 32-bit words**. With range 32, each word is emitted
**most-significant bit first**:

```text
word 0: bit 31 ... bit 0
word 1: bit 31 ... bit 0
...
```

Define the upload format explicitly. A useful wire format is chronological
bytes, most-significant bit first within each byte. The driver then converts
each four-byte group to the native 32-bit value the FIFO expects. On a
little-endian Pi, blindly copying chronological bytes into native words
would reverse the byte ordering within each serialized word.

Initial reference patterns:

| Native FIFO word | At 50 Mbit/s |
| --- | --- |
| `0xAAAAAAAA` repeated | Alternating bits: 25 MHz square wave |
| `0xFFFF0000` repeated | 16 ticks high, 16 low: 1.5625 MHz square wave |
| Asymmetric known words | Check bit order and word/buffer boundaries |

Use only one channel initially. If both channels consume the FIFO, data is
distributed between them, which changes the expected stream. [2]

## 3. Linux interfaces to this hardware

### Standard Linux PWM driver

`pwm-bcm2835` exposes conventional period/duty/polarity/enable controls. Its
implementation writes PWM range and duty registers; it does not expose a
packed serializer stream through PWM sysfs. The current prototype therefore
cannot acquire this capability merely by writing a different duty value.
[3]

The Raspberry Pi device tree assigns a **50 MHz** PWM clock. With that
rate, integer tick quantisation gives 20 ns resolution; the PWM driver
rejects periods below two clock cycles. This agrees with the observed
ordinary-PWM behavior. It does not establish FIFO/DMA streaming performance.
[3]

### Linux DMAengine

The Raspberry Pi `bcm2835-dma` driver implements cyclic transfers and
advertises `DMA_CYCLIC`. It builds hardware control blocks and points the
last one back to the first. This is the required indefinite ring, without
userspace resubmitting each iteration. [5]

A new PWM-streaming driver would be a **DMAengine client**, not a replacement
DMA controller driver. It requests an available channel, configures
memory-to-peripheral transfers and PWM DREQ routing through the platform's
device-tree/DMA binding, prepares a cyclic descriptor, and starts it.
Standard PWM sysfs does not already provide that client. [5][6]

## 4. Proposed userspace contract

### Lifecycle

```text
disabled -> upload complete sample + set rate -> configured
configured -> enable -> looping
looping -> disable -> configured
configured -> replace sample and/or rate -> configured
```

This matches the desired stop/configure/start usage. Reject sample or rate
changes while running, rather than modifying live DMA memory. Seamless
replacement is deliberately outside the first interface.

The driver should:

- Validate buffer size, alignment, format, rate, and complete upload before
  enabling. Initially require a whole number of 32-bit FIFO words.
- Keep the active sample immutable and enforce exclusive control.
- Allocate bounded DMA-capable storage and account for allocation failures.
- Claim registers, pin configuration, clock, and DMA resources exclusively.
  Replace the normal PWM binding for this block rather than bind both drivers.
- Configure the stopped peripheral, clear FIFO/status, prepare the ring, and
  establish a verified priming/start sequence.
- On disable, synchronously terminate DMA and disable/clear the peripheral
  before freeing or changing its buffer, then establish a defined idle level.
- Report configuration failures, underruns, and hardware errors explicitly.
  DMA and FIFO failure detection/recovery must be designed; cyclic submission
  alone is not an error-monitoring service.
- Stop safely on driver removal and define process-exit behavior. Recommended
  initial character-device policy: stop on the controlling file's final close.

Correct driver ownership improves safety, but DMA programming, start/stop
ordering, and error handling still require validation. [6][7]

### Sysfs versus a character device

Conceptually the following controls would fit sysfs:

| Attribute | Meaning |
| --- | --- |
| `enable` | Start/stop the configured repeating sample |
| `bit_rate_hz` | Requested serializer bit rate |
| `actual_bit_rate_hz` | Clock rate actually configured |
| `sample_bits` | Loaded sample length |
| `status` | Disabled/running/error state |

These are **proposed names**, not existing files. Sysfs is designed primarily
for small ASCII attributes, usually one value per file. A binary sysfs
attribute is possible, but needs explicit sizing, offset, partial-write, and
commit semantics; an ordinary text attribute is not a large waveform upload
interface. [8]

The recommended initial interface is a character device, for example
`/dev/pwmstream0`, with `write()` for sample data and defined configuration/
start/stop/status commands. It offers a natural owner file descriptor and a
way to serialize operations. The ABI must specify how partial writes become
a complete sample; it must not treat each write syscall as necessarily being
the entire upload.

Controls could instead use sysfs alongside the character device, but a
single owner-scoped interface avoids races between separate processes
changing shared rate, buffer, and enable files. A small native wrapper may
be convenient for issuing ioctls from Scala; Scala/Java can directly use
ordinary file I/O for any text and binary file operations.

### Non-root access

Yes: runtime control need not require root. An administrator installs/binds
the driver and configures ownership and permissions. A udev rule can assign
the character device to a dedicated group with read/write access, allowing
the Scala application to open it without `/dev/mem`, raw DMA access, or sudo.

Sysfs attributes can also be granted appropriate access through driver modes
and administrator-managed ownership/permissions. A `/dev` permission rule
does not automatically change permissions on sysfs attributes. Avoid
world-writable controls; authorize a specific user/group. Resource bounds
and input validation remain mandatory even for authorized callers.

The two interface styles are alternatives for controlling the same kernel
machinery, not fundamentally different DMA approaches.

## 5. Adjustable clock and rates above 50 MHz

Use **bit rate** for serializer ticks and **waveform frequency** for the
repeating signal. They are not the same:

```text
tick duration       = 1 / actual_bit_rate
buffer duration     = buffer_bits / actual_bit_rate
waveform frequency  = cycles_in_buffer * actual_bit_rate / buffer_bits
fastest square wave = actual_bit_rate / 2
```

The known 20 ns quantum applies at 50 Mbit/s. If the clock changes, so does
the quantum. Adjusting the bit rate provides another way to tune waveform
frequency with the same buffer. It also changes the delta-sigma oversampling
ratio and noise spectrum, so fidelity/filter behavior must be reconsidered.

The clock should be managed through Linux's common clock framework. Request
and read back an achievable rate, avoiding uncoordinated direct clock
register writes. Report requested and actual rates and define whether
rounding is accepted or rejected. Prefer integer division for uniform bit
spacing; fractional division can introduce timing modulation.
The BCM clock driver describes PWM divider capabilities; the manual's
general-purpose-clock discussion explains the fractional-divider tradeoff.
[2, chapter 6][9]

The peripheral manual describes the PWM clock as nominally **100 MHz**.
Combined with a programmable clock, this supports investigating rates above
50 MHz; it is not a board-level signal-integrity guarantee or proof that
every divider-derived rate works. A nominal 500 MHz source divided by ten
gives 50 MHz, and divided by five gives 100 MHz, if that source/rate and route
are available in the active clock tree. Do not retune a shared PLL to obtain
a convenient rate for this application. [2][9]

| Candidate bit rate | Tick | Alternating-bit square | DMA payload rate | Eight-word FIFO duration |
| --- | --- | --- | --- | --- |
| 50 Mbit/s | 20 ns | 25 MHz | 6.25 MB/s | 5.12 us |
| 100 Mbit/s | 10 ns | 50 MHz | 12.5 MB/s | 2.56 us |

The second row is an **experimental candidate**, not an established
capability. DMA average throughput is only one constraint. Others include
clock-provider restrictions, peripheral timing, FIFO service latency,
memory/bus contention, GPIO rise/fall times, loading, wiring, and receiving
bandwidth. Faster rates halve the FIFO's latency margin even when average
memory bandwidth looks comfortable.

Start with 50 Mbit/s as the baseline. Expose adjustable rates
within a validated range, report actual rates, and only expand that range
after continuous-stream tests and physical measurements. Do not label an
unvalidated higher rate safe merely because a clock request succeeds.

## 6. Buffering and playback checks

At 50 Mbit/s, a 1 MiB buffer loops every 167.77216 ms. Pack multiple waveform
cycles if necessary to obtain a whole number of words without padding the
waveform. For example, sixteen 50-bit cycles occupy 800 bits (100 bytes) and
represent a 1 MHz waveform.

Delta-sigma phase and error state must be compatible with repetition.
Repeating an arbitrary fragment may add a periodic artefact at the buffer
rate. This is a waveform-generation concern separate from correct DMA
looping.

Use the kernel DMA API for buffers and device-visible addresses. Coherent
allocation does not eliminate ordering requirements, and a JVM array or
direct buffer is not automatically DMA-addressable. Large coherent
allocations can fail; choose bounded sizes and an allocation strategy that
works with the selected DMAengine controller. [7]

DMA must be paced by PWM DREQ, with a fixed FIFO destination and incrementing
memory source. DREQ mapping and DMA channel number are distinct. The driver must choose and
validate its thresholds and latency margin.

The FIFO's repeat-last-word option is not waveform looping. It repeats only
the last word on starvation and can conceal incorrect output. The DMA ring
is what repeats the complete waveform. Check FIFO gap/error flags, word
boundaries, complete-buffer wrap, startup, disable, and restart. [2]

Validate asymmetric patterns first, then alternating bits, then a generated
sample under CPU, memory, and I/O load. The sustained arbitrary-stream rate,
selected Linux interface have passed initial short-pattern tests on the
target Pi; extended reliability and output quality remain unqualified.
No timing-sensitive work should depend on Scala/JVM scheduling.

## Implementation notes

How the driver in `pwmstream.c` behaves, and why. These depend on the reviewed downstream kernel
(6.18.50); other kernels or DMA providers need review, and the probe checks must not be bypassed to make
probing succeed.

* **Pin ownership.** Pinctrl is strict and the driver holds no GPIO descriptor (one would prevent the
  switch to ALT5). While ALT5 is active, strict mux ownership blocks competing GPIO requests; a
  pre-existing GPIO owner makes the switch fail. Stopped, the pin is an input with pull-down; running,
  it is ALT5. Boot-time pinctrl selection can change the pin before probe completes, so existing pin
  users must be removed before applying the overlay. Pinctrl lookup failures keep their original errno,
  including deferred probe.
* **DMA addresses.** Coherent sample storage is allocated on `dmaengine_get_dma_device(chan)`, not the
  PWM platform device, and must fit in 32 bits. The shared DMA controller's mask is not changed. The
  slave config uses the **CPU resource address** plus FIFO offset `0x18`: `bcm2835-dma` calls
  `dma_map_resource()`, which applies `phys_to_dma()`, and `bcm2710.dtsi` translates CPU `0x3f20c018` to
  bus `0x7e20c018`. Passing the bus address would translate twice. Probe verifies the board,
  controller, DREQ 5, raw DT address, resource, DMA range and a balanced map/unmap of the FIFO address.
* **Start.** START converts the whole staged sample, issues a DMA write barrier, clears the FIFO,
  configures the serializer (range 32), starts the DMA ring **while PWM consumption is disabled**, and
  waits up to 100 ms for the FIFO to become non-empty. Only then is the pin muxed active and channel 1
  enabled. DREQ threshold 8, panic 4, 4-byte width, maxburst 1; channel 2, repeat-last, inversion and
  mark/space off. There are no per-word or per-loop interrupts and no CPU refill. DMA starts at word
  zero, so there is no CPU pre-fill duplication. If disabled-channel DREQ priming fails, START times out
  and stops; it never enables an empty FIFO. See the FIFO-priming findings above.
* **Stop.** STOP disables PWM consumption and DREQ, calls `dmaengine_terminate_sync()` **before**
  clearing the FIFO or touching DMA memory, and attempts the idle pin state even if termination fails.
  The provider aborts and resets the channel; that remains a provider contract, not hardware
  verification. If termination errors, sample memory is retained and configure/rate/start are blocked
  until a STOP succeeds. After a failed final-close termination new controllers get `EIO`; unbind
  retries and, if that also fails, retains the DMA allocation and channel until reboot. Cleanup
  failures are logged without overwriting the original errno in status.
* **Locking and lifetime.** A mutex serialises upload, ioctls, the monitor and removal. Open descriptors
  hold a reference to a non-devm state object; unbind marks it dead, stops, frees quiesced resources and
  deregisters the miscdevice, after which descriptors fail without touching freed resources. Module
  ownership blocks ordinary unload while descriptors remain. Shutdown stops; suspend stops and latches
  `EHOSTDOWN`; nothing restarts after resume.
* **Monitoring.** A delayed work item checks sticky FIFO, gap and bus bits and DMAengine status about
  every 20 ms, and status ioctls check too; errors latch and stop output synchronously. The provider's
  `tx_status` mostly reports cookie and residue, not raw DMA error bits, hence `DMA_LIMITED`. There is no
  independent progress watchdog, bit-level fidelity proof or automatic recovery.
* **Clock.** The PWM divider can be fractional. The driver does not retune shared PLLs or write clock
  registers. It keeps a CCF exclusive-rate reference across rate changes, which protects the rate
  against other CCF consumers but not against firmware or raw register users.

## Sources

Sources describe hardware and particular code versions; they do not identify
the exact kernel/configuration installed on the target Pi.

**Reviewed kernel source.** Package
[linux_6.18.50-1+rpt1.dsc](https://archive.raspberrypi.com/debian/pool/main/l/linux/linux_6.18.50-1+rpt1.dsc)
(version `1:6.18.50-1+rpt1`) corresponds to Linux commit
[`cff533ae`](https://github.com/raspberrypi/linux/commit/cff533aec2fa601846766b32ff57204e0a61bed7)
(`stable_20260911`), per the
[packaging changelog commit](https://github.com/RPi-Distro/linux-packaging/commit/57beb6cc27d4a9e7997413e1213e6d7f4a346c03).
Its Raspberry Pi patch sets `function_is_gpio` and `.strict = true` in BCM2835 pinctrl. Files at that
commit that the implementation relies on:
[`bcm2835-dma.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/drivers/dma/bcm2835-dma.c)
(`bcm2835_dma_xlate`, `bcm2835_dma_prep_dma_cyclic`, termination, `tx_status`),
[`kernel/dma/mapping.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/kernel/dma/mapping.c)
and [`direct.h`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/kernel/dma/direct.h)
(`dma_map_resource()` to `phys_to_dma()`),
[`bcm2710.dtsi`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/arch/arm/boot/dts/broadcom/bcm2710.dtsi),
[`pinctrl-bcm2835.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/drivers/pinctrl/bcm/pinctrl-bcm2835.c),
[`pwm-bcm2835.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/drivers/pwm/pwm-bcm2835.c)
(platform driver name `bcm2835-pwm`) and
[`bcm2835-i2s.c`](https://github.com/raspberrypi/linux/blob/cff533aec2fa601846766b32ff57204e0a61bed7/sound/soc/bcm/bcm2835-i2s.c)
(an in-tree client that passes the resource physical FIFO address to this provider).

1. [Raspberry Pi 3 Model B+ specification](https://www.raspberrypi.com/products/raspberry-pi-3-model-b-plus/)
   - BCM2837B0 and board features.
2. [BCM2835 ARM Peripherals manual](https://datasheets.raspberrypi.com/bcm2835/bcm2835-peripherals.pdf)
   - Chapter 9, pp.138-146: PWM, FIFO, serializer, DMA controls and status.
     Chapter 4: DMA control blocks; chapter 6: general-purpose clock discussion.
3. [Linux PWM driver](https://github.com/torvalds/linux/blob/master/drivers/pwm/pwm-bcm2835.c)
   and [Raspberry Pi peripheral device tree](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm/boot/dts/broadcom/bcm283x.dtsi)
   - Conventional PWM operations and the assigned 50 MHz clock.
4. [Raspberry Pi PWM overlay](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm/boot/dts/overlays/pwm-overlay.dts)
   - Pin functions and analogue-audio conflict.
5. [Raspberry Pi DMA driver](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/dma/bcm2835-dma.c)
   - `bcm2835_dma_prep_dma_cyclic`, cyclic descriptor linkage, and capability
     registration.
6. [DMAengine client documentation](https://docs.kernel.org/driver-api/dmaengine/client.html)
   - Channel allocation, slave transfers, cyclic preparation, and termination.
7. [Linux DMA API HOWTO](https://docs.kernel.org/core-api/dma-api-howto.html)
   - DMA addresses, coherent allocation, and memory ordering.
8. [Sysfs documentation](https://docs.kernel.org/filesystems/sysfs.html)
    - Small text attributes and access modes.
9. [Raspberry Pi clock driver](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/drivers/clk/bcm/clk-bcm2835.c)
    - Clock tree, PWM clock registration, divider constraints and rate handling.
