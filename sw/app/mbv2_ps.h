/* mbv2_ps.h -- PS-side frame orchestrator (PL backbone + NEON head). */
#ifndef MBV2_PS_H
#define MBV2_PS_H
#include <stddef.h>
#include <stdint.h>
#include "model_meta.h"   /* NET_IN_H/W, NET_OUT_C/H/W: the geometry below is derived from it */

#ifdef __cplusplus
extern "C" {
#endif

/* One frame. Inputs:
 *   w2rom/w8rom : the packed weight ROM (data/model_mbv2_packed.bin) the PL reads.
 *   head_blob   : the unpacked blob (data/model_mbv2.bin) for the PS/NEON deconv+final head.
 *   input_i8    : int8[3*NET_IN_H*NET_IN_W] pre-quantized camera frame.
 * Outputs:
 *   final_acc   : int32[NET_OUT_C*NET_OUT_H*NET_OUT_W] raw final-conv accumulator
 *                 (heatmaps = acc*scale+bias).
 *   keypoints   : int[NET_OUT_C*2] argmax (x,y) per joint on the NET_OUT_H x NET_OUT_W grid. */
/* One-time arena setup (weights -> DDR arena). Called lazily by mbv2_ps_infer on the first
 * frame, or explicitly at startup. */
void mbv2_ps_init(const uint8_t *w2rom, const int8_t *w8rom, const int8_t *head_blob);

void mbv2_ps_infer(const uint8_t *w2rom, const int8_t *w8rom, const int8_t *head_blob,
                   const int8_t *input_i8, int32_t *final_acc, int *keypoints);

/* ---- split API for a cross-frame PS/PL pipeline ----
 * mbv2_ps_backbone: im2col(stem) + PL backbone ops, writing the 320x8x8 boundary
 *   tensor into caller-provided cached scratch `bb_out` (int16[MBV2_BB_LEN]).
 *   This is the PL-heavy stage (drive it on a worker thread).
 * mbv2_ps_head: deconv head + final + arg-max from a bb_out buffer -> final_acc + keypoints.
 *   Pure PS/NEON stage. bb_out is a decoupled copy, so head(frame N-1) can run while
 *   backbone(frame N) reuses the DDR arena. Double-buffer bb_out across frames.
 *
 * The boundary tensor is NHWC (int16) when HEAD_NHWC=1, the default in
 * mbv2_ps.c; mbv2_ps_head() then passes it to mbv2_head_nhwc(). With
 * HEAD_NHWC=0 the backbone transposes it to CHW instead. */
/* Backbone->head boundary tensor length (int16 elements). The backbone
 * downsamples by 32, so the spatial side is NET_IN_H/32 (8 at a 256 input). */
#define MBV2_BB_LEN (320 * (NET_IN_H / 32) * (NET_IN_W / 32))
void mbv2_ps_backbone(const uint8_t *w2rom, const int8_t *w8rom, const int8_t *head_blob,
                      const int8_t *input_i8, int16_t *bb_out);

/* mbv2_ps_backbone split into PREP and PLRUN stages. PREP writes a double-buffered
 * slot {0,1} (convert + im2col) and can run one frame ahead, during the PL of the
 * previous frame. PLRUN drives the PL ops and the boundary copy from the
 * precomputed slot. PREP(slot A) does not race PLRUN(slot B != A). Run only one
 * PLRUN at a time. */
void mbv2_ps_prep(const uint8_t *w2rom, const int8_t *w8rom, const int8_t *head_blob,
                  const int8_t *input_i8, int slot);
void mbv2_ps_plrun(int slot, int16_t *bb_out);
void mbv2_ps_head(const int8_t *head_blob, const int16_t *bb_out,
                  int32_t *final_acc, int *keypoints);

/* HEAD_PL mode (env HEAD_PL=1): the PL runs the head too, so mbv2_ps_plrun writes
 * no bb_out and mbv2_ps_head must not be called (it exits if it is). The
 * replacement is mbv2_ps_finish_pl: arena int32 -> CHW final_acc + arg-max
 * keypoints. It reads PL state that is not double-buffered, so it must run in
 * the PLRUN thread before that slot is released to the next frame.
 * mbv2_ps_head_in_pl() reports the mode. */
int  mbv2_ps_head_in_pl(void);
void mbv2_ps_finish_pl(int32_t *final_acc, int *keypoints);

/* The same work split up, for pipelines. Under HEAD_PL the PL writes each frame's
 * accumulator into a private per-slot arena buffer that the next frame does not
 * touch, so a later stage can do the uncached readout and the reshape off the PL
 * thread. Size a per-slot buffer with mbv2_ps_readout_bytes() (valid after one
 * plrun). */
size_t mbv2_ps_readout_bytes(void);
void   mbv2_ps_readout_slot(int slot, int32_t *dst);   /* frame k's own final buffer */
void   mbv2_ps_readout_pl(int32_t *dst);               /* = slot 0, for the sequential path */
void   mbv2_ps_finish_from(const int32_t *src, int32_t *final_acc, int *keypoints);

#ifdef __cplusplus
}
#endif
#endif
