/* ============================================================================
 *  mbv2_ps.c -- PS-side frame orchestrator: the 65-operator PL backbone, the
 *  stem im2col, and the NEON head. The fused app links it only for
 *  mbv2_ps_head().
 *
 *  Per frame:
 *    1. im2col the stem input (3 ch -> 27 ch at half resolution) into the arena
 *    2. run backbone ops [0 .. first_head) on the PL via pl_run_layer()
 *    3. run the deconv head + final + arg-max on the PS/NEON (mbv2_head*)
 *
 *  All PL-touched buffers (weights, requant tables, activations, im2col) live
 *  in one DDR arena from pl_arena_init(): on the board a contiguous reserved
 *  region the PL reads by physical address. Descriptors carry physical
 *  addresses (arena phys + offset); the head reads the arena's virtual side.
 *
 *  Environment: PS_TIMING, OP_TIMING, OP_CKSUM, BB_DUMP (diagnostics),
 *  HEAD_NHWC, HEAD_PL, HEAD_U8, TENSOR8, IMCOL_BOUNCE, IMCOL_CHUNK_KB,
 *  CHASER_OFF, CHASER_ON, HD_OLDW.
 * ========================================================================== */
#include "mbv2_ps.h"
#include "pl_hal.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#ifdef __linux__
#include <sched.h>              /* sched_yield for the chunked imcol copy (board only) */
#include <unistd.h>             /* usleep, for the BB_DUMP settle loop */
#else
static void sched_yield(void) {}   /* host twin: single-threaded, nothing to yield to */
static void usleep(unsigned u) { (void)u; }   /* twin: nothing in flight to wait for */
#endif
#include "model_meta.h"
#include "mbv2_pose.h"
#include "pack_meta_mbv2.h"

/* PS_TIMING=1 prints a per-frame time breakdown (board only).
 * HEAD_NHWC (default 1): the head works on the NHWC boundary tensor directly,
 * with no CHW transpose; HEAD_NHWC=0 selects the CHW head (mbv2_head / HEAD_U8). */
static int ps_head_nhwc(void) {
    static int m = -1;
    if (m < 0) { const char *e = getenv("HEAD_NHWC"); m = e ? atoi(e) : 1; }
    return m;
}
/* BB_DUMP helper. A CPU read taken right after ap_done may not see the
 * accelerator's settled output (posted writes still draining), so read, wait,
 * and read again until two consecutive reads are identical; the retry count is
 * printed. */
static void dump_settled(const char *nm, const void *p, size_t n) {
    unsigned char *a = (unsigned char *)malloc(n), *b = (unsigned char *)malloc(n);
    int tries = 0;
    if (!a || !b) { free(a); free(b); return; }
    memcpy(a, p, n);
    while (tries < 50) {
        usleep(2000);
        memcpy(b, p, n);
        if (!memcmp(a, b, n)) break;
        memcpy(a, b, n);
        tries++;
    }
    FILE *f = fopen(nm, "wb");
    if (f) { fwrite(a, 1, n, f); fclose(f); }
    fprintf(stderr, "[dump] %s %zu B settled after %d retries%c", nm, n, tries, 10);
    free(a); free(b);
}

/* HEAD_PL=1 (default 0) routes the head (3 deconvs + final 1x1) through PL
 * descriptors; the final op's NHWC int32 accumulator is converted to the CHW
 * final_acc contract afterwards. */
static int ps_head_pl(void) {
    static int m = -1;
    if (m < 0) { const char *e = getenv("HEAD_PL"); m = e ? atoi(e) : 0; }
    return m;
}

static double ps_now_ms(void){
#ifdef __linux__
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
#else
    return 0;
#endif
}

#define NBUF 4
#define W2ROM_BYTES (W2_AL + W2HW_BYTES)
#define ALIGN64(x) (((x) + 63) & ~((uint64_t)63))
#define IMCOL_C 32                 /* NHWC stem: 27 im2col channels padded to a multiple of 8 */

static uint8_t  *AR;                 /* arena CPU base */
static uint64_t  ARP;                /* arena physical base */
static int       g_init = 0;
static const int8_t *g_head_blob;    /* CPU/NEON head weights (not PL-touched) */
/* cached PS scratch, so the compute-heavy PS steps (im2col, head) do not run on
   the uncached PL arena */
static int16_t *g_in_cached2[2] = {NULL, NULL}, *g_bb_cached = NULL;   /* double-buffered for prep-ahead */
/* Per-tensor int8 DDR policy. An op's output ships as int8 iff it is type 0, 1
 * or 3 with oc % 16 == 0 and is not the last backbone output (kept int16 for
 * the NEON head unless HEAD_PL); with HEAD_PL the head's type-2 outputs are int8
 * too. TENSOR8=0 disables the whole policy. */
