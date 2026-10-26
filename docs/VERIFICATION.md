# Verification

The accelerator is held to one rule: its output is **bit-exact** to an integer C reference of the
network, on every byte and on every test. Accuracy is measured once on the host model and once on the
board; everything between the two is checked for exact equality, not for closeness. This page lists
the gates, in the order a change meets them, and what each one does and does not show.

## The chain of references

```
quantisation-aware PyTorch model (train/mbv2_pose)          host PCKh, score_ckpt.py
        | export: export_board_model.py (ternary check first)
        v
integer network: models/mbv2_pose + sw/net/mbv2_pose.c        plain layer-by-layer C, the reference
        | P0: same numbers in the accelerator's fused, row-streamed order
        v
golden/p0_fused  ->  golden/p1_golden (P1)                  per-block golden vectors
        | unit tests, 17-block run, whole-frame AXI run
        v
RTL (rtl/), simulated with Vivado xsim
        | bitstream, board
        v
board: deploy.sh verify (4 fixtures), mbv2_fuse_eval (2,289 images, compared with golden/ref_batch)
```

The export changes the numbers once (floating-point model to integer network); the board PCKh in
`results/board_results.json` is measured on the integer network for that reason. After the export,
no step is allowed to change a single bit.

## Gates

| gate | command | compares | must print |
|---|---|---|---|
| ternary check | inside `train/mbv2_pose/export/export_board_model.py` | every ternarised layer holds only {-1, 0, +1} before its scale, and zeros occur | `[ternary gate] ... PASS` |
| P0 | `( cd golden/p0_fused && bash run_p0.sh )` | the fused, row-streamed C order against the plain integer network on the four fixtures; then rebuilds with deliberately wrong ring depths and constant widths, which must fail | `P0 GATE: PASS` |
| P1 | `( cd golden/p1_golden && bash run_p1.sh )` | re-runs P0, generates every block's input, output, weights and requantisation, regenerates and requires identical hashes, checks all four fixtures | `P1 GATE: PASS` |
| DDR image | `python tools/gen_fuse_ddr.py` | the packed weight image and arena map against the golden vectors | `gen_fuse_ddr verify: ALL PASS` |
| multiply-driven lint | `python rtl/sim/lint_multidrive.py --selftest` (run by `vivado/build.cmd`) | no signal is assigned from two always blocks (simulation tolerates it, synthesis does not) | no error |
| unit tests | `powershell -File rtl\fuse\sim\run_units.ps1` | each module against an independent model (Python generators in `rtl/fuse/tb/`, `rtl/tb/`); every gate has at least one "break" run with a planted defect that must fail | PASS per gate, "bites" per break run |
| engine suites | `powershell -File rtl\fuse\sim\run_engine_tests.ps1` | the seven engines (ternary array, depthwise, head, residual, data movers, weight fetch, control), with break runs | `=== ENGINE TESTS: all N ok ===` |
| 17 blocks | `run_p5.ps1` (in `-Integration`) | all 17 blocks through the real sequencer and arrays, 747,520 values, against P1 | `=== P5 bit-exact: 17 pass, 0 fail, ...` |
| whole frame | `run_fuse_axi_boost.ps1 -Only tb_fuse_frame` (in `-Integration`) | every byte `twn_fuse_top` writes to DDR over a frame, through its AXI masters and a DDR model with latency and back-pressure, plus the exact issue-beat count (853,760) | `FRAME PASS` |
| head | `run_hd_int.ps1` (in the head suite) | the head through CSR, sequencer, data movers and AXI, byte for byte, with and without the backbone-to-head direct write, plus destructive arms that must fail | `HD_INT_GATE_PASS` |
| datapath kept | `vivado/fuse_dp_check.tcl` (run by `build.cmd`) | after synthesis and implementation every datapath instance still has cells (a utilisation total cannot tell "fits" from "synthesis removed it") | every instance non-zero |
| timing | `build/timing_impl_fuse_ternpose.rpt` | post-route WNS >= 0 at 240 MHz | "All user specified timing constraints are met" |
| board files | `bash board/deploy.sh data` | SHA-256 of the 9 files on the board against the tree | `all 9 files match` |
| board fixtures | `bash board/deploy.sh verify` | the four fixtures through the whole system, head in the PL and on the processor | max abs diff 0, 14/14 keypoints, for all eight runs |
| board batch | `mbv2_fuse_eval` + `src/score_board.py compare` | 2,289 board outputs against `golden/ref_batch` on the same inputs | 2,289 of 2,289 identical |

`run_engine_tests.ps1 -Integration` runs the engine suites, the 17-block run and the whole-frame run
in one command; on this release it ends with `all 35 ok`.

## Rules that keep the gates meaningful

- **A test that cannot fail proves nothing.** Every unit gate has a break run: the same testbench
  compiled with one planted defect (a define in the RTL, `<MODULE>_NEG_*`, never set in a build, or in
  the testbench). The break run must fail; if it passes, the gate counts as broken.
- **A runner that checked nothing has failed.** A runner ends with one verdict line and a non-zero
  exit code on failure; the whole-frame runner also fails a run that reports zero checks.
- **Generated inputs are never edited by hand.** Golden vectors and testbench cases are written by
  `golden/p1_golden/run_p1.sh`, the generators in `rtl/fuse/tb/` and the tools in `tools/`; the
  generators stop with a message when their inputs are missing or stale.
- **Comment-only edits are proven, not claimed.** `python tools/codeprint.py check --base <dir> <files>`
  hashes the token stream of a source file without comments and whitespace; equal hashes show that a
  change touched only comments.
- **A board reading needs a verify on the same boot.** `deploy.sh verify` must have printed max abs
  diff 0 after the last reboot before a throughput or accuracy number is recorded.

## What the gates do not cover

- The head's capacity checks (buffer size, channel count a multiple of 4) run in simulation only; the
  hardware accepts a bad descriptor.
- The descriptor-table check does not read word 11, so `res_slot == in_slot` is assumed.
- Several parameters are hard-wired for the shipped network (see `DESIGN.md`, section 7); another
  network that changes them needs new tests, not only new vectors.
- Timing closure is a property of one placement; a rebuild must be checked again (step 3 of
  [`REBUILD.md`](REBUILD.md)).
