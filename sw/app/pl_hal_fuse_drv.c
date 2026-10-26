/* ============================================================================
 *  pl_hal_fuse_drv.c -- pl_hal_fuse.h on top of the twn_fuse kernel driver
 *  (linux/driver/twn_fuse). Build with `make -f Makefile.cross HAL=drv`.
 *
 *  The UIO backend (pl_hal_fuse.c) maps the registers and /dev/mem into the
 *  process and writes registers itself. Here the process sees only:
 *    - /dev/twn_fuse, and ioctl() calls that do one register sequence each;
 *    - the driver's DMA buffer, mapped with mmap().
 *
 *  Addresses: fuse_arena_init() reports a base of 0, so every "physical
 *  address" the app computes (base + offset) is an offset into the buffer,
 *  which is what the driver's ioctls take. The app code above this file is
 *  unchanged.
 *
 *  Debug aids (fuse_set_nblk(), fuse_read_pix_nz(), fuse_read_arr_cap()) go
 *  through the driver's debugfs files in /sys/kernel/debug/twn_fuse/.
 * ========================================================================== */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include "pl_hal_fuse.h"
#include "../../tools/fuse_desctab.h"
#include "../../linux/driver/twn_fuse/twn_fuse_ioctl.h"

#define HRQ_STAT_FULL 0x0000100Fu       /* 256 words, all four operators */

static int      g_fd = -1;
static int      g_table_ok = -1;        /* result of the last fuse_load_desctab() */
static uint32_t g_cycles[6];            /* counters returned by the last frame */
static int      g_bb2hd_state = -1;     /* -1: not written yet in this process */

/* one ioctl; on failure print what failed and return -1 */
static int xioctl(unsigned long cmd, void *arg, const char *what) {
    if (ioctl(g_fd, cmd, arg) == 0) return 0;
    fprintf(stderr, "fuse_drv: %s: %s\n", what, strerror(errno));
    return -1;
}

static struct twn_status status(void) {
    struct twn_status s;
    if (xioctl(TWN_IOC_STATUS, &s, "STATUS")) exit(1);
    return s;
}

void fuse_hal_init(void) {
    if (g_fd >= 0) return;
    g_fd = open(TWN_DEV_PATH, O_RDWR | O_CLOEXEC);
    if (g_fd < 0) { perror("open " TWN_DEV_PATH); exit(1); }
    fprintf(stderr, "fuse_hal: kernel driver %s\n", TWN_DEV_PATH);
}

void *fuse_arena_init(uint64_t *phys, uint64_t size) {
    fuse_hal_init();
    struct twn_status s = status();
    if (size > s.arena_size) {
        fprintf(stderr, "arena too small: need %llu, the driver has %llu "
                        "(module parameter arena_mb)\n",
                (unsigned long long)size, (unsigned long long)s.arena_size);
        exit(1);
    }
    void *v = mmap(NULL, s.arena_size, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd, 0);
    if (v == MAP_FAILED) { perror("mmap " TWN_DEV_PATH); exit(1); }
    *phys = 0;                          /* addresses are offsets into the buffer */
    return v;
}

void fuse_set_bases(uint64_t w_base_pa, uint64_t act_base_pa) {
    struct twn_bases b = { .w_off = w_base_pa, .act_off = act_base_pa };
    if (xioctl(TWN_IOC_SET_BASES, &b, "SET_BASES")) exit(1);
}

/* the driver writes the table, sets NBLK and runs the check in one call */
void fuse_load_desctab(void) {
    struct twn_table t = {
        .words  = (uintptr_t)fuse_desctab,
        .nwords = FUSE_NBLK * FUSE_DESC_WORDS,
        .nblk   = FUSE_NBLK,
    };
    g_table_ok = xioctl(TWN_IOC_SET_TABLE, &t, "SET_TABLE (refused: see dmesg)");
}

int fuse_check_table(void) { return g_table_ok; }

/* ---- debug aids, through debugfs ---- */
#define TWN_DEBUGFS "/sys/kernel/debug/twn_fuse/"

/* one register from the "regs" file, whose lines read "NAME = 0x%08x" */
static uint32_t dbg_reg(const char *name) {
    char line[128], key[32];
    unsigned int v = 0;
    FILE *f = fopen(TWN_DEBUGFS "regs", "r");
    if (!f) { perror("open " TWN_DEBUGFS "regs"); return 0; }
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "%31s = %x", key, &v) == 2 && !strcmp(key, name)) { fclose(f); return v; }
    fclose(f);
    fprintf(stderr, "fuse_drv: no %s in " TWN_DEBUGFS "regs\n", name);
    return 0;
}

int fuse_set_nblk(uint32_t n) {
    FILE *f = fopen(TWN_DEBUGFS "nblk", "w");
    if (!f) { perror("open " TWN_DEBUGFS "nblk"); return -1; }
    int bad = fprintf(f, "%u\n", n) < 0;
    bad |= fclose(f) != 0;              /* the driver's range check reports here */
    return (bad || dbg_reg("NBLK") != n) ? -1 : 0;
}
uint32_t fuse_read_pix_nz(void) { return dbg_reg("PIX_NZ") & 0xFFFu; }
void fuse_read_arr_cap(uint32_t out[4]) {
    out[0] = dbg_reg("CAP0"); out[1] = dbg_reg("CAP1");
    out[2] = dbg_reg("CAP2"); out[3] = dbg_reg("CAP3");
}

