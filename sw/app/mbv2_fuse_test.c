/* ============================================================================
 *  mbv2_fuse_test.c -- correctness gate for the fused backbone, on the board.
 *
 *      mbv2_fuse_test <proj_root> [n_fixtures]        (default ".", 4)
 *        <proj_root>/data/fuse_weights.bin       pack_fuse_weights.py's blob
 *        <proj_root>/data/model_mbv2.bin         the head blob
 *        <proj_root>/data/model_mbv2_packed.bin  only with FUSE_HEAD_PL=1
 *        <proj_root>/golden/fix_<n>.bin          input, acc_ref, kp_ref, ck_ref
 *
 *  The fixtures' acc_ref / kp_ref come from the 65-operator path, so they are
 *  independent of the fused design. The head (mbv2_ps_head) is shared with that
 *  path, so a head defect would not be seen here.
 *  Environment: FUSE_HEAD_PL=1 (head in the fabric), FUSE_NBLK=n (short frame;
 *  fixture verdicts are then meaningless), FUSE_DUMP=<dir> (dump arena slots),
 *  PL_UIO / PL_ARENA_PA / PL_ARENA_SZ (pl_hal_fuse.c). Exit status 0 only if
 *  every requested fixture ran and matched.
 * ========================================================================== */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "mbv2_ps.h"
#include "mbv2_fuse_ps.h"
#include "model_meta.h"
#include "pack_meta_mbv2.h"             /* the packed blob's three section sizes */
#include "../../tools/fuse_desctab.h"      /* FUSE_NBLK, the generated block count */

#define FUSE_BLOB_BYTES 740992          /* pack_fuse_weights.py output size; must come
                                         * from the same packer run as
                                         * tools/fuse_desctab.h */
/* model_mbv2_packed.bin; the fabric head's weights are the hd_pl tail of its
 * last section. */
#define PACKED_BYTES ((size_t)W2_AL + (size_t)W2HW_BYTES + (size_t)W8_BYTES)

/* One activation slot: fixed by the bitstream (SLOT_LOG2(18) in twn_act_rd /
 * twn_act_wr). Slots are dumped whole; per-block shapes are in
 * golden/p1_golden/vec/p1_manifest.json. */
#define FUSE_SLOT_BYTES (1u << 18)

/* Must match the clock the PL runs at: it converts the cycle counters to
 * milliseconds, and a wrong value silently prints wrong times. The wall-clock
 * frame times use CLOCK_MONOTONIC and are unaffected. Default 240.0 MHz;
 * override with -DFUSE_CLK_MHZ. */
#ifndef FUSE_CLK_MHZ
#define FUSE_CLK_MHZ 240.0
#endif

static uint8_t  fuse_blob[FUSE_BLOB_BYTES];
static int8_t   head_blob[BLOB_BYTES];
static int8_t   input_i8[NET_IN_C * NET_IN_H * NET_IN_W];
static int32_t  acc_fu[NET_OUT_C * NET_OUT_H * NET_OUT_W];
static int32_t  acc_ref[NET_OUT_C * NET_OUT_H * NET_OUT_W];
static int32_t  kp_ref[NET_OUT_C * 2];
static long long ck_ref[N_OPS];
static int      kp_fu[NET_OUT_C * 2];
static int16_t  bb[MBV2_BB_LEN];

static double now_ms(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
                            return t.tv_sec*1e3 + t.tv_nsec/1e6; }

static int load(const char *path, void *dst, long n) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return 1; }
    long sz;
    /* exact size, not just a short read: n bytes out of a larger file would
     * load a truncated copy of the blob with no error */
    fseek(f, 0, SEEK_END); sz = ftell(f); rewind(f);
    if (sz != n) { printf("%s: file is %ld bytes, want %ld\n", path, sz, n);
                   fclose(f); return 1; }
    { long got = (long)fread(dst, 1, n, f); fclose(f);
      if (got != n) { printf("%s: got %ld want %ld\n", path, got, n); return 1; } }
    return 0;
}

