/* ============================================================================
 *  pl_hal_zynq.c -- board implementation of pl_hal.h (UIO + reserved memory)
 *  for the 65-operator accelerator on Zynq UltraScale+ (AXU2CGB). Cross build
 *  only.
 *
 *   - control: the accelerator's AXI-Lite window is a UIO device
 *              (generic-uio); /dev/uioN map 0 is mmapped and the R_* register
 *              offsets below are written. They follow the HLS-generated driver
 *              header xmbv2_layer_hw.h and must be kept in sync with the IP.
 *   - arena:   the PL m_axi masters read/write a contiguous reserved-memory
 *              region by physical address, mmapped through /dev/mem (O_SYNC).
 *              The device tree must reserve it with `no-map` so it is uncached
 *              and outside the kernel's cached linear map (the PL HP ports are
 *              not cache-coherent); no cache maintenance is then needed.
 *
 *  Environment: PL_UIO (default: the UIO named "mbv2_layer" or "twn_top"),
 *  PL_ARENA_PA (hex), PL_ARENA_SZ (hex), PL_YIELD_US, PL_PREDICT,
 *  PL_TIMEOUT_MS.
 * ========================================================================== */
#include "pl_hal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sched.h>
#include <time.h>
#include <stdint.h>
#include <sys/mman.h>

/* ---- AXI-Lite register offsets (from the generated xmbv2_layer_hw.h) ---- */
#define R_AP_CTRL 0x00
#define R_TYPE 0x10
#define R_IC 0x18
#define R_H 0x20
#define R_W 0x28
#define R_OC 0x30
#define R_KH 0x38
#define R_STRIDE 0x40
#define R_PAD 0x48
#define R_W2OFF 0x50
#define R_W8OFF 0x58
#define R_RQOFF 0x60
#define R_RELU 0x68
#define R_LO 0x70
#define R_HI 0x78
#define R_MP 0x80
#define R_MQ 0x88
#define R_SHV 0x90
#define R_IN 0x98      /* +0x9c high */
#define R_IN2 0xa4     /* +0xa8 */
#define R_OUT 0xb0     /* +0xb4 */
#define R_W2 0xbc      /* +0xc0 */
#define R_W8 0xc8      /* +0xcc */
#define R_M0 0xd4      /* +0xd8 */
#define R_BIAS 0xe0    /* +0xe4 */
#define R_SH 0xec      /* +0xf0 */
#define R_W8FMT 0xf8   /* S2a per-tensor int8 flags (A_W8FMT) */

#define ARENA_PA_DEFAULT  0x60000000ULL
#define ARENA_SZ_DEFAULT  0x10000000ULL     /* 256 MB */
#define CTRL_MAP_SZ       0x1000

static volatile uint32_t *g_ctrl;           /* UIO-mapped AXI-Lite window */
static uint8_t  *g_arena_v;
static uint64_t  g_arena_pa, g_arena_sz;
static int       g_pl_yield = 0;     /* 0=busy-poll (min latency); 1=sleep-poll (pipeline mode) */
void pl_set_wait_yield(int on) { g_pl_yield = on; }

static inline void wr(int off, uint32_t v) { g_ctrl[off >> 2] = v; }
static inline uint32_t rd(int off) { return g_ctrl[off >> 2]; }
static inline void wr64(int off, uint64_t v) { wr(off, (uint32_t)v); wr(off + 4, (uint32_t)(v >> 32)); }

/* Find /dev/uioN whose /sys/class/uio/uioN/name matches `want` (e.g. "mbv2_layer").
   Other UIO nodes (e.g. axi-pmon) may precede the accelerator, so uio0 is not
   assumed. Returns 0 and fills `out` on success. */
static int find_uio_by_name(const char *want, char *out, size_t outsz) {
    for (int i = 0; i < 32; i++) {
        char p[64]; snprintf(p, sizeof p, "/sys/class/uio/uio%d/name", i);
        FILE *f = fopen(p, "r"); if (!f) continue;
        char nm[64] = {0};
        char *g = fgets(nm, sizeof nm, f); fclose(f);
        if (!g) continue;
        nm[strcspn(nm, "\r\n")] = 0;
        if (strcmp(nm, want) == 0) { snprintf(out, outsz, "/dev/uio%d", i); return 0; }
    }
    return -1;
}

