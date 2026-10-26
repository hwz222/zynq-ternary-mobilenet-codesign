/* ============================================================================
 *  pl_hal_fuse.c -- PS side of the fused backbone accelerator and its head
 *  engine: maps the control window (UIO) and the DDR arena (/dev/mem), writes
 *  the block descriptor table once, runs frames by polling CTRL.
 *
 *  Environment: PL_UIO (UIO device path; default: the UIO named twn_fuse_top,
 *  mbv2_fuse or twn_top), PL_ARENA_PA / PL_ARENA_SZ (hex; default
 *  FUSE_ARENA_PA_DEFAULT / FUSE_ARENA_SZ_DEFAULT).
 *
 *  The register map is taken from rtl/fuse/twn_csr.v. A frame starts only if
 *  the descriptor table has been checked and passed, with no error on the
 *  start write; fuse_check_table() must run first (STATUS carries the reason).
 * ========================================================================== */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <dirent.h>

#include "pl_hal_fuse.h"
#include "../../tools/fuse_desctab.h"

/* ---- register map, from rtl/fuse/twn_csr.v ---- */
/* CTRL has different read and write layouts:
 *   R: [0] ap_start   [1] core_busy    [2] ap_done   [3] irq_en
 *   W: [0] start      [1] clear done   [2] irq_en
 * Bit 1 is BUSY when read and CLEAR-DONE when written. */
#define F_CTRL        0x0000  /* layouts above                                  */
#define F_NBLK        0x0008  /* resets to 17                                   */
#define F_ACT_LO      0x000c
#define F_ACT_HI      0x0010
#define F_W_LO        0x0014
#define F_W_HI        0x0018
#define F_IN_LO       0x001c
#define F_IN_HI       0x0020
#define F_OUT_LO      0x0024
#define F_OUT_HI      0x0028
#define F_STATUS      0x002c  /* [0] d_valid [1] tab_checked [6:2] cur_block    */
                              /* [10:7] err_code  [15:11] err_block             */
                              /* [16] ovr_sticky: a ring overrun happened since */
                              /* the last PL reset; only a PL reset clears it   */
#define F_CHECK       0x0030  /* write 1 -> walk the descriptor table           */
#define F_CYC_TOTAL   0x0034
#define F_CYC_ARRAY   0x0038
#define F_CYC_DW      0x003c
#define F_CYC_STALL   0x0040
#define F_CYC_PRE     0x0044
#define F_CYC_POST    0x0048
#define F_BB2HD       0x0060  /* layout in pl_hal_fuse.h                        */
#define F_DESC_BASE   0x1000  /* FUSE_NBLK x 16 words; index = addr[10:2]       */

#define CTRL_START    0x1u      /* write */
#define CTRL_CLR_DONE 0x2u      /* write -- NOT the done bit on read           */
#define CTRL_R_BUSY   0x2u      /* read  -- core_busy                          */
#define CTRL_R_DONE   0x4u      /* read  -- ap_done, set by core_done          */
#define ST_D_VALID    0x1u
#define ST_TAB_CHECKED 0x2u

/* descriptor-check error codes (STATUS[10:7]), as in twn_desctab.v */
static const char *ERRNAME[16] = {
    "none", "SLOT_RANGE", "SLOT_SAME", "SLOT_CHAIN", "TERN_OVF",
    "DW_OVF", "RQA_OVF", "RQD_OVF", "GEOM",
    "?", "?", "?", "?", "?", "?", "?"
};

#define CTRL_MAP_SZ  0x10000          /* 64 KB: the descriptor window is at 0x1000 */

static volatile uint32_t *g_ctrl;
static uint8_t  *g_arena_v;
static uint64_t  g_arena_pa, g_arena_sz;

static inline void   wr(uint32_t off, uint32_t v) { g_ctrl[off >> 2] = v; }
static inline uint32_t rd(uint32_t off)           { return g_ctrl[off >> 2]; }
static inline void   wr64(uint32_t off, uint64_t v) {
    wr(off, (uint32_t)v); wr(off + 4, (uint32_t)(v >> 32));
}

/* ---- ordering: every arena store must land before a START ----
 * g_arena_v is not volatile and the arena is Device memory. Two barriers:
 *   - a compiler barrier, so arena stores are emitted before the START write;
 *   - on AArch64 `dsb sy`, so they have completed before the CSR write that
 *     lets the PL read the arena (arena and CSR window are different Device
 *     regions; Device ordering is only guaranteed within one peripheral).
 * Non-AArch64 builds keep only the compiler barrier. */
