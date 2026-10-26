// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Linux platform driver for the ternary MobileNetV2 accelerator (twn_fuse).
 *
 * Replaces the user-space path of v1.0.0 (UIO for the registers, /dev/mem for
 * the DDR buffer). The kernel now owns both:
 *   - the control registers (64 KB at 0xA000_0000) are mapped only here;
 *   - the DDR buffer the PL reads and writes (the "arena") is allocated with
 *     the DMA API, and it is the only thing user space can mmap;
 *   - every register sequence (start, wait, clear done) runs here, behind ioctl;
 *   - the counters and the status register are readable in sysfs; debug
 *     registers and NBLK are in debugfs.
 * Completion: hardware 1.1 has an interrupt (pl_ps_irq0, enabled through the IRQ
 * register); the driver waits on it when the device tree gives one. Hardware 1.0
 * ties pl_ps_irq0 to 0, and the driver polls. Register map: rtl/fuse/twn_csr.v.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/dma-mapping.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/ktime.h>
#include <linux/interrupt.h>
#include <linux/completion.h>
#include <linux/debugfs.h>
#include "twn_fuse_ioctl.h"

/* ---- registers (rtl/fuse/twn_csr.v) ---- */
#define R_CTRL         0x0000  /* R: [0] start [1] busy [2] done   W: [0] start [1] clear done */
#define R_NBLK         0x0008
#define R_ACT          0x000c  /* 40-bit addresses: low word here, high word at +4 */
#define R_W            0x0014
#define R_IN           0x001c
#define R_OUT          0x0024
#define R_STATUS       0x002c  /* [0] table valid [1] table checked [10:7] error [15:11] block */
#define R_CHECK        0x0030
#define R_CYCLES       0x0034  /* six counters, 0x0034..0x0048 */
#define R_PIX_NZ       0x004c  /* debug: sticky pixel-phase bits */
#define R_CAP          0x0050  /* debug: the frame's first project beat, 4 words */
#define R_BB2HD        0x0060
#define R_IRQ          0x0064  /* 1.1: [0] backbone done -> irq [1] head done -> irq */
#define R_HD_CTRL      0x0100  /* R and W: [0] start [1] busy [2] done (write 1 to clear) */
#define R_HD_COMMIT    0x0104
#define R_HD_RQ_STAT   0x0108
#define R_HD_IN        0x0110
#define R_HD_W         0x0118
#define R_HD_OUT       0x0120
#define R_HD_BEATS     0x0128  /* IN, W, OUT beats, then SHAPE, FLAGS, CLAMP, every 4 bytes */
#define R_HD_RQ        0x0400
#define R_DESC         0x1000

#define CTRL_START     BIT(0)
#define CTRL_CLR_DONE  BIT(1)  /* on write */
#define CTRL_BUSY      BIT(1)  /* on read */
#define CTRL_DONE      BIT(2)  /* on read */
#define ST_VALID       BIT(0)
#define ST_CHECKED     BIT(1)
#define HD_START       BIT(0)
#define HD_BUSY        BIT(1)
#define HD_DONE        BIT(2)
#define IRQ_BB         BIT(0)
#define IRQ_HD         BIT(1)

#define NBLK_RESET     17       /* NBLK's reset value: the only fingerprint this RTL has */
#define POLL_US        50       /* sleep between two reads of a done bit */
#define TIMEOUT_US     3000000  /* 3 s; a frame takes about 4.4 ms */
#define HD_SLOT_OFF    0x10000  /* the head may add this to operator 0's input (twn_hd_seq) */

static unsigned int arena_mb = 8;
module_param(arena_mb, uint, 0444);
MODULE_PARM_DESC(arena_mb, "size of the DMA buffer in MB (default 8)");

static bool use_irq = true;
module_param(use_irq, bool, 0444);
MODULE_PARM_DESC(use_irq, "wait on the interrupt when the device tree gives one (default 1); 0 polls");

static bool map_device;
module_param(map_device, bool, 0444);
MODULE_PARM_DESC(map_device, "map the buffer to user space as Device memory, like /dev/mem (A/B measurement only)");

