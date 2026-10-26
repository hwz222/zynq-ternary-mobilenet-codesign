/* mbv2_pose.c -- integer-only inference engine, golden C model of the pose network
 * (MobileNetV2 backbone, 3 stride-2 deconvs, final 1x1 conv, 14 joints).
 *
 *   - op program: OPS[] / RQ_* tables from model_meta.c, weights from a blob file
 *   - conv ops (type 0): int8 weights, zero weights skipped (ternary layers)
 *   - depthwise (type 1), deconv (type 2), final 1x1 (type 4): int8 weights
 *   - activations are held in int16 buffers; int32 accumulators
 *   - requant per output channel: clamp(rshift(M0*acc + bias, sh), lo, hi)
 * Env knobs read here: HEAD_THREADS, HEAD_PIN, HEAD_SPIN_US, HEAD_FUSE,
 * HEAD_SUBPIX_MAXIC, OP_TIMING, TWN_DUMP_OPS (see the code that reads each). */
/* Exposes CPU_ZERO/CPU_SET/sched_setaffinity (used by pin_to). */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "mbv2_pose.h"
#include "model_meta.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#ifdef __linux__
#include <time.h>
static double _opnow(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1e3+t.tv_nsec/1e6; }
#else
static double _opnow(void){ return 0; }
#endif

#define NBUF 4
static int16_t g_buf[NBUF][MAXACT];
static int32_t g_acc[MAXACT];
static int g_C[NBUF], g_H[NBUF], g_W[NBUF];

static inline int32_t rshift_round(int64_t t, int s) {
    if (s <= 0) return (int32_t)t;
    int64_t half = (int64_t)1 << (s - 1);
    return (int32_t)((t + half) >> s);
}

/* ---- output-channel thread pool (Linux only) ----
 * The head kernels split an output loop whose iterations write disjoint slices,
 * so the result does not depend on the thread count. Workers are spawned once on
 * first use and woken per call. Non-Linux builds call the kernel inline.
 * Env: HEAD_THREADS (1 = scalar), HEAD_PIN=0 (no cpu pinning), HEAD_SPIN_US. */
typedef void (*oc_fn)(void *ctx, int oc0, int oc1);

#ifdef __linux__
#include <pthread.h>
#include <sched.h>

/* g_nthreads-1 persistent workers plus the caller. parallel_oc() splits [0,OC) into
   g_nthreads contiguous chunks.
   wk_oc0, wk_oc1 and wk_pending are each aligned to 64 bytes so the ranges the workers
   read do not share a cache line with the control words written on every call. Keep WK_LINE. */
#define WK_MAX 3                          /* max workers (threads = workers + caller) */
static pthread_t       wk_thread[WK_MAX];
static pthread_mutex_t wk_mtx  = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  wk_go   = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  wk_done = PTHREAD_COND_INITIALIZER;
static oc_fn           wk_fn;
static void           *wk_ctx;
#define WK_LINE __attribute__((aligned(64)))
static int             wk_oc0[WK_MAX] WK_LINE;   /* read by workers; keep off the control line */
static int             wk_oc1[WK_MAX] WK_LINE;
WK_LINE
static unsigned        wk_pending  = 0;   /* bitmask: work posted, worker i hasn't taken it */
static int             wk_running  = 0;   /* workers still executing this call              */
static int             wk_sleepers = 0;   /* workers inside cond_wait (under wk_mtx)        */
static int             wk_joinslp  = 0;   /* caller is (about to be) inside cond_wait       */
static int             wk_spawned  = 0;
/* Bounded spin (g_spin_us, scaled in the loops below) before sleeping on the condvar.
   HEAD_SPIN_US=0 uses the condvar only. */
static int             g_spin_us   = 200;
static int             g_pin       = 1;   /* pin worker i -> cpu i+1, caller -> cpu0        */
static int             g_nthreads  = 4;   /* threads incl. caller, clamped to WK_MAX+1; 1 => scalar */

static void pin_to(int cpu) {
    cpu_set_t s; CPU_ZERO(&s); CPU_SET(cpu, &s);
    sched_setaffinity(0, sizeof(s), &s);
}

static void *wk_main(void *arg) {
    int id = (int)(long)arg;
    if (g_pin) pin_to(id + 1);
    for (;;) {
        /* fast path: bounded spin for new work (release-store of wk_pending publishes fn/ranges) */
        int got = 0;
        for (int s = 0; s < g_spin_us * 20; s++) {          /* spin budget scales with g_spin_us */
            if (__atomic_load_n(&wk_pending, __ATOMIC_ACQUIRE) & (1u << id)) { got = 1; break; }
            __asm__ __volatile__("yield");
        }
        if (!got) {                                          /* slow path: futex sleep */
            pthread_mutex_lock(&wk_mtx);
            wk_sleepers++;
            while (!(wk_pending & (1u << id))) pthread_cond_wait(&wk_go, &wk_mtx);
            wk_sleepers--;
            pthread_mutex_unlock(&wk_mtx);
        }
        oc_fn fn = wk_fn; void *ctx = wk_ctx; int a = wk_oc0[id], b = wk_oc1[id];
        __atomic_and_fetch(&wk_pending, ~(1u << id), __ATOMIC_ACQ_REL);
        if (a < b) fn(ctx, a, b);
        if (__atomic_sub_fetch(&wk_running, 1, __ATOMIC_ACQ_REL) == 0) {
            /* last worker takes the mutex for the caller-asleep check: the caller sets
             * wk_joinslp under the same mutex, so no wake is missed. */
            pthread_mutex_lock(&wk_mtx);
            if (wk_joinslp) pthread_cond_signal(&wk_done);
            pthread_mutex_unlock(&wk_mtx);
        }
    }
    return NULL;
}

static void pool_lazy_init(void) {
    if (wk_spawned) return;
    char *e;
    if ((e = getenv("HEAD_THREADS"))) g_nthreads = atoi(e);
    if ((e = getenv("HEAD_PIN")))     g_pin      = atoi(e);
    if ((e = getenv("HEAD_SPIN_US"))) g_spin_us  = atoi(e);
    if (g_nthreads < 1) g_nthreads = 1;
    if (g_nthreads > WK_MAX + 1) g_nthreads = WK_MAX + 1;
    for (int i = 0; i < g_nthreads - 1; i++)
        if (pthread_create(&wk_thread[i], NULL, wk_main, (void *)(long)i) != 0) {
            g_nthreads = i + 1; break;
        }
    if (g_nthreads >= 2 && g_pin) pin_to(0);   /* caller -> cpu0 */
    wk_spawned = 1;
}

/* Run fn over [0,OC): g_nthreads chunks, workers take the low ones, the caller the last,
   then wait. Runs inline if fewer than 2 threads or OC < 2. */