void pl_hal_init(void) {
    char path[64];
    const char *uio = getenv("PL_UIO");
    if (!uio) {
        /* the device-tree node may be named after the BD cell ("mbv2_layer") or
         * the packaged IP ("twn_top"); accept both */
        if      (find_uio_by_name("twn_fuse",   path, sizeof path) == 0) uio = path;  /* DT node of the fused design */
        else if (find_uio_by_name("fuse_0",     path, sizeof path) == 0) uio = path;  /* its BD cell name */
        else if (find_uio_by_name("mbv2_layer", path, sizeof path) == 0) uio = path;
        else if (find_uio_by_name("twn_top",    path, sizeof path) == 0) uio = path;
        else { fprintf(stderr, "pl_hal: no UIO named 'mbv2_layer'/'twn_top'; falling back to /dev/uio0\n"); uio = "/dev/uio0"; }
    }
    fprintf(stderr, "pl_hal: control UIO = %s\n", uio);
    int fd = open(uio, O_RDWR | O_SYNC);
    if (fd < 0) { perror("open uio"); exit(1); }
    g_ctrl = (volatile uint32_t *)mmap(NULL, CTRL_MAP_SZ, PROT_READ | PROT_WRITE,
                                       MAP_SHARED, fd, 0);
    if (g_ctrl == MAP_FAILED) { perror("mmap uio"); exit(1); }
    close(fd);
}

void *pl_arena_init(uint64_t *phys, uint64_t size) {
    const char *pas = getenv("PL_ARENA_PA"), *szs = getenv("PL_ARENA_SZ");
    g_arena_pa = pas ? strtoull(pas, 0, 16) : ARENA_PA_DEFAULT;
    g_arena_sz = szs ? strtoull(szs, 0, 16) : ARENA_SZ_DEFAULT;
    if (size > g_arena_sz) { fprintf(stderr, "arena too small: need %llu have %llu\n",
                                     (unsigned long long)size, (unsigned long long)g_arena_sz); exit(1); }
    if (!g_ctrl) pl_hal_init();
    int fd = open("/dev/mem", O_RDWR | O_SYNC);   /* O_SYNC -> uncached device mapping */
    if (fd < 0) { perror("open /dev/mem"); exit(1); }
    g_arena_v = (uint8_t *)mmap(NULL, g_arena_sz, PROT_READ | PROT_WRITE, MAP_SHARED,
                                fd, (off_t)g_arena_pa);
    if (g_arena_v == MAP_FAILED) { perror("mmap /dev/mem arena"); exit(1); }
    close(fd);
    *phys = g_arena_pa;
    return g_arena_v;
}