static inline void fuse_wmb(void) {
#if defined(__aarch64__)
    __asm__ __volatile__("dsb sy" ::: "memory");
#else
    __asm__ __volatile__("" ::: "memory");
#endif
}

/* ---- UIO discovery, as in pl_hal_zynq.c: the node name depends on the
 * device-tree generator, and uio0 is not necessarily the accelerator. ---- */
static int find_uio_by_name(const char *want, char *out, size_t outsz) {
    for (int i = 0; i < 32; i++) {
        char p[64], nm[64];
        snprintf(p, sizeof p, "/sys/class/uio/uio%d/name", i);
        FILE *f = fopen(p, "r");
        if (!f) continue;
        if (!fgets(nm, sizeof nm, f)) { fclose(f); continue; }
        fclose(f);
        nm[strcspn(nm, "\r\n")] = 0;
        if (strcmp(nm, want) == 0) { snprintf(out, outsz, "/dev/uio%d", i); return 0; }
    }
    return -1;
}

void fuse_hal_init(void) {
    char path[64];
    const char *uio = getenv("PL_UIO");
    if (!uio) {
        if      (find_uio_by_name("twn_fuse",     path, sizeof path) == 0) uio = path;  /* DT node of the fused design */
        else if (find_uio_by_name("fuse_0",       path, sizeof path) == 0) uio = path;  /* its BD cell name */
        else if (find_uio_by_name("twn_fuse_top", path, sizeof path) == 0) uio = path;
        else if (find_uio_by_name("mbv2_fuse",    path, sizeof path) == 0) uio = path;
        else if (find_uio_by_name("twn_top",      path, sizeof path) == 0) uio = path;
        else {
            fprintf(stderr, "fuse_hal: no UIO named 'twn_fuse'/'fuse_0'/'twn_fuse_top'/'mbv2_fuse'/'twn_top'\n");
            exit(1);       /* no fallback to uio0 */
        }
    }
    fprintf(stderr, "fuse_hal: control UIO = %s\n", uio);
    int fd = open(uio, O_RDWR | O_SYNC);
    if (fd < 0) { perror("open uio"); exit(1); }
    g_ctrl = (volatile uint32_t *)mmap(NULL, CTRL_MAP_SZ, PROT_READ | PROT_WRITE,
                                       MAP_SHARED, fd, 0);
    if (g_ctrl == MAP_FAILED) { perror("mmap uio"); exit(1); }
    close(fd);
}

void *fuse_arena_init(uint64_t *phys, uint64_t size) {
    const char *pas = getenv("PL_ARENA_PA"), *szs = getenv("PL_ARENA_SZ");
    g_arena_pa = pas ? strtoull(pas, 0, 16) : FUSE_ARENA_PA_DEFAULT;
    g_arena_sz = szs ? strtoull(szs, 0, 16) : FUSE_ARENA_SZ_DEFAULT;
    if (size > g_arena_sz) {
        fprintf(stderr, "arena too small: need %llu have %llu\n",
                (unsigned long long)size, (unsigned long long)g_arena_sz);
        exit(1);
    }
    if (!g_ctrl) fuse_hal_init();
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); exit(1); }
    g_arena_v = (uint8_t *)mmap(NULL, g_arena_sz, PROT_READ | PROT_WRITE, MAP_SHARED,
                                fd, (off_t)g_arena_pa);
    if (g_arena_v == MAP_FAILED) { perror("mmap /dev/mem arena"); exit(1); }
    close(fd);
    *phys = g_arena_pa;
    return g_arena_v;
}

/* ---- descriptor table: FUSE_NBLK * FUSE_DESC_WORDS words, written once ----
 * The words come from tools/fuse_desctab.h, generated by tools/gen_desctab.py
 * (the same generator also emits the testbench's tb_desctab_words.vh). */
void fuse_load_desctab(void) {
    for (int i = 0; i < FUSE_NBLK * FUSE_DESC_WORDS; i++)
        wr(F_DESC_BASE + (uint32_t)(i * 4), fuse_desctab[i]);
    wr(F_NBLK, FUSE_NBLK);
}

/* ---- the check. Returns 0 on pass; on failure prints the error code and block
 * (a refused start is otherwise silent). ---- */
