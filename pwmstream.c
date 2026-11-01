// SPDX-License-Identifier: Apache-2.0 OR GPL-2.0-only
/* BCM2837 PWM0 serializer for Pi downstream 6.18.50+ kernels. */
#include <linux/bitfield.h>
#include <linux/clk.h>
#include <linux/compat.h>
#include <linux/delay.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kref.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of_address.h>
#include <linux/pinctrl/consumer.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/unaligned.h>
#include <linux/utsname.h>
#include <linux/workqueue.h>
#include "pwmstream.h"

#define PS_CTL       0x00
#define PS_STA       0x04
#define PS_DMAC      0x08
#define PS_RNG1      0x10
#define PS_FIFO      0x18
#define PS_ENABLE    BIT(0)
#define PS_SERIAL    BIT(1)
#define PS_USE_FIFO  BIT(5)
#define PS_CLEAR     BIT(6)
#define PS_EMPTY     BIT(1)
#define PS_FIFO_ERRORS GENMASK(3, 2)
#define PS_CHANNEL_GAPS GENMASK(7, 4)
#define PS_BUS_ERROR BIT(8)
#define PS_ERRORS    (PS_FIFO_ERRORS | PS_CHANNEL_GAPS | PS_BUS_ERROR)
#define PS_DMA_ON    BIT(31)
#define PS_DMA_DREQ_MASK GENMASK(7, 0)
#define PS_DMA_PANIC_MASK GENMASK(15, 8)
#define PS_DMA_DREQ_THRESHOLD 8
#define PS_DMA_PANIC_THRESHOLD 4
#define PS_RATE_TOLERANCE_HZ 1UL
#define PS_MONITOR_MS 20

/*
 * Release guard. Strict pinctrl, DMA slave-address and termination contracts
 * were reviewed against 6.18.50; later 6.18.N+rpt-rpi-v8 patch releases are
 * accepted as supported. Anything else needs allow_unreviewed=1.
 */
#define PS_REVIEWED_RELEASE "6.18.50+rpt-rpi-v8"
#define PS_MIN_PATCH 50UL

static bool allow_unreviewed;
module_param(allow_unreviewed, bool, 0444);
MODULE_PARM_DESC(allow_unreviewed,
		 "Accept a kernel outside 6.18.N+rpt-rpi-v8 (N>=50); unverified, at your own risk");

static bool ps_release_supported(const char *release)
{
	unsigned long patch = 0;
	const char *p = release;

	if (strncmp(p, "6.18.", 5))
		return false;
	p += 5;
	if (*p < '0' || *p > '9')
		return false;
	for (; *p >= '0' && *p <= '9'; p++) {
		patch = patch * 10 + (*p - '0');
		if (patch > 9999)
			return false;
	}
	return patch >= PS_MIN_PATCH && !strcmp(p, "+rpt-rpi-v8");
}

struct ps_device {
	struct kref ref;
	struct mutex lock;
	struct miscdevice misc;
	struct delayed_work monitor;
	void __iomem *regs;
	struct clk *clk;
	struct pinctrl *pins;
	struct pinctrl_state *idle, *active;
	struct dma_chan *chan;
	struct device *dma_dev;
	void *staging;
	__le32 *buffer;
	dma_addr_t buffer_dma;
	dma_cookie_t cookie;
	u32 length, uploaded, requested, actual;
	u32 pwm_errors, dma_status, residue;
	int last_error;
	bool dead, controller, running, clock_on, dma_quiesced;
};

static void ps_release_ref(struct kref *ref)
{
	kfree(container_of(ref, struct ps_device, ref));
}