static int     g_t8 = -1;
static uint8_t g_op_out8[N_OPS];
static uint8_t g_fmt8[NBUF];
/* byte offsets into the arena */
static uint64_t o_w2, o_w8, o_m0, o_bias, o_sh, o_act[NBUF], o_imcol[2];  /* imcol double-buffered */
/* HEAD_PL: the final 1x1's int32 output has its own per-slot arena buffers,
 * outside the activation ring, so frame k's output survives frame k+1 and a
 * later pipeline stage can drain it. */
static uint64_t o_fin[2];
static int g_fin_C, g_fin_H, g_fin_W;
static int      g_C[NBUF], g_H[NBUF], g_W[NBUF];

static int n_rq_entries(void) {         /* requant-table length = max(rq_off + oc) */
    int m = 0;
    for (int i = 0; i < N_OPS; i++) { int e = OPS[i].rq_off + OPS[i].oc; if (e > m) m = e; }
    return m;
}

/* One-time: build the arena, copy weights + requant tables into it. head_blob stays CPU-side.
 * w2rom/w8rom = data/model_mbv2_packed.bin sections; head_blob = data/model_mbv2.bin. */
void mbv2_ps_init(const uint8_t *w2rom, const int8_t *w8rom, const int8_t *head_blob) {
    int nrq = n_rq_entries();
    uint64_t sz = 0;
    o_w2   = sz; sz = ALIGN64(sz + W2ROM_BYTES);
    o_w8   = sz; sz = ALIGN64(sz + W8_BYTES);
    o_m0   = sz; sz = ALIGN64(sz + (uint64_t)nrq * 4);
    o_bias = sz; sz = ALIGN64(sz + (uint64_t)nrq * 8);
    o_sh   = sz; sz = ALIGN64(sz + (uint64_t)nrq * 1);
    for (int b = 0; b < NBUF; b++) { o_act[b] = sz; sz = ALIGN64(sz + (uint64_t)MAXACT * 2); }
    o_imcol[0] = sz; sz = ALIGN64(sz + (uint64_t)MAXACT * 2);
    o_imcol[1] = sz; sz = ALIGN64(sz + (uint64_t)MAXACT * 2);   /* 2nd imcol buffer */
    o_fin[0] = sz; sz = ALIGN64(sz + (uint64_t)MAXACT * 2);      /* HEAD_PL final output, slot 0 */
    o_fin[1] = sz; sz = ALIGN64(sz + (uint64_t)MAXACT * 2);      /* HEAD_PL final output, slot 1 */

    AR = (uint8_t *)pl_arena_init(&ARP, sz);
    memcpy(AR + o_w2,   w2rom,   W2ROM_BYTES);
    memcpy(AR + o_w8,   w8rom,   W8_BYTES);
    memcpy(AR + o_m0,   RQ_M0,   (size_t)nrq * 4);
    memcpy(AR + o_bias, RQ_BIAS, (size_t)nrq * 8);
    memcpy(AR + o_sh,   RQ_SH,   (size_t)nrq * 1);
    g_head_blob = head_blob;
    /* the PL multiplies the low 18 bits of each requant multiplier: refuse a
     * constant outside signed 18 bits at load rather than truncate on silicon */
    for (int i = 0; i < nrq; i++) {
        int32_t v = RQ_M0[i];
        if (v >= (1 << 17) || v < -(1 << 17)) {
            fprintf(stderr, "FATAL: RQ_M0[%d]=%d exceeds the signed-18-bit requant contract\n", i, v);
            exit(1);
        }
    }
    /* the PL bias table lanes are 40 bits: refuse wider values at load */
    for (int i = 0; i < nrq; i++) {
        int64_t b = RQ_BIAS[i];
        if (b >= ((int64_t)1 << 39) || b < -((int64_t)1 << 39)) {
            fprintf(stderr, "FATAL: RQ_BIAS[%d]=%lld exceeds the signed-40-bit table-lane contract\n",
                    i, (long long)b);
            exit(1);
        }
    }
    for (int i = 0; i < N_OPS; i++) {
        if (OPS[i].type != 3) continue;
        if (OPS[i].mp >= (1<<17) || OPS[i].mp < -(1<<17) ||
            OPS[i].mq >= (1<<17) || OPS[i].mq < -(1<<17)) {
            fprintf(stderr, "FATAL: op %d add mp/mq (%d,%d) exceed the signed-18-bit contract\n",
                    i, OPS[i].mp, OPS[i].mq);
            exit(1);
        }
    }
#ifdef W2_LANES
    /* The pack class derived from the input channel count (effic <= 32 -> 2,
     * <= 64 -> 1, else 0) must match W2_PACK from tools/pack_ternary.py;
     * W2_PACK_LAYOUT is the blob's generation. Refuse a mismatch at startup. */
#ifndef W2_PACK_LAYOUT
#error "pack_meta_mbv2.h predates the tri-class layout -- regenerate with tools/pack_ternary.py"
#endif
    for (int i = 0; i < N_OPS; i++) {
        if (OPS[i].type != 0) continue;
        int effic = (OPS[i].kh == 3) ? IMCOL_C : OPS[i].ic;   /* stem runs as im2col'd 1x1 */
        int want = (effic <= 32) ? 2 : (effic <= 64) ? 1 : 0;
        if (W2_PACK[i] != want) {
            fprintf(stderr, "FATAL: pack-class drift at op %d: blob says %d, RTL criterion says %d "
                            "(effic=%d). Regenerate data/model_mbv2_packed.bin + pack_meta.\n",
                    i, W2_PACK[i], want, effic);
            exit(1);
        }
    }
#endif
    {
        const char *e = getenv("TENSOR8");
        g_t8 = e ? atoi(e) : 1;
        int fd = mbv2_first_head_op();
        /* the PL head reads and writes int8, so it requires the int8 policy */
        if (ps_head_pl() && !g_t8) {
            fprintf(stderr, "FATAL: HEAD_PL=1 requires the int8 tensor policy (TENSOR8=1)\n");
            exit(1);
        }
        for (int i = 0; i < N_OPS; i++) {
            g_op_out8[i] = 0;
            if (!g_t8) continue;
            if (i >= fd) {                             /* head ops: PL deconvs emit int8 */
                if (ps_head_pl() && OPS[i].type == 2) g_op_out8[i] = 1;
                continue;
            }
            if (OPS[i].type != 0 && OPS[i].type != 1 && OPS[i].type != 3) continue;
            if (OPS[i].oc % 16 != 0) continue;
            /* the seam (the last backbone op) stays int16 for the NEON head and
             * is int8 when the head is in the PL */
            if (i == fd - 1 && !ps_head_pl()) continue;
            g_op_out8[i] = 1;
        }
        {   /* log which op outputs ship as int8 */
            int n8 = 0; for (int i = 0; i < N_OPS; i++) n8 += g_op_out8[i];
            fprintf(stderr, "[tensor8] policy=%d imcol=int%d, %d op outputs int8:", g_t8, g_t8 ? 8 : 16, n8);
            for (int i = 0; i < N_OPS; i++) if (g_op_out8[i]) fprintf(stderr, " %d", i);
            fprintf(stderr, "%s", g_t8 ? "" : " (killed by TENSOR8=0)");
            fprintf(stderr, "%c", 10);
        }
    }
    g_init = 1;
}

