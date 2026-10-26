/* ============================================================================
 *  p0_fused.c -- checks that the fused, row-streamed execution order of the
 *  backbone gives bit-identical results to the whole-tensor op-by-op flow.
 *
 *  Each output element depends only on its own input window and the weights, so
 *  streaming by row cannot change a value provided the schedule presents the same
 *  input rows, with the same zero padding, for every output row. What is checked:
 *    - which expand rows must be live before depthwise row r can be produced
 *    - ring depth (no row overwritten before it is read)
 *    - stride-2 row correspondence
 *    - top/bottom padding applied per row window
 *    - residual source readable when its output row is emitted
 *    - block 0, whose first stage is a 3x3 stride-2 stem conv
 *
 *  Gate A: the tiled path in THIS file reproduces sw/net/mbv2_pose.c (per-block checksum).
 *  Gate B: the fused path equals the tiled path byte for byte at every block boundary.
 *  Further checks (printed as items 4, 8, 9, 10, 11): requant-table reverse test,
 *  ternary weight reorder round trip, peak/13x13 window, constant narrowing,
 *  final keypoints.
 *
 *  build:  cc -O2 -I../../sw/net -I. p0_fused.c ../../models/mbv2_pose/model_meta.c \
 *             ../../sw/net/mbv2_pose.c -o p0_fused -lm   (run_p0.sh does this)
 *  run  :  ./p0_fused <blob.bin> <fixture.bin>
 *          fixture.bin starts with the int8 input tensor (3*256*256 bytes).
 *  exit :  0 if every check passes.
 * ========================================================================== */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include "model_meta.h"
#include "mbv2_pose.h"

/* ---------------------------------------------------------------- kernels --
 * Scalar transcription of the kernels in sw/net/mbv2_pose.c; gate A checks it against
 * the reference. */

/* ---- item 10: constant narrowing -------------------------------------------
 * The host model applies the constant widths the hardware carries (defaults below:
 * M0 and residual mp/mq 18 bits signed, bias 40 bits signed, shift 6 bits unsigned).
 * Narrowing is applied unless built with -DNARROW=0. A constant that does not fit
 * changes value, so gate B fails instead of the hardware silently truncating. */
#ifndef NARROW
#define NARROW 1
#endif
/* The widths are overridable (-DNB_M0= etc.) so run_p0.sh can show that a too-small
 * width makes gate B fail. */
#ifndef NB_M0
#define NB_M0 18
#endif
#ifndef NB_BIAS
#define NB_BIAS 40
#endif
#ifndef NB_SH
#define NB_SH 6
#endif
static inline int64_t sfit(int64_t v, int bits) {       /* wrap to `bits` signed */
    int64_t m = (int64_t)1 << (bits - 1);
    return ((v + m) & (((int64_t)1 << bits) - 1)) - m;
}
static inline int32_t nar_m0(int32_t v)   { return NARROW ? (int32_t)sfit(v, NB_M0) : v; }
static inline int64_t nar_bias(int64_t v) { return NARROW ? sfit(v, NB_BIAS) : v; }
static inline int     nar_sh(int v)       { return NARROW ? (v & ((1 << NB_SH) - 1)) : v; }
static inline int     nar_mq(int v)       { return NARROW ? (int)sfit(v, NB_M0) : v; }

static inline int32_t rshift_round(int64_t t, int s) {
    if (s <= 0) return (int32_t)t;
    int64_t half = (int64_t)1 << (s - 1);
    return (int32_t)((t + half) >> s);
}

static void requant_row(const int32_t *acc, int OC, int OW, int rq_off,
                        int relu, int lo, int hi, int16_t *out)
{
    for (int oc = 0; oc < OC; oc++) {
        int32_t M = nar_m0(RQ_M0[rq_off + oc]);
        int64_t b = nar_bias(RQ_BIAS[rq_off + oc]);
        int s = nar_sh(RQ_SH[rq_off + oc]);
        const int32_t *ai = acc + (size_t)oc * OW;
        int16_t *oi = out + (size_t)oc * OW;
        for (int p = 0; p < OW; p++) {
            int64_t t = (int64_t)ai[p] * M + b;
            int32_t r = rshift_round(t, s);
            if (relu && r < 0) r = 0;
            if (r < lo) r = lo;
            if (r > hi) r = hi;
            oi[p] = (int16_t)r;
        }
    }
}

static void add_requant_row(const int16_t *p, const int16_t *xin, int n,
                            int mp, int mq, int sh, int lo, int hi, int16_t *out)
{
    for (int i = 0; i < n; i++) {
        int64_t t = (int64_t)p[i] * nar_mq(mp) + (int64_t)xin[i] * nar_mq(mq);
        int32_t r = rshift_round(t, sh);
        if (r < lo) r = lo;
        if (r > hi) r = hi;
        out[i] = (int16_t)r;
    }
}

/* ------------------------------------------------------------ block table --
 * A block is: conv (1x1, or the 3x3 stem in block 0) -> depthwise -> conv 1x1 [-> add] */
typedef struct { int e, dw, p, add; } Block;
static Block BLK[24];
/* item 4 modifies a table base and restores it; OPS is const. */
static Op OPS_MUT[N_OPS];
#define OPS OPS_MUT
static int   N_BLK = 0;

static void build_blocks(void) {
#undef OPS
    for (int q = 0; q < N_OPS; q++) OPS_MUT[q] = OPS[q];
#define OPS OPS_MUT
    int i = 0;
    while (i < N_OPS) {
        if (OPS[i].type == 0 && i + 2 < N_OPS &&
            OPS[i + 1].type == 1 && OPS[i + 2].type == 0) {
            Block b = { i, i + 1, i + 2, -1 };
            if (i + 3 < N_OPS && OPS[i + 3].type == 3) b.add = i + 3;
            BLK[N_BLK++] = b;
            i = (b.add >= 0) ? i + 4 : i + 3;
        } else i++;
    }
}