/* All hardware and upload accesses are serialized, including removal. */
static int ps_stop(struct ps_device *ps)
{
	int ret, pinret;

	writel(0, ps->regs + PS_CTL);
	readl(ps->regs + PS_CTL);
	writel(0, ps->regs + PS_DMAC);
	ret = dmaengine_terminate_sync(ps->chan);
	ps->running = false;
	ps->dma_quiesced = !ret;
	/* Try to disconnect the pin even if DMA termination fails. */
	pinret = pinctrl_select_state(ps->pins, ps->idle);
	if (pinret)
		dev_err(ps->dma_dev, "PWM idle pin selection failed: %d\n", pinret);
	if (ret) {
		dev_err(ps->dma_dev, "PWM DMA termination failed: %d; retaining sample and channel\n",
			ret);
		ps->last_error = ret;
		return ret;
	}
	ps->dma_status = DMA_COMPLETE;
	ps->residue = 0;
	ps->pwm_errors |= readl(ps->regs + PS_STA) & PS_ERRORS;
	writel(PS_CLEAR, ps->regs + PS_CTL);
	usleep_range(100, 200);
	writel(0, ps->regs + PS_CTL);
	writel(PS_ERRORS, ps->regs + PS_STA);
	if (pinret)
		ps->last_error = pinret;
	return pinret;
}

static void ps_free_buffer(struct ps_device *ps)
{
	/* Retain DMA-owned storage if a provider ever fails to terminate. */
	if (WARN_ON_ONCE(!ps->dma_quiesced))
		return;
	if (ps->buffer)
		dma_free_coherent(ps->dma_dev, ps->length,
				  ps->buffer, ps->buffer_dma);
	kvfree(ps->staging);
	ps->buffer = NULL;
	ps->staging = NULL;
	ps->length = ps->uploaded = 0;
}

/* Preserve the triggering error; ps_stop logs any separate cleanup failure. */
static void ps_fail(struct ps_device *ps, int error)
{
	ps_stop(ps);
	ps->last_error = error;
}

static void ps_check(struct ps_device *ps)
{
	struct dma_tx_state tx = {};
	u32 errors;
	int error = 0;

	if (!ps->running)
		return;
	errors = readl(ps->regs + PS_STA) & PS_ERRORS;
	ps->pwm_errors |= errors;
	ps->dma_status = dmaengine_tx_status(ps->chan, ps->cookie, &tx);
	ps->residue = tx.residue;
	if (errors || ps->dma_status != DMA_IN_PROGRESS)
		error = -EIO;
	if (error)
		ps_fail(ps, error);
}

static void ps_monitor(struct work_struct *work)
{
	struct ps_device *ps = container_of(to_delayed_work(work),
					    struct ps_device, monitor);

	mutex_lock(&ps->lock);
	if (!ps->dead) {
		ps_check(ps);
		if (ps->running)
			schedule_delayed_work(&ps->monitor,
					     msecs_to_jiffies(PS_MONITOR_MS));
	}
	mutex_unlock(&ps->lock);
}

static bool ps_rate_in_range(unsigned long hz)
{
	/* CCF reports 100000001 Hz for the nominal 100 MHz target on this Pi. */
	return hz >= PWMSTREAM_MIN_HZ &&
	       hz <= (unsigned long)PWMSTREAM_MAX_HZ + PS_RATE_TOLERANCE_HZ;
}

static int ps_validate_rate(struct ps_device *ps, u32 hz)
{
	long rounded;

	if (hz < PWMSTREAM_MIN_HZ || hz > PWMSTREAM_MAX_HZ)
		return -ERANGE;
	rounded = clk_round_rate(ps->clk, hz);
	if (rounded < 0)
		return rounded;
	return ps_rate_in_range(rounded) ? 0 : -ERANGE;
}

static int ps_set_rate(struct ps_device *ps, u32 hz)
{
	unsigned long actual;
	int ret;

	ret = ps_validate_rate(ps, hz);
	if (ret)
		return ret;
	/*
	 * Keep the exclusive rate reference across changes. clk_set_rate() on
	 * this same consumer is permitted by CCF without an exclusivity gap.
	 */
	if (ps->clock_on) {
		clk_disable_unprepare(ps->clk);
		ps->clock_on = false;
	}
	ret = clk_set_rate(ps->clk, hz);
	actual = clk_get_rate(ps->clk);
	ps->actual = actual <= U32_MAX ? actual : 0;
	if (!ret && !ps_rate_in_range(actual))
		ret = -ERANGE;
	if (!ret)
		ret = clk_prepare_enable(ps->clk);
	if (!ret) {
		ps->clock_on = true;
		ps->requested = hz;
	}
	/*
	 * Hardware changes are not transactional: keep readback and the last
	 * successful request, but leave our clock disabled on failure.
	 */
	ps->last_error = ret;
	return ret;
}