struct twn_dev {
	struct device *dev;
	void __iomem *regs;     /* the control registers, mapped by ioremap */
	void *arena;            /* the DMA buffer, CPU address */
	dma_addr_t arena_dma;   /* the DMA buffer, the address the PL uses */
	size_t arena_size;
	struct mutex bb_lock;   /* backbone registers */
	struct mutex hd_lock;   /* head registers */
	unsigned long in_use;   /* bit 0 set while a process has the device open */
	struct miscdevice misc; /* /dev/twn_fuse */
	int irq;                /* > 0: the interrupt is used; otherwise the driver polls */
	struct completion bb_done, hd_done;     /* completed by the interrupt handler */
	u32 irq_count;          /* interrupts handled (debugfs) */
	struct dentry *dbg;     /* /sys/kernel/debug/twn_fuse */
	struct debugfs_regset32 regset;
};

static u32 rd(struct twn_dev *td, u32 off)
{
	return readl(td->regs + off);
}

static void wr(struct twn_dev *td, u32 off, u32 v)
{
	writel(v, td->regs + off);
}

/* write the 40-bit DDR address arena + off into a lo/hi register pair */
static void wr_addr(struct twn_dev *td, u32 reg, u64 off)
{
	u64 a = td->arena_dma + off;

	wr(td, reg, lower_32_bits(a));
	wr(td, reg + 4, upper_32_bits(a));
}

/* [off, off + len) must lie inside the arena and start on a 16-byte AXI beat */
static bool in_arena(struct twn_dev *td, u64 off, u64 len)
{
	return !(off & 0xf) && off <= td->arena_size && len <= td->arena_size - off;
}

/* poll until (reg & bit) is set / clear, sleeping POLL_US between reads */
static int wait_bit(struct twn_dev *td, u32 reg, u32 bit, bool set)
{
	u32 v;

	return readl_poll_timeout(td->regs + reg, v, !!(v & bit) == set,
				  POLL_US, TIMEOUT_US);
}

/* wait for an engine's done: on the interrupt when there is one, else by polling */
static int wait_done(struct twn_dev *td, struct completion *c, u32 reg, u32 bit)
{
	if (td->irq > 0)
		return wait_for_completion_timeout(c, usecs_to_jiffies(TIMEOUT_US)) ?
		       0 : -ETIMEDOUT;
	return wait_bit(td, reg, bit, true);
}

/* ---- ioctl handlers; except twn_status(), the caller holds the engine's mutex ---- */

static long twn_status(struct twn_dev *td, void __user *arg)
{
	struct twn_status s = {
		.arena_size = td->arena_size,
		.ctrl       = rd(td, R_CTRL),
		.status     = rd(td, R_STATUS),
		.hd_ctrl    = rd(td, R_HD_CTRL),
		.hd_commit  = rd(td, R_HD_COMMIT),
		.hd_rq_stat = rd(td, R_HD_RQ_STAT),
		.bb2hd      = rd(td, R_BB2HD),
	};

	return copy_to_user(arg, &s, sizeof(s)) ? -EFAULT : 0;
}

static long twn_set_table(struct twn_dev *td, void __user *arg)
{
	struct twn_table t;
	u32 *w, st;
	int i, ret;

	if (copy_from_user(&t, arg, sizeof(t)))
		return -EFAULT;
	if (!t.nwords || t.nwords > TWN_DESC_MAX_WORDS || !t.nblk || t.nblk > 31)
		return -EINVAL;
	w = memdup_user(u64_to_user_ptr(t.words), t.nwords * sizeof(u32));
	if (IS_ERR(w))
		return PTR_ERR(w);
	for (i = 0; i < t.nwords; i++)
		wr(td, R_DESC + 4 * i, w[i]);
	kfree(w);
	wr(td, R_NBLK, t.nblk);

	/* the PL walks the table; a START is ignored until this check passes */
	wr(td, R_CHECK, 1);
	ret = readl_poll_timeout(td->regs + R_STATUS, st, st & ST_CHECKED, 10, 100000);
	if (ret)
		return ret;
	if (!(st & ST_VALID)) {
		dev_err(td->dev, "descriptor table refused: error %u at block %u\n",
			(st >> 7) & 0xf, (st >> 11) & 0x1f);
		return -EINVAL;
	}
	return 0;
}

