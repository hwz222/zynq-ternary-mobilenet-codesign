/* ============================================================================
 *  mbv2_fuse_ps.c -- frame program for the fused backbone and its PL head.
 *
 *  mbv2_fuse_backbone() replaces mbv2_ps_backbone(): it writes the input image
 *  into the arena, starts the fused accelerator (one start per frame, the block
 *  descriptors are written once at init) and widens the boundary tensor to
 *  int16 NHWC. mbv2_ps_head() is then called unchanged.
 *
 *  Environment: FUSE_HEAD_PL=1 runs the head in the fabric; FUSE_BB2HD=0 turns
 *  off the direct backbone-to-head handover. The control window and arena come
 *  from pl_hal_fuse.c (PL_UIO, PL_ARENA_PA, PL_ARENA_SZ).
 * ========================================================================== */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "pl_hal_fuse.h"
#include "mbv2_ps.h"
#include "mbv2_fuse_ps.h"
#include "model_meta.h"          /* OPS / RQ_M0 / RQ_BIAS / RQ_SH: head geometry
                                  * and requantisation                         */
#include "pack_meta_mbv2.h"      /* HD_PL_OFF_*: where the head's weights sit in
                                  * model_mbv2_packed.bin                      */
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

/* ---- the arena map: everything the PL touches lives here ----
 * The slot stride is fixed in the bitstream (twn_act_rd / twn_act_wr are
 * instantiated with SLOT_LOG2(18)); descriptors carry slot indices, not
 * addresses. */
#define FUSE_SLOT_LOG2   18
#define FUSE_SLOT_STRIDE (1u << FUSE_SLOT_LOG2)        /* 262,144 */
#define FUSE_N_SLOTS     2                             /* blocks alternate slots */

#define OFF_WEIGHTS   0x00000000u                      /* fuse_weights.bin, 64-B aligned */
#define OFF_ACT       0x00100000u                      /* the slot region          */
#define OFF_IN        (OFF_ACT + FUSE_N_SLOTS * FUSE_SLOT_STRIDE)
#define OFF_OUT       (OFF_IN + 0x00100000u)
/* the whole map ends at OFF_HD_OUT + 2 * HD_OUT_SLOT_BYTES (asserted below the
 * head's regions); the kernel driver's DMA buffer must be at least this big */
#define FUSE_ARENA_NEED 0x00600000u

/* the last block (16) writes out_slot = 16 % 2 = 0, so the backbone tensor
 * lands at the base of slot 0, int8 */
#define BB_BYTES      MBV2_BB_LEN
/* The input image as the PL addresses it: rows padded up to a whole 128-byte
 * twn_act_rd word. Must equal the descriptor's row_bytes_in and
 * tools/gen_fuse_ddr.py's FM_ROW_BYTES_IN. */
#define FUSE_IN_ROW_STRIDE   (((NET_IN_C * NET_IN_W) + 127u) / 128u * 128u)
#define FUSE_IN_IMAGE_BYTES  ((size_t)FUSE_IN_ROW_STRIDE * NET_IN_H)

static uint8_t  *g_arena_v;
static uint64_t  g_arena_pa;
static fuse_split_t g_split;
static int       g_ready;

/* ---- one-time setup ---- */
void mbv2_fuse_init(const uint8_t *weight_file, size_t weight_bytes) {
    if (g_ready) return;
    fuse_hal_init();
    g_arena_v = (uint8_t *)fuse_arena_init(&g_arena_pa, FUSE_ARENA_NEED);

    /* the weight file is tools/pack_fuse_weights.py's output; the descriptors
     * carry the offsets into it */
    memcpy(g_arena_v + OFF_WEIGHTS, weight_file, weight_bytes);

    fuse_set_bases(g_arena_pa + OFF_WEIGHTS, g_arena_pa + OFF_ACT);
    fuse_load_desctab();

    /* required: twn_csr gates ap_start on tab_checked && d_valid and reports
     * nothing on the start write itself */
    if (fuse_check_table() != 0) {
        fprintf(stderr, "mbv2_fuse: descriptor table refused -- cannot run\n");
        exit(1);
    }
    g_ready = 1;
}

/* ---- int8 out of the arena, int16 into normal memory ----
 * A plain loop on purpose: the compiler vectorises it, and volatile wide
 * accesses cannot be merged or overlapped. */