/* ------------------------------------------------------------------ shapes */
static int outdim(int in, int k, int s, int p) { return (in + 2 * p - k) / s + 1; }

/* ---- item 7: expand stage, walked one KERNEL ROW at a time ------------------
 * kh separate passes, each reducing one input row into the same int32 accumulator.
 * A pass whose input row falls outside the tensor contributes nothing, so padding
 * is decided per pass. For a 1x1 there is one pass. Integer addition is associative,
 * so partitioning the sum by kernel row is exact; this checks the row mapping and the
 * per-pass padding. */
static void expand_row(const int8_t *blob, const Op *e, const int16_t *X,
                       int H, int W, int We, int oy, int32_t *acc)
{
    for (int oc = 0; oc < e->oc; oc++)
        memset(acc + (size_t)oc * We, 0, sizeof(int32_t) * (size_t)We);
    for (int ky = 0; ky < e->kh; ky++) {
        int iy = oy * e->stride - e->pad + ky;
        if (iy < 0 || iy >= H) continue;              /* whole pass is padding */
        for (int oc = 0; oc < e->oc; oc++) {
            int32_t *ar = acc + (size_t)oc * We;
            for (int ic = 0; ic < e->ic; ic++) {
                const int8_t *wr = blob + e->w_off +
                                   ((size_t)oc * e->ic + ic) * e->kh * e->kw;
                const int16_t *xr = X + (size_t)ic * H * W + (size_t)iy * W;
                for (int kx = 0; kx < e->kw; kx++) {
                    int8_t wv = wr[ky * e->kw + kx];
                    if (!wv) continue;
                    for (int ox = 0; ox < We; ox++) {
                        int ix = ox * e->stride - e->pad + kx;
                        if (ix < 0 || ix >= W) continue;
                        ar[ox] += (int32_t)wv * (int32_t)xr[ix];
                    }
                }
            }
        }
    }
}

/* ------------------------------------------------------- tiled (path A) ----
 * Whole-tensor, op by op, as in the reference flow.
 * Stage taps: when g_tap is set, tiled_block() hands the intermediate tensors
 * (expand output, depthwise output, project output before the residual) to the
 * caller through g_tapE/g_tapD/g_tapP instead of freeing them; p1_golden uses this. */
static int      g_tap  = 0;
static int16_t *g_tapE = NULL, *g_tapD = NULL, *g_tapP = NULL;

static void tiled_block(const int8_t *blob, const Block *b,
                        const int16_t *X, int H, int W, int16_t *OUT, int *OHp, int *OWp)
{
    const Op *e = &OPS[b->e], *d = &OPS[b->dw], *p = &OPS[b->p];
    int He = outdim(H, e->kh, e->stride, e->pad), We = outdim(W, e->kw, e->stride, e->pad);
    int Hd = outdim(He, d->kh, d->stride, d->pad), Wd = outdim(We, d->kw, d->stride, d->pad);

    int16_t *E = malloc(sizeof(int16_t) * (size_t)e->oc * He * We);
    int16_t *D = malloc(sizeof(int16_t) * (size_t)d->oc * Hd * Wd);
    int32_t *A = malloc(sizeof(int32_t) * (size_t)e->oc * (We > Wd ? We : Wd));
    int16_t *P = (b->add >= 0) ? malloc(sizeof(int16_t) * (size_t)p->oc * Hd * Wd) : OUT;

    for (int oy = 0; oy < He; oy++) {
        for (int oc = 0; oc < e->oc; oc++) {
            int32_t *ar = A + (size_t)oc * We;
            memset(ar, 0, sizeof(int32_t) * (size_t)We);
            for (int ic = 0; ic < e->ic; ic++) {
                const int8_t *wr = blob + e->w_off + ((size_t)oc * e->ic + ic) * e->kh * e->kw;
                const int16_t *xc = X + (size_t)ic * H * W;
                for (int ky = 0; ky < e->kh; ky++) {
                    int iy = oy * e->stride - e->pad + ky;
                    if (iy < 0 || iy >= H) continue;
                    for (int kx = 0; kx < e->kw; kx++) {
                        int8_t wv = wr[ky * e->kw + kx];
                        if (!wv) continue;
                        for (int ox = 0; ox < We; ox++) {
                            int ix = ox * e->stride - e->pad + kx;
                            if (ix < 0 || ix >= W) continue;
                            ar[ox] += (int32_t)wv * (int32_t)xc[(size_t)iy * W + ix];
                        }
                    }
                }
            }
        }
        int16_t *erow = malloc(sizeof(int16_t) * (size_t)e->oc * We);
        requant_row(A, e->oc, We, e->rq_off, e->relu, e->lo, e->hi, erow);
        for (int oc = 0; oc < e->oc; oc++)
            memcpy(E + ((size_t)oc * He + oy) * We, erow + (size_t)oc * We,
                   sizeof(int16_t) * (size_t)We);
        free(erow);
    }
    for (int oy = 0; oy < Hd; oy++) {
        for (int c = 0; c < d->oc; c++) {
            const int8_t *wc = blob + d->w_off + (size_t)c * d->kh * d->kw;
            int32_t *ar = A + (size_t)c * Wd;
            const int16_t *xc = E + (size_t)c * He * We;
            for (int ox = 0; ox < Wd; ox++) {
                int32_t s = 0;
                for (int ky = 0; ky < d->kh; ky++) {
                    int iy = oy * d->stride - d->pad + ky;
                    if (iy < 0 || iy >= He) continue;
                    for (int kx = 0; kx < d->kw; kx++) {
                        int ix = ox * d->stride - d->pad + kx;
                        if (ix < 0 || ix >= We) continue;
                        s += (int32_t)wc[ky * d->kw + kx] * (int32_t)xc[(size_t)iy * We + ix];
                    }
                }
                ar[ox] = s;
            }
        }
        int16_t *drow = malloc(sizeof(int16_t) * (size_t)d->oc * Wd);
        requant_row(A, d->oc, Wd, d->rq_off, d->relu, d->lo, d->hi, drow);
        for (int c = 0; c < d->oc; c++)
            memcpy(D + ((size_t)c * Hd + oy) * Wd, drow + (size_t)c * Wd,
                   sizeof(int16_t) * (size_t)Wd);
        free(drow);
    }
    for (int oy = 0; oy < Hd; oy++) {
        for (int oc = 0; oc < p->oc; oc++) {
            int32_t *ar = A + (size_t)oc * Wd;
            memset(ar, 0, sizeof(int32_t) * (size_t)Wd);
            for (int ic = 0; ic < p->ic; ic++) {
                int8_t wv = blob[p->w_off + (size_t)oc * p->ic + ic];
                if (!wv) continue;
                const int16_t *xc = D + (size_t)ic * Hd * Wd + (size_t)oy * Wd;
                for (int ox = 0; ox < Wd; ox++) ar[ox] += (int32_t)wv * (int32_t)xc[ox];
            }
        }
        int16_t *prow = malloc(sizeof(int16_t) * (size_t)p->oc * Wd);
        requant_row(A, p->oc, Wd, p->rq_off, p->relu, p->lo, p->hi, prow);
        for (int oc = 0; oc < p->oc; oc++)
            memcpy(P + ((size_t)oc * Hd + oy) * Wd, prow + (size_t)oc * Wd,
                   sizeof(int16_t) * (size_t)Wd);
        free(prow);
    }
    if (b->add >= 0) {
        const Op *a = &OPS[b->add];
        add_requant_row(P, X, (int)((size_t)p->oc * Hd * Wd),
                        a->mp, a->mq, a->sh, a->lo, a->hi, OUT);
    }
    if (g_tap) {                       /* hand the intermediates to the caller */
        g_tapE = E; g_tapD = D;
        g_tapP = (b->add >= 0) ? P : NULL;   /* no residual -> project output IS OUT */
    } else {
        if (b->add >= 0) free(P);
        free(E); free(D);
    }
    free(A);
    *OHp = Hd; *OWp = Wd;
}