int main(int argc, char **argv) {
    /* unbuffer stdout first: when redirected to a file, a crash would otherwise
     * discard every result line printed before it */
    setvbuf(stdout, NULL, _IONBF, 0);

    const char *root = argc > 1 ? argv[1] : ".";
    int nfix = argc > 2 ? atoi(argv[2]) : 4;
    char p[512];
    /* the verdict is "all requested fixtures ran and passed", so a request for
     * none is refused */
    if (nfix < 1) {
        printf("n_fixtures must be >= 1 (got '%s')\n", argc > 2 ? argv[2] : "");
        return 1;
    }

    snprintf(p, sizeof p, "%s/data/fuse_weights.bin", root);
    if (load(p, fuse_blob, FUSE_BLOB_BYTES)) return 1;
    snprintf(p, sizeof p, "%s/data/model_mbv2.bin", root);
    if (load(p, head_blob, BLOB_BYTES)) return 1;

    mbv2_fuse_init(fuse_blob, FUSE_BLOB_BYTES);

    /* ---- the head in the fabric, if FUSE_HEAD_PL=1 ----
     * Same fixtures and comparison as the processor head. */
    int head_pl = mbv2_fuse_head_in_pl();
    if (head_pl) {
        static uint8_t packed[PACKED_BYTES];
        snprintf(p, sizeof p, "%s/data/model_mbv2_packed.bin", root);
        if (load(p, packed, (long)PACKED_BYTES)) return 1;
        printf("== FUSE_HEAD_PL=1: the three deconvolutions and the final 1x1 run "
               "in the fabric ==\n");
        mbv2_fuse_head_init(packed, PACKED_BYTES);
    }

    /* ---- FUSE_NBLK: stop the frame early, to find which block is wrong ----
     * The arena has two slots and blocks alternate, so a full frame leaves only
     * blocks 16 and 15 inspectable. Sweep n and the first block whose slot stops
     * matching its golden is the first broken one. The fixture verdict of a
     * short frame is meaningless: the head is fed a mid-backbone tensor. */
    int nblk = FUSE_NBLK;
    const char *nb = getenv("FUSE_NBLK");
    if (nb) {
        nblk = atoi(nb);
        if (fuse_set_nblk((uint32_t)nblk)) {
            printf("FUSE_NBLK=%d refused (valid 1..%d) -- stop\n", nblk, FUSE_NBLK);
            return 1;
        }
        printf("== SHORT FRAME: %d of %d blocks. Fixture verdicts below are"
               " MEANINGLESS; read the dump. ==\n", nblk, FUSE_NBLK);
    }

    int fail = 0, ran = 0;
    for (int fx = 0; fx < nfix; fx++) {
        snprintf(p, sizeof p, "%s/golden/fix_%d.bin", root, fx);
        FILE *g = fopen(p, "rb");
        if (!g) { printf("no fixture %d (%s) -- stop; the run will FAIL\n", fx, p); break; }
        size_t ok = 1;
        ok &= fread(input_i8, 1, sizeof input_i8, g) == sizeof input_i8;
        ok &= fread(acc_ref,  1, sizeof acc_ref,  g) == sizeof acc_ref;
        ok &= fread(kp_ref,   1, sizeof kp_ref,   g) == sizeof kp_ref;
        ok &= fread(ck_ref,   1, sizeof ck_ref,   g) == sizeof ck_ref;
        fclose(g);
        if (!ok) { printf("fixture %d truncated\n", fx); fail++; continue; }

        fuse_counters_t ctr;
        double t0 = now_ms(), t1, t2;
        if (head_pl) {
            /* sequential: backbone, then the head on the boundary it left, then
             * the drain and the reshape; t1 splits the two engines */
            static int32_t *bounce;
            if (!bounce) bounce = (int32_t *)malloc(mbv2_fuse_head_readout_bytes());
            if (!bounce) { printf("readout bounce alloc failed\n"); return 1; }
            mbv2_fuse_frame_pl(input_i8, -1, &ctr);   /* backbone only */
            t1 = now_ms();
            mbv2_fuse_head_run(0);
            mbv2_fuse_head_readout(0, bounce);
            mbv2_fuse_head_finish(bounce, acc_fu, kp_fu);
            t2 = now_ms();
        } else {
            mbv2_fuse_backbone(input_i8, bb, &ctr);
            t1 = now_ms();
            mbv2_ps_head(head_blob, bb, acc_fu, kp_fu);
            t2 = now_ms();
        }
        ran++;

        long maxd = 0; long nbad = 0; int first = -1;
        for (int i = 0; i < NET_OUT_C * NET_OUT_H * NET_OUT_W; i++) {
            long d = (long)acc_fu[i] - (long)acc_ref[i]; if (d < 0) d = -d;
            if (d) { nbad++; if (first < 0) first = i; }
            if (d > maxd) maxd = d;
        }
        int kbad = 0;
        for (int i = 0; i < NET_OUT_C * 2; i++) if (kp_fu[i] != kp_ref[i]) kbad++;
        int pass = (maxd == 0) && (kbad == 0);

        /* ---- FUSE_DUMP: dump what the PL left in the arena ----
         * Compare slot 0 with golden/p1_golden/vec/b16_out.bin and slot 1 with
         * b15_out.bin. The goldens are CHW and the slot bytes are the PL's
         * [x][c]: transpose exactly once before comparing. */
        const char *dumpdir = getenv("FUSE_DUMP");
        if (dumpdir) {
            /* Whole slots, named by the block whose output they hold: blocks
             * nblk-1 and nblk-2 (16 and 15 for a full frame). */
            for (int slot = 0; slot < 2; slot++) {
                /* the block in slot `slot` is the largest b < nblk with
                 * b % 2 == slot */
                int last = nblk - 1;
                int blk  = (last % 2 == slot) ? last : last - 1;
                if (blk < 0) continue;
                const uint8_t *s = mbv2_fuse_slot_ptr(slot);
                if (!s) { printf("    dump: no slot %d\n", slot); continue; }
                snprintf(p, sizeof p, "%s/fx%d_b%02d_slot%d.bin",
                         dumpdir, fx, blk, blk % 2);
                FILE *o = fopen(p, "wb");
                if (!o) { printf("    dump: cannot write %s\n", p); continue; }
                size_t w = fwrite(s, 1, FUSE_SLOT_BYTES, o);
                fclose(o);
                printf("    dump: %s %zu bytes (block %d)\n", p, w, blk);
            }
            snprintf(p, sizeof p, "%s/fx%d_bb_chw_i16.bin", dumpdir, fx);
            FILE *o = fopen(p, "wb");
            if (o) { fwrite(bb, 1, sizeof bb, o); fclose(o);
                     printf("    dump: %s %zu bytes\n", p, sizeof bb); }
        }

        printf("fixture %d: %s | final max|diff|=%ld | kpts %s"
               " | backbone %.2f ms  head %.2f ms  frame %.2f ms\n",
               fx, pass ? "PASS" : "FAIL", maxd,
               kbad == 0 ? "14/14" : "MISMATCH", t1 - t0, t2 - t1, t2 - t0);

        /* "backbone" above is not the programmable logic: it includes the
         * CHW->[x][c] input transpose, which crosses the uncached arena. Only
         * `pl` below is the hardware. */
        if (head_pl) {
            /* `head` above is the head PL plus the uncached drain plus the
             * reshape; only pl_head below is the hardware. */
            fuse_pl_split_t sp;
            mbv2_fuse_last_pl_split(&sp);
            printf("    split: ps_write_in %.2f ms | ps_stage_bb %.2f ms | "
                   "pl_backbone %.3f ms | pl_head %.3f ms"
                   "  (the two pl_ numbers are the only hardware)\n",
                   sp.t_in_ms, sp.t_stage_ms, sp.t_pl_ms, sp.t_hd_ms);
        } else {
            fuse_split_t sp;
            mbv2_fuse_last_split(&sp);
            printf("    split: ps_write_in %.2f ms | pl %.3f ms | ps_read_out %.2f ms"
                   "  (pl is the only one that is the hardware)\n",
                   sp.t_in_ms, sp.t_pl_ms, sp.t_out_ms);
        }

        /* pixel-phase sticky bits (cleared at ap_start, so per frame); zeros
         * unless the bitstream was built with FUSE_OBS */
        uint32_t nz = fuse_read_pix_nz();
        printf("    pix_nz: array %c%c%c%c | bank_wr %c%c%c%c | bank_rd %c%c%c%c   (0x%03x)\n",
               (nz>>0&1)?'1':'.', (nz>>1&1)?'1':'.', (nz>>2&1)?'1':'.', (nz>>3&1)?'1':'.',
               (nz>>4&1)?'1':'.', (nz>>5&1)?'1':'.', (nz>>6&1)?'1':'.', (nz>>7&1)?'1':'.',
               (nz>>8&1)?'1':'.', (nz>>9&1)?'1':'.', (nz>>10&1)?'1':'.', (nz>>11&1)?'1':'.',
               nz);
        printf("            pixel 0 1 2 3 in each group; '.' = that pixel NEVER"
               " carried data in a PROJECT beat this frame\n");

        /* the frame's first project beat; with FUSE_NBLK=1 it is block 0's */
        uint32_t cap[4];
        fuse_read_arr_cap(cap);
        printf("    arr_cap: pix0 %08x  pix1 %08x  pix2 %08x  pix3 %08x\n",
               cap[0], cap[1], cap[2], cap[3]);

        if (!pass) {
            /* the head is shared with the 65-operator path, so a wrong final
             * accumulator here points at the backbone */
            printf("    %ld of %d accumulator elements differ, first at %d"
                   " (got %ld want %ld)\n",
                   nbad, NET_OUT_C * NET_OUT_H * NET_OUT_W, first,
                   first >= 0 ? (long)acc_fu[first] : 0L,
                   first >= 0 ? (long)acc_ref[first] : 0L);
            if (kbad) {
                printf("    keypoints:");
                for (int k = 0; k < NET_OUT_C; k++)
                    printf(" %s(%d,%d/%d,%d)",
                           (kp_fu[k*2] != kp_ref[k*2] ||
                            kp_fu[k*2+1] != kp_ref[k*2+1]) ? "!" : "",
                           kp_fu[k*2], kp_fu[k*2+1], kp_ref[k*2], kp_ref[k*2+1]);
                printf("\n");
            }
            fail++;
        }

        /* the hardware counters print on pass as well as fail; they are a
         * second instrument against the wall clock */
        fuse_print_counters(&ctr, FUSE_CLK_MHZ);
    }

    /* a run that compared nothing, or fewer fixtures than requested, is not a
     * pass */
    if (ran == 0) { printf("== NO FIXTURE RAN -- nothing was checked ==\n"); return 1; }
    if (ran < nfix) {
        printf("== FAIL: ONLY %d OF %d REQUESTED FIXTURES RAN (%d of those failed) ==\n",
               ran, nfix, fail);
        return 1;
    }
    if (fail) printf("== %d of %d FIXTURE(S) FAILED ==\n", fail, ran);
    else      printf("== FUSED BACKBONE BIT-EXACT vs golden (%d fixtures) ==\n", ran);
    return fail ? 1 : 0;
}