uint64_t pl_run_layer(const pl_desc_t *d) {
    wr(R_TYPE, d->type); wr(R_IC, d->ic); wr(R_H, d->h); wr(R_W, d->w);
    wr(R_OC, d->oc); wr(R_KH, d->kh); wr(R_STRIDE, d->stride); wr(R_PAD, d->pad);
    wr(R_W2OFF, d->w2_off); wr(R_W8OFF, d->w8_off); wr(R_RQOFF, d->rq_off);
    wr(R_RELU, d->relu); wr(R_LO, d->lo); wr(R_HI, d->hi);
    wr(R_MP, d->mp); wr(R_MQ, d->mq); wr(R_SHV, d->sh); wr(R_W8FMT, d->w8fmt);
    wr64(R_IN, d->in_pa); wr64(R_IN2, d->in2_pa); wr64(R_OUT, d->out_pa);
    wr64(R_W2, d->w2_pa); wr64(R_W8, d->w8_pa);
    wr64(R_M0, d->m0_pa); wr64(R_BIAS, d->bias_pa); wr64(R_SH, d->sh_pa);

    wr(R_AP_CTRL, 0x1);                          /* ap_start */
    if (g_pl_yield) {
        /* pipeline mode: yield this thread's core to the head worker during PL
         * compute. PL_YIELD_US=0 uses sched_yield, which busy-spins if the head
         * never blocks. */
        static int us = -2, predict = -2;
        if (us == -2) { const char *e = getenv("PL_YIELD_US"); us = e ? atoi(e) : 40; }
        if (predict == -2) { const char *e = getenv("PL_PREDICT"); predict = e ? atoi(e) : 0; }  /* default off */
        /* PL_YIELD_US: sleep-poll period in microseconds (default 40; 0 uses
         * sched_yield). PL_PREDICT=1 enables the predictive sleep below. */
        if (predict) {
            /* PL_PREDICT=1: per-op durations are quasi-static, so sleep about
             * 7/8 of the learned duration in one nanosleep and then fine-poll
             * every 5 us. Keyed by op (rq_off, type, h); an EMA (3/4 old) tracks
             * the in-pipeline time. Under-sleeping is safe because of the poll
             * tail. */
            static int64_t ema[128];
            struct timespec t0, t1;
            unsigned idx = ((d->rq_off >> 2) ^ ((unsigned)d->type << 5) ^ (d->h)) & 127u;
            clock_gettime(CLOCK_MONOTONIC, &t0);
            int64_t est = ema[idx];
            if (est > 400000) {                       /* only ops > 0.4 ms are worth a sleep */
                int64_t ns = (est - (est >> 3)) - 100000;   /* 7/8 of EMA, wake >=100 us early */
                struct timespec ts = { (time_t)(ns / 1000000000LL), (long)(ns % 1000000000LL) };
                nanosleep(&ts, NULL);
            }
            while (!(rd(R_AP_CTRL) & 0x2)) usleep(5);
            clock_gettime(CLOCK_MONOTONIC, &t1);
            int64_t el = (int64_t)(t1.tv_sec - t0.tv_sec) * 1000000000LL
                       + (t1.tv_nsec - t0.tv_nsec);
            ema[idx] = ema[idx] ? ((ema[idx] * 3 + el) >> 2) : el;
        }
        else if (us <= 0) { while (!(rd(R_AP_CTRL) & 0x2)) sched_yield(); }
        else              { while (!(rd(R_AP_CTRL) & 0x2)) usleep(us); }
    } else {
        /* minimum-latency busy-poll (sequential path) with a watchdog: a PL
         * that never raises ap_done would otherwise spin forever holding the
         * accelerator. PL_TIMEOUT_MS=0 restores the infinite poll. */
        static int tmo_ms = -1;
        if (tmo_ms < 0) { const char *e = getenv("PL_TIMEOUT_MS"); tmo_ms = e ? atoi(e) : 3000; }
        if (tmo_ms == 0) { while (!(rd(R_AP_CTRL) & 0x2)) { } }
        else {
            struct timespec ta, tb;
            clock_gettime(CLOCK_MONOTONIC, &ta);
            while (!(rd(R_AP_CTRL) & 0x2)) {
                clock_gettime(CLOCK_MONOTONIC, &tb);
                long ms = (tb.tv_sec - ta.tv_sec) * 1000L + (tb.tv_nsec - ta.tv_nsec) / 1000000L;
                if (ms > tmo_ms) {
                    fprintf(stderr, "FATAL: PL never asserted done after %ld ms -- type=%d ic=%d oc=%d %dx%d%c",
                            ms, d->type, d->ic, d->oc, d->h, d->w, 10);
                    fprintf(stderr, "  (the accelerator is left BUSY; reboot the board before the next run)%c", 10);
                    exit(2);
                }
            }
        }
    }
    return 0;                                    /* PL cycle counter: add a counter reg later */
}

void pl_hal_close(void) {
    if (g_ctrl) munmap((void *)g_ctrl, CTRL_MAP_SZ);
    if (g_arena_v) munmap(g_arena_v, g_arena_sz);
}