static void parallel_oc(oc_fn fn, void *ctx, int OC) {
    pool_lazy_init();
    int nt = g_nthreads;
    if (nt > OC) nt = OC;
    if (nt < 2) { fn(ctx, 0, OC); return; }
    int nw = nt - 1;                              /* workers used this call */
    int chunk = OC / nt, rem = OC % nt, pos = 0;
    wk_fn = fn; wk_ctx = ctx;
    for (int i = 0; i < nw; i++) {
        int len = chunk + (i < rem ? 1 : 0);
        wk_oc0[i] = pos; wk_oc1[i] = pos + len; pos += len;
    }
    /* publish under the mutex: sleeping workers re-check wk_pending under the same mutex,
     * so the broadcast can be skipped when nobody sleeps. Spinning workers see the
     * release-store. */
    pthread_mutex_lock(&wk_mtx);
    __atomic_store_n(&wk_running, nw, __ATOMIC_RELAXED);
    __atomic_store_n(&wk_pending, (1u << nw) - 1u, __ATOMIC_RELEASE);  /* publishes fn/ranges */
    if (wk_sleepers) pthread_cond_broadcast(&wk_go);
    pthread_mutex_unlock(&wk_mtx);
    fn(ctx, pos, OC);                             /* caller does the last chunk */
    /* join: bounded spin, then condvar */
    int joined = 0;
    for (int s = 0; s < g_spin_us * 20; s++) {
        if (__atomic_load_n(&wk_running, __ATOMIC_ACQUIRE) == 0) { joined = 1; break; }
        __asm__ __volatile__("yield");
    }
    if (!joined) {
        pthread_mutex_lock(&wk_mtx);
        wk_joinslp = 1;
        while (__atomic_load_n(&wk_running, __ATOMIC_ACQUIRE) != 0)
            pthread_cond_wait(&wk_done, &wk_mtx);
        wk_joinslp = 0;
        pthread_mutex_unlock(&wk_mtx);
    }
}
#else
/* Non-Linux build: run the range inline. */
static void parallel_oc(oc_fn fn, void *ctx, int OC) { fn(ctx, 0, OC); }
#endif

/* regular conv: w[oc][ic][kh][kw]; zero weights (ternary layers) are skipped.
   The oc loop is split across threads (each oc writes a disjoint acc slice). */
typedef struct {
    const int8_t *w; const int16_t *x;
    int IC, H, W, OC, KH, KW, stride, pad, OH, OW;
    int32_t *acc;
} conv_ctx;

/* Fast path for 1x1 stride-1: channel GEMV with a contiguous inner loop over the HW plane.
   out[oc][p] = sum_ic w[oc][ic]*x[ic][p]. Same integer sum as the general path. */
static void conv2d_1x1_range(void *ctx, int oc0, int oc1) {
    conv_ctx *c = (conv_ctx *)ctx;
    int HW = c->H * c->W, IC = c->IC;
    for (int oc = oc0; oc < oc1; oc++) {
        int32_t *ap = c->acc + (size_t)oc * HW;
        memset(ap, 0, sizeof(int32_t) * (size_t)HW);
        const int8_t *wo = c->w + (size_t)oc * IC;
        for (int ic = 0; ic < IC; ic++) {
            int wv = wo[ic];
            if (!wv) continue;
            const int16_t *xr = c->x + (size_t)ic * HW;
            for (int p = 0; p < HW; p++) ap[p] += (int32_t)wv * (int32_t)xr[p];
        }
    }
}

static void conv2d_gen_range(void *ctx, int oc0, int oc1) {
    conv_ctx *c = (conv_ctx *)ctx;
    int IC = c->IC, H = c->H, W = c->W, KH = c->KH, KW = c->KW;
    int OH = c->OH, OW = c->OW, stride = c->stride, pad = c->pad;
    for (int oc = oc0; oc < oc1; oc++)
        for (int oy = 0; oy < OH; oy++)
            for (int ox = 0; ox < OW; ox++) {
                int32_t s = 0;
                for (int ic = 0; ic < IC; ic++) {
                    const int8_t  *wr = c->w + ((oc * IC + ic) * KH) * KW;
                    const int16_t *xc = c->x + ic * H * W;
                    for (int ky = 0; ky < KH; ky++) {
                        int iy = oy * stride - pad + ky;
                        if (iy < 0 || iy >= H) continue;
                        for (int kx = 0; kx < KW; kx++) {
                            int ix = ox * stride - pad + kx;
                            if (ix < 0 || ix >= W) continue;
                            int8_t wv = wr[ky * KW + kx];   /* zero weights skipped */
                            if (wv) s += (int32_t)wv * (int32_t)xc[iy * W + ix];
                        }
                    }
                }
                c->acc[(oc * OH + oy) * OW + ox] = s;
            }
}

static void conv2d(const int8_t *w, const int16_t *x, int IC, int H, int W,
                   int OC, int KH, int KW, int stride, int pad,
                   int32_t *acc, int *OHp, int *OWp) {
    int OH = (H + 2 * pad - KH) / stride + 1;
    int OW = (W + 2 * pad - KW) / stride + 1;
    conv_ctx c = { w, x, IC, H, W, OC, KH, KW, stride, pad, OH, OW, acc };
    if (KH == 1 && KW == 1 && stride == 1 && pad == 0)
        parallel_oc(conv2d_1x1_range, &c, OC);
    else
        parallel_oc(conv2d_gen_range, &c, OC);
    *OHp = OH; *OWp = OW;
}

/* depthwise conv: w[c][kh][kw] (INT8), one input channel per output channel */
static void dwconv2d(const int8_t *w, const int16_t *x, int C, int H, int W,
                     int KH, int KW, int stride, int pad,
                     int32_t *acc, int *OHp, int *OWp) {
    int OH = (H + 2 * pad - KH) / stride + 1;
    int OW = (W + 2 * pad - KW) / stride + 1;
    for (int c = 0; c < C; c++) {
        const int8_t  *wc = w + c * KH * KW;
        const int16_t *xc = x + c * H * W;
        int32_t *ac = acc + c * OH * OW;
        for (int oy = 0; oy < OH; oy++)
            for (int ox = 0; ox < OW; ox++) {
                int32_t s = 0;
                for (int ky = 0; ky < KH; ky++) {
                    int iy = oy * stride - pad + ky;
                    if (iy < 0 || iy >= H) continue;
                    for (int kx = 0; kx < KW; kx++) {
                        int ix = ox * stride - pad + kx;
                        if (ix < 0 || ix >= W) continue;
                        s += (int32_t)wc[ky * KW + kx] * (int32_t)xc[iy * W + ix];
                    }
                }
                ac[oy * OW + ox] = s;
            }
    }
    *OHp = OH; *OWp = OW;
}

/* transposed conv (gather form): w[ic][oc][kh][kw] (int8).
   The input is transposed to channel-last and the per-oc weights are rearranged so the ic
   reduction is a contiguous dot product. oc ranges are split across threads; each thread
   builds its own `wt`, the shared transposed input `xt` is read-only. */
typedef struct {
    const int8_t *w; const int16_t *xt;   /* xt[(iy*W+ix)*IC + ic], shared read-only */
    int IC, OC, KH, KW, stride, pad, H, W, OH, OW;
    int32_t *acc;
    /* fused requant (out != NULL): requant each acc value in a register and store int16,
       the int32 acc plane is not written. Same math as the separate requant() pass. */
    int16_t *out; int rq_off, relu, lo, hi;
} deconv_ctx;