static int16_t *actv(int b) { return (int16_t *)(AR + o_act[b]); }      /* virtual */
static uint64_t actp(int b) { return ARP + o_act[b]; }                  /* physical */

/* stem 3x3 s2 p1 as NHWC im2col into the arena imcol buffer (channel-last,
 * IMCOL_C ch, (IN/2)x(IN/2)). Channel c = ic*9 + ky*3 + kx holds input[ic]
 * shifted by (ky,kx) and subsampled by 2; channels 27..IMCOL_C-1 are zero
 * (their weights are 0). Geometry is derived from NET_IN_H/W. */

/* Legacy path (IMCOL_BOUNCE=0): write straight into the uncached arena. */
static void im2col_stem_arena(const int16_t *in, int slot) {
    const int IH = NET_IN_H, IW = NET_IN_W;
    const int OH = IH / 2, OW = IW / 2;              /* 3x3 stride-2 pad-1 */
    if (g_t8) {                                      /* the imcol tensor ships as int8 */
        int8_t *db = (int8_t *)(AR + o_imcol[slot]);
        for (int oy = 0; oy < OH; oy++)
            for (int ox = 0; ox < OW; ox++) {
                int8_t *dst = db + ((size_t)oy * OW + ox) * IMCOL_C;
                for (int c = 27; c < IMCOL_C; c++) dst[c] = 0;
                for (int ic = 0; ic < 3; ic++)
                    for (int ky = 0; ky < 3; ky++)
                        for (int kx = 0; kx < 3; kx++) {
                            int iy = oy * 2 - 1 + ky, ix = ox * 2 - 1 + kx;
                            dst[ic * 9 + ky * 3 + kx] =
                                (iy >= 0 && iy < IH && ix >= 0 && ix < IW)
                                    ? (int8_t)in[ic * IH * IW + iy * IW + ix] : (int8_t)0;
                        }
            }
        return;
    }
    int16_t *dst0 = (int16_t *)(AR + o_imcol[slot]);
    /* no memset on the arena: glibc memset uses `dc zva`, which faults on
     * uncached device memory; zero only the padding channels */
    for (int oy = 0; oy < OH; oy++)
        for (int ox = 0; ox < OW; ox++) {
            int16_t *dst = dst0 + ((size_t)oy * OW + ox) * IMCOL_C;
            for (int c = 27; c < IMCOL_C; c++) dst[c] = (int16_t)0;
            for (int ic = 0; ic < 3; ic++)
                for (int ky = 0; ky < 3; ky++)
                    for (int kx = 0; kx < 3; kx++) {
                        int iy = oy * 2 - 1 + ky, ix = ox * 2 - 1 + kx;
                        dst[ic * 9 + ky * 3 + kx] =
                            (iy >= 0 && iy < IH && ix >= 0 && ix < IW)
                                ? in[ic * IH * IW + iy * IW + ix] : (int16_t)0;
                    }
        }
}