static long twn_set_bases(struct twn_dev *td, void __user *arg)
{
	struct twn_bases b;

	if (copy_from_user(&b, arg, sizeof(b)))
		return -EFAULT;
	if (!in_arena(td, b.w_off, 16) || !in_arena(td, b.act_off, 16))
		return -EINVAL;
	wr_addr(td, R_W, b.w_off);
	wr_addr(td, R_ACT, b.act_off);
	return 0;
}

static long twn_bb_run(struct twn_dev *td, void __user *arg)
{
	struct twn_bb_run r;
	u64 t0;
	int i, ret;

	if (copy_from_user(&r, arg, sizeof(r)))
		return -EFAULT;
	if (!in_arena(td, r.in_off, 16) || !in_arena(td, r.out_off, 16))
		return -EINVAL;
	t0 = ktime_get_ns();

	/* a START written while busy is dropped, so wait for idle first */
	ret = wait_bit(td, R_CTRL, CTRL_BUSY, false);
	if (ret)
		return ret;
	wr(td, R_CTRL, CTRL_CLR_DONE);  /* a stale done would end the wait at once */
	reinit_completion(&td->bb_done);
	wr_addr(td, R_IN, r.in_off);
	wr_addr(td, R_OUT, r.out_off);
	/*
	 * writel() puts a barrier before the store: the app's writes into the
	 * arena reach DDR before the PL is started.
	 */
	wr(td, R_CTRL, CTRL_START);

	ret = wait_done(td, &td->bb_done, R_CTRL, CTRL_DONE);
	if (ret) {
		dev_err(td->dev, "frame timed out: CTRL %08x STATUS %08x\n",
			rd(td, R_CTRL), rd(td, R_STATUS));
		return ret;
	}
	wr(td, R_CTRL, CTRL_CLR_DONE);
	r.ns = ktime_get_ns() - t0;
	for (i = 0; i < 6; i++)
		r.cycles[i] = rd(td, R_CYCLES + 4 * i);
	return copy_to_user(arg, &r, sizeof(r)) ? -EFAULT : 0;
}

static long twn_bb2hd(struct twn_dev *td, void __user *arg)
{
	u32 v;

	if (get_user(v, (u32 __user *)arg))
		return -EFAULT;
	/* writable bits: [0] enable, [1] clear parity, [3] clear collision */
	wr(td, R_BB2HD, v & 0xb);
	return put_user(rd(td, R_BB2HD), (u32 __user *)arg);
}

static long twn_hd_set_rq(struct twn_dev *td, void __user *arg)
{
	struct twn_hd_rq *rq;
	int i;

	rq = memdup_user(arg, sizeof(*rq));
	if (IS_ERR(rq))
		return PTR_ERR(rq);
	wr(td, R_HD_RQ_STAT, 0);        /* restart the "words written" evidence */
	for (i = 0; i < TWN_HD_RQ_WORDS; i++)
		wr(td, R_HD_RQ + 4 * i, rq->words[i]);
	kfree(rq);
	return 0;
}