static void deconv_oc_range(void *ctx, int oc0, int oc1) {
    deconv_ctx *c = (deconv_ctx *)ctx;
    int IC = c->IC, KH = c->KH, KW = c->KW, H = c->H, W = c->W;
    int OH = c->OH, OW = c->OW, stride = c->stride, pad = c->pad;
    int sw = c->OC * KH * KW;
    const int16_t *xt = c->xt;
    int8_t wt[8192];                        /* thread-local per-oc weights */
    for (int oc = oc0; oc < oc1; oc++) {
        for (int kk = 0; kk < KH * KW; kk++) {
            const int8_t *ws = c->w + oc * KH * KW + kk;
            int8_t *wd = wt + kk * IC;
            for (int ic = 0; ic < IC; ic++) wd[ic] = ws[(size_t)ic * sw];
        }
        int32_t *ap = c->out ? NULL : c->acc + (size_t)oc * OH * OW;
        int16_t *op16 = c->out ? c->out + (size_t)oc * OH * OW : NULL;
        int32_t rqM = 0; int64_t rqB = 0; int rqS = 0;
        if (c->out) { rqM = RQ_M0[c->rq_off + oc]; rqB = RQ_BIAS[c->rq_off + oc]; rqS = RQ_SH[c->rq_off + oc]; }
        /* Valid taps per output row/col are computed once; stride 2 uses shift/mask
         * instead of div/mod. Same tap set and accumulation order. */
        int s2 = (stride == 2);
        for (int oy = 0; oy < OH; oy++) {
            int nky = 0, kyv[8], iyv[8];        /* valid (ky, iy) for this output row */
            for (int ky = 0; ky < KH; ky++) {
                int iyn = oy + pad - ky; if (iyn < 0) continue;
                int iy = s2 ? (iyn >> 1) : (iyn / stride);
                if ((s2 ? (iyn & 1) : (iyn % stride)) || iy >= H) continue;
                kyv[nky] = ky; iyv[nky] = iy; nky++;
            }
            for (int ox = 0; ox < OW; ox++) {
                int nkx = 0, kxv[8], ixv[8];     /* valid (kx, ix) for this output col */
                for (int kx = 0; kx < KW; kx++) {
                    int ixn = ox + pad - kx; if (ixn < 0) continue;
                    int ix = s2 ? (ixn >> 1) : (ixn / stride);
                    if ((s2 ? (ixn & 1) : (ixn % stride)) || ix >= W) continue;
                    kxv[nkx] = kx; ixv[nkx] = ix; nkx++;
                }
                int32_t s = 0;
                for (int a = 0; a < nky; a++)
                    for (int b = 0; b < nkx; b++) {
                        const int8_t  *wr = wt + (kyv[a] * KW + kxv[b]) * IC;
                        const int16_t *xr = xt + (iyv[a] * W + ixv[b]) * IC;
                        for (int ic = 0; ic < IC; ic++) s += (int32_t)wr[ic] * (int32_t)xr[ic];
                    }
                if (op16) {                       /* fused requant: int32 acc stays in-register */
                    int64_t t = (int64_t)s * rqM + rqB;
                    int32_t r = rshift_round(t, rqS);
                    if (c->relu && r < 0) r = 0;
                    if (r < c->lo) r = c->lo;
                    if (r > c->hi) r = c->hi;
                    op16[oy * OW + ox] = (int16_t)r;
                } else
                    ap[oy * OW + ox] = s;
            }
        }
    }
}

static void conv_transpose2d(const int8_t *w, const int16_t *x, int IC, int H, int W,
                             int OC, int KH, int KW, int stride, int pad,
                             int32_t *acc, int *OHp, int *OWp) {
    int OH = (H - 1) * stride - 2 * pad + KH;
    int OW = (W - 1) * stride - 2 * pad + KW;
    int HW = H * W;
    static int16_t xt[65536];      /* xt[(iy*W+ix)*IC + ic] -- seeded once, then read-only */
    for (int ic = 0; ic < IC; ic++) {
        const int16_t *xc = x + (size_t)ic * HW;
        for (int p = 0; p < HW; p++) xt[p * IC + ic] = xc[p];
    }
    deconv_ctx c = { w, xt, IC, OC, KH, KW, stride, pad, H, W, OH, OW, acc,
                     NULL, 0, 0, 0, 0 };
    parallel_oc(deconv_oc_range, &c, OC);
    *OHp = OH; *OWp = OW;
}

/* ---- k4/s2/p1 subpixel-phase deconv + fused requant ----
 * An interior output pixel of a 4x4/stride-2/pad-1 deconv has exactly 2x2 valid taps,
 * selected by output parity: oy even -> ky in {1,3}, oy odd -> ky in {0,2} (same for x).
 * On border rows/columns one tap in that direction falls outside the input; the bounds
 * `continue` in the kernel skips it.
 * The kernel is pixel-major with an oc-contiguous inner loop over repacked int16 weights
 * wt[ky][kx][ic][oc]. int32 adds wrap and are associative, so accumulation order does not
 * change acc. */
typedef struct {
    const int16_t *wt;    /* repacked [ky][kx][ic][oc] int16 */
    const int16_t *xt;    /* input NHWC: xt[(iy*W+ix)*IC + ic] (contiguous IC per tap) */
    int IC, OC, H, W, OH, OW;
    int rq_off, relu, lo, hi;
    int16_t *out;
} dk4_ctx;

static void deconv_k4s2_rows(void *ctx, int oy0, int oy1) {
    dk4_ctx *c = (dk4_ctx *)ctx;
    int IC = c->IC, OC = c->OC, H = c->H, W = c->W, OW = c->OW;
    int32_t acc[1024];                       /* OC <= 1024 */
    for (int oy = oy0; oy < oy1; oy++) {
        int ky0 = (oy & 1) ? 0 : 1;          /* taps ky0, ky0+2 */
        int iyA = (oy + 1 - ky0) >> 1, iyB = iyA - 1;   /* iy for ky0 / ky0+2 */
        for (int ox = 0; ox < OW; ox++) {
            int kx0 = (ox & 1) ? 0 : 1;
            int ixA = (ox + 1 - kx0) >> 1, ixB = ixA - 1;
            for (int oc = 0; oc < OC; oc++) acc[oc] = 0;
            for (int t = 0; t < 4; t++) {
                int ky = ky0 + ((t >> 1) << 1), kx = kx0 + ((t & 1) << 1);
                int iy = (t >> 1) ? iyB : iyA, ix = (t & 1) ? ixB : ixA;
                if (iy < 0 || iy >= H || ix < 0 || ix >= W) continue;
                const int16_t *xp = c->xt + ((size_t)(iy * W + ix)) * IC;
                const int16_t *wp = c->wt + ((size_t)(ky * 4 + kx) * IC) * OC;
                for (int ic = 0; ic < IC; ic++) {
                    int32_t xv = xp[ic];
                    const int16_t *wr = wp + (size_t)ic * OC;
                    if (!xv) continue;
                    for (int oc = 0; oc < OC; oc++) acc[oc] += xv * (int32_t)wr[oc];
                }
            }
            for (int oc = 0; oc < OC; oc++) {                            /* fused requant */
                int64_t tq = (int64_t)acc[oc] * RQ_M0[c->rq_off + oc] + RQ_BIAS[c->rq_off + oc];
                int32_t r = rshift_round(tq, RQ_SH[c->rq_off + oc]);
                if (c->relu && r < 0) r = 0;
                if (r < c->lo) r = c->lo;
                if (r > c->hi) r = c->hi;
                c->out[((size_t)oc * c->OH + oy) * OW + ox] = (int16_t)r;
            }
        }
    }
}

/* Fused deconv + requant: same acc and requant math per element as conv_transpose2d +
   requant(), but the int32 acc plane is not stored (writes int16 `out` directly). */
