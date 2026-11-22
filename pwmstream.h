/* SPDX-License-Identifier: Apache-2.0 */
/*
 * pwmstream ABI: the ioctl interface to /dev/pwmstream0, shared by the kernel module and user
 * space. Versioned (PWMSTREAM_ABI_VERSION); the semantics and error codes are in docs/abi.md.
 */
#ifndef PWMSTREAM_H
#define PWMSTREAM_H

#ifdef __KERNEL__
#include <linux/ioctl.h>
#include <linux/types.h>
typedef __u32 ps_u32;
typedef __s32 ps_s32;
#else
#include <stdint.h>
#include <sys/ioctl.h>
typedef uint32_t ps_u32;
typedef int32_t ps_s32;
#endif

#define PWMSTREAM_ABI_VERSION 1U
#define PWMSTREAM_MAX_PATTERN_BYTES (1024U * 1024U)
#define PWMSTREAM_DEFAULT_BIT_RATE_HZ 50000000U
#define PWMSTREAM_MIN_BIT_RATE_HZ 100000U
#define PWMSTREAM_MAX_BIT_RATE_HZ 100000000U

/* Reserved fields must be zero. channels is a bitmask; only bit 0 (channel 1) is supported. */
struct pwmstream_config {
	ps_u32 version;
	ps_u32 channels;
	ps_u32 pattern_bytes; /* per channel */
	ps_u32 bit_rate_hz;   /* 0 keeps the current rate */
	ps_u32 reserved[4];
};

struct pwmstream_start {
	ps_u32 version;
	ps_u32 flags; /* must be 0: repeat until stopped */
	ps_u32 reserved[2];
};

struct pwmstream_bit_rate {
	ps_u32 version;
	ps_u32 bit_rate_hz;
	ps_u32 reserved[2];
};

#define PWMSTREAM_F_RUNNING         (1U << 0)
#define PWMSTREAM_F_UPLOAD_COMPLETE (1U << 1)
#define PWMSTREAM_F_CONTROLLER      (1U << 2)
#define PWMSTREAM_F_CLOCK_READY     (1U << 3)
/* DMAengine's status is not a hardware-error detector on bcm2835-dma. */
#define PWMSTREAM_F_DMA_LIMITED     (1U << 4)
/* Usable pattern configuration; UPLOAD_COMPLETE is independently required for START. */
#define PWMSTREAM_F_CONFIG_READY    (1U << 5)

struct pwmstream_status {
	ps_u32 version;
	ps_u32 flags;
	ps_u32 pattern_bytes;
	ps_u32 uploaded_bytes;
	ps_u32 requested_bit_rate_hz;
	ps_u32 actual_bit_rate_hz;
	ps_s32 last_error;
	ps_u32 pwm_errors;
	ps_u32 dma_status;
	ps_u32 dma_residue;
	ps_u32 channels;
	ps_u32 reserved[13];
};

#define PWMSTREAM_CONFIG   _IOW('P', 0x40, struct pwmstream_config)
#define PWMSTREAM_BIT_RATE _IOW('P', 0x41, struct pwmstream_bit_rate)
#define PWMSTREAM_START    _IOW('P', 0x42, struct pwmstream_start)
#define PWMSTREAM_STOP     _IO('P', 0x43)
#define PWMSTREAM_STATUS   _IOR('P', 0x44, struct pwmstream_status)

#endif