/* Bounce path (default): build the tile in cached memory, then copy it into the
 * arena in one pass. memset zeroes the pad channels and every out-of-bounds tap,
 * and the boundary tests collapse: iy is out of range only at (oy=0,ky=0) and ix
 * only at (ox=0,kx=0) for any even IW, so the hot loop is branch-free. */
static int16_t *g_imcol_bounce = NULL;
static void im2col_stem(const int16_t *in, int slot) {
    static int bounce = -1;
    /* IMCOL_BOUNCE=0 selects the legacy arena-direct path (default 1) */
    if (bounce < 0) { const char *e = getenv("IMCOL_BOUNCE"); bounce = e ? atoi(e) : 1; }
    if (!bounce) { im2col_stem_arena(in, slot); return; }
    const int IH = NET_IN_H, IW = NET_IN_W;
    const int OH = IH / 2, OW = IW / 2;
    const size_t bytes = (size_t)OH * OW * IMCOL_C * (g_t8 ? 1 : 2);
    if (!g_imcol_bounce) g_imcol_bounce = (int16_t *)malloc((size_t)OH * OW * IMCOL_C * 2);
    int16_t *dst0 = g_imcol_bounce;
    int8_t  *dst8 = (int8_t *)g_imcol_bounce;
    memset(dst0, 0, bytes);
    for (int oy = 0; oy < OH; oy++) {
        int16_t *dpix = dst0 + (size_t)oy * OW * IMCOL_C;
        for (int ic = 0; ic < 3; ic++) {
            const int16_t *pin = in + (size_t)ic * IH * IW;
            for (int ky = 0; ky < 3; ky++) {
                int iy = oy * 2 - 1 + ky;
                if (iy < 0) continue;                     /* only (oy=0,ky=0); iy<IH always */
                const int16_t *row = pin + (size_t)iy * IW;
                if (g_t8) {
                    int8_t *d = dst8 + (size_t)oy * OW * IMCOL_C + ic * 9 + ky * 3;
                    d[1] = (int8_t)row[0]; d[2] = (int8_t)row[1]; d += IMCOL_C;
                    for (int ox = 1; ox < OW; ox++) {
                        const int16_t *sp = row + ox * 2 - 1;
                        d[0] = (int8_t)sp[0]; d[1] = (int8_t)sp[1]; d[2] = (int8_t)sp[2];
                        d += IMCOL_C;
                    }
                } else {
                int16_t *d = dpix + ic * 9 + ky * 3;
                d[1] = row[0];                            /* ox=0: kx=1,2 in bounds, kx=0 pad */
                d[2] = row[1];
                d += IMCOL_C;
                for (int ox = 1; ox < OW; ox++) {         /* branch-free interior */
                    const int16_t *s = row + ox * 2 - 1;
                    d[0] = s[0]; d[1] = s[1]; d[2] = s[2];
                    d += IMCOL_C;
                }
                }
            }
        }
    }
    /* copy in chunks with a sched_yield between them; IMCOL_CHUNK_KB sets the
     * chunk size (default 64), 0 selects the one-shot copy */
    static long ck = -1;
    if (ck < 0) { const char *e = getenv("IMCOL_CHUNK_KB"); ck = e ? atol(e) * 1024 : 64 * 1024; }
    if (ck <= 0) { memcpy(AR + o_imcol[slot], dst0, bytes); return; }
    for (size_t off = 0; off < bytes; off += (size_t)ck) {
        size_t n = bytes - off < (size_t)ck ? bytes - off : (size_t)ck;
        memcpy(AR + o_imcol[slot] + off, (uint8_t *)dst0 + off, n);
        sched_yield();
    }
}

/* --- Split into PREP (convert + im2col, double-buffered) and PLRUN (PL ops +
 * boundary copy) so a pipeline can run PREP(frame N+1) during PL(frame N). PREP
 * touches only g_in_cached2[slot] and o_imcol[slot], so it does not race
 * PLRUN. */