static void conv_transpose2d_fused(const int8_t *w, const int16_t *x, int IC, int H, int W,
                                   int OC, int KH, int KW, int stride, int pad,
                                   int rq_off, int relu, int lo, int hi,
                                   int16_t *out, int *OHp, int *OWp) {
    int OH = (H - 1) * stride - 2 * pad + KH;
    int OW = (W - 1) * stride - 2 * pad + KW;
    int HW = H * W;
    /* The subpixel path is used when IC <= HEAD_SUBPIX_MAXIC (default 64); larger IC takes
     * the oc-major gather kernel. The env var is a debugging switch. */
    static int spmax = -1;
    if (spmax < 0) { const char *e = getenv("HEAD_SUBPIX_MAXIC"); spmax = e ? atoi(e) : 64; }
    if (KH == 4 && KW == 4 && stride == 2 && pad == 1 && OC <= 1024 && IC <= spmax) {
        /* subpixel-phase fast path. Weight repack w[ic][oc][ky][kx] -> wt[ky][kx][ic][oc] int16,
         * cached per weight pointer (weights are constant across frames). */
        static const int8_t *ck[4] = {0, 0, 0, 0};
        static int16_t *cw[4] = {0, 0, 0, 0};
        int slot = -1;
        for (int i = 0; i < 4; i++) if (ck[i] == w) { slot = i; break; }
        if (slot < 0) {
            for (int i = 0; i < 4; i++) if (!ck[i]) { slot = i; break; }
            if (slot < 0) slot = 0;
            if (!cw[slot]) cw[slot] = (int16_t *)malloc((size_t)16 * IC * OC * sizeof(int16_t));
            for (int ky = 0; ky < 4; ky++)
                for (int kx = 0; kx < 4; kx++)
                    for (int ic = 0; ic < IC; ic++)
                        for (int oc = 0; oc < OC; oc++)
                            cw[slot][(((size_t)(ky * 4 + kx) * IC) + ic) * OC + oc] =
                                w[((size_t)ic * OC + oc) * 16 + ky * 4 + kx];
            ck[slot] = w;
        }
        static int16_t xt4[65536];                   /* NHWC gather (shared read-only after seed) */
        for (int ic = 0; ic < IC; ic++) {
            const int16_t *xc = x + (size_t)ic * HW;
            for (int p = 0; p < HW; p++) xt4[p * IC + ic] = xc[p];
        }
        dk4_ctx c = { cw[slot], xt4, IC, OC, H, W, OH, OW, rq_off, relu, lo, hi, out };
        parallel_oc(deconv_k4s2_rows, &c, OH);       /* split output ROWS across threads */
        *OHp = OH; *OWp = OW;
        return;
    }
    static int16_t xt[65536];
    for (int ic = 0; ic < IC; ic++) {
        const int16_t *xc = x + (size_t)ic * HW;
        for (int p = 0; p < HW; p++) xt[p * IC + ic] = xc[p];
    }
    deconv_ctx c = { w, xt, IC, OC, KH, KW, stride, pad, H, W, OH, OW, NULL,
                     out, rq_off, relu, lo, hi };
    parallel_oc(deconv_oc_range, &c, OC);
    *OHp = OH; *OWp = OW;
}

/* per-output-channel requant: out = clamp(rshift(M0*acc + bias, sh), lo, hi) (+ReLU).
   Independent per oc, so the oc range is split across threads. */
typedef struct {
    const int32_t *acc; int hw, rq_off, relu, lo, hi; int16_t *out;
} requant_ctx;

static void requant_range(void *ctx, int oc0, int oc1) {
    requant_ctx *c = (requant_ctx *)ctx;
    int hw = c->hw;
    for (int oc = oc0; oc < oc1; oc++) {
        int32_t M = RQ_M0[c->rq_off + oc];
        int64_t b = RQ_BIAS[c->rq_off + oc];
        int s = RQ_SH[c->rq_off + oc];
        const int32_t *ai = c->acc + oc * hw;
        int16_t *oi = c->out + oc * hw;
        for (int p = 0; p < hw; p++) {
            int64_t t = (int64_t)ai[p] * M + b;
            int32_t r = rshift_round(t, s);
            if (c->relu && r < 0) r = 0;
            if (r < c->lo) r = c->lo;
            if (r > c->hi) r = c->hi;
            oi[p] = (int16_t)r;
        }
    }
}

static void requant(const int32_t *acc, int oc_n, int hw, int rq_off,
                    int relu, int lo, int hi, int16_t *out) {
    requant_ctx c = { acc, hw, rq_off, relu, lo, hi, out };
    parallel_oc(requant_range, &c, oc_n);
}

/* residual seam add: out = clamp(rshift(mp*proj + mq*seam_in, sh), lo, hi) -> int16 */
static void add_requant(const int16_t *p, const int16_t *xin, int n,
                        int mp, int mq, int sh, int lo, int hi, int16_t *out) {
    for (int i = 0; i < n; i++) {
        int64_t t = (int64_t)p[i] * mp + (int64_t)xin[i] * mq;
        int32_t r = rshift_round(t, sh);
        if (r < lo) r = lo;
        if (r > hi) r = hi;
        out[i] = (int16_t)r;
    }
}

int mbv2_load_weights(const char *path, int8_t **blob) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    int8_t *buf = (int8_t *)malloc(BLOB_BYTES);
    size_t n = fread(buf, 1, BLOB_BYTES, f);
    fclose(f);
    if ((long)n != (long)BLOB_BYTES) {
        fprintf(stderr, "blob size %ld != %ld\n", (long)n, (long)BLOB_BYTES);
        free(buf); return 2;
    }
    *blob = buf; return 0;
}

/* ---- per-op tensor dump (host tooling; enabled by env TWN_DUMP_OPS=<dir>) ----
 * Writes <dir>/op<NN>_in.bin and op<NN>_out.bin as int32 C,H,W followed by the int16
 * payload in the CHW layout of the ping-pong buffers. No effect when the variable is unset. */
static const char *dump_dir(void) { static const char *d = (const char *)1;
    if (d == (const char *)1) d = getenv("TWN_DUMP_OPS"); return d; }
static void dump_tensor(int oi, const char *tag, const int16_t *t, int C, int H, int W) {
    const char *d = dump_dir(); if (!d) return;
    char path[512]; snprintf(path, sizeof path, "%s/op%02d_%s.bin", d, oi, tag);
    FILE *f = fopen(path, "wb"); if (!f) return;
    int32_t hdr[3] = { C, H, W };
    fwrite(hdr, sizeof hdr, 1, f);
    fwrite(t, sizeof(int16_t), (size_t)C * H * W, f);
    fclose(f);
}
/* Run OPS[start .. N_OPS). The ping-pong buffers must already hold the input tensor of
 * OPS[start]. Used by mbv2_forward (start=0) and mbv2_head (start=first deconv). */