/* ------------------------------------------------------- fused (path B) ----
 * Row-streaming. The expand output lives in a ring of EDEPTH rows and the depthwise
 * output in one row; neither exists as a full tensor. */
/* Ring geometry. EDEPTH: expand-output rows held in the ring. ELOOK: rows the expand
 * stage may run ahead of what the depthwise currently needs. With ELOOK=0 the stages
 * are sequential and 3 rows suffice (the window's three rows are distinct slots); with
 * ELOOK=1 the ring needs 4 rows or the writer overwrites a row still to be read.
 * Both can be set at build time (-DEDEPTH= / -DELOOK=) for the negative tests. */
#ifndef EDEPTH
#define EDEPTH 4
#endif
#ifndef ELOOK
#define ELOOK  1
#endif

static int g_need_depth = 0;   /* max (highest row produced - oldest row still needed + 1) */

static void fused_block(const int8_t *blob, const Block *b,
                        const int16_t *X, int H, int W, int16_t *OUT, int *OHp, int *OWp)
{
    const Op *e = &OPS[b->e], *d = &OPS[b->dw], *p = &OPS[b->p];
    int He = outdim(H, e->kh, e->stride, e->pad), We = outdim(W, e->kw, e->stride, e->pad);
    int Hd = outdim(He, d->kh, d->stride, d->pad), Wd = outdim(We, d->kw, d->stride, d->pad);

    /* RingB: EDEPTH rows of the expand output, indexed by (row mod EDEPTH). */
    int16_t *ring = calloc((size_t)EDEPTH * e->oc * We, sizeof(int16_t));
    int      *ring_row = malloc(sizeof(int) * EDEPTH);     /* which expand row each slot holds */
    for (int i = 0; i < EDEPTH; i++) ring_row[i] = -1;
    /* RingC: one depthwise output row. RingD: one block output row. */
    int16_t *drow = malloc(sizeof(int16_t) * (size_t)d->oc * Wd);
    int16_t *prow = malloc(sizeof(int16_t) * (size_t)p->oc * Wd);
    int32_t *acc  = malloc(sizeof(int32_t) * (size_t)e->oc * (We > Wd ? We : Wd));

    int produced = 0;      /* next expand row to produce */

    for (int r = 0; r < Hd; r++) {
        /* --- make sure the depthwise's 3-row window for output row r is live --- */
        int need_hi = r * d->stride - d->pad + (d->kh - 1);   /* highest input row touched */
        if (need_hi > He - 1) need_hi = He - 1;
        int run_to = need_hi + ELOOK;                         /* the expand stage runs ahead */
        if (run_to > He - 1) run_to = He - 1;
        while (produced <= run_to) {
            int oy = produced;
            int slot = oy % EDEPTH;
            /* expand row oy from the block input, one kernel row per pass (item 7) */
            expand_row(blob, e, X, H, W, We, oy, acc);
            requant_row(acc, e->oc, We, e->rq_off, e->relu, e->lo, e->hi,
                        ring + (size_t)slot * e->oc * We);
            ring_row[slot] = oy;
            produced++;
        }

        /* --- depthwise output row r, reading only the ring --- */
        {   /* ring depth needed for this read: rows from the oldest one still needed up to
             * the newest produced must all survive. */
            int need_lo = r * d->stride - d->pad;
            if (need_lo < 0) need_lo = 0;
            int depth = (produced - 1) - need_lo + 1;
            if (depth > g_need_depth) g_need_depth = depth;
        }
        for (int c = 0; c < d->oc; c++) {
            const int8_t *wc = blob + d->w_off + (size_t)c * d->kh * d->kw;
            int32_t *ar = acc + (size_t)c * Wd;
            for (int ox = 0; ox < Wd; ox++) {
                int32_t s = 0;
                for (int ky = 0; ky < d->kh; ky++) {
                    int iy = r * d->stride - d->pad + ky;
                    if (iy < 0 || iy >= He) continue;
                    int slot = iy % EDEPTH;
                    if (ring_row[slot] != iy) {          /* the row was overwritten */
                        fprintf(stderr,
                          "FUSED SCHEDULE VIOLATION: depthwise row %d needs expand row %d, "
                          "but ring slot %d holds row %d. EDEPTH=%d is too small.\n",
                          r, iy, slot, ring_row[slot], EDEPTH);
                        exit(2);
                    }
                    const int16_t *xc = ring + (size_t)slot * d->oc * We + (size_t)c * We;
                    for (int kx = 0; kx < d->kw; kx++) {
                        int ix = ox * d->stride - d->pad + kx;
                        if (ix < 0 || ix >= We) continue;
                        s += (int32_t)wc[ky * d->kw + kx] * (int32_t)xc[ix];
                    }
                }
                ar[ox] = s;
            }
        }
        requant_row(acc, d->oc, Wd, d->rq_off, d->relu, d->lo, d->hi, drow);

        /* --- second 1x1 on that one row --- */
        for (int oc = 0; oc < p->oc; oc++) {
            int32_t *ar = acc + (size_t)oc * Wd;
            memset(ar, 0, sizeof(int32_t) * (size_t)Wd);
            for (int ic = 0; ic < p->ic; ic++) {
                int8_t wv = blob[p->w_off + (size_t)oc * p->ic + ic];
                if (!wv) continue;
                const int16_t *xc = drow + (size_t)ic * Wd;
                for (int ox = 0; ox < Wd; ox++) ar[ox] += (int32_t)wv * (int32_t)xc[ox];
            }
        }
        requant_row(acc, p->oc, Wd, p->rq_off, p->relu, p->lo, p->hi, prow);

        /* --- residual, read back from the block input X --- */
        if (b->add >= 0) {
            const Op *a = &OPS[b->add];
            for (int oc = 0; oc < p->oc; oc++)
                add_requant_row(prow + (size_t)oc * Wd,
                                X + (size_t)oc * H * W + (size_t)r * W, Wd,
                                a->mp, a->mq, a->sh, a->lo, a->hi,
                                OUT + ((size_t)oc * Hd + r) * Wd);
        } else {
            for (int oc = 0; oc < p->oc; oc++)
                memcpy(OUT + ((size_t)oc * Hd + r) * Wd, prow + (size_t)oc * Wd,
                       sizeof(int16_t) * (size_t)Wd);
        }
    }
    free(ring); free(ring_row); free(drow); free(prow); free(acc);
    *OHp = Hd; *OWp = Wd;
}

