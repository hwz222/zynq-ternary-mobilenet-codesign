/* ============================================================================
 *  mbv2_fuse_eval.c -- run a batch of pre-quantised images through the board
 *  and save the raw outputs, for an accuracy measurement on the board itself.
 *
 *      mbv2_fuse_eval <proj_root> <inputs.bin> <outputs.bin>
 *        <proj_root>/data/fuse_weights.bin, data/model_mbv2.bin,
 *        data/model_mbv2_packed.bin (FUSE_HEAD_PL=1)       as mbv2_fuse_test
 *        <inputs.bin>   N records of int8[3*256*256] (CHW, quantised with
 *                       INPUT_SCALE), the format of a fixture's first part
 *        <outputs.bin>  N records of int32 final accumulator [14*64*64]
 *                       followed by int32 keypoints [14*2], the format of a
 *                       fixture's acc_ref and kp_ref
 *
 *  The frame path is mbv2_fuse_test's, one image at a time (no cross-frame
 *  pipeline), so the outputs are those the fixture gate checks bit-exact.
 *  The host scores them with train/mbv2_pose/src/score_board.py.
 *  Environment: FUSE_HEAD_PL=1 head in the fabric (as deployed), 0 on the
 *  processor. Exit status 0 only if every record of inputs.bin was written.
 * ========================================================================== */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "mbv2_ps.h"
#include "mbv2_fuse_ps.h"
#include "model_meta.h"
#include "pack_meta_mbv2.h"
#include "../../tools/fuse_desctab.h"

#define FUSE_BLOB_BYTES 740992          /* as mbv2_fuse_test.c */
#define PACKED_BYTES ((size_t)W2_AL + (size_t)W2HW_BYTES + (size_t)W8_BYTES)
#define IN_BYTES  ((long)NET_IN_C * NET_IN_H * NET_IN_W)
#define ACC_N     (NET_OUT_C * NET_OUT_H * NET_OUT_W)

static uint8_t  fuse_blob[FUSE_BLOB_BYTES];
static int8_t   head_blob[BLOB_BYTES];
static int8_t   input_i8[NET_IN_C * NET_IN_H * NET_IN_W];
static int32_t  acc_fu[ACC_N];
static int32_t  kp_out[NET_OUT_C * 2];
static int      kp_fu[NET_OUT_C * 2];
static int16_t  bb[MBV2_BB_LEN];

static double now_ms(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
                            return t.tv_sec*1e3 + t.tv_nsec/1e6; }

static int load(const char *path, void *dst, long n) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return 1; }
    long sz;
    fseek(f, 0, SEEK_END); sz = ftell(f); rewind(f);
    if (sz != n) { printf("%s: file is %ld bytes, want %ld\n", path, sz, n);
                   fclose(f); return 1; }
    { long got = (long)fread(dst, 1, n, f); fclose(f);
      if (got != n) { printf("%s: got %ld want %ld\n", path, got, n); return 1; } }
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 4) {
        printf("usage: mbv2_fuse_eval <proj_root> <inputs.bin> <outputs.bin>\n");
        return 1;
    }
    const char *root = argv[1];
    char p[512];

    snprintf(p, sizeof p, "%s/data/fuse_weights.bin", root);
    if (load(p, fuse_blob, FUSE_BLOB_BYTES)) return 1;
    snprintf(p, sizeof p, "%s/data/model_mbv2.bin", root);
    if (load(p, head_blob, BLOB_BYTES)) return 1;
    mbv2_fuse_init(fuse_blob, FUSE_BLOB_BYTES);

    int head_pl = mbv2_fuse_head_in_pl();
    int32_t *bounce = NULL;
    if (head_pl) {
        static uint8_t packed[PACKED_BYTES];
        snprintf(p, sizeof p, "%s/data/model_mbv2_packed.bin", root);
        if (load(p, packed, (long)PACKED_BYTES)) return 1;
        mbv2_fuse_head_init(packed, PACKED_BYTES);
        bounce = (int32_t *)malloc(mbv2_fuse_head_readout_bytes());
        if (!bounce) { printf("readout bounce alloc failed\n"); return 1; }
    }

    FILE *fi = fopen(argv[2], "rb");
    if (!fi) { printf("cannot open %s\n", argv[2]); return 1; }
    fseek(fi, 0, SEEK_END); long isz = ftell(fi); rewind(fi);
    if (isz <= 0 || isz % IN_BYTES) {
        printf("%s: %ld bytes is not a whole number of %ld-byte inputs\n", argv[2], isz, IN_BYTES);
        fclose(fi); return 1;
    }
    long n = isz / IN_BYTES;
    FILE *fo = fopen(argv[3], "wb");
    if (!fo) { printf("cannot write %s\n", argv[3]); fclose(fi); return 1; }

    printf("== mbv2_fuse_eval: %ld images, head %s ==\n", n, head_pl ? "in the fabric" : "on the processor");
    double t0 = now_ms();
    long done = 0;
    for (long i = 0; i < n; i++) {
        if (fread(input_i8, 1, sizeof input_i8, fi) != sizeof input_i8) {
            printf("short read at image %ld\n", i); break;
        }
        fuse_counters_t ctr;
        if (head_pl) {
            mbv2_fuse_frame_pl(input_i8, -1, &ctr);
            mbv2_fuse_head_run(0);
            mbv2_fuse_head_readout(0, bounce);
            mbv2_fuse_head_finish(bounce, acc_fu, kp_fu);
        } else {
            mbv2_fuse_backbone(input_i8, bb, &ctr);
            mbv2_ps_head(head_blob, bb, acc_fu, kp_fu);
        }
        for (int k = 0; k < NET_OUT_C * 2; k++) kp_out[k] = (int32_t)kp_fu[k];
        if (fwrite(acc_fu, 1, sizeof acc_fu, fo) != sizeof acc_fu ||
            fwrite(kp_out, 1, sizeof kp_out, fo) != sizeof kp_out) {
            printf("write failed at image %ld\n", i); break;
        }
        done++;
        if ((i + 1) % 100 == 0) printf("  %ld / %ld\n", i + 1, n);
    }
    fclose(fi);
    if (fclose(fo)) { printf("closing %s failed\n", argv[3]); return 1; }
    double t1 = now_ms();
    printf("== wrote %ld of %ld records (%zu bytes each) in %.1f s ==\n",
           done, n, sizeof acc_fu + sizeof kp_out, (t1 - t0) / 1e3);
    return done == n ? 0 : 1;
}
