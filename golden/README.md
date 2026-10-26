# golden

The software reference the hardware is checked against: the integer network executed in the
accelerator's fused, row-streamed order, and the per-block golden vectors generated from it.

## Contents

| path | what it is | output |
|---|---|---|
| `p0_fused/` | `p0_fused.c`: the fused execution order in C, checked against the plain integer network `sw/net/mbv2_pose.c` on the four fixtures; `run_p0.sh` also rebuilds it with planted defects that must fail | `p0_fused` binary (ignored) |
| `p1_golden/` | `gen_p1.c`, `gen_tb.py`, `run_p1.sh`: runs the P0-verified kernels on the fixtures and writes every block's input, output, weights and requantisation, plus the block testbenches | `vec/` (about 10 MB, ignored), `tb_p1_*.v` (ignored) |
| `ref_batch/` | `ref_batch.c`: the integer reference on a batch of pre-quantised images, in the record format of the board app `mbv2_fuse_eval`, so the two compare byte for byte (build line in its header) | the output file you name |

## How to run

    ( cd golden/p1_golden && bash run_p1.sh )      # Git Bash; must end: P1 GATE: PASS (runs P0 first)

Needs `gcc`, Python with numpy, and Vivado's `xvlog` (on the PATH or under `C:\Xilinx\Vivado\*\bin`)
for the testbench syntax check. `PYTHON` selects the interpreter.

## Inputs

`models/mbv2_pose/` (`model_mbv2.bin`, `model_meta.c`, `fixtures/fix_0..3.bin`) and `sw/net/`. The
weight file comes from the release and the fixtures are regenerated from MPII; see the root
[`README.md`](../README.md), sections "Release assets" and "Fixtures and dataset files".

## Rules

- Never edit a file in `vec/`: change the generator and regenerate.
- The RTL generators (`rtl/fuse/tb/gen_*.py`) and `tools/*.py` read `golden/p1_golden/vec`; when it is
  missing or stale they stop with a message.
- A change to P0 or P1 changes what the hardware is compared against: re-run
  `rtl\fuse\sim\run_engine_tests.ps1 -Integration`.