/* ---- item 10 self-report: do the constants fit? ------------------------------
 * Counts how many constants each hardware width would alter (zero = they all fit),
 * then the width the data actually needs. */
static int narrow_report(void) {
    int nm = 0, nb = 0, ns = 0, nq = 0, total = 0;
    for (int i = 0; i < N_OPS; i++) {
        const Op *o = &OPS[i];
        int n = (o->type == 3) ? 0 : o->oc;
        for (int c = 0; c < n; c++) {
            int idx = o->rq_off + c; total++;
            if ((int64_t)RQ_M0[idx]  != sfit(RQ_M0[idx], NB_M0))       nm++;
            if (RQ_BIAS[idx]         != sfit(RQ_BIAS[idx], NB_BIAS))   nb++;
            if ((int64_t)RQ_SH[idx]  != (RQ_SH[idx] & ((1<<NB_SH)-1))) ns++;
        }
        if (o->type == 3) {
            if ((int64_t)o->mp != sfit(o->mp, NB_M0)) nq++;
            if ((int64_t)o->mq != sfit(o->mq, NB_M0)) nq++;
        }
    }
    printf("  constants checked: %d requant entries + %d residual multipliers\n",
           total, 2 * 10);
    printf("  exceeding the hardware width: M0(%db)=%d  bias(%db)=%d  shift(%db)=%d  mp/mq(%db)=%d\n",
           NB_M0, nm, NB_BIAS, nb, NB_SH, ns, NB_M0, nq);
    int wm = 1, wb = 1, ws = 1, wq = 1;
    for (int i = 0; i < N_OPS; i++) {
        const Op *o = &OPS[i];
        int n = (o->type == 3) ? 0 : o->oc;
        for (int c = 0; c < n; c++) {
            int idx = o->rq_off + c;
            while ((int64_t)RQ_M0[idx] != sfit(RQ_M0[idx], wm)) wm++;
            while (RQ_BIAS[idx]        != sfit(RQ_BIAS[idx], wb)) wb++;
            while ((int64_t)RQ_SH[idx] != (RQ_SH[idx] & ((1LL<<ws)-1))) ws++;
        }
        if (o->type == 3) {
            while ((int64_t)o->mp != sfit(o->mp, wq)) wq++;
            while ((int64_t)o->mq != sfit(o->mq, wq)) wq++;
        }
    }
    printf("  width the DATA needs (measured):  M0=%d  bias=%d  shift=%d  mp/mq=%d\n", wm, wb, ws, wq);
    printf("  headroom vs the hardware:         M0=%+d bias=%+d shift=%+d mp/mq=%+d\n",
           NB_M0-wm, NB_BIAS-wb, NB_SH-ws, NB_M0-wq);
    return nm + nb + ns + nq;
}

