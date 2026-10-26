/* ============================================================================
 *  mbv2_fuse_ps.h -- frame program for the fused backbone (and its head engine).
 *
 *  The backbone replaces mbv2_ps_backbone(); the NEON head, mbv2_ps_head(), is
 *  reused against the same boundary tensor: int16, NHWC, MBV2_BB_LEN elements.
 *  It requires the NHWC head (HEAD_NHWC=1, the default in mbv2_ps.c).
 *
 *  With FUSE_HEAD_PL=1 the head (three deconvolutions and the final 1x1) runs in
 *  the fabric as a second engine; see the last section.
 * ========================================================================== */
#ifndef MBV2_FUSE_PS_H
#define MBV2_FUSE_PS_H
#include <stddef.h>
#include <stdint.h>
#include "pl_hal_fuse.h"
#include "mbv2_ps.h"      /* MBV2_BB_LEN, mbv2_ps_head */

#ifdef __cplusplus
extern "C" {
#endif

/* Where a frame's time went. Only t_pl_ms (the start->done window returned by
 * fuse_run_frame()) is programmable logic; t_in_ms and t_out_ms are processor
 * accesses to the uncached arena, so the wall clock around
 * mbv2_fuse_backbone() is not a backbone time. */
typedef struct {
    double t_in_ms;    /* PS: CHW -> [x][c] into uncached arena memory */
    double t_pl_ms;    /* PL: CTRL_START -> ap_done                    */
    double t_out_ms;   /* PS: [x][c] int8 -> CHW int16 read-back       */
} fuse_split_t;

void mbv2_fuse_last_split(fuse_split_t *s);

void mbv2_fuse_init(const uint8_t *weight_file, size_t weight_bytes);

void mbv2_fuse_backbone(const int8_t *input_i8, int16_t *bb_out,
                        fuse_counters_t *counters);

/* Diagnostic, not a frame path: does the two uncached memory phases of
 * mbv2_fuse_backbone() and skips the PL run between them, so `bb_out` gets the
 * previous frame's boundary. `cached` repeats the same two phases against
 * ordinary cacheable memory, plus the `dc civac` maintenance a cacheable arena
 * would owe. */
void mbv2_fuse_backbone_io_only(const int8_t *input_i8, int16_t *bb_out, int cached);

void mbv2_fuse_infer(const int8_t *input_i8, const int8_t *head_blob,
                     int32_t *final_acc, int *keypoints,
                     fuse_counters_t *counters);

/* ============================================================================
 *  The head in the programmable logic
 *
 *  Selected by the environment (FUSE_HEAD_PL=1, default 0), so both paths are
 *  available in one binary. The three deconvolutions and the final 1x1 run in
 *  the fabric; arg-max stays on the processor (mbv2_fuse_head_finish). What
 *  crosses back is the heatmap accumulator, mbv2_fuse_head_readout_bytes() per
 *  frame, instead of the boundary tensor.
 *
 *  The head's output is double-buffered (slot frame & 1) so frame k's
 *  accumulator is not touched while frame k+1's head runs. Without the BB2HD
 *  register the driver re-commits op64 with an alternating out_base between
 *  frames (the fabric offsets only op61's input); with it, the fabric offsets
 *  op64's output itself.
 * ========================================================================== */
int    mbv2_fuse_head_in_pl(void);        /* env FUSE_HEAD_PL, default 0 */

/* The derivation on its own: no board, no arena, no register touched. Fills the
 * four descriptors and the 4 x FUSE_HD_NRQ requantisation entries for an arena
 * whose physical base is `arena_pa`, with op64's output pointed at heatmap slot
 * `hm_slot`. Returns 0, or -1 with a reason on stderr. */
int    mbv2_fuse_head_build(uint64_t arena_pa, fuse_hd_desc_t d[FUSE_HD_NOPS],
                            fuse_hd_rq_t rq[FUSE_HD_NOPS][FUSE_HD_NRQ],
                            int hm_slot);

/* Boot the head: copy its weights into the arena, derive the four descriptors
 * and the requantisation words from the model's own tables, program them, and
 * verify both sticky registers. `packed` is models/mbv2_pose/
 * model_mbv2_packed.bin; the head weights are its HD_PL tail, in the fabric's
 * stream order. Exits on failure. */
void   mbv2_fuse_head_init(const uint8_t *packed, size_t packed_bytes);

/* One frame of the producer stage with the head in the fabric:
 *   - the input image into the arena
 *   - if `head_frame >= 0`: start the head on the boundary the last backbone
 *     left (staging it and re-pointing op64 first when BB2HD is off)
 *   - run the backbone for this frame (fuse_run_frame, which waits on it)
 *   - if `head_frame >= 0`: wait for the head
 * The two engines overlap. A call with head_frame < 0 starts a sequence.
 * Nothing here reads the heatmap. */
void   mbv2_fuse_frame_pl(const int8_t *input_i8, int head_frame,
                          fuse_counters_t *counters);

/* Run the head alone (pipeline drain, sequential path): start it on the last
 * backbone's boundary, wait, and leave the heatmap in slot `frame & 1`. */
void   mbv2_fuse_head_run(int frame);

/* Consumer side: an uncached drain of the heatmap slot, then cached work. */
size_t mbv2_fuse_head_readout_bytes(void);              /* 262,144 */
void   mbv2_fuse_head_readout(int frame, int32_t *dst); /* slot frame & 1 */
void   mbv2_fuse_head_finish(const int32_t *src, int32_t *final_acc, int *keypoints);

/* Diagnostic, not a frame path: the PL-head twin of
 * mbv2_fuse_backbone_io_only(). Does the producer stage's uncached traffic
 * (input image in, boundary staged) with both engines skipped. */
void   mbv2_fuse_frame_pl_io_only(const int8_t *input_i8);

/* Where a PL-head frame's time went, alongside fuse_split_t's three phases. */
typedef struct {
    double t_in_ms;      /* PS: the input image into the arena              */
    double t_stage_ms;   /* PS: the boundary into the head's private slots  */
    double t_pl_ms;      /* PL: the backbone, start->done                   */
    double t_hd_ms;      /* PL: the head, start->done (overlapped)          */
} fuse_pl_split_t;
void   mbv2_fuse_last_pl_split(fuse_pl_split_t *s);

/* A read-only pointer to slot `slot` of the activation arena, to dump the bytes
 * the PL wrote. Returns NULL before init or for an out-of-range slot. The bytes
 * are in the PL's [x][c] order, not CHW. Diagnosis only. */
const uint8_t *mbv2_fuse_slot_ptr(int slot);

/* ============================================================================
 *  Input layout. The PL reads every activation row as c_in * w_in bytes in
 *  [x][c] order; the stem's 3x3 stride-2 gather is done in the PL
 *  (twn_act_gather, stem mode). mbv2_fuse_write_input() is therefore a
 *  CHW -> [x][c] transpose of the int8 image, each row padded with zeros to a
 *  multiple of 128 bytes (tools/gen_fuse_ddr.py is the reference for the bytes).
 * ========================================================================== */
void mbv2_fuse_write_input(const int8_t *input_i8, uint8_t *dst);

#ifdef __cplusplus
}
#endif
#endif
