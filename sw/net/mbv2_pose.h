/* mbv2_pose.h -- integer-only C inference of the pose network (golden model). */
#ifndef MBV2_POSE_H
#define MBV2_POSE_H
#include <stdint.h>

int mbv2_load_weights(const char *path, int8_t **blob);

/* input: int8[3*256*256] (pre-quantized with INPUT_SCALE).
 * final_acc: int32[14*64*64] raw final-conv accumulator (heatmaps = acc*FINAL_OUT_MULT+bias).
 * keypoints: int[14*2] argmax (x,y) per joint, or NULL.
 * checksums: long long[N_OPS] per-op output sums for golden comparison, or NULL. */
void mbv2_forward(const int8_t *blob, const int8_t *input,
                  int32_t *final_acc, int *keypoints, long long *checksums);

/* Backbone/head split helpers:
 *   mbv2_first_head_op() -> index of the first deconv op (backbone/head boundary).
 *   mbv2_head()          -> deconv head + final conv + argmax from the backbone output
 *                           tensor (int16 CHW, OPS[first deconv].ic x 8 x 8 at 256 input). */
int  mbv2_first_head_op(void);
void mbv2_dark_refine(const int32_t *final_acc, float coords[][2]);  /* sub-pixel decode */
void mbv2_head8(const int8_t *blob, const int16_t *backbone_out,
                int32_t *final_acc, int *keypoints);   /* uint8-activation head, same values */
void mbv2_head(const int8_t *blob, const int16_t *backbone_out,
               int32_t *final_acc, int *keypoints);
void mbv2_head_nhwc(const int8_t *blob, const int16_t *bb_nhwc,
                    int32_t *final_acc, int *keypoints);  /* NHWC backbone_out */

#endif
