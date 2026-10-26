/* ============================================================================
 *  pl_hal_fuse_enc.c -- the parts of the fused-accelerator HAL that touch no
 *  register: the head's descriptor encoders and checks, and the counter print.
 *
 *  Linked with either backend: pl_hal_fuse.c (UIO + /dev/mem) or
 *  pl_hal_fuse_drv.c (the twn_fuse kernel driver). Moved out of pl_hal_fuse.c
 *  unchanged so that both backends share one copy.
 * ========================================================================== */
#include <stdio.h>
#include <stdint.h>

#include "pl_hal_fuse.h"

#define H_RQ_BASE     0x0400            /* .. 0x07fc, 256 words                */

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