static int ps_configure(struct ps_device *ps, struct pwmstream_config *cfg)
{
	void *staging;
	__le32 *buffer;
	dma_addr_t addr;
	int ret;

	if (cfg->version != PWMSTREAM_ABI_VERSION || cfg->reserved ||
	    !cfg->sample_bytes || cfg->sample_bytes % 4 ||
	    cfg->sample_bytes > PWMSTREAM_MAX_BYTES)
		return -EINVAL;
	ret = ps_validate_rate(ps, cfg->rate_hz ?: PWMSTREAM_DEFAULT_HZ);
	if (ret)
		return ret;
	staging = kvmalloc(cfg->sample_bytes, GFP_KERNEL);
	if (!staging)
		return -ENOMEM;
	buffer = dma_alloc_coherent(ps->dma_dev, cfg->sample_bytes, &addr,
				    GFP_KERNEL);
	if (!buffer) {
		kvfree(staging);
		return -ENOMEM;
	}
	if (addr > U32_MAX || cfg->sample_bytes - 1 > U32_MAX - addr) {
		ret = -EOVERFLOW;
		goto free_new;
	}
	ret = ps_set_rate(ps, cfg->rate_hz ?: PWMSTREAM_DEFAULT_HZ);
	if (ret)
		goto free_new;
	ps_free_buffer(ps);
	ps->staging = staging;
	ps->buffer = buffer;
	ps->buffer_dma = addr;
	ps->length = cfg->sample_bytes;
	ps->pwm_errors = 0;
	ps->dma_status = DMA_COMPLETE;
	ps->residue = 0;
	return 0;
free_new:
	dma_free_coherent(ps->dma_dev, cfg->sample_bytes, buffer, addr);
	kvfree(staging);
	return ret;
}

static int ps_start(struct ps_device *ps)
{
	struct dma_async_tx_descriptor *desc;
	u32 status;
	unsigned int i;
	int ret;

	if (ps->running)
		return -EBUSY;
	if (!ps->buffer || ps->uploaded != ps->length)
		return -ENODATA;
	if (!ps->clock_on || ps->last_error)
		return ps->last_error ?: -EIO;
	for (i = 0; i < ps->length / 4; i++)
		ps->buffer[i] = cpu_to_le32(get_unaligned_be32(
						(u8 *)ps->staging + 4 * i));
	dma_wmb();
	ret = ps_stop(ps);
	if (ret)
		goto fail;
	ps->pwm_errors = 0;
	writel(32, ps->regs + PS_RNG1);
	usleep_range(100, 200);
	writel(PS_SERIAL | PS_USE_FIFO, ps->regs + PS_CTL);
	desc = dmaengine_prep_dma_cyclic(ps->chan, ps->buffer_dma,
					ps->length, ps->length,
					DMA_MEM_TO_DEV, DMA_CTRL_ACK);
	if (!desc) {
		ret = -EIO;
		goto fail;
	}
	ps->cookie = dmaengine_submit(desc);
	ret = dma_submit_error(ps->cookie);
	if (ret)
		goto fail;
	/*
	 * DMA itself primes the FIFO starting at sample word zero. No CPU
	 * prefill (which would require rotating the DMA ring). Wait for data,
	 * not FULL: DREQ pacing need not fill the FIFO completely. The channel
	 * remains disabled so the sample prefix is not consumed while priming.
	 */
	writel(PS_DMA_ON |
	       FIELD_PREP(PS_DMA_DREQ_MASK, PS_DMA_DREQ_THRESHOLD) |
	       FIELD_PREP(PS_DMA_PANIC_MASK, PS_DMA_PANIC_THRESHOLD),
	       ps->regs + PS_DMAC);
	ps->dma_quiesced = false;
	dma_async_issue_pending(ps->chan);
	ret = readl_poll_timeout(ps->regs + PS_STA, status,
				 !(status & PS_EMPTY) || (status & PS_ERRORS),
				 10, 100000);
	if (ret || (status & PS_ERRORS)) {
		struct dma_tx_state tx = {};
		enum dma_status dma_status;

		dma_status = dmaengine_tx_status(ps->chan, ps->cookie, &tx);
		dev_err(ps->misc.parent,
			"FIFO priming failed: ret=%d ctl=%#x sta=%#x dmac=%#x rng1=%u dma_status=%d residue=%u sample_bytes=%u actual_hz=%u\n",
			ret ?: -EIO, readl(ps->regs + PS_CTL),
			readl(ps->regs + PS_STA), readl(ps->regs + PS_DMAC),
			readl(ps->regs + PS_RNG1), dma_status, tx.residue,
			ps->length, ps->actual);
		ret = ret ?: -EIO;
		goto fail;
	}
	ret = pinctrl_select_state(ps->pins, ps->active);
	if (ret)
		goto fail;
	writel(PS_SERIAL | PS_USE_FIFO | PS_ENABLE, ps->regs + PS_CTL);
	readl(ps->regs + PS_CTL);
	ps->running = true;
	usleep_range(100, 200);
	ps_check(ps);
	if (!ps->running)
		return ps->last_error;
	schedule_delayed_work(&ps->monitor, msecs_to_jiffies(PS_MONITOR_MS));
	return 0;
fail:
	ps_fail(ps, ret);
	return ret;
}