static void run_ops(const int8_t *blob, int start,
                    int32_t *final_acc, int *keypoints, long long *checksums) {
    int _prof = getenv("OP_TIMING") != NULL;
    for (int oi = start; oi < N_OPS; oi++) {
        const Op *op = &OPS[oi];
        const int16_t *x = g_buf[op->in_buf];
        int H = g_H[op->in_buf], W = g_W[op->in_buf];
        int OH, OW;
        double _t0 = _prof ? _opnow() : 0;
        dump_tensor(oi, "in", x, g_C[op->in_buf], H, W);
        if (op->type == 3) dump_tensor(oi, "in2", g_buf[op->in2_buf], g_C[op->in2_buf], H, W);
        if (op->type == 4) {                                   /* FINAL 1x1 INT8 */
            conv2d(blob + op->w_off, x, op->ic, H, W, op->oc, 1, 1, 1, 0,
                   final_acc, &OH, &OW);
            if (checksums) {
                long long s = 0;
                for (int p = 0; p < op->oc * OH * OW; p++) s += final_acc[p];
                checksums[oi] = s;
            }
            if (keypoints) {
                int hw = OH * OW;
                for (int k = 0; k < op->oc; k++) {
                    const int32_t *a = final_acc + k * hw;
                    int best = 0; int32_t bv = a[0];
                    for (int p = 1; p < hw; p++) if (a[p] > bv) { bv = a[p]; best = p; }
                    keypoints[k * 2] = best % OW; keypoints[k * 2 + 1] = best / OW;
                }
            }
            if (_prof) fprintf(stderr, "  op %d type=%d(final) ic=%d oc=%d %dx%d  %.2f ms\n", oi, op->type, op->ic, op->oc, H, W, _opnow()-_t0);
            return;
        }
        int16_t *out = g_buf[op->out_buf];
        if (op->type == 3) {                                   /* residual ADD (seam) */
            int n = g_C[op->in_buf] * H * W;
            add_requant(x, g_buf[op->in2_buf], n, op->mp, op->mq, op->sh,
                        op->lo, op->hi, out);
            g_C[op->out_buf] = g_C[op->in_buf]; g_H[op->out_buf] = H; g_W[op->out_buf] = W;
        } else {
            if (op->type == 0)
                conv2d(blob + op->w_off, x, op->ic, H, W, op->oc,
                       op->kh, op->kw, op->stride, op->pad, g_acc, &OH, &OW);
            else if (op->type == 1)
                dwconv2d(blob + op->w_off, x, op->oc, H, W,
                         op->kh, op->kw, op->stride, op->pad, g_acc, &OH, &OW);
            else {                                             /* DECONV: fused requant path */
                static int fuse = -1;
                if (fuse < 0) { char *e = getenv("HEAD_FUSE"); fuse = e ? atoi(e) : 1; }
                if (fuse) {
                    conv_transpose2d_fused(blob + op->w_off, x, op->ic, H, W, op->oc,
                                           op->kh, op->kw, op->stride, op->pad,
                                           op->rq_off, op->relu, op->lo, op->hi, out, &OH, &OW);
                    g_C[op->out_buf] = op->oc; g_H[op->out_buf] = OH; g_W[op->out_buf] = OW;
                    goto op_done;
                }
                conv_transpose2d(blob + op->w_off, x, op->ic, H, W, op->oc,
                                 op->kh, op->kw, op->stride, op->pad, g_acc, &OH, &OW);
            }
            requant(g_acc, op->oc, OH * OW, op->rq_off, op->relu, op->lo, op->hi, out);
            g_C[op->out_buf] = op->oc; g_H[op->out_buf] = OH; g_W[op->out_buf] = OW;
            op_done: ;
        }
        dump_tensor(oi, "out", out, g_C[op->out_buf], g_H[op->out_buf], g_W[op->out_buf]);
        if (checksums) {
            long long s = 0;
            int n = g_C[op->out_buf] * g_H[op->out_buf] * g_W[op->out_buf];
            for (int p = 0; p < n; p++) s += out[p];
            checksums[oi] = s;
        }
        if (_prof) fprintf(stderr, "  op %d type=%d ic=%d oc=%d %dx%d  %.2f ms\n", oi, op->type, op->ic, op->oc, H, W, _opnow()-_t0);
    }
}

/* Whole model (image -> keypoints): seeds the input and runs all ops.
 * final_acc: int32[14*64*64]; checksums (optional): long long[N_OPS] per-op sums. */
void mbv2_forward(const int8_t *blob, const int8_t *input,
                  int32_t *final_acc, int *keypoints, long long *checksums) {
    for (int i = 0; i < NET_IN_C * NET_IN_H * NET_IN_W; i++)
        g_buf[0][i] = (int16_t)input[i];
    g_C[0] = NET_IN_C; g_H[0] = NET_IN_H; g_W[0] = NET_IN_W;
    run_ops(blob, 0, final_acc, keypoints, checksums);
}

/* Index of the first deconv op = the PS/PL boundary (backbone ends just before it). */
int mbv2_first_head_op(void) {
    for (int i = 0; i < N_OPS; i++) if (OPS[i].type == 2) return i;
    return N_OPS;
}

/* ===================== NHWC head (layout-only rewrite) =====================
 * Keeps every intermediate tensor NHWC end to end: input taps are contiguous IC reads and
 * outputs are linear stores, so no CHW<->NHWC gather/scatter per layer. Per-element math
 * (tap order t0..t3, ic ascending, same requant) matches the CHW path, so int32 sums are
 * identical. final_acc is still written as CHW int32 planes (argmax/DARK contract). */
typedef struct {
    const int16_t *wt;    /* repacked [ky][kx][ic][oc] int16 (same repack as the CHW path) */
    const int16_t *xin;   /* NHWC input  (H*W*IC), read directly -- no per-layer gather */
    int IC, OC, H, W, OH, OW;
    int rq_off, relu, lo, hi;
    int16_t *out;         /* NHWC output (OH*OW*OC), linear stores */
    int skip0;            /* 1: zero-skip the ic loop (post-ReLU sparse input); 0: dense
                             (deconv1's seam input -- the branch only costs there) */
} dk4n_ctx;

