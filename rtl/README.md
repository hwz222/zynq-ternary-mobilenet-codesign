# rtl

Verilog of the fused streaming accelerator, its testbenches and its test runners.

## Contents

| path | what lives here |
|---|---|
| `fuse/` | the 26 engine modules `twn_*.v` (top: `twn_fuse_top.v`, registers: `twn_csr.v`), one module per file, file name = module name |
| `src/` | shared leaf modules: block-RAM wrappers `bram_*.v`, AXI masters `twn_axi_rd.v` / `twn_axi_wr.v`, the head datapath `twn_hd_compute.v` |
| `ip/` | `twn_fuse_layer.v`, the wrapper packaged as the IP `twn:user:twn_fuse` (the packaged output `twn_fuse_ip/` is generated and ignored) |
| `fuse/tb/` | testbenches `tb_*.v`, includes `tb_*.vh`, case generators `gen_*.py` (generated `.hex`/`.vh` files are ignored) |
| `fuse/sim/` | PowerShell runners `run_*.ps1`, each ending with one verdict line and a non-zero exit code on failure |
| `tb/` | Python reference models used by the generators (`hd_ref.py`, `gen_hd_op.py`), independent of the Verilog under test |
| `sim/` | `lint_multidrive.py`, the multiply-driven-signal lint (run by `vivado/build.cmd`) |

The design is described in [`docs/DESIGN.md`](../docs/DESIGN.md); the gates in
[`docs/VERIFICATION.md`](../docs/VERIFICATION.md).

## How to run

PowerShell, Vivado 2023.2 simulator on the PATH or in `C:\Xilinx\Vivado\2023.2\bin` (`VIVADO_BIN`
overrides it), after the golden vectors and tool outputs of [`docs/REBUILD.md`](../docs/REBUILD.md)
step 1:

    powershell -File rtl\fuse\sim\run_engine_tests.ps1 -Integration   # everything, about 40 min: all 35 ok
    powershell -File rtl\fuse\sim\run_engine_tests.ps1 -Engine head    # one engine
    powershell -File rtl\fuse\sim\run_units.ps1 -Only tb_uop_enc       # one unit test with its break runs

Work directories go to `%TEMP%\twn_sim\`.

## Rules for changes

1. A design change passes, in order: `python rtl/sim/lint_multidrive.py --selftest`,
   `powershell -File vivado\elab_fuse_layer.ps1`, and `run_engine_tests.ps1 -Integration` (all 35 ok).
2. The build has no timing margin (WNS 0.000 ns). Any change that moves placement can make it negative:
   rebuild the bitstream and read the timing report before calling a change done.
3. A new module gets a unit test in `fuse/tb/` and a row in `fuse/sim/run_units.ps1`, with at least one
   deliberate defect ("break" run) that the test must catch.
4. Comments describe what the code does now. A comment-only edit is shown to be comment-only with
   `python tools/codeprint.py check --base <dir> <files>`.
5. Do not write a synthesis-directive keyword pair in a comment: a comment that starts with a tool
   name followed by a directive word is read as an instruction by the tools.
6. Golden data is not stored here; it is generated into `golden/p1_golden/vec`.