static int ps_open(struct inode *inode, struct file *file)
{
	struct miscdevice *misc = file->private_data;
	struct ps_device *ps = container_of(misc, struct ps_device, misc);
	int ret = 0;

	mutex_lock(&ps->lock);
	if (ps->dead)
		ret = -ENODEV;
	else if ((file->f_mode & FMODE_WRITE) &&
		 !ps->dma_quiesced && !ps->running && !ps->controller)
		ret = -EIO;
	else if ((file->f_mode & FMODE_WRITE) && ps->controller)
		ret = -EBUSY;
	else {
		kref_get(&ps->ref);
		if (file->f_mode & FMODE_WRITE)
			ps->controller = true;
		file->private_data = ps;
	}
	mutex_unlock(&ps->lock);
	return ret ?: nonseekable_open(inode, file);
}

static int ps_close(struct inode *inode, struct file *file)
{
	struct ps_device *ps = file->private_data;

	mutex_lock(&ps->lock);
	if (file->f_mode & FMODE_WRITE) {
		if (!ps->dead) {
			ps_stop(ps);
			if (ps->dma_quiesced)
				ps_free_buffer(ps);
		}
		ps->controller = false;
	}
	mutex_unlock(&ps->lock);
	kref_put(&ps->ref, ps_release_ref);
	return 0;
}

static ssize_t ps_write(struct file *file, const char __user *buf,
			size_t count, loff_t *pos)
{
	struct ps_device *ps = file->private_data;
	size_t amount, copied;
	ssize_t ret;

	mutex_lock(&ps->lock);
	if (ps->dead)
		ret = -ENODEV;
	else if (ps->running || !ps->dma_quiesced)
		ret = -EBUSY;
	else if (!ps->buffer)
		ret = -EINVAL;
	else if (!count)
		ret = 0;
	else if (ps->uploaded == ps->length)
		ret = -ENOSPC;
	else {
		amount = min_t(size_t, count, ps->length - ps->uploaded);
		copied = amount - copy_from_user((u8 *)ps->staging + ps->uploaded,
						buf, amount);
		ps->uploaded += copied;
		ret = copied ?: -EFAULT;
	}
	mutex_unlock(&ps->lock);
	return ret;
}