/* PREP stage: int8->int16 convert + im2col(stem) into double-buffered slot {0,1}. */
void mbv2_ps_prep(const uint8_t *w2rom, const int8_t *w8rom, const int8_t *head_blob,
                  const int8_t *input_i8, int slot) {
    if (!g_init) mbv2_ps_init(w2rom, w8rom, head_blob);
    int tim = getenv("PS_TIMING") != NULL;
    double t0 = tim ? ps_now_ms() : 0;
    int16_t *inc = g_in_cached2[slot];
    if (!inc) inc = g_in_cached2[slot] = (int16_t *)malloc((size_t)NET_IN_C * NET_IN_H * NET_IN_W * 2);
    for (int i = 0; i < NET_IN_C * NET_IN_H * NET_IN_W; i++) inc[i] = (int16_t)input_i8[i];
    double t_c = tim ? ps_now_ms() : 0;
    im2col_stem(inc, slot);
    if (tim) fprintf(stderr, "[ps_timing] prep(convert=%.1f  im2col=%.1f) ms\n", t_c - t0, ps_now_ms() - t_c);
}

/* PL stage: backbone ops [0..first_head) (the stem reads the precomputed
 * o_imcol[slot]), then the boundary tensor into bb_out. Run one at a time: it
 * uses the shared o_act[] arena and g_C/H/W state. */
