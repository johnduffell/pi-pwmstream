/* SPDX-License-Identifier: Apache-2.0 */
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
#define PWMSTREAM_MAX_BYTES (1024U * 1024U)
#define PWMSTREAM_DEFAULT_HZ 50000000U
#define PWMSTREAM_MIN_HZ 100000U
#define PWMSTREAM_MAX_HZ 100000000U

struct pwmstream_config {
	ps_u32 version;
	ps_u32 sample_bytes;
	ps_u32 rate_hz;
	ps_u32 reserved;
};

struct pwmstream_rate {
	ps_u32 version;
	ps_u32 rate_hz;
	ps_u32 reserved[2];
};

#define PWMSTREAM_F_RUNNING       (1U << 0)
#define PWMSTREAM_F_COMPLETE      (1U << 1)
#define PWMSTREAM_F_CONTROLLER    (1U << 2)
#define PWMSTREAM_F_CLOCK_READY   (1U << 3)
/* DMAengine's status is not a hardware-error detector on bcm2835-dma. */
#define PWMSTREAM_F_DMA_LIMITED   (1U << 4)
/* Usable sample configuration; COMPLETE is independently required for START. */
#define PWMSTREAM_F_CONFIG_READY  (1U << 5)

struct pwmstream_status {
	ps_u32 version;
	ps_u32 flags;
	ps_u32 sample_bytes;
	ps_u32 uploaded_bytes;
	ps_u32 requested_hz;
	ps_u32 actual_hz;
	ps_s32 last_error;
	ps_u32 pwm_errors;
	ps_u32 dma_status;
	ps_u32 dma_residue;
	ps_u32 reserved[6];
};

#define PWMSTREAM_CONFIG _IOW('P', 0x40, struct pwmstream_config)
#define PWMSTREAM_RATE   _IOW('P', 0x41, struct pwmstream_rate)
#define PWMSTREAM_START  _IO('P', 0x42)
#define PWMSTREAM_STOP   _IO('P', 0x43)
#define PWMSTREAM_STATUS _IOR('P', 0x44, struct pwmstream_status)

#endif