static long ps_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct ps_device *ps = file->private_data;
	void __user *ptr = (void __user *)arg;
	struct pwmstream_config cfg;
	struct pwmstream_rate rate;
	struct pwmstream_status status = {};
	long ret = 0;

	mutex_lock(&ps->lock);
	if (ps->dead) {
		ret = -ENODEV;
		goto out;
	}
	ps_check(ps);
	if (cmd == PWMSTREAM_STATUS) {
		status.version = PWMSTREAM_ABI_VERSION;
		status.flags = PWMSTREAM_F_DMA_LIMITED |
			(ps->running ? PWMSTREAM_F_RUNNING : 0) |
			(ps->length && ps->uploaded == ps->length ?
			 PWMSTREAM_F_COMPLETE : 0) |
			(ps->controller ? PWMSTREAM_F_CONTROLLER : 0) |
			(ps->clock_on ? PWMSTREAM_F_CLOCK_READY : 0) |
			(ps->buffer && ps->clock_on && !ps->last_error &&
			 (ps->running || ps->dma_quiesced) ?
			 PWMSTREAM_F_CONFIG_READY : 0);
		status.sample_bytes = ps->length;
		status.uploaded_bytes = ps->uploaded;
		status.requested_hz = ps->requested;
		status.actual_hz = ps->actual;
		status.last_error = ps->last_error;
		status.pwm_errors = ps->pwm_errors;
		status.dma_status = ps->dma_status;
		status.dma_residue = ps->residue;
		if (copy_to_user(ptr, &status, sizeof(status)))
			ret = -EFAULT;
		goto out;
	}
	if (!(file->f_mode & FMODE_WRITE)) {
		ret = -EPERM;
		goto out;
	}
	if (cmd == PWMSTREAM_STOP) {
		ret = ps_stop(ps);
		goto out;
	}
	if (ps->running || !ps->dma_quiesced) {
		ret = -EBUSY;
		goto out;
	}
	switch (cmd) {
	case PWMSTREAM_CONFIG:
		if (copy_from_user(&cfg, ptr, sizeof(cfg)))
			ret = -EFAULT;
		else
			ret = ps_configure(ps, &cfg);
		break;
	case PWMSTREAM_RATE:
		if (copy_from_user(&rate, ptr, sizeof(rate)))
			ret = -EFAULT;
		else if (rate.version != PWMSTREAM_ABI_VERSION ||
			 rate.reserved[0] || rate.reserved[1])
			ret = -EINVAL;
		else
			ret = ps_set_rate(ps, rate.rate_hz);
		break;
	case PWMSTREAM_START:
		ret = ps_start(ps);
		break;
	default:
		ret = -ENOTTY;
	}
out:
	mutex_unlock(&ps->lock);
	return ret;
}

#ifdef CONFIG_COMPAT
static long ps_compat_ioctl(struct file *file, unsigned int cmd,
			    unsigned long arg)
{
	return ps_ioctl(file, cmd, (unsigned long)compat_ptr(arg));
}
#endif

static const struct file_operations ps_fops = {
	.owner = THIS_MODULE,
	.open = ps_open,
	.release = ps_close,
	.write = ps_write,
	.unlocked_ioctl = ps_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl = ps_compat_ioctl,
#endif
};

/*
 * This downstream bcm2835-dma maps slave CPU addresses with dma_map_resource().
 * Check its DT DMA translation, rather than guessing that CPU == bus address
 * or passing an already-translated address (which would translate twice).
 */
static int ps_validate_dma(struct ps_device *ps, struct device_node *np,
			   struct resource *res)
{
	struct of_phandle_args spec;
	struct of_range_parser parser;
	struct of_range range;
	struct device_node *parent;
	const __be32 *addr;
	u64 size, bus;
	dma_addr_t mapped;
	bool found = false;
	int ret;