static long twn_hd_commit(struct twn_dev *td, void __user *arg)
{
	struct twn_hd_desc d;
	u64 in_len;

	if (copy_from_user(&d, arg, sizeof(d)))
		return -EFAULT;
	if (d.op > 3)
		return -EINVAL;
	/* the head's transfer lengths are known, so the whole range is checked */
	in_len = (u64)d.in_beats * 16 + (d.op == 0 ? HD_SLOT_OFF : 0);
	if (!in_arena(td, d.in_off, in_len) ||
	    !in_arena(td, d.w_off, (u64)d.w_beats * 16) ||
	    !in_arena(td, d.out_off, (u64)d.out_beats * 16))
		return -EINVAL;
	wr_addr(td, R_HD_IN, d.in_off);
	wr_addr(td, R_HD_W, d.w_off);
	wr_addr(td, R_HD_OUT, d.out_off);
	wr(td, R_HD_BEATS + 0x00, d.in_beats);
	wr(td, R_HD_BEATS + 0x04, d.w_beats);
	wr(td, R_HD_BEATS + 0x08, d.out_beats);
	wr(td, R_HD_BEATS + 0x0c, d.shape);
	wr(td, R_HD_BEATS + 0x10, d.flags);
	wr(td, R_HD_BEATS + 0x14, d.clamp);
	wr(td, R_HD_COMMIT, d.op);      /* latches the twelve fields into operator d.op */
	return 0;
}

static long twn_hd_start(struct twn_dev *td)
{
	if (rd(td, R_HD_CTRL) & HD_BUSY)
		return -EBUSY;          /* a start written while busy would be dropped */
	reinit_completion(&td->hd_done);
	wr(td, R_HD_CTRL, HD_START);    /* also clears done */
	return 0;
}

static long twn_hd_wait(struct twn_dev *td, void __user *arg)
{
	u64 t0 = ktime_get_ns();
	int ret;

	ret = wait_done(td, &td->hd_done, R_HD_CTRL, HD_DONE);
	if (ret) {
		dev_err(td->dev, "head timed out: HD_CTRL %08x\n", rd(td, R_HD_CTRL));
		return ret;
	}
	wr(td, R_HD_CTRL, HD_DONE);
	return put_user(ktime_get_ns() - t0, (u64 __user *)arg);
}

/* ---- file operations of /dev/twn_fuse ---- */

static struct twn_dev *file_to_td(struct file *f)
{
	/* misc_open() stores the struct miscdevice in private_data */
	return container_of(f->private_data, struct twn_dev, misc);
}

static int twn_open(struct inode *inode, struct file *f)
{
	/* one process owns the accelerator at a time */
	return test_and_set_bit(0, &file_to_td(f)->in_use) ? -EBUSY : 0;
}

static int twn_release(struct inode *inode, struct file *f)
{
	clear_bit(0, &file_to_td(f)->in_use);
	return 0;
}

static int twn_mmap(struct file *f, struct vm_area_struct *vma)
{
	struct twn_dev *td = file_to_td(f);
	unsigned long len = vma->vm_end - vma->vm_start;

	/* only the arena, from its start: the registers are never mapped */
	if (vma->vm_pgoff || len > td->arena_size)
		return -EINVAL;
	if (map_device) {
		/*
		 * A/B measurement only: Device-nGnRnE, the attribute /dev/mem gives.
		 * Valid only without an IOMMU, where the DMA address is the physical one.
		 */
		if (device_iommu_mapped(td->dev))
			return -EINVAL;
		vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
		return remap_pfn_range(vma, vma->vm_start, PHYS_PFN(td->arena_dma), len,
				       vma->vm_page_prot);
	}
	return dma_mmap_coherent(td->dev, vma, td->arena, td->arena_dma, len);
}