static void deconv_k4s2_nhwc_rows(void *ctx, int oy0, int oy1) {
    dk4n_ctx *c = (dk4n_ctx *)ctx;
    int IC = c->IC, OC = c->OC, H = c->H, W = c->W, OW = c->OW;
#if defined(__aarch64__)
    /* NEON path for OC==32: 8 int32x4 accumulators stay in registers for a whole pixel.
     * Per-lane sums are in ic-ascending order, so the int32 result matches the scalar path. */
    if (OC == 32) {
        for (int oy = oy0; oy < oy1; oy++) {
            int ky0 = (oy & 1) ? 0 : 1;
            int iyA = (oy + 1 - ky0) >> 1, iyB = iyA - 1;
            for (int ox = 0; ox < OW; ox++) {
                int kx0 = (ox & 1) ? 0 : 1;
                int ixA = (ox + 1 - kx0) >> 1, ixB = ixA - 1;
                int32x4_t a0 = vdupq_n_s32(0), a1 = a0, a2 = a0, a3 = a0,
                          a4 = a0, a5 = a0, a6 = a0, a7 = a0;
                for (int t = 0; t < 4; t++) {
                    int ky = ky0 + ((t >> 1) << 1), kx = kx0 + ((t & 1) << 1);
                    int iy = (t >> 1) ? iyB : iyA, ix = (t & 1) ? ixB : ixA;
                    if (iy < 0 || iy >= H || ix < 0 || ix >= W) continue;
                    const int16_t *xp = c->xin + ((size_t)(iy * W + ix)) * IC;
                    const int16_t *wr = c->wt + ((size_t)(ky * 4 + kx) * IC) * 32;
                    for (int ic = 0; ic < IC; ic++, wr += 32) {
                        if (c->skip0 && !xp[ic]) continue;  /* zero input adds nothing; off for the dense seam */
                        int16x4_t xd = vdup_n_s16(xp[ic]);
                        int16x8_t w01 = vld1q_s16(wr),      w23 = vld1q_s16(wr + 8);
                        int16x8_t w45 = vld1q_s16(wr + 16), w67 = vld1q_s16(wr + 24);
                        a0 = vmlal_s16(a0, vget_low_s16(w01),  xd);
                        a1 = vmlal_s16(a1, vget_high_s16(w01), xd);
                        a2 = vmlal_s16(a2, vget_low_s16(w23),  xd);
                        a3 = vmlal_s16(a3, vget_high_s16(w23), xd);
                        a4 = vmlal_s16(a4, vget_low_s16(w45),  xd);
                        a5 = vmlal_s16(a5, vget_high_s16(w45), xd);
                        a6 = vmlal_s16(a6, vget_low_s16(w67),  xd);
                        a7 = vmlal_s16(a7, vget_high_s16(w67), xd);
                    }
                }
                int32_t accv[32];
                vst1q_s32(accv,      a0); vst1q_s32(accv + 4,  a1);
                vst1q_s32(accv + 8,  a2); vst1q_s32(accv + 12, a3);
                vst1q_s32(accv + 16, a4); vst1q_s32(accv + 20, a5);
                vst1q_s32(accv + 24, a6); vst1q_s32(accv + 28, a7);
                int16_t *op_ = c->out + ((size_t)(oy * OW + ox)) * 32;
                for (int oc = 0; oc < 32; oc++) {
                    int64_t tq = (int64_t)accv[oc] * RQ_M0[c->rq_off + oc] + RQ_BIAS[c->rq_off + oc];
                    int32_t r = rshift_round(tq, RQ_SH[c->rq_off + oc]);
                    if (c->relu && r < 0) r = 0;
                    if (r < c->lo) r = c->lo;
                    if (r > c->hi) r = c->hi;
                    op_[oc] = (int16_t)r;
                }
            }
        }
        return;
    }
#endif
    int32_t acc[1024];
    for (int oy = oy0; oy < oy1; oy++) {
        int ky0 = (oy & 1) ? 0 : 1;
        int iyA = (oy + 1 - ky0) >> 1, iyB = iyA - 1;
        for (int ox = 0; ox < OW; ox++) {
            int kx0 = (ox & 1) ? 0 : 1;
            int ixA = (ox + 1 - kx0) >> 1, ixB = ixA - 1;
            for (int oc = 0; oc < OC; oc++) acc[oc] = 0;
            for (int t = 0; t < 4; t++) {
                int ky = ky0 + ((t >> 1) << 1), kx = kx0 + ((t & 1) << 1);
                int iy = (t >> 1) ? iyB : iyA, ix = (t & 1) ? ixB : ixA;
                if (iy < 0 || iy >= H || ix < 0 || ix >= W) continue;
                const int16_t *xp = c->xin + ((size_t)(iy * W + ix)) * IC;
                const int16_t *wp = c->wt + ((size_t)(ky * 4 + kx) * IC) * OC;
                for (int ic = 0; ic < IC; ic++) {
                    int32_t xv = xp[ic];
                    const int16_t *wr = wp + (size_t)ic * OC;
                    if (!xv) continue;
                    for (int oc = 0; oc < OC; oc++) acc[oc] += xv * (int32_t)wr[oc];
                }
            }
            int16_t *op_ = c->out + ((size_t)(oy * OW + ox)) * OC;      /* LINEAR store */
            for (int oc = 0; oc < OC; oc++) {
                int64_t tq = (int64_t)acc[oc] * RQ_M0[c->rq_off + oc] + RQ_BIAS[c->rq_off + oc];
                int32_t r = rshift_round(tq, RQ_SH[c->rq_off + oc]);
                if (c->relu && r < 0) r = 0;
                if (r < c->lo) r = c->lo;
                if (r > c->hi) r = c->hi;
                op_[oc] = (int16_t)r;
            }
        }
    }
}

/* final 1x1 conv, NHWC input -> CHW int32 planes (contract of final_acc/argmax/DARK).
 * Same ic-ascending sum order as conv2d -> bit-exact. Split by output ROWS. */
typedef struct {
    const int8_t *w;      /* w[oc][ic] */
    const int16_t *xin;   /* NHWC (H*W*IC) */
    int IC, OC, H, W;
    int32_t *acc;         /* CHW planes */
} fin_ctx;

static void final_nhwc_rows(void *ctx, int y0, int y1) {
    fin_ctx *c = (fin_ctx *)ctx;
    int IC = c->IC, OC = c->OC, W = c->W, HW = c->H * c->W;
#if defined(__aarch64__)
    if (IC == 32) {
        /* int8 weights widened once per oc (cached), x loaded once per pixel; horizontal
         * add reorders the 32 partial sums -- int32 wraparound associative -> bit-exact. */
        static int16_t wex[32 * 32]; static const int8_t *wck = NULL;
        if (wck != c->w) {
            for (int oc = 0; oc < OC; oc++)
                for (int ic = 0; ic < 32; ic++) wex[oc * 32 + ic] = c->w[(size_t)oc * 32 + ic];
            wck = c->w;
        }
        for (int y = y0; y < y1; y++)
            for (int x = 0; x < W; x++) {
                int p = y * W + x;
                const int16_t *xp = c->xin + (size_t)p * 32;
                int16x8_t x0 = vld1q_s16(xp),      x1 = vld1q_s16(xp + 8);
                int16x8_t x2 = vld1q_s16(xp + 16), x3 = vld1q_s16(xp + 24);
                for (int oc = 0; oc < OC; oc++) {
                    const int16_t *wr = wex + oc * 32;
                    int16x8_t w0 = vld1q_s16(wr),      w1 = vld1q_s16(wr + 8);
                    int16x8_t w2 = vld1q_s16(wr + 16), w3 = vld1q_s16(wr + 24);
                    int32x4_t a = vmull_s16(vget_low_s16(x0), vget_low_s16(w0));
                    a = vmlal_s16(a, vget_high_s16(x0), vget_high_s16(w0));
                    a = vmlal_s16(a, vget_low_s16(x1),  vget_low_s16(w1));
                    a = vmlal_s16(a, vget_high_s16(x1), vget_high_s16(w1));
                    a = vmlal_s16(a, vget_low_s16(x2),  vget_low_s16(w2));
                    a = vmlal_s16(a, vget_high_s16(x2), vget_high_s16(w2));
                    a = vmlal_s16(a, vget_low_s16(x3),  vget_low_s16(w3));
                    a = vmlal_s16(a, vget_high_s16(x3), vget_high_s16(w3));
                    c->acc[(size_t)oc * HW + p] = vaddvq_s32(a);
                }
            }
        return;
    }
#endif
    for (int y = y0; y < y1; y++)
        for (int x = 0; x < W; x++) {
            int p = y * W + x;
            const int16_t *xp = c->xin + (size_t)p * IC;
            for (int oc = 0; oc < OC; oc++) {
                const int8_t *wr = c->w + (size_t)oc * IC;
                int32_t a = 0;
                for (int ic = 0; ic < IC; ic++) a += (int32_t)xp[ic] * wr[ic];
                c->acc[(size_t)oc * HW + p] = a;
            }
        }
}