void mbv2_ps_plrun(int slot, int16_t *bb_out) {
    int fd = mbv2_first_head_op();
    int lastop = ps_head_pl() ? N_OPS : fd;        /* HEAD_PL: the PL runs the head too */
    int tim = getenv("PS_TIMING") != NULL;
    int oprof = getenv("OP_TIMING") != NULL;
    double t0 = tim ? ps_now_ms() : 0, t_pl = 0;
    g_C[0] = NET_IN_C; g_H[0] = NET_IN_H; g_W[0] = NET_IN_W;

    for (int b = 0; b < NBUF; b++) g_fmt8[b] = 0;   /* frame start: all tensors int16 */
    for (int oi = 0; oi < lastop; oi++) {
        const Op *op = &OPS[oi];
        int H = g_H[op->in_buf], W = g_W[op->in_buf];
        pl_desc_t d; memset(&d, 0, sizeof d);
        d.type = op->type; d.oc = op->oc; d.kh = op->kh; d.stride = op->stride; d.pad = op->pad;
        d.rq_off = op->rq_off; d.relu = op->relu; d.lo = op->lo; d.hi = op->hi;
        d.mp = op->mp; d.mq = op->mq; d.sh = op->sh;
        d.w2_pa = ARP + o_w2; d.w8_pa = ARP + o_w8;
        d.m0_pa = ARP + o_m0; d.bias_pa = ARP + o_bias; d.sh_pa = ARP + o_sh;
        int oub = (op->out_buf >= 0) ? op->out_buf : 2;   /* the final op has no ring buffer */
        d.out_pa = actp(oub);
        int fin_op = ps_head_pl() && (oi == N_OPS - 1);
        if (fin_op) d.out_pa = ARP + o_fin[slot & 1];     /* private slot, survives the next frame */
        d.w2_off = (op->type == 0) ? (int)(W2_AL + W2HW_OFF[oi]) : (int)W2_OFF[oi];
        d.w8_off = (int)W8_OFF[oi];
#ifdef HD_PL
        /* the PL head streams the repacked hd_pl section (slice order for the
         * deconvs, [16][IC] zero-padded for the final: the engine emits OC/4
         * beats, so the final's int32 output lands at stride 16) */
        if (ps_head_pl() && (op->type == 2 || op->type == 4)) {
            static const long hd_off[] = { HD_PL_OFF_LIST };  /* indexed [oi - fd] */
            static int oldw = -1;   /* HD_OLDW=1: keep the deconvs' old weight offsets */
            if (oldw < 0) { const char *e2 = getenv("HD_OLDW"); oldw = e2 ? atoi(e2) : 0; }
            if (!(oldw && op->type == 2)) d.w8_off = (int)hd_off[oi - fd];
            if (op->type == 4) d.oc = 16;
        }
#endif

        /* Store-chaser selection. r_mp is a don't-care for pointwise ops, so
         * 0xDEADBEEF tells the RTL to use the serial store for this op. Default:
         * the chaser is on for every op. CHASER_OFF=1 selects the serial store
         * everywhere; CHASER_ON=lo-hi (or n) chases only that op range. */
        if (op->type == 0) {
            static int init = 0, lo = 0, hi = (1 << 30);   /* default: chased everywhere */
            if (!init) { init = 1;
                const char *off = getenv("CHASER_OFF");
                if (off && atoi(off)) { lo = 1; hi = 0; }  /* empty range => off everywhere */
                else {
                    const char *e = getenv("CHASER_ON");
                    if (e && *e && sscanf(e, "%d-%d", &lo, &hi) != 2) { lo = hi = atoi(e); }
                }
            }
            if (!(oi >= lo && oi <= hi)) d.mp = (int)0xDEADBEEF;
        }
        if (op->type == 0 && op->kh == 3) {          /* stem: im2col already computed in PREP */
            d.ic = IMCOL_C; d.h = NET_IN_H / 2; d.w = NET_IN_W / 2; d.kh = 1; d.stride = 1; d.pad = 0;
            d.in_pa = ARP + o_imcol[slot]; d.in2_pa = ARP + o_imcol[slot];
        } else {
            d.ic = op->ic; d.h = H; d.w = W;
            d.in_pa  = actp(op->in_buf);
            d.in2_pa = actp((op->type == 3) ? op->in2_buf : op->in_buf);
        }
        /* per-tensor int8 flags (b0 input, b1 second input, b2 output): the
         * stem's input follows the policy switch, everything else follows the
         * format its producer chose */
        {
            int in8  = (op->type == 0 && op->kh == 3) ? g_t8 : g_fmt8[op->in_buf];
            int in28 = (op->in2_buf >= 0) ? g_fmt8[op->in2_buf] : 0;
            int out8 = g_op_out8[oi];
            d.w8fmt = (in8 ? 1 : 0) | (in28 ? 2 : 0) | (out8 ? 4 : 0);
        }
        { int _t = tim || oprof; double s = _t ? ps_now_ms() : 0; pl_run_layer(&d); double e = _t ? ps_now_ms() : 0;
          if (tim) t_pl += e - s;
          if (oprof) fprintf(stderr, "  PLop %2d type=%d ic=%d oc=%d %dx%d  %.2f ms\n", oi, op->type, d.ic, op->oc, d.h, d.w, e - s); }

        if (op->type == 3) { g_C[oub] = g_C[op->in_buf]; g_H[oub] = H; g_W[oub] = W; }
        else if (op->type == 2) {                       /* transposed conv upsamples 2x */
            g_C[oub] = op->oc; g_H[oub] = H * 2; g_W[oub] = W * 2;
        }
        else {
            int num = H + 2 * op->pad - op->kh;
            int OH = (op->stride == 1) ? num + 1 : (num >> 1) + 1;
            num = W + 2 * op->pad - op->kh;
            int OW = (op->stride == 1) ? num + 1 : (num >> 1) + 1;
            g_C[oub] = op->oc; g_H[oub] = OH; g_W[oub] = OW;
        }
        g_fmt8[oub] = g_op_out8[oi];                    /* record the produced format */
        if (fin_op) { g_fin_C = g_C[oub]; g_fin_H = g_H[oub]; g_fin_W = g_W[oub]; }
        /* BB_DUMP: raw-byte dump of every head-boundary tensor after its
         * producer ran. The file name carries the op index and element width;
         * type 4 writes the padded channel stride (16) under HEAD_PL. */
        if (oi >= fd - 1 && getenv("BB_DUMP")) {
            int w = (op->type == 4) ? 4 : (g_fmt8[oub] ? 1 : 2);
            int cs = (op->type == 4 && ps_head_pl()) ? 16 : g_C[oub];
            char nm[32];
            snprintf(nm, sizeof nm, "op%02d_i%d.bin", oi, w * 8);
            dump_settled(nm, actv(oub), (size_t)w * cs * g_H[oub] * g_W[oub]);
        }
        /* late re-read of the seam, one PL op after it was written: op fd has
         * run and only op fd+1 overwrites the seam buffer later */
        if (oi == fd && ps_head_pl() && getenv("BB_DUMP")) {
            int sb = OPS[fd].in_buf;
            dump_settled("seamlate_i8.bin", actv(sb), (size_t)g_C[sb] * g_H[sb] * g_W[sb]);
        }
        /* OP_CKSUM=1: per-op int64 output sum, comparable to the fixture's
         * embedded checksum list (forward_int order) */
        if (getenv("OP_CKSUM")) {
            long long ck = 0; int n = g_C[oub] * g_H[oub] * g_W[oub];
            if (op->type == 4) {                        /* the final acc is raw int32 */
                const int32_t *ov = (const int32_t *)actv(oub);
                int CS = g_C[oub];
#ifdef HD_PL
                if (ps_head_pl()) CS = 16;              /* padded stride, lanes 14/15 skipped */
#endif
                for (int y2 = 0; y2 < g_H[oub] * g_W[oub]; y2++)
                    for (int c2 = 0; c2 < g_C[oub]; c2++) ck += ov[(size_t)y2 * CS + c2];
                n = 0;                                  /* summed above */
                for (int q = 0; q < n; q++) ck += ov[q];
            } else if (g_fmt8[oub]) {
                const int8_t *ov = (const int8_t *)actv(oub);
                for (int q = 0; q < n; q++) ck += ov[q];
            } else {
                const int16_t *ov = actv(oub);
                for (int q = 0; q < n; q++) ck += ov[q];
            }
            fprintf(stderr, "  CK %2d %lld\n", oi, ck);
        }
    }

    /* boundary tensor into cached bb_out, decoupling the head from the arena:
     * one sequential uncached->cached copy, then (HEAD_NHWC=0 only) the strided
     * transpose to CHW in cached memory */
    double t_bb = tim ? ps_now_ms() : 0;
    if (ps_head_pl()) {                                 /* no bb handoff: the head ran in the PL */
        if (tim) fprintf(stderr, "[ps_timing] PL=%.1f (incl head)  plrun-total=%.1f ms%c", t_pl, ps_now_ms() - t0, 10);
        return;
    }
    int last = OPS[fd - 1].out_buf;
    int bbC = g_C[last], bbH = g_H[last], bbW = g_W[last];
    {
        size_t nb = (size_t)bbC * bbH * bbW;
        if (ps_head_nhwc()) {
            /* NHWC head: the PL boundary is already NHWC, so one copy suffices */
            memcpy(bb_out, actv(last), nb * sizeof(int16_t));
            if (getenv("BB_DUMP")) {                     /* debug: the head's input */
                FILE *bf = fopen("bb_dump.bin", "wb");
                if (bf) { fwrite(bb_out, sizeof(int16_t), nb, bf); fclose(bf); }
            }
        } else {
            static int16_t *bounce = NULL;
            if (!bounce) bounce = (int16_t *)malloc(nb * sizeof(int16_t));
            memcpy(bounce, actv(last), nb * sizeof(int16_t));   /* sequential uncached reads */
            for (int c = 0; c < bbC; c++)                       /* NHWC: b[(y*W+x)*C + c] -> CHW bb_out */
                for (int y = 0; y < bbH; y++)
                    for (int x = 0; x < bbW; x++)
                        bb_out[((size_t)c * bbH + y) * bbW + x] =
                            bounce[((size_t)(y * bbW + x)) * bbC + c];
        }
    }
    if (tim) fprintf(stderr, "[ps_timing] PL=%.1f  transpose=%.1f  plrun-total=%.1f ms\n",
                     t_pl, ps_now_ms() - t_bb, ps_now_ms() - t0);
}