static long twn_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct twn_dev *td = file_to_td(f);
	void __user *p = (void __user *)arg;
	struct mutex *lock;     /* the engine this command touches */
	long ret;

	/*
	 * The two engines have separate registers, so each has its own lock and
	 * the head can run while the backbone is being waited for.
	 */
	switch (cmd) {
	case TWN_IOC_STATUS:
		return twn_status(td, p);       /* reads only */
	case TWN_IOC_SET_TABLE:
	case TWN_IOC_SET_BASES:
	case TWN_IOC_BB_RUN:
	case TWN_IOC_BB2HD:
		lock = &td->bb_lock;
		break;
	case TWN_IOC_HD_SET_RQ:
	case TWN_IOC_HD_COMMIT:
	case TWN_IOC_HD_START:
	case TWN_IOC_HD_WAIT:
		lock = &td->hd_lock;
		break;
	default:
		return -ENOTTY;
	}

	if (mutex_lock_interruptible(lock))
		return -ERESTARTSYS;
	switch (cmd) {
	case TWN_IOC_SET_TABLE:
		ret = twn_set_table(td, p);
		break;
	case TWN_IOC_SET_BASES:
		ret = twn_set_bases(td, p);
		break;
	case TWN_IOC_BB_RUN:
		ret = twn_bb_run(td, p);
		break;
	case TWN_IOC_BB2HD:
		ret = twn_bb2hd(td, p);
		break;
	case TWN_IOC_HD_SET_RQ:
		ret = twn_hd_set_rq(td, p);
		break;
	case TWN_IOC_HD_COMMIT:
		ret = twn_hd_commit(td, p);
		break;
	case TWN_IOC_HD_START:
		ret = twn_hd_start(td);
		break;
	default: /* TWN_IOC_HD_WAIT */
		ret = twn_hd_wait(td, p);
		break;
	}
	mutex_unlock(lock);
	return ret;
}

static const struct file_operations twn_fops = {
	.owner          = THIS_MODULE,
	.open           = twn_open,
	.release        = twn_release,
	.mmap           = twn_mmap,
	.unlocked_ioctl = twn_ioctl,
};

/* ---- sysfs: /sys/bus/platform/devices/a0000000.twn_fuse/<name> ---- */

#define TWN_REG_ATTR(name, off, fmt)						\
static ssize_t name##_show(struct device *dev, struct device_attribute *a,	\
			   char *buf)						\
{										\
	struct twn_dev *td = dev_get_drvdata(dev);				\
										\
	return sysfs_emit(buf, fmt "\n", rd(td, off));				\
}										\
static DEVICE_ATTR_RO(name)

TWN_REG_ATTR(cycles_total,     R_CYCLES + 0x00, "%u");
TWN_REG_ATTR(cycles_array,     R_CYCLES + 0x04, "%u");
TWN_REG_ATTR(cycles_dw,        R_CYCLES + 0x08, "%u");
TWN_REG_ATTR(cycles_stall,     R_CYCLES + 0x0c, "%u");
TWN_REG_ATTR(cycles_idle_pre,  R_CYCLES + 0x10, "%u");
TWN_REG_ATTR(cycles_idle_post, R_CYCLES + 0x14, "%u");
TWN_REG_ATTR(status,           R_STATUS,        "0x%08x");
TWN_REG_ATTR(nblk,             R_NBLK,          "%u");

static struct attribute *twn_attrs[] = {
	&dev_attr_cycles_total.attr,
	&dev_attr_cycles_array.attr,
	&dev_attr_cycles_dw.attr,
	&dev_attr_cycles_stall.attr,
	&dev_attr_cycles_idle_pre.attr,
	&dev_attr_cycles_idle_post.attr,
	&dev_attr_status.attr,
	&dev_attr_nblk.attr,
	NULL,
};
ATTRIBUTE_GROUPS(twn);

/* ---- interrupt (hardware 1.1): level high, cleared by clearing the done it reports ---- */

static irqreturn_t twn_isr(int irq, void *data)
{
	struct twn_dev *td = data;
	irqreturn_t ret = IRQ_NONE;

	if (rd(td, R_CTRL) & CTRL_DONE) {
		wr(td, R_CTRL, CTRL_CLR_DONE);
		complete(&td->bb_done);
		ret = IRQ_HANDLED;
	}
	if (rd(td, R_HD_CTRL) & HD_DONE) {
		wr(td, R_HD_CTRL, HD_DONE);
		complete(&td->hd_done);
		ret = IRQ_HANDLED;
	}
	if (ret == IRQ_HANDLED) {
		td->irq_count++;
		/*
		 * The clears above are posted writes; read the device back so they
		 * have landed, and the line has dropped, before the handler returns.
		 */
		rd(td, R_IRQ);
	}
	return ret;
}

/* ---- debugfs: /sys/kernel/debug/twn_fuse/ (the UIO path's debug aids) ---- */