void mbv2_head_nhwc(const int8_t *blob, const int16_t *bb_nhwc,
                    int32_t *final_acc, int *keypoints) {
    int fd = mbv2_first_head_op();
    static int16_t *pp[2] = { NULL, NULL };
    if (!pp[0]) { pp[0] = (int16_t *)malloc(1 << 19); pp[1] = (int16_t *)malloc(1 << 19); }
    const int16_t *x = bb_nhwc;
    int H = NET_IN_H / 32, W = NET_IN_W / 32;
    int pi = 0;
    for (int oi = fd; oi < N_OPS; oi++) {
        const Op *op = &OPS[oi];
        int _prof = getenv("OP_TIMING") != NULL;
        double _t0 = _prof ? _opnow() : 0;
        if (op->type == 2) {
            int IC = op->ic, OC = op->oc;
            int OH = (H - 1) * 2 - 2 + 4, OW = (W - 1) * 2 - 2 + 4;
            /* weight repack cache (same layout as the CHW fast path, separate slots) */
            static const int8_t *ck[4] = {0,0,0,0}; static int16_t *cw[4] = {0,0,0,0};
            int slot = -1;
            for (int i = 0; i < 4; i++) if (ck[i] == blob + op->w_off) { slot = i; break; }
            if (slot < 0) {
                for (int i = 0; i < 4; i++) if (!ck[i]) { slot = i; break; }
                if (slot < 0) slot = 0;
                free(cw[slot]);
                cw[slot] = (int16_t *)malloc((size_t)16 * IC * OC * sizeof(int16_t));
                const int8_t *w8 = blob + op->w_off;
                for (int ky = 0; ky < 4; ky++)
                    for (int kx = 0; kx < 4; kx++)
                        for (int ic = 0; ic < IC; ic++)
                            for (int oc = 0; oc < OC; oc++)
                                cw[slot][(((size_t)(ky*4+kx) * IC) + ic) * OC + oc] =
                                    w8[((size_t)ic * OC + oc) * 16 + ky * 4 + kx];
                ck[slot] = blob + op->w_off;
            }
            dk4n_ctx c = { cw[slot], x, IC, OC, H, W, OH, OW,
                           op->rq_off, op->relu, op->lo, op->hi, pp[pi],
                           oi != fd };   /* zero-skip except the dense seam input of deconv1 */
            parallel_oc(deconv_k4s2_nhwc_rows, &c, OH);
            x = pp[pi]; pi ^= 1; H = OH; W = OW;
        } else if (op->type == 4) {
            fin_ctx c = { blob + op->w_off, x, op->ic, op->oc, H, W, final_acc };
            parallel_oc(final_nhwc_rows, &c, H);
            if (keypoints) {
                int hw = H * W;
                for (int k = 0; k < op->oc; k++) {
                    const int32_t *a = final_acc + (size_t)k * hw;
                    int best = 0; int32_t bv = a[0];
                    for (int p = 1; p < hw; p++) if (a[p] > bv) { bv = a[p]; best = p; }
                    keypoints[k * 2] = best % W; keypoints[k * 2 + 1] = best / W;
                }
            }
        }
        if (_prof) fprintf(stderr, "  nhwc op %d type=%d ic=%d oc=%d %dx%d  %.2f ms\n",
                           oi, op->type, op->ic, op->oc, H, W, _opnow() - _t0);
    }
}

/* PS-side head: given backbone_out (int16 CHW, OPS[first deconv].ic channels at
 * NET_IN_H/32 x NET_IN_W/32), run the deconv head + final 1x1 + argmax. Same integer
 * kernels as the whole-model path. */
void mbv2_head(const int8_t *blob, const int16_t *backbone_out,
               int32_t *final_acc, int *keypoints) {
    int fd = mbv2_first_head_op();
    int ib = OPS[fd].in_buf;
    /* the backbone downsamples the input by 32 */
    int bh = NET_IN_H / 32, bw = NET_IN_W / 32;
    int n = OPS[fd].ic * bh * bw;
    for (int i = 0; i < n; i++) g_buf[ib][i] = backbone_out[i];
    g_C[ib] = OPS[fd].ic; g_H[ib] = bh; g_W[ib] = bw;
    run_ops(blob, fd, final_acc, keypoints, NULL);
}

/* ===================== uint8-activation head =====================
 * The head deconvs' requant clamps to [lo,hi] = [0,255] after ReLU (see OPS), so their
 * outputs fit uint8 exactly and are stored as uint8: same values, less activation traffic.
 * The boundary tensor stays int16, so deconv0 uses the int16 fused kernel and narrows
 * its output; deconv1/2 and the final conv read uint8. */
typedef struct {
    const int8_t *w; const uint8_t *xt;   /* xt[(iy*W+ix)*IC + ic], uint8 activations */
    int IC, OC, KH, KW, stride, pad, H, W, OH, OW;
    int rq_off, relu, lo, hi;
    uint8_t *out;                          /* fused requant -> uint8 store */
} deconv8_ctx;

static void deconv8_oc_range(void *ctx, int oc0, int oc1) {
    deconv8_ctx *c = (deconv8_ctx *)ctx;
    int IC = c->IC, KH = c->KH, KW = c->KW, H = c->H, W = c->W;
    int OH = c->OH, OW = c->OW, stride = c->stride, pad = c->pad;
    int sw = c->OC * KH * KW;
    const uint8_t *xt = c->xt;
    int8_t wt[8192];
    for (int oc = oc0; oc < oc1; oc++) {
        for (int kk = 0; kk < KH * KW; kk++) {
            const int8_t *ws = c->w + oc * KH * KW + kk;
            int8_t *wd = wt + kk * IC;
            for (int ic = 0; ic < IC; ic++) wd[ic] = ws[(size_t)ic * sw];
        }
        uint8_t *op8 = c->out + (size_t)oc * OH * OW;
        int32_t rqM = RQ_M0[c->rq_off + oc];
        int64_t rqB = RQ_BIAS[c->rq_off + oc];
        int rqS = RQ_SH[c->rq_off + oc];
        int s2 = (stride == 2);
        for (int oy = 0; oy < OH; oy++) {
            int nky = 0, kyv[8], iyv[8];
            for (int ky = 0; ky < KH; ky++) {
                int iyn = oy + pad - ky; if (iyn < 0) continue;
                int iy = s2 ? (iyn >> 1) : (iyn / stride);
                if ((s2 ? (iyn & 1) : (iyn % stride)) || iy >= H) continue;
                kyv[nky] = ky; iyv[nky] = iy; nky++;
            }
            for (int ox = 0; ox < OW; ox++) {
                int nkx = 0, kxv[8], ixv[8];
                for (int kx = 0; kx < KW; kx++) {
                    int ixn = ox + pad - kx; if (ixn < 0) continue;
                    int ix = s2 ? (ixn >> 1) : (ixn / stride);
                    if ((s2 ? (ixn & 1) : (ixn % stride)) || ix >= W) continue;
                    kxv[nkx] = kx; ixv[nkx] = ix; nkx++;
                }
                int32_t s = 0;
                for (int a = 0; a < nky; a++)
                    for (int b = 0; b < nkx; b++) {
                        const int8_t  *wr = wt + (kyv[a] * KW + kxv[b]) * IC;
                        const uint8_t *xr = xt + (iyv[a] * W + ixv[b]) * IC;
                        for (int ic = 0; ic < IC; ic++) s += (int32_t)wr[ic] * (int32_t)xr[ic];
                    }
                int64_t t = (int64_t)s * rqM + rqB;      /* fused requant (same math/order) */
                int32_t r = rshift_round(t, rqS);
                if (c->relu && r < 0) r = 0;
                if (r < c->lo) r = c->lo;
                if (r > c->hi) r = c->hi;
                op8[oy * OW + ox] = (uint8_t)r;
            }
        }
    }
}

typedef struct { const int8_t *w; const uint8_t *x; int IC, HW; int32_t *acc; } conv1x1u8_ctx;
static void conv2d_1x1_u8_range(void *ctx, int oc0, int oc1) {
    conv1x1u8_ctx *c = (conv1x1u8_ctx *)ctx;
    int HW = c->HW, IC = c->IC;
    for (int oc = oc0; oc < oc1; oc++) {
        int32_t *ap = c->acc + (size_t)oc * HW;
        memset(ap, 0, sizeof(int32_t) * (size_t)HW);
        const int8_t *wo = c->w + (size_t)oc * IC;
        for (int ic = 0; ic < IC; ic++) {
            int wv = wo[ic];
            if (!wv) continue;
            const uint8_t *xr = c->x + (size_t)ic * HW;
            for (int p = 0; p < HW; p++) ap[p] += (int32_t)wv * (int32_t)xr[p];
        }
    }
}