uint64_t fuse_run_frame(uint64_t in_pa, uint64_t out_pa, int yield_wait) {
    (void)yield_wait;                   /* the driver always sleeps between polls */
    struct twn_bb_run r = { .in_off = in_pa, .out_off = out_pa };
    if (xioctl(TWN_IOC_BB_RUN, &r, "BB_RUN")) exit(1);
    memcpy(g_cycles, r.cycles, sizeof g_cycles);
    return r.ns;
}

void fuse_read_counters(fuse_counters_t *c) {
    c->total     = g_cycles[0];
    c->array     = g_cycles[1];
    c->dw        = g_cycles[2];
    c->stall_mem = g_cycles[3];
    c->idle_pre  = g_cycles[4];
    c->idle_post = g_cycles[5];
}

/* ---- head engine: the app packs the words, the driver checks the ranges ---- */
int fuse_hd_commit(const fuse_hd_desc_t *d, int op) {
    char why[256];
    if (fuse_hd_desc_check(d, op, why, sizeof why) != 0) {
        fprintf(stderr, "fuse_hd: REFUSING op%d's descriptor -- %s\n", 61 + op, why);
        return -1;
    }
    struct twn_hd_desc k = {
        .in_off = d->in_base, .w_off = d->w_base, .out_off = d->out_base,
        .in_beats = d->in_beats, .w_beats = d->w_beats, .out_beats = d->out_beats,
        .shape = fuse_hd_shape_word(d), .flags = fuse_hd_flags_word(d),
        .clamp = fuse_hd_clamp_word(d), .op = (uint32_t)op,
    };
    return xioctl(TWN_IOC_HD_COMMIT, &k, "HD_COMMIT");
}

int fuse_hd_program(const fuse_hd_desc_t d[FUSE_HD_NOPS],
                    const fuse_hd_rq_t rq[FUSE_HD_NOPS][FUSE_HD_NRQ]) {
    struct twn_hd_rq w;
    for (int op = 0; op < FUSE_HD_NOPS; op++)
        for (int c = 0; c < FUSE_HD_NRQ; c++) {
            const fuse_hd_rq_t *e = &rq[op][c];
            if (e->m0 < -(1 << 17) || e->m0 >= (1 << 17) ||
                e->bias < -((int64_t)1 << 39) || e->bias >= ((int64_t)1 << 39) || e->sh > 63) {
                fprintf(stderr, "fuse_hd: op%d oc%d requantisation entry does not fit "
                                "18 / 40 / 6 bits\n", 61 + op, c);
                return -1;
            }
            /* word index = (fuse_hd_rq_off() - 0x400) / 4 = op*64 + oc*2 + half */
            fuse_hd_rq_words(e, &w.words[op * 64 + c * 2]);
        }
    if (xioctl(TWN_IOC_HD_SET_RQ, &w, "HD_SET_RQ")) return -1;
    for (int op = 0; op < FUSE_HD_NOPS; op++)
        if (fuse_hd_commit(&d[op], op) != 0) return -1;

    /* the tables cannot be read back; the two sticky registers are the evidence */
    struct twn_status s = status();
    if (((s.hd_commit >> 4) & 0xF) != 0xF || s.hd_rq_stat != HRQ_STAT_FULL) {
        fprintf(stderr, "fuse_hd: HD_COMMIT %08x HD_RQ_STAT %08x -- not every "
                        "descriptor or requantisation word landed\n",
                s.hd_commit, s.hd_rq_stat);
        return -1;
    }
    fprintf(stderr, "fuse_hd: four descriptors committed (HD_COMMIT %08x), "
                    "256 requant words (HD_RQ_STAT %08x)\n", s.hd_commit, s.hd_rq_stat);
    return 0;
}

void fuse_hd_read_status(uint32_t *ctrl, uint32_t *commit, uint32_t *rq_stat) {
    struct twn_status s = status();
    if (ctrl)    *ctrl    = s.hd_ctrl;
    if (commit)  *commit  = s.hd_commit;
    if (rq_stat) *rq_stat = s.hd_rq_stat;
}

int fuse_hd_start(void) { return xioctl(TWN_IOC_HD_START, NULL, "HD_START"); }

int fuse_hd_wait(int yield_wait, uint64_t *ns) {
    (void)yield_wait;
    uint64_t t = 0;
    int r = xioctl(TWN_IOC_HD_WAIT, &t, "HD_WAIT");
    if (ns) *ns = t;
    return r;
}

/* ---- BB2HD: same caching as the UIO backend ---- */
static uint32_t bb2hd_write(uint32_t v) {
    if (xioctl(TWN_IOC_BB2HD, &v, "BB2HD")) exit(1);
    return v;                           /* the register, read back */
}

int fuse_bb2hd_probe(void) {
    int has = (bb2hd_write(FUSE_BB2HD_EN) & FUSE_BB2HD_EN) != 0;
    bb2hd_write(0);
    g_bb2hd_state = 0;
    return has;
}

void fuse_bb2hd_set(int en) {
    en = en ? 1 : 0;
    if (en == g_bb2hd_state) return;
    bb2hd_write(en ? FUSE_BB2HD_EN : 0);
    g_bb2hd_state = en;
}

void fuse_bb2hd_restart(void) {
    bb2hd_write(FUSE_BB2HD_EN | FUSE_BB2HD_PAR | FUSE_BB2HD_COLL);
    g_bb2hd_state = 1;
}

uint32_t fuse_bb2hd_read(void) { return status().bb2hd; }
