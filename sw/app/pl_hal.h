/* ============================================================================
 *  pl_hal.h -- hardware abstraction for the 65-operator PL accelerator.
 *
 *  The board implementation is pl_hal_zynq.c: pl_run_layer() writes the AXI-Lite
 *  descriptor, starts the IP and polls ap_done. Everything above it (op
 *  sequencing, im2col, head, arg-max) lives in mbv2_ps.c and uses only this
 *  interface.
 * ========================================================================== */
#ifndef PL_HAL_H
#define PL_HAL_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Pipeline mode: when on (1), pl_run_layer sleep-polls ap_done so the PL-driver
 * thread yields its core to the head worker during PL compute. */
void pl_set_wait_yield(int on);

/* AXI-Lite s_axi_control offsets of the HLS-generated IP driver (each 64-bit
 * pointer occupies two 32-bit words). pl_hal_zynq.c does not use these macros:
 * it has its own R_* table, whose values differ from the pointer offsets here. */
#define PL_CTRL       0x00   /* [0]=ap_start [1]=ap_done [2]=ap_idle [3]=ap_ready */
#define PL_GIE        0x04
#define PL_IER        0x08
#define PL_ISR        0x0c
#define PL_IN         0x10   /* + 0x14 : in   (activations, gmem0)      */
#define PL_IN2        0x1c   /* + 0x20 : in2  (residual branch, gmem2)  */
#define PL_OUT        0x28   /* + 0x2c : out  (activations, gmem0)      */
#define PL_W2         0x34   /* + 0x38 : w2   (2-bit ternary ROM, gmem1)*/
#define PL_W8         0x40   /* + 0x44 : w8   (int8 dw weights, gmem1)  */
#define PL_M0         0x4c   /* + 0x50 : M0   (requant, gmem2)          */
#define PL_BIAS       0x58   /* + 0x5c : bias (requant, gmem2)          */
#define PL_SH         0x64   /* + 0x68 : sh   (requant, gmem2)          */
/* One layer descriptor = the mbv2_layer() argument list. All pointers are DDR
 * physical addresses (what the m_axi masters see). */
typedef struct {
    int type, ic, h, w, oc, kh, stride, pad;
    int w2_off, w8_off, rq_off;
    int relu, lo, hi, mp, mq, sh;
    int w8fmt;                           /* S2a per-tensor int8 DDR flags: b0=in b1=in2 b2=out */
    uint64_t in_pa, in2_pa, out_pa;      /* DDR physical addrs of the act tensors     */
    uint64_t w2_pa, w8_pa, m0_pa, bias_pa, sh_pa;  /* weight/requant table addrs        */
} pl_desc_t;

/* Run one layer to completion (blocking). Returns a PL cycle count if the
 * implementation can read one, else 0 (pl_hal_zynq.c always returns 0). */
uint64_t pl_run_layer(const pl_desc_t *d);

/* Allocate the DDR arena the PL m_axi masters read/write. Returns the CPU
 * (virtual) base and writes the physical base to *phys. On the board this is a
 * contiguous reserved-memory region. mbv2_ps.c lays all PL-touched buffers
 * (weights, requant tables, activations) into it and passes physical addresses
 * in the descriptor. */
void *pl_arena_init(uint64_t *phys, uint64_t size);

void pl_hal_init(void);
void pl_hal_close(void);

#ifdef __cplusplus
}
#endif
#endif