/* uint8-activation head. Same values as mbv2_head: uint8 stores are exact for
 * tensors clamped to [0,255]. */
void mbv2_head8(const int8_t *blob, const int16_t *backbone_out,
                int32_t *final_acc, int *keypoints) {
    int fd = mbv2_first_head_op();
    int bh = NET_IN_H / 32, bw = NET_IN_W / 32;
    static int16_t d0out[32 * 16 * 16 * 4];        /* deconv0 out (int16 kernel), <=32x16x16 @256 */
    static uint8_t a8[2][32 * 64 * 64];            /* uint8 CHW ping-pong (max deconv2 out) */
    static uint8_t xt8[32 * 32 * 32 * 4];          /* uint8 NHWC gather (max deconv2 in) */

    /* deconv0: int16 boundary in -> fused requant -> int16 tmp (0..255) -> narrow to uint8 */
    const Op *op = &OPS[fd];
    int OH, OW, H = bh, W = bw;
    conv_transpose2d_fused(blob + op->w_off, backbone_out, op->ic, H, W, op->oc,
                           op->kh, op->kw, op->stride, op->pad,
                           op->rq_off, op->relu, op->lo, op->hi, d0out, &OH, &OW);
    int C = op->oc, n0 = C * OH * OW, pp = 0;
    for (int i = 0; i < n0; i++) a8[0][i] = (uint8_t)d0out[i];
    H = OH; W = OW;

    /* deconv1..: uint8 in -> fused requant -> uint8 out */
    for (int oi = fd + 1; OPS[oi].type == 2; oi++) {
        op = &OPS[oi];
        const uint8_t *x = a8[pp];
        int HW = H * W;
        for (int ic = 0; ic < C; ic++) {           /* CHW -> NHWC gather for the dot product */
            const uint8_t *xc = x + (size_t)ic * HW;
            for (int p = 0; p < HW; p++) xt8[p * C + ic] = xc[p];
        }
        OH = (H - 1) * op->stride - 2 * op->pad + op->kh;
        OW = (W - 1) * op->stride - 2 * op->pad + op->kw;
        deconv8_ctx c = { blob + op->w_off, xt8, C, op->oc, op->kh, op->kw,
                          op->stride, op->pad, H, W, OH, OW,
                          op->rq_off, op->relu, op->lo, op->hi, a8[pp ^ 1] };
        parallel_oc(deconv8_oc_range, &c, op->oc);
        pp ^= 1; C = op->oc; H = OH; W = OW;
        fd = oi;                                    /* remember last deconv index */
    }

    /* final 1x1 (uint8 in) + argmax, as the type-4 branch of run_ops */
    op = &OPS[fd + 1];
    int HW = H * W;
    conv1x1u8_ctx fc = { blob + op->w_off, a8[pp], op->ic, HW, final_acc };
    parallel_oc(conv2d_1x1_u8_range, &fc, op->oc);
    if (keypoints) {
        for (int k = 0; k < op->oc; k++) {
            const int32_t *a = final_acc + k * HW;
            int best = 0; int32_t bv = a[0];
            for (int p = 1; p < HW; p++) if (a[p] > bv) { bv = a[p]; best = p; }
            keypoints[k * 2] = best % W; keypoints[k * 2 + 1] = best / W;
        }
    }
}

/* ===================== DARK decode refinement (PS post-processing) =====================
 * Distribution-aware sub-pixel decode (Zhang et al. 2020) on the final heatmaps: per joint,
 * Gaussian blur (11 taps, sigma 2.0, reflect-101 borders) then a 2nd-order log-Taylor step
 * around the integer argmax. Joints 0 and 1 keep the plain argmax.
 * Output only: the integer argmax keypoints are unchanged. */
void mbv2_dark_refine(const int32_t *final_acc, float coords[][2]) {
    const int K = NET_OUT_C, H = NET_OUT_H, W = NET_OUT_W;
    static float g[11]; static int g_init = 0;
    if (!g_init) {
        double s = 0, sig = 2.0;
        for (int i = 0; i < 11; i++) { g[i] = (float)exp(-0.5 * (i - 5) * (i - 5) / (sig * sig)); s += g[i]; }
        for (int i = 0; i < 11; i++) g[i] = (float)(g[i] / s);
        g_init = 1;
    }
    /* Windowed: the log-Taylor step reads only the blurred 3x3 around the peak, which
     * depends on a 13x13 source window (separable radius-5 blur). The peak-amplitude
     * rescale is a uniform factor that cancels in the log derivatives, so it is skipped. */
    for (int k = 0; k < K; k++) {
        const int32_t *a = final_acc + k * H * W;
        int best = 0; int32_t bv = a[0];
        for (int p = 1; p < H * W; p++) if (a[p] > bv) { bv = a[p]; best = p; }
        int x = best % W, y = best / W;
        coords[k][0] = (float)x; coords[k][1] = (float)y;
        if (k < 2) continue;                       /* selective: skip head_top/neck */
        /* pass 1 (horizontal) into tmp rows y-6..y+6, cols x-1..x+1 */
        float tmp[13][3], blr[3][3];
        for (int r = 0; r < 13; r++) {
            int yy = y - 6 + r;
            if (yy < 0) yy = -yy;
            if (yy >= H) yy = 2 * H - 2 - yy;
            for (int c = 0; c < 3; c++) {
                int xc = x - 1 + c;
                float s2 = 0;
                for (int t2 = -5; t2 <= 5; t2++) {
                    int xi = xc + t2;
                    if (xi < 0) xi = -xi;
                    if (xi >= W) xi = 2 * W - 2 - xi;
                    s2 += g[t2 + 5] * (float)(a[yy * W + xi] * FINAL_OUT_MULT + FINAL_BIAS[k]);
                }
                tmp[r][c] = s2;
            }
        }
        /* pass 2 (vertical) -> blurred 3x3 around (y,x) */
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++) {
                float s2 = 0;
                for (int t2 = -5; t2 <= 5; t2++) s2 += g[t2 + 5] * tmp[r + 5 + t2][c];
                blr[r][c] = s2;
            }
        if (x < 1 || x >= W - 1 || y < 1 || y >= H - 1) continue;
        /* The window is refined around the original argmax; modulation could move the
         * peak of the blurred map on flat tops. */
        #define LG(r, c) logf(fmaxf(blr[r][c], 1e-10f))
        float dx = 0.5f * (LG(1, 2) - LG(1, 0));
        float dy = 0.5f * (LG(2, 1) - LG(0, 1));
        float dxx = LG(1, 2) - 2 * LG(1, 1) + LG(1, 0);
        float dyy = LG(2, 1) - 2 * LG(1, 1) + LG(0, 1);
        float dxy = 0.25f * (LG(2, 2) - LG(2, 0) - LG(0, 2) + LG(0, 0));
        #undef LG
        float det = dxx * dyy - dxy * dxy;
        if (fabsf(det) > 1e-10f) {
            float ox = -(dyy * dx - dxy * dy) / det;
            float oy = -(dxx * dy - dxy * dx) / det;
            if (fabsf(ox) < 1.5f && fabsf(oy) < 1.5f) {
                coords[k][0] = x + ox; coords[k][1] = y + oy;
            }
        }
    }
}