	ret = of_property_match_string(np, "dma-names", "tx");
	if (ret < 0)
		return ret;
	ret = of_parse_phandle_with_args(np, "dmas", "#dma-cells", ret, &spec);
	if (ret)
		return ret;
	if (spec.args_count != 1 || spec.args[0] != 5 ||
	    !of_device_is_compatible(spec.np, "brcm,bcm2835-dma") ||
	    ps->chan->device->dev->of_node != spec.np) {
		ret = -EINVAL;
		goto out;
	}
	addr = of_get_address(np, 0, &size, NULL);
	if (!addr || of_n_addr_cells(np) != 1 || size < PS_FIFO + 4) {
		ret = -EINVAL;
		goto out;
	}
	bus = be32_to_cpup(addr) + PS_FIFO;
	/* A deliberately narrow initial target: BCM2837's PWM block. */
	if (bus != 0x7e20c018 || res->start + PS_FIFO != 0x3f20c018) {
		ret = -EINVAL;
		goto out;
	}
	parent = of_get_parent(spec.np);
	ret = of_pci_dma_range_parser_init(&parser, parent);
	if (!ret) {
		for_each_of_range(&parser, &range) {
			u64 phys = res->start + PS_FIFO;

			if (phys >= range.cpu_addr &&
			    phys - range.cpu_addr + 4 <= range.size &&
			    range.bus_addr + phys - range.cpu_addr == bus)
				found = true;
		}
	}
	of_node_put(parent);
	ret = -EINVAL;
	if (found) {
		mapped = dma_map_resource(ps->dma_dev, res->start + PS_FIFO,
					  4, DMA_TO_DEVICE, 0);
		if (!dma_mapping_error(ps->dma_dev, mapped)) {
			ret = mapped == bus ? 0 : -EINVAL;
			dma_unmap_resource(ps->dma_dev, mapped, 4,
					   DMA_TO_DEVICE, 0);
		}
	}
out:
	of_node_put(spec.np);
	return ret;
}

static int ps_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ps_device *ps;
	struct resource *res;
	struct dma_slave_config dma_cfg = {};
	int ret;

	if (!of_machine_is_compatible("raspberrypi,3-model-b-plus") ||
	    !of_machine_is_compatible("brcm,bcm2837"))
		return dev_err_probe(dev, -ENODEV,
			"requires Pi 3B+ BCM2837\n");
	if (!ps_release_supported(utsname()->release)) {
		if (!allow_unreviewed)
			return dev_err_probe(dev, -ENODEV,
				"unsupported kernel %s; supported: 6.18.N+rpt-rpi-v8, N>=50 (set allow_unreviewed=1 to override at your own risk)\n",
				utsname()->release);
		dev_warn(dev, "UNREVIEWED kernel %s accepted by allow_unreviewed; DMA, clock and pin-ownership assumptions are unverified\n",
			 utsname()->release);
	} else if (strcmp(utsname()->release, PS_REVIEWED_RELEASE)) {
		dev_info(dev, "kernel %s is in the supported range; last reviewed " PS_REVIEWED_RELEASE "\n",
			 utsname()->release);
	}
	ps = kzalloc(sizeof(*ps), GFP_KERNEL);
	if (!ps)
		return -ENOMEM;
	kref_init(&ps->ref);
	ps->dma_quiesced = true;
	mutex_init(&ps->lock);
	INIT_DELAYED_WORK(&ps->monitor, ps_monitor);
	ps->dma_status = DMA_COMPLETE;
	ps->regs = devm_platform_get_and_ioremap_resource(pdev, 0, &res);
	if (IS_ERR(ps->regs)) {
		ret = PTR_ERR(ps->regs);
		goto free_ps;
	}
	ps->pins = devm_pinctrl_get(dev);
	if (IS_ERR(ps->pins)) {
		ret = PTR_ERR(ps->pins);
		goto free_ps;
	}
	ps->idle = pinctrl_lookup_state(ps->pins, "default");
	if (IS_ERR(ps->idle)) {
		ret = PTR_ERR(ps->idle);
		goto free_ps;
	}
	ps->active = pinctrl_lookup_state(ps->pins, "active");
	if (IS_ERR(ps->active)) {
		ret = PTR_ERR(ps->active);
		goto free_ps;
	}
	ret = pinctrl_select_state(ps->pins, ps->idle);
	if (ret)
		goto free_ps;
	/* Strict pinctrl excludes GPIO API users while ALT5 is active. */
	ps->clk = devm_clk_get(dev, NULL);
	if (IS_ERR(ps->clk)) {
		ret = PTR_ERR(ps->clk);
		goto free_ps;
	}
	ret = clk_rate_exclusive_get(ps->clk);
	if (ret)
		goto free_ps;
	ret = ps_set_rate(ps, PWMSTREAM_DEFAULT_HZ);
	if (ret)
		goto release_clock;
	ps->chan = dma_request_chan(dev, "tx");
	if (IS_ERR(ps->chan)) {
		ret = PTR_ERR(ps->chan);
		goto release_clock;
	}
	ps->dma_dev = dmaengine_get_dma_device(ps->chan);
	ret = ps_validate_dma(ps, dev->of_node, res);
	if (ret) {
		dev_err(dev, "unsupported peripheral DMA translation/DREQ\n");
		goto release_dma;
	}
	if (!dma_has_cap(DMA_CYCLIC, ps->chan->device->cap_mask)) {
		ret = -EOPNOTSUPP;
		goto release_dma;
	}
	dma_cfg.direction = DMA_MEM_TO_DEV;
	dma_cfg.dst_addr = res->start + PS_FIFO;
	dma_cfg.dst_addr_width = DMA_SLAVE_BUSWIDTH_4_BYTES;
	dma_cfg.dst_maxburst = 1;
	ret = dmaengine_slave_config(ps->chan, &dma_cfg);
	if (ret)
		goto release_dma;
	ret = ps_stop(ps);
	if (ret)
		goto release_dma;
	ps->misc.minor = MISC_DYNAMIC_MINOR;
	ps->misc.name = "pwmstream0";
	ps->misc.fops = &ps_fops;
	ps->misc.parent = dev;
	ps->misc.mode = 0600;
	platform_set_drvdata(pdev, ps);
	ret = misc_register(&ps->misc);
	if (!ret) {
		dev_info(dev, "experimental PWM0 GPIO18 serializer, %u Hz\n",
			 ps->actual);
		return 0;
	}