/* Sequential wrapper (unchanged behavior): prep(slot 0) + plrun(slot 0). */
void mbv2_ps_backbone(const uint8_t *w2rom, const int8_t *w8rom, const int8_t *head_blob,
                      const int8_t *input_i8, int16_t *bb_out) {
    mbv2_ps_prep(w2rom, w8rom, head_blob, input_i8, 0);
    mbv2_ps_plrun(0, bb_out);
}

/* Pure PS/NEON stage: deconv head + final + arg-max from a decoupled boundary
 * tensor (NHWC with HEAD_NHWC=1, else CHW). */
void mbv2_ps_head(const int8_t *head_blob, const int16_t *bb_out,
                  int32_t *final_acc, int *keypoints) {
    /* g_head_blob is cached by mbv2_ps_init(); an app that never calls it (the
     * fused app) passes the blob as the argument. Prefer the cached pointer and
     * fall back to the argument. */
    const int8_t *hb = g_head_blob ? g_head_blob : head_blob;
    if (!hb) {
        fprintf(stderr, "FATAL: mbv2_ps_head has no head blob -- neither "
                        "mbv2_ps_init() nor the caller supplied one%c", 10);
        exit(1);
    }
    if (ps_head_pl()) {
        /* under HEAD_PL the PL computes the head and mbv2_ps_plrun never writes
         * bb_out; callers must use mbv2_ps_finish_pl instead */
        fprintf(stderr, "FATAL: mbv2_ps_head called with HEAD_PL=1 -- the head ran in the PL "
                        "and bb_out was never written; call mbv2_ps_finish_pl instead%c", 10);
        exit(2);
    }
    int tim = getenv("PS_TIMING") != NULL;
    double th0 = tim ? ps_now_ms() : 0;
    /* HEAD_U8=1 selects the uint8-activation head (mbv2_head8); default 0 */
    static int u8 = -1;
    if (u8 < 0) { char *e = getenv("HEAD_U8"); u8 = e ? atoi(e) : 0; }
    if (ps_head_nhwc()) mbv2_head_nhwc(hb, bb_out, final_acc, keypoints);
    else if (u8) mbv2_head8(hb, bb_out, final_acc, keypoints);
    else         mbv2_head (hb, bb_out, final_acc, keypoints);
    if (tim) fprintf(stderr, "[ps_timing] head=%.1f ms\n", ps_now_ms() - th0);
}

int mbv2_ps_head_in_pl(void) { return ps_head_pl(); }

/* HEAD_PL only: turn what the PL left in the arena into the caller's contract.
 * The PL's raw int32 accumulator sits in the arena as NHWC at a padded channel
 * stride; it is converted to the CHW final_acc contract, with the same plain
 * arg-max keypoints the PS head computes. DARK stays with the caller.
 *
 * mbv2_ps_finish_pl() must be called from the thread that just ran
 * mbv2_ps_plrun, before that slot is handed to the next frame: its source is
 * o_act[] and g_C/g_H/g_W, which are not double-buffered. */
