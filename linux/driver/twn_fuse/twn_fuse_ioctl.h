/* SPDX-License-Identifier: MIT */
/*
 * The interface between the twn_fuse driver and user space.
 *
 * Shared by the driver (twn_fuse.c) and the app backend (sw/app/pl_hal_fuse_drv.c).
 * Every DDR location is an OFFSET into the driver's buffer (the "arena"), never a
 * physical address: the driver checks the offset and adds the buffer's DMA address.
 */
#ifndef TWN_FUSE_IOCTL_H
#define TWN_FUSE_IOCTL_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define TWN_DEV_PATH        "/dev/twn_fuse"
/* 0xBC is unused in Documentation/userspace-api/ioctl/ioctl-number.rst */
#define TWN_IOC_MAGIC       0xBC
#define TWN_DESC_MAX_WORDS  512    /* the descriptor window 0x1000..0x17ff */
#define TWN_HD_RQ_WORDS     256    /* the head's requantisation window 0x0400..0x07ff */

/* registers worth showing to user space, read in one go */
struct twn_status {
	__u64 arena_size;  /* bytes; mmap() at offset 0 maps all of it */
	__u32 ctrl;        /* backbone CTRL: [0] start [1] busy [2] done */
	__u32 status;      /* STATUS: [0] table valid [1] table checked [6:2] block ... */
	__u32 hd_ctrl;     /* head HD_CTRL: [0] start pending [1] busy [2] done */
	__u32 hd_commit;   /* HD_COMMIT: [7:4] sticky mask of committed descriptors */
	__u32 hd_rq_stat;  /* HD_RQ_STAT: words written and operator mask */
	__u32 bb2hd;       /* A_BB2HD: [0] enable [1] parity [2] head slot [3] collision */
};

/* the block descriptor table; the driver writes it, sets NBLK and runs the check */
struct twn_table {
	__u64 words;       /* user pointer to nwords 32-bit words */
	__u32 nwords;
	__u32 nblk;        /* number of blocks to run */
};

struct twn_bases {
	__u64 w_off;       /* backbone weights */
	__u64 act_off;     /* activation slots */
};

/* one backbone frame: blocks until done or timeout */
struct twn_bb_run {
	__u64 in_off;      /* input image */
	__u64 out_off;     /* output pointer (with BB2HD on: the head's input slots) */
	__u64 ns;          /* out: START -> done, nanoseconds */
	__u32 cycles[6];   /* out: total, array, depthwise, memory stall, idle before, idle after */
};

/* one head descriptor, already packed by the app (see pl_hal_fuse_enc.c) */
struct twn_hd_desc {
	__u64 in_off, w_off, out_off;
	__u32 in_beats, w_beats, out_beats;   /* 128-bit beats */
	__u32 shape, flags, clamp;            /* HD_SHAPE, HD_FLAGS, HD_CLAMP words */
	__u32 op;                             /* which of the four operators, 0..3 */
	__u32 pad;
};

struct twn_hd_rq {
	__u32 words[TWN_HD_RQ_WORDS];         /* in address order: op*64 + oc*2 + half */
};

#define TWN_IOC_STATUS     _IOR(TWN_IOC_MAGIC, 0, struct twn_status)
#define TWN_IOC_SET_TABLE  _IOW(TWN_IOC_MAGIC, 1, struct twn_table)
#define TWN_IOC_SET_BASES  _IOW(TWN_IOC_MAGIC, 2, struct twn_bases)
#define TWN_IOC_BB_RUN     _IOWR(TWN_IOC_MAGIC, 3, struct twn_bb_run)
#define TWN_IOC_BB2HD      _IOWR(TWN_IOC_MAGIC, 4, __u32)  /* in: value to write, out: read back */
#define TWN_IOC_HD_SET_RQ  _IOW(TWN_IOC_MAGIC, 5, struct twn_hd_rq)
#define TWN_IOC_HD_COMMIT  _IOW(TWN_IOC_MAGIC, 6, struct twn_hd_desc)
#define TWN_IOC_HD_START   _IO(TWN_IOC_MAGIC, 7)
#define TWN_IOC_HD_WAIT    _IOR(TWN_IOC_MAGIC, 8, __u64)    /* out: wait -> done, nanoseconds */

#endif
