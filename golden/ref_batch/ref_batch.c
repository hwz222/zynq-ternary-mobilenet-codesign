/* ============================================================================
 *  ref_batch.c -- the integer C reference (sw/net/mbv2_pose.c) on a batch of
 *  pre-quantised images, written in the record format of the board's
 *  mbv2_fuse_eval, so the two can be compared byte for byte.
 *
 *  Build and run from the repository root (git-bash, gcc):
 *    gcc -O2 -Isw/net -Imodels/mbv2_pose -o build/ref_batch golden/ref_batch/ref_batch.c \
 *        models/mbv2_pose/model_meta.c sw/net/mbv2_pose.c -lm
 *    build/ref_batch models/mbv2_pose/model_mbv2.bin <inputs.bin> <outputs.bin>
 *
 *  inputs.bin   N records of int8[3*256*256] (CHW, quantised with INPUT_SCALE)
 *  outputs.bin  N records of int32 final accumulator [14*64*64] + int32 keypoints [14*2]
 *  The model description is the model_meta.c it was compiled with; it must be
 *  the one the blob was exported with (the same export folder).
 * ========================================================================== */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "mbv2_pose.h"
#include "model_meta.h"

#define IN_BYTES ((long)NET_IN_C * NET_IN_H * NET_IN_W)
#define ACC_N    (NET_OUT_C * NET_OUT_H * NET_OUT_W)

static int8_t  input_i8[NET_IN_C * NET_IN_H * NET_IN_W];
static int32_t acc[ACC_N];
static int     kp[NET_OUT_C * 2];
static int32_t kp_out[NET_OUT_C * 2];

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: ref_batch <model_mbv2.bin> <inputs.bin> <outputs.bin>\n");
        return 1;
    }
    int8_t *blob = NULL;
    if (mbv2_load_weights(argv[1], &blob)) return 1;
    FILE *fi = fopen(argv[2], "rb");
    if (!fi) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }
    fseek(fi, 0, SEEK_END); long isz = ftell(fi); rewind(fi);
    if (isz <= 0 || isz % IN_BYTES) {
        fprintf(stderr, "%s: %ld bytes is not a whole number of inputs\n", argv[2], isz);
        return 1;
    }
    long n = isz / IN_BYTES, done = 0;
    FILE *fo = fopen(argv[3], "wb");
    if (!fo) { fprintf(stderr, "cannot write %s\n", argv[3]); return 1; }
    for (long i = 0; i < n; i++) {
        if (fread(input_i8, 1, sizeof input_i8, fi) != sizeof input_i8) break;
        mbv2_forward(blob, input_i8, acc, kp, NULL);
        for (int k = 0; k < NET_OUT_C * 2; k++) kp_out[k] = (int32_t)kp[k];
        if (fwrite(acc, 1, sizeof acc, fo) != sizeof acc ||
            fwrite(kp_out, 1, sizeof kp_out, fo) != sizeof kp_out) break;
        done++;
    }
    fclose(fi);
    if (fclose(fo)) return 1;
    printf("ref_batch: %ld of %ld records\n", done, n);
    return done == n ? 0 : 1;
}