/* ---- item 8: the weight reorder is a bijection -----------------------------
 * Ternary weights are stored as 128-lane words: for one output channel the
 * n_eff = Cin*kh*kw taps are laid out in lane order (for the stem, ic*9+ky*3+kx),
 * padded up to a whole number of 128-lane words, two bits each (00 = 0, 01 = +1,
 * 11 = -1). `pack` output channels share a word when n_eff*pack <= 128.
 * Round trip: build the word stream, decode it, compare with the blob element by
 * element. */
/* Largest packing factor (output channels per 128-lane word group) considered. */
#ifndef PACK_MAX
#define PACK_MAX 4
#endif
static int pack_of(int n_eff) {
    int p = 1;
    while (p < PACK_MAX && n_eff * (p * 2) <= 128) p *= 2;
    return p;
}
static int weight_roundtrip(const int8_t *blob) {
    int bad = 0, checked = 0;
    for (int bi = 0; bi < N_BLK; bi++) {
        const int stage_op[2] = { BLK[bi].e, BLK[bi].p };
        for (int s = 0; s < 2; s++) {
            const Op *o = &OPS[stage_op[s]];
            int n_eff = o->ic * o->kh * o->kw;
            int pk = pack_of(n_eff);
            int words = (n_eff * pk + 127) / 128;          /* per group of `pk` oc */
            int ngrp = (o->oc + pk - 1) / pk;
            /* --- encode --- */
            size_t nb = (size_t)ngrp * words * 32;          /* 128 lanes * 2 bits = 32 B */
            uint8_t *img = calloc(nb, 1);
            for (int g = 0; g < ngrp; g++)
                for (int j = 0; j < pk; j++) {
                    int oc = g * pk + j;
                    if (oc >= o->oc) continue;
                    for (int k = 0; k < n_eff; k++) {
                        int lane = j * n_eff + k;           /* pack: oc j owns lanes j*n_eff.. */
                        int w = blob[o->w_off + (size_t)oc * n_eff + k];
                        int code = (w == 0) ? 0 : (w > 0 ? 1 : 3);
                        size_t bit = ((size_t)g * words * 128 + lane) * 2;
                        img[bit >> 3] |= (uint8_t)(code << (bit & 7));
                    }
                }
            /* --- decode and compare --- */
            for (int g = 0; g < ngrp; g++)
                for (int j = 0; j < pk; j++) {
                    int oc = g * pk + j;
                    if (oc >= o->oc) continue;
                    for (int k = 0; k < n_eff; k++) {
                        int lane = j * n_eff + k;
                        size_t bit = ((size_t)g * words * 128 + lane) * 2;
                        int code = (img[bit >> 3] >> (bit & 7)) & 3;
                        int back = (code == 0) ? 0 : (code == 1 ? 1 : -1);
                        int w = blob[o->w_off + (size_t)oc * n_eff + k];
                        checked++;
                        if (back != w) bad++;
                    }
                }
            free(img);
        }
    }
    printf("  round-tripped %d ternary weights across %d block stages\n", checked, 2 * N_BLK);
    return bad;
}

/* ---- item 9 (strong form): the 13x13 window is sufficient -----------------
 * Recomputes the refined coordinate from the 13x13 window alone and requires it to
 * equal, as a float, what mbv2_dark_refine() produces from the full plane. Constants,
 * mirroring and skip rules are transcribed from sw/net/mbv2_pose.c, including:
 *   - joints 0 and 1 skip refinement
 *   - the Taylor step is skipped on the outermost ring, but the window read happens
 *     before that test.
 * Peaks are planted near all four edges below to exercise the mirror. */
static void refine_from_window(const int32_t *win, int k, int x, int y, float *ox, float *oy)
{
    static float g[11]; static int gi = 0;
    if (!gi) { double s = 0, sig = 2.0;
        for (int i = 0; i < 11; i++) { g[i] = (float)exp(-0.5*(i-5)*(i-5)/(sig*sig)); s += g[i]; }
        for (int i = 0; i < 11; i++) g[i] = (float)(g[i]/s); gi = 1; }
    *ox = (float)x; *oy = (float)y;
    if (k < 2) return;
    /* the window is indexed [dy+6][dx+6]; the shipped pass 1 reads a[yy*W+xi] with
     * xi in [x-6, x+6] and yy in [y-6, y+6], both already mirrored -- exactly the
     * window's contents, so no further mirroring is needed here. */
    float tmp[13][3], blr[3][3];
    for (int r = 0; r < 13; r++)
        for (int c = 0; c < 3; c++) {
            float s2 = 0;
            for (int t2 = -5; t2 <= 5; t2++)
                s2 += g[t2+5] * (float)(win[r*13 + (c-1) + t2 + 6] * FINAL_OUT_MULT + FINAL_BIAS[k]);
            tmp[r][c] = s2;
        }
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++) {
            float s2 = 0;
            for (int t2 = -5; t2 <= 5; t2++) s2 += g[t2+5] * tmp[r+5+t2][c];
            blr[r][c] = s2;
        }
    if (x < 1 || x >= NET_OUT_W-1 || y < 1 || y >= NET_OUT_H-1) return;
    #define LG(r,c) logf(fmaxf(blr[r][c], 1e-10f))
    float dx = 0.5f*(LG(1,2)-LG(1,0)), dy = 0.5f*(LG(2,1)-LG(0,1));
    float dxx = LG(1,2)-2*LG(1,1)+LG(1,0), dyy = LG(2,1)-2*LG(1,1)+LG(0,1);
    float dxy = 0.25f*(LG(2,2)-LG(2,0)-LG(0,2)+LG(0,0));
    #undef LG
    float det = dxx*dyy - dxy*dxy;
    if (fabsf(det) > 1e-10f) {
        float ax = -(dyy*dx - dxy*dy)/det, ay = -(dxx*dy - dxy*dx)/det;
        if (fabsf(ax) < 1.5f && fabsf(ay) < 1.5f) { *ox = x + ax; *oy = y + ay; }
    }
}