static int twn_nblk_get(void *data, u64 *val)
{
	*val = rd(data, R_NBLK);
	return 0;
}

/* run only the first n blocks, to find which block of a frame goes wrong */
static int twn_nblk_set(void *data, u64 val)
{
	struct twn_dev *td = data;

	if (val < 1 || val > NBLK_RESET)
		return -EINVAL;
	mutex_lock(&td->bb_lock);
	wr(td, R_NBLK, val);
	mutex_unlock(&td->bb_lock);
	return 0;
}
DEFINE_DEBUGFS_ATTRIBUTE(twn_nblk_fops, twn_nblk_get, twn_nblk_set, "%llu\n");

/*
 * A test of the SMMU, not of the accelerator: one backbone frame that reads its input from
 * the first byte after the DMA buffer. Behind the SMMU that address is not mapped, so the
 * SMMU stops the reads and the kernel logs a context fault; without the SMMU the PL reads
 * whatever memory follows the buffer, and nothing notices. The output, written to the start
 * of the buffer, is meaningless; an app reloads the buffer when it starts.
 */
static int twn_fault_set(void *data, u64 val)
{
	struct twn_dev *td = data;
	int ret;

	if (val != 1 || !(rd(td, R_STATUS) & ST_VALID))
		return -EINVAL;         /* needs the table an app loads */
	mutex_lock(&td->bb_lock);
	ret = wait_bit(td, R_CTRL, CTRL_BUSY, false);
	if (!ret) {
		wr(td, R_CTRL, CTRL_CLR_DONE);
		reinit_completion(&td->bb_done);
		wr_addr(td, R_IN, td->arena_size);
		wr_addr(td, R_OUT, 0);
		wr(td, R_CTRL, CTRL_START);
		ret = wait_done(td, &td->bb_done, R_CTRL, CTRL_DONE);
		wr(td, R_CTRL, CTRL_CLR_DONE);
	}
	dev_info(td->dev, "dma_fault: input at %pad + %zu KB: %s, STATUS %08x\n",
		 &td->arena_dma, td->arena_size >> 10, ret ? "timed out" : "frame done",
		 rd(td, R_STATUS));
	mutex_unlock(&td->bb_lock);
	return ret;
}
DEFINE_DEBUGFS_ATTRIBUTE(twn_fault_fops, NULL, twn_fault_set, "%llu\n");

static const struct debugfs_reg32 twn_dbg_regs[] = {
	{ "CTRL",    R_CTRL },        { "NBLK",    R_NBLK },
	{ "STATUS",  R_STATUS },      { "PIX_NZ",  R_PIX_NZ },
	{ "CAP0",    R_CAP + 0x0 },   { "CAP1",    R_CAP + 0x4 },
	{ "CAP2",    R_CAP + 0x8 },   { "CAP3",    R_CAP + 0xc },
	{ "BB2HD",   R_BB2HD },       { "IRQ",     R_IRQ },
	{ "HD_CTRL", R_HD_CTRL },     { "HD_COMMIT", R_HD_COMMIT },
	{ "HD_RQ_STAT", R_HD_RQ_STAT },
};

static void twn_debugfs_init(struct twn_dev *td)
{
	td->regset.regs  = twn_dbg_regs;
	td->regset.nregs = ARRAY_SIZE(twn_dbg_regs);
	td->regset.base  = td->regs;
	td->dbg = debugfs_create_dir("twn_fuse", NULL);
	debugfs_create_regset32("regs", 0444, td->dbg, &td->regset);
	debugfs_create_file_unsafe("nblk", 0644, td->dbg, td, &twn_nblk_fops);
	debugfs_create_u32("irq_count", 0444, td->dbg, &td->irq_count);
	debugfs_create_file_unsafe("dma_fault", 0200, td->dbg, td, &twn_fault_fops);
}

/* ---- probe / remove ---- */