static int fin_stride(void) {
#ifdef HD_PL
    return 16;                   /* the padded final writes stride 16 (lanes 14/15 zero) */
#else
    return g_fin_C;
#endif
}

size_t mbv2_ps_readout_bytes(void) {
    return (size_t)fin_stride() * g_fin_H * g_fin_W * 4;
}

/* Stage 1 of the finish: copy the PL's accumulator out of the arena. This part
 * must run in the PL thread before the slot is reused; the rest is ordinary
 * cached work.
 *
 * The arena is reserved `no-map`, so arm64 maps it Device-nGnRnE: no merging
 * and no speculation, each load instruction is one bus transaction. arena_read()
 * therefore issues four independent 128-bit loads per 64 bytes (not
 * vld1q_u8_x4, not a uint64 loop, not memcpy). */
#if defined(__aarch64__)
#include <arm_neon.h>
static void arena_read(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst; const uint8_t *s = (const uint8_t *)src;
    size_t m = n & ~(size_t)63;
    for (size_t i = 0; i < m; i += 64) {
        uint8x16_t a = vld1q_u8(s + i),      b = vld1q_u8(s + i + 16);
        uint8x16_t c = vld1q_u8(s + i + 32), e = vld1q_u8(s + i + 48);
        vst1q_u8(d + i, a);      vst1q_u8(d + i + 16, b);
        vst1q_u8(d + i + 32, c); vst1q_u8(d + i + 48, e);
    }
    if (m < n) memcpy(d + m, s + m, n - m);
}
#else
static void arena_read(void *dst, const void *src, size_t n) { memcpy(dst, src, n); }
#endif

void mbv2_ps_readout_slot(int slot, int32_t *dst) {
    int tim = getenv("PS_TIMING") != NULL;
    double t0 = tim ? ps_now_ms() : 0;
    arena_read(dst, (const void *)(AR + o_fin[slot & 1]), mbv2_ps_readout_bytes());
    if (tim) fprintf(stderr, "[ps_timing] readout(slot %d)=%.2f ms%c", slot & 1,
                     ps_now_ms() - t0, 10);
}

void mbv2_ps_readout_pl(int32_t *dst) { mbv2_ps_readout_slot(0, dst); }

/* Stage 2: NHWC (padded stride) -> CHW final_acc + arg-max. Pure cached work on
 * a caller-owned buffer, so it can run in a later pipeline stage. Channel-outer
 * so writes are sequential within one channel plane. */
void mbv2_ps_finish_from(const int32_t *src, int32_t *final_acc, int *keypoints) {
    int C = g_fin_C, H = g_fin_H, W = g_fin_W, HW = H * W;
    int CS = fin_stride();
    int tim = getenv("PS_TIMING") != NULL;
    double t0 = tim ? ps_now_ms() : 0;
    for (int c = 0; c < C; c++) {
        int32_t *d = final_acc + (size_t)c * HW;
        const int32_t *s = src + c;
        int best = 0; int32_t bv = s[0];
        for (int p = 0; p < HW; p++) {
            int32_t v = s[(size_t)p * CS];
            d[p] = v;
            if (v > bv) { bv = v; best = p; }
        }
        if (keypoints) { keypoints[c * 2] = best % W; keypoints[c * 2 + 1] = best / W; }
    }
    if (tim) fprintf(stderr, "[ps_timing] finish_from=%.2f ms%c", ps_now_ms() - t0, 10);
}

void mbv2_ps_finish_pl(int32_t *final_acc, int *keypoints) {
    static int32_t *bounce32 = NULL;
    if (!bounce32) bounce32 = (int32_t *)malloc(mbv2_ps_readout_bytes());
    mbv2_ps_readout_pl(bounce32);
    mbv2_ps_finish_from(bounce32, final_acc, keypoints);
}

/* Sequential single-frame wrapper (unchanged behavior): backbone -> internal cached bb -> head. */
void mbv2_ps_infer(const uint8_t *w2rom, const int8_t *w8rom, const int8_t *head_blob,
                   const int8_t *input_i8, int32_t *final_acc, int *keypoints) {
    if (ps_head_pl()) {
        mbv2_ps_prep(w2rom, w8rom, head_blob, input_i8, 0);
        mbv2_ps_plrun(0, NULL);
        mbv2_ps_finish_pl(final_acc, keypoints);
        return;
    }
    if (!g_bb_cached) g_bb_cached = (int16_t *)malloc((size_t)MAXACT * 2);
    mbv2_ps_backbone(w2rom, w8rom, head_blob, input_i8, g_bb_cached);
    mbv2_ps_head(head_blob, g_bb_cached, final_acc, keypoints);
}