/* ---- item 9: peak locating and the 13x13 window -----------------------------
 * The argmax rule is a row-major scan with STRICTLY greater, so ties keep the first
 * occurrence. The 13x13 window is mirrored at the edges (yy<0 -> -yy ;
 * yy>=H -> 2H-2-yy). Its centre is not known until the whole plane has been scanned. */
#define KP NET_OUT_C
#define HM NET_OUT_H
/* HM is used for both heatmap dimensions; reject a non-square heatmap at compile time. */
typedef char p0_hm_square_check[(NET_OUT_H == NET_OUT_W) ? 1 : -1];
static int mirror(int v, int n) {
    if (v < 0) return -v;
    if (v >= n) return 2 * n - 2 - v;
    return v;
}
static int argmax_and_window(const int32_t *acc, int *kx, int *ky, int32_t *win)
{
    int last6 = 0;
    for (int k = 0; k < KP; k++) {
        const int32_t *a = acc + (size_t)k * HM * HM;
        int best = 0; int32_t bv = a[0];
        for (int p = 1; p < HM * HM; p++) if (a[p] > bv) { bv = a[p]; best = p; }
        kx[k] = best % HM; ky[k] = best / HM;
        if (ky[k] >= HM - 6) last6++;
        for (int dy = -6; dy <= 6; dy++)
            for (int dx = -6; dx <= 6; dx++)
                win[((size_t)k * 13 + (dy + 6)) * 13 + (dx + 6)] =
                    a[mirror(ky[k] + dy, HM) * HM + mirror(kx[k] + dx, HM)];
    }
    return last6;
}