int fuse_check_table(void) {
    wr(F_CHECK, 1);
    for (int spin = 0; spin < 1000000; spin++) {
        uint32_t st = rd(F_STATUS);
        if (st & ST_TAB_CHECKED) {
            if (st & ST_D_VALID) return 0;
            fprintf(stderr, "fuse_hal: descriptor table REFUSED -- %s at block %u\n",
                    ERRNAME[(st >> 7) & 0xF], (st >> 11) & 0x1F);
            return -1;
        }
    }
    fprintf(stderr, "fuse_hal: descriptor check never completed (STATUS %08x)\n",
            rd(F_STATUS));
    return -1;
}

void fuse_set_bases(uint64_t w_base_pa, uint64_t act_base_pa) {
    wr64(F_W_LO, w_base_pa);
    wr64(F_ACT_LO, act_base_pa);
}

/* ---- pixel-phase sticky bits (PIX_NZ, 0x004c) ----
 * Twelve bits, three groups of 4 (one per pixel of a group), sticky for the
 * frame and cleared at ap_start:
 *   [3:0]   the array's output had this pixel non-zero on a valid beat
 *   [7:4]   the scatter bank's WRITE data was non-zero
 *   [11:8]  the scatter bank's READ data was non-zero
 * Read after the frame, before starting another. */
#define F_PIX_NZ 0x004c
uint32_t fuse_read_pix_nz(void) { return rd(F_PIX_NZ) & 0xFFFu; }

/* The first project beat of the frame, verbatim: 128 bits at 0x0050..0x005c
 * (CAP0..CAP3); pixel p is out[p]. With one block run (fuse_set_nblk(1)) it is
 * block 0's first project beat. */
void fuse_read_arr_cap(uint32_t out[4]) {
    out[0] = rd(0x0050); out[1] = rd(0x0054);
    out[2] = rd(0x0058); out[3] = rd(0x005c);
}

/* Run only the first `n` blocks. twn_csr.v backs n_blocks with a writable
 * register (F_NBLK), and twn_frameseq stops prefetching at n_blocks, so a short
 * frame leaves no fetch outstanding. Out-of-range values are refused, not
 * clamped; the write is read back. */
int fuse_set_nblk(uint32_t n) {
    if (n < 1 || n > FUSE_NBLK) return -1;
    wr(F_NBLK, n);
    return rd(F_NBLK) == n ? 0 : -1;
}