static int twn_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct twn_dev *td;
	u32 nblk;
	int ret;

	td = devm_kzalloc(dev, sizeof(*td), GFP_KERNEL);
	if (!td)
		return -ENOMEM;
	td->dev = dev;

	/* 1. map the node's "reg" range: 64 KB of registers at 0xA000_0000 */
	td->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(td->regs))
		return PTR_ERR(td->regs);

	/* 2. is this our hardware? (a debug run can leave NBLK changed, so only warn) */
	nblk = rd(td, R_NBLK);
	if (nblk != NBLK_RESET)
		dev_warn(dev, "NBLK reads %u, expected %u: another bitstream, or a debug run changed it\n",
			 nblk, NBLK_RESET);

	/* 3. the DMA buffer; the PL's address registers are 40 bits wide */
	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(40));
	if (ret)
		return ret;
	td->arena_size = (size_t)arena_mb << 20;
	td->arena = dmam_alloc_coherent(dev, td->arena_size, &td->arena_dma, GFP_KERNEL);
	if (!td->arena)
		return -ENOMEM;
	/* the app lays out 64 KB-aligned regions (head input slots 64 KB apart) */
	if (td->arena_dma & (SZ_64K - 1)) {
		dev_err(dev, "DMA buffer at %pad is not 64 KB aligned\n", &td->arena_dma);
		return -EINVAL;
	}

	mutex_init(&td->bb_lock);
	mutex_init(&td->hd_lock);
	init_completion(&td->bb_done);
	init_completion(&td->hd_done);
	platform_set_drvdata(pdev, td);

	/* 4. the interrupt, if the device tree gives one (hardware 1.1); else poll */
	td->irq = use_irq ? platform_get_irq_optional(pdev, 0) : -ENXIO;
	if (td->irq > 0) {
		ret = devm_request_irq(dev, td->irq, twn_isr, 0, dev_name(dev), td);
		if (ret)
			return ret;
		wr(td, R_IRQ, IRQ_BB | IRQ_HD);
	}

	/* 5. the character device /dev/twn_fuse, last: from here on it can be opened */
	td->misc.minor  = MISC_DYNAMIC_MINOR;
	td->misc.name   = "twn_fuse";
	td->misc.fops   = &twn_fops;
	td->misc.parent = dev;
	ret = misc_register(&td->misc);
	if (ret)
		return ret;

	twn_debugfs_init(td);
	dev_info(dev, "NBLK %u, %zu KB DMA buffer at %pad, /dev/%s, %s\n",
		 nblk, td->arena_size >> 10, &td->arena_dma, td->misc.name,
		 td->irq > 0 ? "interrupt" : "polling");
	return 0;
}

static int twn_remove(struct platform_device *pdev)
{
	struct twn_dev *td = platform_get_drvdata(pdev);

	/*
	 * Everything else (mapping, buffer, interrupt, memory) was allocated with
	 * devm_ and is released by the driver core; stop the interrupt source first.
	 */
	debugfs_remove_recursive(td->dbg);
	misc_deregister(&td->misc);
	if (td->irq > 0)
		wr(td, R_IRQ, 0);
	return 0;
}

static const struct of_device_id twn_of_match[] = {
	{ .compatible = "wjhuang,twn-fuse-1.1" },       /* with the interrupt */
	{ .compatible = "wjhuang,twn-fuse-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, twn_of_match);

static struct platform_driver twn_driver = {
	.probe  = twn_probe,
	.remove = twn_remove,
	.driver = {
		.name           = "twn_fuse",
		.of_match_table = twn_of_match,
		.dev_groups     = twn_groups,
		/*
		 * No sysfs "unbind": it would free the buffer under a process that
		 * still has it mapped. Unloading goes through rmmod, which the
		 * kernel refuses while the device is open or mapped.
		 */
		.suppress_bind_attrs = true,
	},
};
module_platform_driver(twn_driver);

MODULE_AUTHOR("Wei-Jhe Huang");
MODULE_DESCRIPTION("Driver for the ternary MobileNetV2 accelerator (twn_fuse)");
MODULE_LICENSE("Dual MIT/GPL");