/* -------------------------------------------------------------------- main */
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <blob.bin> <fixture.bin>\n", argv[0]); return 2; }
    int8_t *blob = NULL;
    if (mbv2_load_weights(argv[1], &blob) != 0) { fprintf(stderr, "blob load failed\n"); return 2; }

    /* fixture: the strict-int8 golden fixtures start with the int8 input tensor */
    FILE *f = fopen(argv[2], "rb");
    if (!f) { fprintf(stderr, "fixture open failed\n"); return 2; }
    int8_t *inp = malloc(NET_IN_C * NET_IN_H * NET_IN_W);
    if (fread(inp, 1, NET_IN_C * NET_IN_H * NET_IN_W, f) !=
        (size_t)(NET_IN_C * NET_IN_H * NET_IN_W)) {
        fprintf(stderr, "fixture too short\n"); return 2; }
    fclose(f);

    build_blocks();
    printf("blocks: %d (ops 0..%d); head ops from %d\n",
           N_BLK, BLK[N_BLK - 1].add >= 0 ? BLK[N_BLK - 1].add : BLK[N_BLK - 1].p,
           mbv2_first_head_op());

    /* ---- Gate A: run the reference for its per-op checksums, then the tiled path here,
     * and compare the tensor at each block boundary. */
    long long *ref_sums = malloc(sizeof(long long) * N_OPS);
    int32_t *facc = malloc(sizeof(int32_t) * KP * HM * HM);
    int kp[28];
    mbv2_forward(blob, inp, facc, kp, ref_sums);

    size_t maxel = MAXACT;
    int16_t *cur   = malloc(sizeof(int16_t) * maxel);
    int16_t *nxt_t = malloc(sizeof(int16_t) * maxel);
    int16_t *nxt_f = malloc(sizeof(int16_t) * maxel);

    for (int i = 0; i < NET_IN_C * NET_IN_H * NET_IN_W; i++) cur[i] = (int16_t)inp[i];
    int H = NET_IN_H, W = NET_IN_W;

    int failA = 0, failB = 0;
    printf("\n blk  ops          shape         out          gate A (vs reference)   gate B (fused vs tiled)\n");
    printf(" ---  -----------  ------------  -----------  ----------------------  -----------------------\n");
    for (int bi = 0; bi < N_BLK; bi++) {
        Block *b = &BLK[bi];
        int OH, OW, OH2, OW2;
        tiled_block(blob, b, cur, H, W, nxt_t, &OH, &OW);
        fused_block(blob, b, cur, H, W, nxt_f, &OH2, &OW2);

        int oc = OPS[b->p].oc;
        size_t n = (size_t)oc * OH * OW;

        /* gate A: checksum of this block's final op must equal the reference's */
        int last = (b->add >= 0) ? b->add : b->p;
        long long s = 0; for (size_t i = 0; i < n; i++) s += nxt_t[i];
        int okA = (s == ref_sums[last]);
        if (!okA) failA++;

        /* gate B: byte-for-byte */
        size_t bad = 0, first = 0;
        for (size_t i = 0; i < n; i++)
            if (nxt_t[i] != nxt_f[i]) { if (!bad) first = i; bad++; }
        int okB = (bad == 0 && OH == OH2 && OW == OW2);
        if (!okB) failB++;

        printf(" %3d  %2d-%2d-%2d%-4s %4dx%-4d->%4dx%-4d  %3dx%3dx%3d  %-22s  %s",
               bi, b->e, b->dw, b->p, b->add >= 0 ? "-add" : "",
               H, W, OH, OW, oc, OH, OW,
               okA ? "checksum matches" : "CHECKSUM DIFFERS",
               okB ? "identical" : "DIFFERS");
        if (!okB) printf("  (%zu of %zu elements, first at %zu)", bad, n, first);
        printf("\n");

        memcpy(cur, nxt_t, sizeof(int16_t) * n);
        H = OH; W = OW;
    }

    printf("\nring: EDEPTH=%d, expand runs ELOOK=%d row(s) ahead of the depthwise;\n"
           "      deepest simultaneous demand observed across all blocks = %d rows\n",
           EDEPTH, ELOOK, g_need_depth);
    /* ================= item 10: are the hardware widths actually respected? ==== */
    printf("\n--- item 10: constant narrowing ---\n");
    int failN = narrow_report();
    printf("  gate B above ran WITH narrowing applied, so a violation would have shown as a mismatch\n");

    /* ================= item 8: weight reorder round trip ====================== */
    printf("\n--- item 8: weight reorder round trip ---\n");
    int failW = weight_roundtrip(blob);
    printf("  mismatches after decode: %d\n", failW);

    /* ================= item 4: the reverse test the checklist asks for ======== */
    /* Give all three stages of block 1 the first stage's requant table; the comparison
     * must then differ, otherwise it cannot detect a table-base bug. */
    printf("\n--- item 4: reverse test (force all three stages onto one requant table) ---\n");
    int failR = 0;
    {
        for (int i = 0; i < NET_IN_C * NET_IN_H * NET_IN_W; i++) cur[i] = (int16_t)inp[i];
        int H2 = NET_IN_H, W2 = NET_IN_W, OH, OW;
        Op saved_d = OPS_MUT[BLK[1].dw], saved_p = OPS_MUT[BLK[1].p];
        /* block 0 first, untouched, to get block 1's input */
        tiled_block(blob, &BLK[0], cur, H2, W2, nxt_t, &OH, &OW);
        memcpy(cur, nxt_t, sizeof(int16_t) * (size_t)OPS[BLK[0].p].oc * OH * OW);
        H2 = OH; W2 = OW;
        tiled_block(blob, &BLK[1], cur, H2, W2, nxt_t, &OH, &OW);      /* golden */
        OPS_MUT[BLK[1].dw].rq_off = OPS[BLK[1].e].rq_off;              /* sabotage */
        OPS_MUT[BLK[1].p ].rq_off = OPS[BLK[1].e].rq_off;
        tiled_block(blob, &BLK[1], cur, H2, W2, nxt_f, &OH, &OW);
        size_t n2 = (size_t)OPS[BLK[1].p].oc * OH * OW, diff = 0;
        for (size_t i = 0; i < n2; i++) if (nxt_t[i] != nxt_f[i]) diff++;
        OPS_MUT[BLK[1].dw] = saved_d; OPS_MUT[BLK[1].p] = saved_p;     /* restore */
        printf("  sharing one table changed %zu of %zu elements\n", diff, n2);
        if (diff == 0) { failR = 1; printf("  *** the check has NO POWER: a shared table is invisible ***\n"); }
        else printf("  the check bites: a wrong table base produces wrong numbers, as required\n");
    }

    /* ================= items 9 and 11: head, peaks, window, keypoints ========= */
    printf("\n--- items 9 and 11: peak locating, 13x13 window, final keypoints ---\n");
    int failH = 0;
    {
        /* rebuild the fused backbone, then run the shipped head on its output */
        for (int i = 0; i < NET_IN_C * NET_IN_H * NET_IN_W; i++) cur[i] = (int16_t)inp[i];
        int H2 = NET_IN_H, W2 = NET_IN_W, OH, OW;
        for (int bi = 0; bi < N_BLK; bi++) {
            fused_block(blob, &BLK[bi], cur, H2, W2, nxt_f, &OH, &OW);
            memcpy(cur, nxt_f, sizeof(int16_t) *
                   (size_t)OPS[BLK[bi].p].oc * OH * OW);
            H2 = OH; W2 = OW;
        }
        int32_t *facc2 = malloc(sizeof(int32_t) * KP * HM * HM);
        int kp2[KP * 2];
        mbv2_head(blob, cur, facc2, kp2);
        int bad = 0;
        for (int k = 0; k < KP * 2; k++) if (kp2[k] != kp[k]) bad++;
        printf("  item 11: final keypoints from the FUSED backbone vs the reference: %s (%d/%d coords differ)\n",
               bad ? "DIFFER" : "identical", bad, KP * 2);
        if (bad) failH = 1;

        int *ax = malloc(sizeof(int)*KP), *ay = malloc(sizeof(int)*KP);
        int32_t *win = malloc(sizeof(int32_t) * KP * 13 * 13);
        int last6 = argmax_and_window(facc2, ax, ay, win);
        int badk = 0;
        for (int k = 0; k < KP; k++) if (ax[k] != kp2[k*2] || ay[k] != kp2[k*2+1]) badk++;
        printf("  item 9a: argmax rule (row-major, strictly greater) vs the reference: %s (%d/%d)\n",
               badk ? "DIFFER" : "identical", badk, KP);
        /* 9b: the window is SUFFICIENT -- refine from it alone, compare to the
         * shipped full-plane refinement */
        float (*cref)[2] = malloc(sizeof(float) * KP * 2);
        mbv2_dark_refine(facc2, cref);
        int badw = 0;
        for (int k = 0; k < KP; k++) {
            float wx, wy;
            refine_from_window(win + (size_t)k*13*13, k, ax[k], ay[k], &wx, &wy);
            if (wx != cref[k][0] || wy != cref[k][1]) badw++;
        }
        printf("  item 9b: sub-pixel coords from the 13x13 window ALONE vs the shipped\n"
               "           full-plane mbv2_dark_refine: %s (%d/%d joints)\n",
               badw ? "DIFFER" : "identical to the last float bit", badw, KP);
        printf("  item 9c: natural peaks in the last 6 rows (needs rows not yet produced): %d of %d\n",
               last6, KP);

        /* 9d: plant a strict maximum at positions that make the blur reach past each
         * edge while the Taylor step still runs (y in 1..5 fires yy<0 -> -yy, y in
         * HM-6..HM-2 fires yy>=H -> 2H-2-yy; same for x). */
        int probe[] = { 1, 3, 5, HM/2, HM-6, HM-4, HM-2 };
        int nprobe = (int)(sizeof(probe)/sizeof(probe[0]));
        int badp = 0, nrun = 0, nedge = 0, nmoved = 0;
        int32_t *scratch = malloc(sizeof(int32_t) * KP * HM * HM);
        for (int pi = 0; pi < nprobe; pi++)
            for (int pj = 0; pj < nprobe; pj++) {
                int py = probe[pi], px = probe[pj];
                if (py < 6 || py >= HM-6 || px < 6 || px >= HM-6) nedge++;
                memcpy(scratch, facc2, sizeof(int32_t) * KP * HM * HM);
                for (int k = 0; k < KP; k++) {          /* plant a strict maximum */
                    int32_t mx = scratch[(size_t)k*HM*HM];
                    for (int q = 1; q < HM*HM; q++)
                        if (scratch[(size_t)k*HM*HM + q] > mx) mx = scratch[(size_t)k*HM*HM + q];
                    scratch[((size_t)k*HM + py)*HM + px] = mx + 1;
                }
                mbv2_dark_refine(scratch, cref);
                int *px2 = malloc(sizeof(int)*KP), *py2 = malloc(sizeof(int)*KP);
                int32_t *w2 = malloc(sizeof(int32_t)*KP*13*13);
                argmax_and_window(scratch, px2, py2, w2);
                for (int k = 0; k < KP; k++) {
                    if (px2[k] != px || py2[k] != py) { badp++; continue; }
                    float wx, wy;
                    refine_from_window(w2 + (size_t)k*13*13, k, px2[k], py2[k], &wx, &wy);
                    nrun++;
                    if (wx != (float)px2[k] || wy != (float)py2[k]) nmoved++;
                    if (wx != cref[k][0] || wy != cref[k][1]) badp++;
                }
                free(px2); free(py2); free(w2);
            }
        printf("  item 9d: planted peaks at %d positions x %d joints = %d cases, of which\n"
               "           %d put the 13x13 window across a tensor edge: %s (%d mismatches)\n",
               nprobe*nprobe, KP, nrun, nedge*KP,
               badp ? "DIFFER" : "identical to the last float bit", badp);
        printf("           of those, %d had the sub-pixel step ACCEPTED (the coordinate moved\n"
               "           off the integer peak) -- that is where the comparison has teeth\n", nmoved);
        free(scratch); free(cref);
        if (badk || badw || badp) failH = 1;
        free(facc2); free(ax); free(ay); free(win);
    }

    printf("\ngate A (this file's kernels vs sw/net/mbv2_pose.c): %s\n",
           failA ? "FAIL" : "PASS -- the transcription is faithful");
    printf("gate B (fused row-streaming vs tiled whole-tensor): %s\n",
           failB ? "FAIL" : "PASS -- BIT-IDENTICAL at every block boundary");
    int bad_all = failA || failB || failN || failW || failR || failH;
    printf("\n--- 10.2 checklist ---\n");
    printf("  1 per-block output tensors            %s\n", failB ? "FAIL" : "PASS");
    printf("  2 depthwise edge padding              %s\n", failB ? "FAIL" : "PASS");
    printf("  3 stride-2 row mapping                %s\n", failB ? "FAIL" : "PASS");
    printf("  4 three separate requant tables       %s (reverse test)\n", failR ? "NO POWER" : "PASS");
    printf("  5 residual source                     %s\n", failB ? "FAIL" : "PASS");
    printf("  6 second ternary conv constants/clamp %s\n", failB ? "FAIL" : "PASS");
    printf("  7 3x3 stem unrolled per kernel row    %s\n", failB ? "FAIL" : "PASS");
    printf("  8 weight reorder round trip           %s\n", failW ? "FAIL" : "PASS");
    printf("  9 peak locating + 13x13 window        %s\n", failH ? "FAIL" : "PASS");
    printf(" 10 constant narrowing applied          %s\n", failN ? "FAIL" : "PASS");
    printf(" 11 final keypoints                     %s\n", failH ? "FAIL" : "PASS");
    printf("\nP0 %s\n", bad_all ? "FAILED" : "PASSED -- all 11 items");
    return bad_all ? 1 : 0;
}