/* ---- one frame: clear done, write the pointers, START, poll CTRL ---- */
uint64_t fuse_run_frame(uint64_t in_pa, uint64_t out_pa, int yield_wait) {
    struct timespec t0, t1;
    static int stale_warned = 0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    /* Clear a leftover done before starting: ap_done is cleared only by
     * writing CTRL[1], a START does not clear it, and a stale done would end
     * the poll below at once. Warn once per process if one is found. If the core
     * is still busy, wait for it first: a START written while busy is dropped,
     * not queued. */
    {
        uint32_t c0 = rd(F_CTRL);
        if ((c0 & CTRL_R_DONE) && !stale_warned) {
            fprintf(stderr, "fuse_hal: WARNING -- CTRL reads %08x before START: a "
                            "leftover ap_done from a run that never cleared it. "
                            "Clearing it now (printed once per process).\n", c0);
            stale_warned = 1;
        }
        while (c0 & CTRL_R_BUSY) {
            clock_gettime(CLOCK_MONOTONIC, &t1);
            double el = (t1.tv_sec - t0.tv_sec) + 1e-9 * (t1.tv_nsec - t0.tv_nsec);
            if (el > 3.0) {
                fprintf(stderr, "fuse_hal: the core stayed busy for 3 s before START -- "
                                "CTRL %08x STATUS %08x\n", c0, rd(F_STATUS));
                exit(1);
            }
            c0 = rd(F_CTRL);
        }
        wr(F_CTRL, CTRL_CLR_DONE);
    }

    wr64(F_IN_LO,  in_pa);
    wr64(F_OUT_LO, out_pa);
    /* the caller's arena stores must be complete before the PL reads them */
    fuse_wmb();
    wr(F_CTRL, CTRL_START);

    /* Wait on ap_done (READ bit 2), not core_busy (READ bit 1). There is no
     * interrupt: twn_fuse_top has no irq port; irq_en is only stored. */
    for (;;) {
        uint32_t c = rd(F_CTRL);
        if (c & CTRL_R_DONE) break;
        if (yield_wait) {
            struct timespec ts = { 0, 50000 };      /* 50 us */
            nanosleep(&ts, NULL);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double el = (t1.tv_sec - t0.tv_sec) + 1e-9 * (t1.tv_nsec - t0.tv_nsec);
        if (el > 3.0) {
            fprintf(stderr, "fuse_hal: frame did not finish in 3 s -- CTRL %08x "
                            "STATUS %08x block %u cyc %u\n",
                    c, rd(F_STATUS), (rd(F_STATUS) >> 2) & 0x1F, rd(F_CYC_TOTAL));
            exit(1);
        }
    }
    wr(F_CTRL, CTRL_CLR_DONE);

    clock_gettime(CLOCK_MONOTONIC, &t1);
    return (uint64_t)((t1.tv_sec - t0.tv_sec) * 1000000000ull
                      + (t1.tv_nsec - t0.tv_nsec));
}

/* ---- the six performance counters (read-only, from the core) ---- */
void fuse_read_counters(fuse_counters_t *c) {
    c->total     = rd(F_CYC_TOTAL);
    c->array     = rd(F_CYC_ARRAY);
    c->dw        = rd(F_CYC_DW);
    c->stall_mem = rd(F_CYC_STALL);
    c->idle_pre  = rd(F_CYC_PRE);
    c->idle_post = rd(F_CYC_POST);
}

/* ---- head engine ----
 * Offsets and bit positions are from rtl/fuse/twn_csr.v; the order of the
 * writes follows the hd_desc() / program_rq() tasks of rtl/fuse/tb/tb_hd_int.v. */
#define H_CTRL        0x0100
#define H_COMMIT      0x0104
#define H_RQ_STAT     0x0108
#define H_IN_LO       0x0110
#define H_IN_HI       0x0114
#define H_W_LO        0x0118
#define H_W_HI        0x011c
#define H_OUT_LO      0x0120
#define H_OUT_HI      0x0124
#define H_IN_BEATS    0x0128
#define H_W_BEATS     0x012c
#define H_OUT_BEATS   0x0130
#define H_SHAPE       0x0134
#define H_FLAGS       0x0138
#define H_CLAMP       0x013c
#define H_RQ_BASE     0x0400            /* .. 0x07fc, 256 words                */

/* HD_CTRL has the same bit meaning on read and write (unlike CTRL at 0x0000),
 * so one constant serves both directions. */
#define HC_START      0x1u              /* W: start (also clears done). R: pending */
#define HC_BUSY       0x2u              /* R only -- writing it does nothing       */
#define HC_DONE       0x4u              /* R: done is set. W: clear it.            */

#define HRQ_STAT_FULL 0x0000100Fu       /* 256 words, all four operators           */

/* ---- pure encoders, no register access ---- */
uint32_t fuse_hd_shape_word(const fuse_hd_desc_t *d) {
    return  (d->ic & 0x1FFu)
         | ((d->oc & 0x3Fu)  <<  9)
         | ((d->h  & 0x7Fu)  << 15)
         | ((d->w  & 0x7Fu)  << 22);
}
/* HD_FLAGS: [0] type4  [1] slice  [2] relu */
uint32_t fuse_hd_flags_word(const fuse_hd_desc_t *d) {
    return (d->type4 ? 1u : 0u) | (d->slice ? 2u : 0u) | (d->relu ? 4u : 0u);
}
uint32_t fuse_hd_clamp_word(const fuse_hd_desc_t *d) {
    return ((uint32_t)(d->lo & 0xFFFF)) | ((uint32_t)(d->hi & 0xFFFF) << 16);
}
/* One 64-bit entry, two 32-bit words. half 0 = bias[31:0];
 * half 1 = {sh[31:26], m0[25:8], bias[39:32]}. */
void fuse_hd_rq_words(const fuse_hd_rq_t *e, uint32_t w[2]) {
    uint64_t b = (uint64_t)e->bias;
    w[0] = (uint32_t)(b & 0xFFFFFFFFu);
    w[1] = ((uint32_t)(e->sh & 0x3Fu) << 26)
         | (((uint32_t)e->m0 & 0x3FFFFu) << 8)
         |  (uint32_t)((b >> 32) & 0xFFu);
}
/* address bits [9:8] operator, [7:3] oc, [2] half */
uint32_t fuse_hd_rq_off(int op, int oc, int half) {
    return (uint32_t)H_RQ_BASE + ((uint32_t)(op & 3) << 8)
                               + ((uint32_t)(oc & 31) << 3)
                               + ((uint32_t)(half & 1) << 2);
}

int fuse_hd_desc_check(const fuse_hd_desc_t *d, int op, char *why, size_t n) {
#define BAD(...) do { if (why && n) snprintf(why, n, __VA_ARGS__); return -1; } while (0)
    if (op < 0 || op >= FUSE_HD_NOPS)      BAD("operator index %d is not 0..3", op);
    if (d->ic  > 0x1FF)                    BAD("IC=%u does not fit HD_SHAPE's 9 bits", d->ic);
    if (d->oc  > 0x3F)                     BAD("OC=%u does not fit HD_SHAPE's 6 bits", d->oc);
    if (d->h   > 0x7F || d->w > 0x7F)      BAD("H=%u W=%u do not fit HD_SHAPE's 7 bits", d->h, d->w);
    if (d->in_beats  > 0xFFFFFF ||
        d->w_beats   > 0xFFFFFF ||
        d->out_beats > 0xFFFFFF)           BAD("a beat count does not fit 24 bits");
    if (d->lo < -32768 || d->lo > 32767 ||
        d->hi < -32768 || d->hi > 32767)   BAD("clamp %d..%d does not fit signed 16", d->lo, d->hi);
    if (d->in_base >> 40 || d->w_base >> 40 || d->out_base >> 40)
                                           BAD("a base address exceeds 40 bits");
    /* the bases feed AXI movers that transfer 128-bit beats */
    if ((d->in_base | d->w_base | d->out_base) & 0xF)
                                           BAD("a base address is not 16-byte aligned");

    /* type 4: the engine emits OC[5:2] beats, so OC must be a multiple of 4 */
    if (d->type4 && (d->oc & 3))
        BAD("type 4 with OC=%u: twn_hd_compute emits OC[5:2] beats, so OC=%u emits "
            "%u channels and the rest vanish in silence. op64 must declare OC=16, "
            "not the model's 14.", d->oc, d->oc, d->oc & ~3u);

    /* in_beats is per pass: the input is re-read once per (phase, ocg) slice
     * and the sequencer re-issues the reader each time */
    if ((uint64_t)d->in_beats * 16u != (uint64_t)d->h * d->w * d->ic)
        BAD("in_beats=%u but H*W*IC/16 = %llu. in_beats is ONE PASS, not the "
            "sixteen mode A performs.", d->in_beats,
            (unsigned long long)((uint64_t)d->h * d->w * d->ic / 16u));

    /* mode A's whole-output buffer limit */
    if (!d->type4 && d->slice && (4u * d->h * d->w * d->oc) > 8192u)
        BAD("mode A with H=%u W=%u OC=%u needs %u bytes; the whole-output buffer "
            "is 1024 x 64 bits = 8192", d->h, d->w, d->oc, 4u * d->h * d->w * d->oc);

    /* out_beats must match the output size the geometry implies */
    {
        uint64_t want = d->type4 ? ((uint64_t)d->h * d->w * d->oc * 4u) / 16u
                                 : ((uint64_t)(2 * d->h) * (2 * d->w) * d->oc) / 16u;
        if ((uint64_t)d->out_beats != want)
            BAD("out_beats=%u but the geometry implies %llu", d->out_beats,
                (unsigned long long)want);
    }
    return 0;
#undef BAD
}

/* ---- twelve fields then the commit, in tb_hd_int.v's order (hd_desc()) ---- */
int fuse_hd_commit(const fuse_hd_desc_t *d, int op) {
    char why[256];
    if (fuse_hd_desc_check(d, op, why, sizeof why) != 0) {
        fprintf(stderr, "fuse_hd: REFUSING op%d's descriptor -- %s\n", 61 + op, why);
        return -1;
    }
    wr(H_IN_LO,      (uint32_t)d->in_base);
    wr(H_IN_HI,      (uint32_t)(d->in_base >> 32) & 0xFFu);
    wr(H_W_LO,       (uint32_t)d->w_base);
    wr(H_W_HI,       (uint32_t)(d->w_base >> 32) & 0xFFu);
    wr(H_OUT_LO,     (uint32_t)d->out_base);
    wr(H_OUT_HI,     (uint32_t)(d->out_base >> 32) & 0xFFu);
    wr(H_IN_BEATS,   d->in_beats);
    wr(H_W_BEATS,    d->w_beats);
    wr(H_OUT_BEATS,  d->out_beats);
    wr(H_SHAPE,      fuse_hd_shape_word(d));
    wr(H_FLAGS,      fuse_hd_flags_word(d));
    wr(H_CLAMP,      fuse_hd_clamp_word(d));

    /* the staging registers drive twn_hd_seq directly; this write pulses the
     * commit, and twn_hd_seq latches the whole entry at once */
    wr(H_COMMIT, (uint32_t)(op & 3));

    /* The staging set can be read back (the committed entry cannot); this
     * catches a mis-decoded address. */
    {
        uint32_t sh = rd(H_SHAPE), ob = rd(H_OUT_BEATS);
        if (sh != fuse_hd_shape_word(d) || (ob & 0xFFFFFFu) != d->out_beats) {
            fprintf(stderr, "fuse_hd: op%d staging read-back disagrees -- "
                            "SHAPE %08x want %08x, OUT_BEATS %u want %u\n",
                    61 + op, sh, fuse_hd_shape_word(d), ob & 0xFFFFFFu, d->out_beats);
            return -1;
        }
    }
    return 0;
}

int fuse_hd_program(const fuse_hd_desc_t d[FUSE_HD_NOPS],
                    const fuse_hd_rq_t rq[FUSE_HD_NOPS][FUSE_HD_NRQ]) {
    uint32_t v;

    /* clear the requantisation evidence so this boot is counted on its own */
    wr(H_RQ_STAT, 0);

    for (int op = 0; op < FUSE_HD_NOPS; op++)
        for (int c = 0; c < FUSE_HD_NRQ; c++) {
            const fuse_hd_rq_t *e = &rq[op][c];
            uint32_t w[2];
            /* the store carries 18 / 40 / 6 bits; refuse values that do not fit */
            if (e->m0 < -(1 << 17) || e->m0 >= (1 << 17)) {
                fprintf(stderr, "fuse_hd: op%d oc%d m0=%d does not fit signed 18\n",
                        61 + op, c, e->m0); return -1; }
            if (e->bias < -((int64_t)1 << 39) || e->bias >= ((int64_t)1 << 39)) {
                fprintf(stderr, "fuse_hd: op%d oc%d bias=%lld does not fit signed 40\n",
                        61 + op, c, (long long)e->bias); return -1; }
            if (e->sh > 63) {
                fprintf(stderr, "fuse_hd: op%d oc%d shift=%u does not fit 6 bits\n",
                        61 + op, c, e->sh); return -1; }
            fuse_hd_rq_words(e, w);
            wr(fuse_hd_rq_off(op, c, 0), w[0]);
            wr(fuse_hd_rq_off(op, c, 1), w[1]);
        }

    for (int op = 0; op < FUSE_HD_NOPS; op++)
        if (fuse_hd_commit(&d[op], op) != 0) return -1;

    /* ---- sticky evidence that the writes landed ---- */
    v = rd(H_COMMIT);
    if (((v >> 4) & 0xF) != 0xF) {
        fprintf(stderr, "fuse_hd: HD_COMMIT reads %08x -- sticky mask %x, not 0xF. "
                        "Not all four descriptors landed; an uncommitted operator "
                        "runs on all-zero geometry.\n", v, (v >> 4) & 0xF);
        return -1;
    }
    v = rd(H_RQ_STAT);
    if (v != HRQ_STAT_FULL) {
        fprintf(stderr, "fuse_hd: HD_RQ_STAT reads %08x, want %08x -- %u words "
                        "written (want 256), operator mask %x (want F). The table "
                        "the head is about to use is partly somebody else's.\n",
                v, HRQ_STAT_FULL, (v >> 4) & 0x1FF, v & 0xF);
        return -1;
    }
    fprintf(stderr, "fuse_hd: four descriptors committed (HD_COMMIT %08x), "
                    "256 requant words (HD_RQ_STAT %08x)\n", rd(H_COMMIT), v);
    return 0;
}

void fuse_hd_read_status(uint32_t *ctrl, uint32_t *commit, uint32_t *rq_stat) {
    if (ctrl)    *ctrl    = rd(H_CTRL);
    if (commit)  *commit  = rd(H_COMMIT);
    if (rq_stat) *rq_stat = rd(H_RQ_STAT);
}

int fuse_hd_start(void) {
    uint32_t c = rd(H_CTRL);
    if (c & HC_BUSY) {
        /* a start written while busy is dropped, not queued */
        fprintf(stderr, "fuse_hd: start refused, the head is still busy "
                        "(HD_CTRL %08x)\n", c);
        return -1;
    }
    /* arena stores (the staged boundary) must complete before the head reads */
    fuse_wmb();
    wr(H_CTRL, HC_START);       /* a start also clears done */
    return 0;
}

int fuse_hd_wait(int yield_wait, uint64_t *ns) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        uint32_t c = rd(H_CTRL);
        if (c & HC_DONE) break;                 /* bit 2, both sides */
        if (yield_wait) {
            struct timespec ts = { 0, 50000 };  /* 50 us, as fuse_run_frame */
            nanosleep(&ts, NULL);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double el = (t1.tv_sec - t0.tv_sec) + 1e-9 * (t1.tv_nsec - t0.tv_nsec);
        if (el > 3.0) {
            uint32_t cm = rd(H_COMMIT), rs = rd(H_RQ_STAT);
            fprintf(stderr,
                "fuse_hd: the head did not finish in 3 s -- HD_CTRL %08x "
                "(start-pending %u, busy %u, done %u) HD_COMMIT %08x HD_RQ_STAT %08x\n",
                c, c & 1u, (c >> 1) & 1u, (c >> 2) & 1u, cm, rs);
            if (!(c & (HC_BUSY | HC_DONE)) && (c & HC_START))
                fprintf(stderr,
                    "  the start is STILL PENDING and the engine never went busy. "
                    "That is what a bitstream built WITHOUT FUSE_HD_PROBE=1 looks "
                    "like from here: twn_csr is outside the generate, so every "
                    "descriptor write and both sticky registers read back "
                    "perfectly while no head exists to take the start.\n");
            if (ns) *ns = 0;
            return -1;
        }
    }
    wr(H_CTRL, HC_DONE);                        /* clear it, same bit */
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (ns) *ns = (uint64_t)((t1.tv_sec - t0.tv_sec) * 1000000000ull
                             + (t1.tv_nsec - t0.tv_nsec));
    return 0;
}

