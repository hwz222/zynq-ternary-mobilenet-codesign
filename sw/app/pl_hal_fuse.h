/* ============================================================================
 *  pl_hal_fuse.h -- PS interface to the fused backbone accelerator and its head
 *  engine (control registers in rtl/fuse/twn_csr.v, UIO + /dev/mem arena).
 *
 *  Not an implementation of pl_hal.h: that interface issues one call per
 *  operator, the fused design runs a whole frame from one start.
 *
 *  Backbone lifecycle:
 *      fuse_hal_init()                 find the UIO node, map the control window
 *      fuse_arena_init(&pa, size)      map the DDR arena
 *      ... load the weight file at w_base and the input tensor at in_pa ...
 *      fuse_set_bases(w_base, act_base)
 *      fuse_load_desctab()             FUSE_NBLK * FUSE_DESC_WORDS words, once
 *      fuse_check_table()              required: the start is gated on it
 *      per frame:  fuse_run_frame(in_pa, out_pa, yield)
 *      fuse_read_counters(&c)
 *
 *  twn_csr.v starts a frame only if tab_checked && d_valid, and reports no
 *  error on the start write, so skipping fuse_check_table() hangs the first
 *  frame silently.
 *
 *  Head engine (separate start/busy/done, own descriptors and requantisation
 *  store):
 *      fuse_hd_program(desc, rq)       once at boot; verifies the sticky evidence
 *      per frame:  fuse_hd_start() ... fuse_hd_wait()
 *
 *  The bitstream must be built with FUSE_HD_PROBE=1 (vivado/build_bd_fuse.tcl,
 *  parameter HD_PROBE of twn_fuse_top). Without it the CSR window still exists
 *  and reads back, but no head engine is instantiated and done never asserts.
 *  Without a head engine, the backbone output can be handed to mbv2_ps_head().
 * ========================================================================== */
#ifndef PL_HAL_FUSE_H
#define PL_HAL_FUSE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Default arena: a `no-map` reserved-memory region, mapped as Device memory.
 * memset() can fault on it (dc zva); use the NEON copy helpers instead. */
#define FUSE_ARENA_PA_DEFAULT  0x60000000ull
#define FUSE_ARENA_SZ_DEFAULT  0x10000000ull   /* 256 MB */

typedef struct {
    uint32_t total;        /* the backbone, end to end                        */
    uint32_t array;        /* the shared ternary array issuing                */
    uint32_t dw;           /* the depthwise running                           */
    uint32_t stall_mem;    /* no stage could advance                          */
    uint32_t idle_pre;     /* array idle BEFORE its first grant in a block    */
    uint32_t idle_post;    /* array idle AFTER its last                       */
} fuse_counters_t;

void      fuse_hal_init(void);
void     *fuse_arena_init(uint64_t *phys, uint64_t size);
void      fuse_set_bases(uint64_t w_base_pa, uint64_t act_base_pa);

/* Run only the first `n` blocks (1..FUSE_NBLK). Block n-1's output is left in
 * slot (n-1) % 2 and can be compared against its golden output, which locates
 * the first wrong block. Call after fuse_load_desctab(), which writes the full
 * count. Returns 0, or -1 if out of range or the register did not take. */
int       fuse_set_nblk(uint32_t n);

/* Twelve sticky pixel-phase bits (PIX_NZ), cleared at ap_start, read after a
 * frame:
 *   [3:0]  array output non-zero for pixel p   [7:4]  scatter bank write non-zero
 *   [11:8] scatter bank read non-zero
 * Only meaningful when twn_fuse_top is built with FUSE_OBS (zeros otherwise). */
uint32_t  fuse_read_pix_nz(void);

/* The frame's first project beat, verbatim (128 bits at CAP0..CAP3); out[p] is
 * pixel p's bytes. Zeros unless twn_fuse_top is built with FUSE_OBS. */
void      fuse_read_arr_cap(uint32_t out[4]);
void      fuse_load_desctab(void);
int       fuse_check_table(void);                 /* 0 = pass, -1 = refused    */
/* One backbone frame: clears any leftover ap_done (warning once per process if
 * one is found), waits out a still-busy core, fences the caller's arena stores
 * (dsb sy on AArch64), then START and poll. Returns the START->done wall clock
 * in ns; exits on a 3 s timeout. */
uint64_t  fuse_run_frame(uint64_t in_pa, uint64_t out_pa, int yield_wait);
void      fuse_read_counters(fuse_counters_t *c);
void      fuse_print_counters(const fuse_counters_t *c, double clk_mhz);

/* ---- head engine: twn_csr.v window 0x0100..0x013c, requantisation store
 * 0x0400..0x07fc. The write sequence follows rtl/fuse/tb/tb_hd_int.v. ---- */
#define FUSE_HD_NOPS   4         /* operators; index 0..3 = op61..op64          */
#define FUSE_HD_NRQ    32        /* requantisation entries per operator         */

/* One descriptor. Field widths are twn_csr.v's HD_SHAPE / HD_FLAGS / HD_CLAMP
 * packings; fuse_hd_desc_check() enforces them plus three engine rules. */