release_dma:
	if (ps->dma_quiesced)
		dma_release_channel(ps->chan);
release_clock:
	if (ps->clock_on)
		clk_disable_unprepare(ps->clk);
	clk_rate_exclusive_put(ps->clk);
free_ps:
	kref_put(&ps->ref, ps_release_ref);
	return dev_err_probe(dev, ret, "PWM stream probe failed\n");
}

static void ps_remove(struct platform_device *pdev)
{
	struct ps_device *ps = platform_get_drvdata(pdev);

	mutex_lock(&ps->lock);
	ps->dead = true;
	ps_stop(ps);
	if (ps->dma_quiesced)
		ps_free_buffer(ps);
	mutex_unlock(&ps->lock);
	misc_deregister(&ps->misc);
	cancel_delayed_work_sync(&ps->monitor);
	/*
	 * A failed provider termination cannot veto unbind. Retain its channel
	 * (and DMA allocation) rather than hand live memory back to allocators.
	 * No DMA callbacks reference this driver's state. Recovery needs reboot.
	 */
	if (ps->dma_quiesced)
		dma_release_channel(ps->chan);
	if (ps->clock_on)
		clk_disable_unprepare(ps->clk);
	clk_rate_exclusive_put(ps->clk);
	kref_put(&ps->ref, ps_release_ref);
}

static void ps_shutdown(struct platform_device *pdev)
{
	struct ps_device *ps = platform_get_drvdata(pdev);

	mutex_lock(&ps->lock);
	ps->dead = true;
	ps_stop(ps);
	mutex_unlock(&ps->lock);
	cancel_delayed_work_sync(&ps->monitor);
}

/* Do not silently continue DMA over suspend, or automatically restart it. */
static int ps_suspend(struct device *dev)
{
	struct ps_device *ps = dev_get_drvdata(dev);
	int ret;

	mutex_lock(&ps->lock);
	ret = ps_stop(ps);
	ps->last_error = ret ?: -EHOSTDOWN;
	mutex_unlock(&ps->lock);
	return ret;
}

static DEFINE_SIMPLE_DEV_PM_OPS(ps_pm, ps_suspend, NULL);

static const struct of_device_id ps_match[] = {
	{ .compatible = "pwmstream,bcm2837-pwmstream" },
	{}
};
MODULE_DEVICE_TABLE(of, ps_match);

static struct platform_driver ps_driver = {
	.probe = ps_probe,
	.remove = ps_remove,
	.shutdown = ps_shutdown,
	.driver = {
		.name = "pwmstream",
		.of_match_table = ps_match,
		.pm = pm_sleep_ptr(&ps_pm),
	},
};
module_platform_driver(ps_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Experimental BCM2837 PWM0 cyclic serializer");