/* ---- BB2HD ---- */
static int g_bb2hd_state = -1;          /* -1: not written yet in this process */

int fuse_bb2hd_probe(void) {
    wr(F_BB2HD, FUSE_BB2HD_EN);
    int has = (rd(F_BB2HD) & FUSE_BB2HD_EN) != 0;
    wr(F_BB2HD, 0);
    g_bb2hd_state = 0;
    return has;
}

void fuse_bb2hd_set(int en) {
    en = en ? 1 : 0;
    if (en == g_bb2hd_state) return;
    wr(F_BB2HD, en ? FUSE_BB2HD_EN : 0);
    g_bb2hd_state = en;
}

void fuse_bb2hd_restart(void) {
    /* enable, clear the parity (bit 1), clear the collision flag (bit 3) */
    wr(F_BB2HD, FUSE_BB2HD_EN | FUSE_BB2HD_PAR | FUSE_BB2HD_COLL);
    g_bb2hd_state = 1;
}

uint32_t fuse_bb2hd_read(void) { return rd(F_BB2HD); }

void fuse_print_counters(const fuse_counters_t *c, double clk_mhz) {
    double t = c->total ? (double)c->total : 1.0;
    fprintf(stderr,
        "  backbone %u cycles = %.3f ms @ %.3f MHz\n"
        "    array busy   %9u  %5.1f%%   (gate: >= 90%%)\n"
        "    depthwise    %9u  %5.1f%%\n"
        "    memory stall %9u  %5.1f%%   (gate: <  10%%)\n"
        "    idle before  %9u  %5.1f%%\n"
        "    idle after   %9u  %5.1f%%\n",
        c->total, c->total / (clk_mhz * 1000.0), clk_mhz,
        c->array,     100.0 * c->array     / t,
        c->dw,        100.0 * c->dw        / t,
        c->stall_mem, 100.0 * c->stall_mem / t,
        c->idle_pre,  100.0 * c->idle_pre  / t,
        c->idle_post, 100.0 * c->idle_post / t);
}