typedef struct {
    uint64_t in_base, w_base, out_base;   /* 40-bit physical                    */
    uint32_t in_beats, w_beats, out_beats;/* 24-bit, in 128-bit beats           */
    uint32_t ic, oc, h, w;                /* 9 / 6 / 7 / 7 bits                 */
    uint8_t  type4, slice, relu;          /* HD_FLAGS [0] [1] [2]               */
    int32_t  lo, hi;                      /* HD_CLAMP, signed 16 each           */
} fuse_hd_desc_t;

/* One requantisation entry: m0 signed 18 bits, bias signed 40, sh 6 bits;
 * stored as two 32-bit words (see twn_csr.v, requantisation window). */
typedef struct { int32_t m0; int64_t bias; uint32_t sh; } fuse_hd_rq_t;

/* ---- pure encoders: no register access, so they can be tested on a host ---- */
uint32_t fuse_hd_shape_word(const fuse_hd_desc_t *d);
uint32_t fuse_hd_flags_word(const fuse_hd_desc_t *d);
uint32_t fuse_hd_clamp_word(const fuse_hd_desc_t *d);
void     fuse_hd_rq_words(const fuse_hd_rq_t *e, uint32_t w[2]);
uint32_t fuse_hd_rq_off(int op, int oc, int half);   /* byte offset in the window */

/* 0 = legal. On refusal writes a one-line reason into `why` and returns -1.
 * Besides the field widths it enforces three rules that the RTL checks only in
 * simulation:
 *   type-4 OC must be a multiple of 4 (op64 declares 16, not the model's 14:
 *      the engine emits OC[5:2] beats, so OC=14 would drop two channels)
 *   mode A (not type 4, slice set) needs 4*H*W*OC <= 8192
 *   in_beats is one pass: in_beats*16 == H*W*IC */
int      fuse_hd_desc_check(const fuse_hd_desc_t *d, int op, char *why, size_t n);

/* ---- board ---- */
/* Stage all twelve fields and commit them to `op`. A commit does not clear the
 * staging set, so every field is written every time. */
int  fuse_hd_commit(const fuse_hd_desc_t *d, int op);

/* Boot: writes the 256 requantisation words, then the four descriptors, then
 * reads back both sticky registers and fails unless HD_COMMIT[7:4] == 0xF and
 * HD_RQ_STAT == 0x0000100F. The tables themselves cannot be read back, so these
 * are the only evidence the writes landed. Returns 0/-1. */
int  fuse_hd_program(const fuse_hd_desc_t d[FUSE_HD_NOPS],
                     const fuse_hd_rq_t rq[FUSE_HD_NOPS][FUSE_HD_NRQ]);

/* Start the four-operator walk. Returns -1 if the head is still busy: a start
 * written while busy is dropped by twn_csr.v, not queued. */
int  fuse_hd_start(void);

/* Wait for done. HD_CTRL has one layout for read and write: bit 0 start, bit 1
 * busy (read only), bit 2 done (read) / clear done (write). The backbone's CTRL
 * at 0x0000 differs: read done is bit 2, write clear-done is bit 1. Returns 0 on
 * done, -1 on timeout, and fills *ns with the start->done wall clock. */
int  fuse_hd_wait(int yield_wait, uint64_t *ns);

/* Diagnostics, in the shape the CSR offers them: HD_CTRL, HD_COMMIT, HD_RQ_STAT. */
void fuse_hd_read_status(uint32_t *ctrl, uint32_t *commit, uint32_t *rq_stat);

/* ---- BB2HD (0x0060, twn_csr.v): last block writes into the head's input ----
 * With the enable on, the last backbone block writes to OUT_PTR + bb_par *
 * 0x10000 instead of its descriptor's slot, and a head start latches hd_sel =
 * the slot the last finished backbone wrote. Read layout:
 *   [0] enable  [1] bb_par (slot the NEXT backbone writes)
 *   [2] hd_sel (slot of the most recently started head)
 *   [3] collision, sticky  [4] the most recent head start ran with enable on
 * Write layout: [0] enable, [1] 1 = clear bb_par (effective only while the
 * backbone is idle), [3] 1 = clear collision. */
#define FUSE_BB2HD_EN        0x1u
#define FUSE_BB2HD_PAR       0x2u
#define FUSE_BB2HD_HDSEL     0x4u
#define FUSE_BB2HD_COLL      0x8u
#define FUSE_BB2HD_HDEN      0x10u
/* 1 if this bitstream has the register (write 1, read it back, restore 0). A
 * bitstream without the register ignores the write and reads 0. */
int      fuse_bb2hd_probe(void);
/* Set the enable. Written only when it changes, except the first call in a
 * process, which always writes: a previous process may have left it on. */
void     fuse_bb2hd_set(int en);
/* Enable on, parity back to 0, collision cleared. Only while the backbone is
 * idle (the fabric ignores the parity clear otherwise). */
void     fuse_bb2hd_restart(void);
uint32_t fuse_bb2hd_read(void);

#ifdef __cplusplus
}
#endif
#endif