static void fuse_widen_from_arena(int16_t *dst, const uint8_t *src, size_t n) {
    const int8_t *s = (const int8_t *)src;
    for (size_t i = 0; i < n; i++) dst[i] = (int16_t)s[i];
}

/* ---- the backbone, one frame ----
 * `input_i8` is the pre-quantized camera frame, int8 CHW; the transpose into
 * the PL's layout is mbv2_fuse_write_input(). */
void mbv2_fuse_backbone(const int8_t *input_i8, int16_t *bb_out,
                        fuse_counters_t *counters) {
    if (!g_ready) { fprintf(stderr, "mbv2_fuse: init first\n"); exit(1); }

    /* the three phases are timed apart: only fuse_run_frame()'s start->done
     * window is the PL; the input write and read-back are PS accesses to the
     * uncached arena */
    struct timespec a, b, c, d;
    /* this path reads the boundary out of act slot 0, so the BB2HD enable must
     * be off; a previous process may have left it on */
    fuse_bb2hd_set(0);
    clock_gettime(CLOCK_MONOTONIC, &a);
    mbv2_fuse_write_input(input_i8, g_arena_v + OFF_IN);
    clock_gettime(CLOCK_MONOTONIC, &b);

    uint64_t pl_ns = fuse_run_frame(g_arena_pa + OFF_IN, g_arena_pa + OFF_OUT, 1);
    clock_gettime(CLOCK_MONOTONIC, &c);

    /* The backbone tensor: the last block's output, int8, at the base of slot 0.
     * The PL writes rows of c_out * w_out bytes in [x][c] order, which is NHWC,
     * the layout mbv2_ps_head() takes with HEAD_NHWC=1, so the conversion is a
     * widening copy with no transpose. */
    fuse_widen_from_arena(bb_out,
                          (const uint8_t *)(g_arena_v + OFF_ACT + 0 * FUSE_SLOT_STRIDE),
                          (size_t)MBV2_BB_LEN);
    clock_gettime(CLOCK_MONOTONIC, &d);

    g_split.t_in_ms  = (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
    g_split.t_pl_ms  = pl_ns / 1e6;
    g_split.t_out_ms = (d.tv_sec - c.tv_sec) * 1e3 + (d.tv_nsec - c.tv_nsec) / 1e6;

    if (counters) fuse_read_counters(counters);
}

void mbv2_fuse_last_split(fuse_split_t *s) { if (s) *s = g_split; }

/* ---- diagnostic: the same frame without the programmable logic ----
 * Does not compute the backbone: it performs the two uncached memory phases of
 * mbv2_fuse_backbone() and skips the PL run, so `bb_out` receives the previous
 * frame's boundary. Nothing in the frame path may call it. It separates the
 * processor's uncached-arena traffic from the accelerator's own DDR traffic. */

/* Clean-and-invalidate to the point of coherency from user space (`dc civac`;
 * Linux sets SCTLR_EL1.UCI). A cacheable arena would owe this every frame: the
 * HP ports are not I/O-coherent. AArch64 only; the host build aborts rather
 * than silently doing no maintenance. */
#if defined(__aarch64__)
static void dcache_civac(const void *p, size_t n) {
    const uintptr_t LINE = 64;
    uintptr_t a = (uintptr_t)p & ~(LINE - 1);
    uintptr_t e = (uintptr_t)p + n;
    for (; a < e; a += LINE) __asm__ volatile("dc civac, %0" :: "r"(a) : "memory");
    __asm__ volatile("dsb sy" ::: "memory");
}
#else
static void dcache_civac(const void *p, size_t n) {
    (void)p; (void)n;
    fprintf(stderr, "mbv2_fuse: the cacheable-arena diagnostic needs AArch64 "
                    "cache maintenance; there is none on this host.\n");
    abort();
}
#endif

void mbv2_fuse_backbone_io_only(const int8_t *input_i8, int16_t *bb_out, int cached) {
    if (!g_ready) { fprintf(stderr, "mbv2_fuse: init first\n"); exit(1); }
    /* `cached` repeats the same two phases against cacheable memory plus the
     * cache maintenance such an arena would owe, with the same instruction and
     * byte counts, to test whether the memory attribute is the cost. */
    static uint8_t *scratch_in;
    static uint8_t *scratch_act;
    if (cached && !scratch_in) {
        scratch_in  = (uint8_t *)aligned_alloc(4096, FUSE_IN_IMAGE_BYTES);
        scratch_act = (uint8_t *)aligned_alloc(4096, (size_t)MBV2_BB_LEN);
        if (!scratch_in || !scratch_act) {
            fprintf(stderr, "mbv2_fuse: cached-scratch alloc failed\n"); exit(1); }
        /* seed it from the arena so the head sees the real boundary tensor */
        memcpy(scratch_act, g_arena_v + OFF_ACT + 0 * FUSE_SLOT_STRIDE,
               (size_t)MBV2_BB_LEN);
    }
    uint8_t *dst_in  = cached ? scratch_in  : g_arena_v + OFF_IN;
    const uint8_t *src_act = cached ? scratch_act
                                    : g_arena_v + OFF_ACT + 0 * FUSE_SLOT_STRIDE;
    struct timespec a, b, c, d;
    clock_gettime(CLOCK_MONOTONIC, &a);
    mbv2_fuse_write_input(input_i8, dst_in);
    if (cached) dcache_civac(dst_in, FUSE_IN_IMAGE_BYTES);
    clock_gettime(CLOCK_MONOTONIC, &b);
    c = b;
    if (cached) dcache_civac(src_act, (size_t)MBV2_BB_LEN);
    fuse_widen_from_arena(bb_out, src_act, (size_t)MBV2_BB_LEN);
    clock_gettime(CLOCK_MONOTONIC, &d);
    g_split.t_in_ms  = (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
    g_split.t_pl_ms  = 0.0;
    g_split.t_out_ms = (d.tv_sec - c.tv_sec) * 1e3 + (d.tv_nsec - c.tv_nsec) / 1e6;
}

/* ---- the raw slot bytes, for boundary diagnosis ----
 * Read-only pointer into the arena so a caller can dump what the PL left there
 * and compare it with golden/p1_golden/vec/bNN_out.bin. The bytes are in the PL's
 * [x][c] order; the goldens are CHW, so compare after exactly one transpose. */
const uint8_t *mbv2_fuse_slot_ptr(int slot) {
    if (!g_ready || slot < 0 || slot >= FUSE_N_SLOTS) return NULL;
    return g_arena_v + OFF_ACT + (size_t)slot * FUSE_SLOT_STRIDE;
}

/* ---- the input tensor, CHW -> [x][c] ----
 * The PL does the stem's spatial gather, so the PS writes a plain [x][c] image.
 * Row stride is FUSE_IN_ROW_STRIDE: c_in * w_in rounded up to 128 bytes, with
 * the pad bytes zeroed; tools/gen_fuse_ddr.py (chw_to_hwc, FM_ROW_BYTES_IN)
 * defines the byte layout. The loop writes straight into the arena; staging each
 * row in cached memory and pushing it out with volatile stores does not help. */
void mbv2_fuse_write_input(const int8_t *input_i8, uint8_t *dst) {
    enum { C = NET_IN_C, H = NET_IN_H, W = NET_IN_W };
    const size_t stride = FUSE_IN_ROW_STRIDE;
    int8_t *d = (int8_t *)dst;
    for (int y = 0; y < H; y++) {
        const int8_t *r0 = input_i8 + 0 * H * W + y * W;
        const int8_t *r1 = input_i8 + 1 * H * W + y * W;
        const int8_t *r2 = input_i8 + 2 * H * W + y * W;
        int8_t *o = d + (size_t)y * stride;
        for (int x = 0; x < W; x++) { o[0] = r0[x]; o[1] = r1[x]; o[2] = r2[x]; o += C; }
        for (size_t t = (size_t)C * W; t < stride; t++) o[t - (size_t)C * W] = 0;
    }
}

/* ============================================================================
 *  The head in the programmable logic
 * ==========================================================================*/

/* ---- the head's own arena regions ----
 * Each region is 64 KB aligned and sized to its tensor, so a read one beat past
 * a tensor lands in a hole rather than in the next tensor.
 *
 * HD_IN holds two slots HD_IN_SLOT_STRIDE apart: op61's input base is offset by
 * the head's slot (twn_hd_seq adds slot_off to op61's input base only). HD_OUT
 * holds two op64 output slots, HD_OUT_SLOT_BYTES apart. */
#define OFF_HD_W      0x00400000u                 /* HD_PL_BYTES of weights    */
#define OFF_HD_IN     0x00440000u                 /* + 0 and + 0x10000         */
#define HD_IN_SLOT_STRIDE 0x10000u                /* slot_off step             */
#define OFF_HD_A1     0x00460000u                 /* op61 out = op62 in        */
#define OFF_HD_A2     0x00470000u                 /* op62 out = op63 in        */
#define OFF_HD_A3     0x00480000u                 /* op63 out = op64 in        */
#define OFF_HD_OUT    0x004C0000u                 /* op64 out, two slots       */

#define HD_FIN_STRIDE 16                          /* op64's OC padded 14 -> 16 */
#define HD_OUT_SLOT_BYTES ((size_t)HD_FIN_STRIDE * NET_OUT_H * NET_OUT_W * 4)
_Static_assert(OFF_HD_OUT + 2 * HD_OUT_SLOT_BYTES <= FUSE_ARENA_NEED,
               "the arena map outgrew FUSE_ARENA_NEED");

/* the head's four operators, by 0-based index into OPS[] */
#define HD_OP0 61
#define HD_N   FUSE_HD_NOPS

static int  g_hd_ready;
/* 1 = the last block writes straight into the head's input slots and the
 * fabric picks the head's slot and heatmap box (BB2HD register), so
 * hd_stage_boundary() and hd_point_output() are not called. Decided once in
 * mbv2_fuse_head_init(): FUSE_BB2HD=0 forces the copy path, and a bitstream
 * without the register falls back to it with a message. */
static int  g_bb2hd;
static fuse_hd_desc_t  g_hd_desc[HD_N];
static fuse_hd_rq_t    g_hd_rq[HD_N][FUSE_HD_NRQ];
static fuse_pl_split_t g_pl_split;

int mbv2_fuse_head_in_pl(void) {
    static int m = -1;
    if (m < 0) { const char *e = getenv("FUSE_HEAD_PL"); m = e ? atoi(e) : 0; }
    return m;
}

size_t mbv2_fuse_head_readout_bytes(void) { return HD_OUT_SLOT_BYTES; }

/* ---- the descriptors, derived from the model's tables ----
 *   ic, oc, relu, lo, hi, rq_off   OPS[61..64] in model_meta.c
 *   w_beats                        the HD_PL_OFF_* deltas in pack_meta_mbv2.h
 *   h, w                           walked forward from the boundary tensor, each
 *                                  deconvolution doubling, and checked against
 *                                  NET_OUT_H x NET_OUT_W
 *   in_beats, out_beats            arithmetic on the above
 *   slice                          mode A when IC * (OC/8) > 128: resident mode
 *                                  needs 4*IC*OCG <= 512 tap-bank words
 *                                  (twn_hd_compute.v)
 * op64 uses oc_engine = 16, not the model's 14: the engine emits OC[5:2] beats,
 * and tools/append_hd_pl.py pads that operator's weights from 14 to 16 rows.
 * fuse_hd_desc_check() refuses a type-4 OC that is not a multiple of 4. */
int mbv2_fuse_head_build(uint64_t pa, fuse_hd_desc_t d[HD_N],
                         fuse_hd_rq_t rq[HD_N][FUSE_HD_NRQ], int hm_slot) {
    /* the four weight tensors at the offsets the packed blob uses, so one
     * memcpy of the HD_PL tail places every operator's weights */
    static const long WOFF[HD_N] = { HD_PL_OFF_LIST };
    const long wtail = HD_PL_OFF_61 + HD_PL_BYTES;

    /* the boundary tensor's shape, from the contract constant and op61's IC */
    const uint32_t bb_ic = (uint32_t)OPS[HD_OP0].ic;
    uint32_t hw = (uint32_t)MBV2_BB_LEN / bb_ic, h = 0, w;
    while (h * h < hw) h++;
    if (h * h != hw || h * h * bb_ic != (uint32_t)MBV2_BB_LEN) {
        fprintf(stderr, "mbv2_fuse_head: the boundary is %d bytes with IC=%u, "
                        "which is not a square feature map\n", MBV2_BB_LEN, bb_ic);
        return -1;
    }
    w = h;

    for (int i = 0; i < HD_N; i++) {
        const Op *o = &OPS[HD_OP0 + i];
        fuse_hd_desc_t *e = &d[i];
        int type4 = (o->type == 4);
        uint32_t oc_eng = type4 ? 16u : (uint32_t)o->oc;
        long wbytes = (i + 1 < HD_N ? WOFF[i + 1] : wtail) - WOFF[i];

        e->ic = (uint32_t)o->ic;
        e->oc = oc_eng;
        e->h  = h;
        e->w  = w;
        e->type4 = (uint8_t)type4;
        e->slice = (uint8_t)(!type4 && ((uint32_t)o->ic * ((uint32_t)o->oc / 8u) > 128u));
        e->relu  = (uint8_t)(o->relu != 0);
        e->lo = o->lo;
        e->hi = o->hi;

        /* in_beats is one pass: mode A re-reads the whole input once per
         * (phase, ocg) slice and the sequencer re-issues the reader each time.
         * fuse_hd_desc_check() re-derives it from H*W*IC. */
        e->in_beats  = (e->h * e->w * e->ic) / 16u;
        e->w_beats   = (uint32_t)(wbytes / 16);
        e->out_beats = type4 ? (e->h * e->w * oc_eng * 4u) / 16u
                             : ((2u * e->h) * (2u * e->w) * oc_eng) / 16u;

        e->w_base = pa + OFF_HD_W + (uint64_t)(WOFF[i] - HD_PL_OFF_61);
        switch (i) {
            case 0: e->in_base = pa + OFF_HD_IN;  e->out_base = pa + OFF_HD_A1; break;
            case 1: e->in_base = pa + OFF_HD_A1;  e->out_base = pa + OFF_HD_A2; break;
            case 2: e->in_base = pa + OFF_HD_A2;  e->out_base = pa + OFF_HD_A3; break;
            default:e->in_base = pa + OFF_HD_A3;
                    e->out_base = pa + OFF_HD_OUT
                                + (uint64_t)(hm_slot & 1) * HD_OUT_SLOT_BYTES; break;
        }
        if (!type4) { h *= 2; w *= 2; }        /* each deconvolution doubles */

        for (int c = 0; c < FUSE_HD_NRQ; c++) {
            /* op64 is type 4 (raw int32 output, no requantisation): its entries
             * are zero but are still written, so the store has no holes */
            if (type4 || c >= o->oc) {
                rq[i][c].m0 = 0; rq[i][c].bias = 0; rq[i][c].sh = 0;
            } else {
                rq[i][c].m0   = RQ_M0[o->rq_off + c];
                rq[i][c].bias = RQ_BIAS[o->rq_off + c];
                rq[i][c].sh   = (uint32_t)RQ_SH[o->rq_off + c];
            }
        }
    }
    if (h != NET_OUT_H || w != NET_OUT_W) {
        fprintf(stderr, "mbv2_fuse_head: the deconvolution chain ends at %ux%u, "
                        "not the model's %dx%d\n", h, w, NET_OUT_H, NET_OUT_W);
        return -1;
    }
    return 0;
}

void mbv2_fuse_head_init(const uint8_t *packed, size_t packed_bytes) {
    if (!g_ready) { fprintf(stderr, "mbv2_fuse: init first\n"); exit(1); }
    if (g_hd_ready) return;

    /* the head's weights are the packed blob's HD_PL tail; the W8 section
     * starts after the two ternary sections (sizes from pack_meta_mbv2.h) */
    const size_t w8base = (size_t)W2_AL + (size_t)W2HW_BYTES;
    const size_t off    = w8base + (size_t)HD_PL_OFF_61;
    if (packed_bytes < off + (size_t)HD_PL_BYTES) {
        fprintf(stderr, "mbv2_fuse_head: the packed blob is %zu bytes, the head's "
                        "weights need %zu. Is this model_mbv2_packed.bin from an "
                        "export WITHOUT the hd_pl tail (tools/append_hd_pl.py)?\n",
                packed_bytes, off + (size_t)HD_PL_BYTES);
        exit(1);
    }
    memcpy(g_arena_v + OFF_HD_W, packed + off, (size_t)HD_PL_BYTES);

    if (mbv2_fuse_head_build(g_arena_pa, g_hd_desc, g_hd_rq, 0) != 0) exit(1);
    if (fuse_hd_program(g_hd_desc, (const fuse_hd_rq_t (*)[FUSE_HD_NRQ])g_hd_rq) != 0) {
        fprintf(stderr, "mbv2_fuse_head: the head could not be programmed -- "
                        "refusing to run rather than producing plausible numbers "
                        "from an operator on all-zero geometry\n");
        exit(1);
    }
    {
        const char *e = getenv("FUSE_BB2HD");
        int want = e ? atoi(e) : 1;
        if (!want) {
            g_bb2hd = 0;
            fuse_bb2hd_set(0);
            fprintf(stderr, "mbv2_fuse_head: FUSE_BB2HD=0 -- the processor copies the "
                            "boundary into the head's slots and re-commits op64 (BB2HD off)\n");
        } else if (!fuse_bb2hd_probe()) {
            g_bb2hd = 0;
            fprintf(stderr, "mbv2_fuse_head: this bitstream has no A_BB2HD register -- "
                            "falling back to the processor copy (BB2HD off)\n");
        } else {
            /* OUT_PTR is the head's two input slots; the last block adds
             * bb_par * 0x10000. Require 64 KB alignment and both slots below A1. */
            const uint64_t op = g_arena_pa + OFF_HD_IN;
            if ((op & 0xFFFFu) != 0 ||
                OFF_HD_IN + 2u * HD_IN_SLOT_STRIDE > OFF_HD_A1) {
                fprintf(stderr, "mbv2_fuse_head: head input slots at %#llx are not "
                                "64 KB aligned or overlap A1\n", (unsigned long long)op);
                exit(1);
            }
            g_bb2hd = 1;
            fuse_bb2hd_restart();
            fprintf(stderr, "mbv2_fuse_head: BB2HD on -- block 16 writes the head's "
                            "input slots directly (A_BB2HD %08x)\n", fuse_bb2hd_read());
        }
    }
    for (int i = 0; i < HD_N; i++) {
        const fuse_hd_desc_t *e = &g_hd_desc[i];
        fprintf(stderr, "  op%d  %-6s IC=%-3u OC=%-2u %2ux%-2u  in %5u x%-2d  "
                        "w %5u  out %5u  clamp %d..%d relu %u\n",
                61 + i, e->type4 ? "type4" : (e->slice ? "modeA" : "modeB"),
                e->ic, e->oc, e->h, e->w, e->in_beats,
                e->slice ? 4 * (int)(e->oc / 8) : 1,
                e->w_beats, e->out_beats, e->lo, e->hi, e->relu);
    }
    g_hd_ready = 1;
}

/* ---- the uncached drain: four independent 128-bit loads per 64 bytes ----
 * Written as separate vld1q_u8 loads rather than vld1q_u8_x4. */
#if defined(__aarch64__)
static void hd_arena_read(void *dst, const void *src, size_t n) {
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
static void hd_arena_read(void *dst, const void *src, size_t n) { memcpy(dst, src, n); }
#endif

/* ---- copy the boundary from the array's slot into the head's input slots ----
 * Used only when BB2HD is off. The array writes the boundary to act_base + 0 on
 * every frame (block 16's out_slot is 0), while the head's input alternates
 * between HD_IN and HD_IN + HD_IN_SLOT_STRIDE, and the hd_slot that selects
 * between them is not readable from the processor. Both slots are therefore
 * written. Pointing op61 at the array's slot directly would be wrong on every
 * other frame and would race with the array's next write. */
static void hd_stage_boundary(void) {
    static uint8_t bounce[MBV2_BB_LEN];
    hd_arena_read(bounce, g_arena_v + OFF_ACT + 0 * FUSE_SLOT_STRIDE, sizeof bounce);
    memcpy(g_arena_v + OFF_HD_IN,                       bounce, sizeof bounce);
    memcpy(g_arena_v + OFF_HD_IN + HD_IN_SLOT_STRIDE,   bounce, sizeof bounce);
}

/* Re-commit op64 so this frame's accumulator lands in its own buffer. All
 * twelve fields are rewritten because a commit does not clear the staging set. */
static void hd_point_output(int frame) {
    g_hd_desc[HD_N - 1].out_base = g_arena_pa + OFF_HD_OUT
                                 + (uint64_t)(frame & 1) * HD_OUT_SLOT_BYTES;
    if (fuse_hd_commit(&g_hd_desc[HD_N - 1], HD_N - 1) != 0) {
        fprintf(stderr, "mbv2_fuse_head: op64 re-commit failed\n");
        exit(1);
    }
}

/* BB2HD on: after a head has finished, check the slot and box the fabric used.
 * Readers index the heatmap box by the frame number's parity, so the fabric's
 * choice must equal it. mbv2_fuse_frame_pl() resets the parity on every
 * head_frame < 0 call; a mismatch means a call sequence this file does not
 * handle, and it is reported rather than ignored. */
static void hd_check_box(int frame) {
    uint32_t v = fuse_bb2hd_read();
    int box = (v & FUSE_BB2HD_HDSEL) ? 1 : 0;
    if (!(v & FUSE_BB2HD_HDEN) || (v & FUSE_BB2HD_COLL) || box != (frame & 1)) {
        fprintf(stderr, "mbv2_fuse_head: BB2HD slot check failed for frame %d: "
                        "A_BB2HD %08x (head used box %d, the readout expects %d; "
                        "collision %u). A head started without a backbone since the "
                        "last parity reset (PIPE_PLSIM?) needs FUSE_BB2HD=0.\n",
                frame, v, box, frame & 1, (v & FUSE_BB2HD_COLL) ? 1u : 0u);
        exit(1);
    }
}

void mbv2_fuse_head_run(int frame) {
    struct timespec a, b;
    uint64_t ns = 0;
    if (!g_hd_ready) { fprintf(stderr, "mbv2_fuse_head: init first\n"); exit(1); }
    clock_gettime(CLOCK_MONOTONIC, &a);
    if (!g_bb2hd) {
        hd_stage_boundary();
        hd_point_output(frame);
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    if (fuse_hd_start() != 0) exit(1);
    if (fuse_hd_wait(1, &ns) != 0) exit(1);
    if (g_bb2hd) hd_check_box(frame);
    /* same field the producer stage uses for the boundary staging */
    g_pl_split.t_stage_ms = (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
    g_pl_split.t_hd_ms    = ns / 1e6;
}

/* ---- the producer stage, both engines in flight ----
 * The head is started first and waited for last, with fuse_run_frame() (which
 * starts the array and polls its done) in between. The engines have separate
 * start/busy/done and separate AXI ports. Nothing here reads the heatmap. */
void mbv2_fuse_frame_pl(const int8_t *input_i8, int head_frame,
                        fuse_counters_t *counters) {
    struct timespec a, b, c;
    uint64_t hd_ns = 0;
    if (!g_ready) { fprintf(stderr, "mbv2_fuse: init first\n"); exit(1); }

    clock_gettime(CLOCK_MONOTONIC, &a);
    mbv2_fuse_write_input(input_i8, g_arena_v + OFF_IN);
    clock_gettime(CLOCK_MONOTONIC, &b);

    if (g_bb2hd) {
        /* A sequence starts with head_frame < 0: reset the parity so backbone k
         * writes head input slot k & 1 and head k uses box k & 1, the box
         * mbv2_fuse_head_readout() indexes by. The boundary is already in the
         * head's slot, so nothing is copied and op64 needs no re-commit. */
        if (head_frame < 0) fuse_bb2hd_restart();
        else                fuse_bb2hd_set(1);
        if (head_frame >= 0 && fuse_hd_start() != 0) exit(1);
    } else if (head_frame >= 0) {
        /* the boundary the last backbone left in act slot 0, before this
         * frame's backbone overwrites it */
        hd_stage_boundary();
        hd_point_output(head_frame);
        if (fuse_hd_start() != 0) exit(1);
    }
    clock_gettime(CLOCK_MONOTONIC, &c);

    /* OUT_PTR is used by the fabric only with BB2HD on, as the base of the
     * head's two input slots */
    uint64_t pl_ns = fuse_run_frame(g_arena_pa + OFF_IN,
                                    g_arena_pa + (g_bb2hd ? OFF_HD_IN : OFF_OUT), 1);

    if (head_frame >= 0 && fuse_hd_wait(1, &hd_ns) != 0) exit(1);
    if (head_frame >= 0 && g_bb2hd) hd_check_box(head_frame);

    g_pl_split.t_in_ms    = (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
    g_pl_split.t_stage_ms = (c.tv_sec - b.tv_sec) * 1e3 + (c.tv_nsec - b.tv_nsec) / 1e6;
    g_pl_split.t_pl_ms    = pl_ns / 1e6;
    g_pl_split.t_hd_ms    = hd_ns / 1e6;
    if (counters) fuse_read_counters(counters);
}

void mbv2_fuse_last_pl_split(fuse_pl_split_t *s) { if (s) *s = g_pl_split; }

/* Diagnostic, the PL-head twin of mbv2_fuse_backbone_io_only(): the producer
 * stage's uncached memory traffic with both engines skipped. Nothing in the
 * frame path may call it. */
void mbv2_fuse_frame_pl_io_only(const int8_t *input_i8) {
    struct timespec a, b, c;
    if (!g_hd_ready) { fprintf(stderr, "mbv2_fuse_head: init first\n"); exit(1); }
    clock_gettime(CLOCK_MONOTONIC, &a);
    mbv2_fuse_write_input(input_i8, g_arena_v + OFF_IN);
    clock_gettime(CLOCK_MONOTONIC, &b);
    if (!g_bb2hd) hd_stage_boundary();      /* BB2HD on: no copy is issued */
    clock_gettime(CLOCK_MONOTONIC, &c);
    g_pl_split.t_in_ms    = (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
    g_pl_split.t_stage_ms = (c.tv_sec - b.tv_sec) * 1e3 + (c.tv_nsec - b.tv_nsec) / 1e6;
    g_pl_split.t_pl_ms    = 0.0;
    g_pl_split.t_hd_ms    = 0.0;
}

void mbv2_fuse_head_readout(int frame, int32_t *dst) {
    hd_arena_read(dst,
                  g_arena_v + OFF_HD_OUT + (size_t)(frame & 1) * HD_OUT_SLOT_BYTES,
                  HD_OUT_SLOT_BYTES);
}

/* NHWC at the padded stride -> the CHW final_acc contract, plus a plain
 * arg-max. Cached work on a caller-owned buffer, so it can run in a later
 * pipeline stage. Channel-outer so writes are sequential per channel plane.
 * The source stride is 16, not 14: op64 emits a padded 16-channel tensor whose
 * lanes 14 and 15 are zero. */
void mbv2_fuse_head_finish(const int32_t *src, int32_t *final_acc, int *keypoints) {
    const int C = NET_OUT_C, H = NET_OUT_H, W = NET_OUT_W, HW = H * W;
    for (int c = 0; c < C; c++) {
        int32_t *d = final_acc + (size_t)c * HW;
        const int32_t *s = src + c;
        int best = 0; int32_t bv = s[0];
        for (int p = 0; p < HW; p++) {
            int32_t v = s[(size_t)p * HD_FIN_STRIDE];
            d[p] = v;
            if (v > bv) { bv = v; best = p; }
        }
        if (keypoints) { keypoints[c * 2] = best % W; keypoints[c * 2 + 1] = best / W; }
    }
}

/* ---- a whole frame, for the simple (non-pipelined) path ---- */
void mbv2_fuse_infer(const int8_t *input_i8, const int8_t *head_blob,
                     int32_t *final_acc, int *keypoints,
                     fuse_counters_t *counters) {
    if (mbv2_fuse_head_in_pl()) {
        /* sequential: the backbone, then the head on the boundary it left; no
         * overlap (the pipelined path is mbv2_fuse_pipe) */
        static int32_t *bounce;
        if (!bounce) bounce = (int32_t *)malloc(mbv2_fuse_head_readout_bytes());
        if (!bounce) { fprintf(stderr, "mbv2_fuse_head: bounce alloc failed\n"); exit(1); }
        mbv2_fuse_frame_pl(input_i8, -1, counters);   /* backbone only */
        mbv2_fuse_head_run(0);                        /* then the head */
        mbv2_fuse_head_readout(0, bounce);
        mbv2_fuse_head_finish(bounce, final_acc, keypoints);
        return;
    }
    static int16_t bb[MBV2_BB_LEN];
    mbv2_fuse_backbone(input_i8, bb, counters);
    mbv2_ps_head(head_blob, bb, final_acc, keypoints);
}
