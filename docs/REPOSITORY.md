# How it works, repository layout and glossary

A short tour of the design and of where each part lives. The full design reference is
[`DESIGN.md`](DESIGN.md).

## How it works

![System architecture](figures/architecture.svg)

- **Backbone.** MobileNetV2 (width 1.0, the 17 inverted-residual blocks of `features[:18]`), with a
  256 x 256 x 3 int8 input. A block is expand 1x1, depthwise 3x3, project 1x1, plus a residual add
  where the shapes allow it (10 of 17 blocks). The accelerator computes an output row of a block as
  soon as the input rows it needs exist, so the 17 blocks run as a pipeline of rows with row buffers
  on chip and the full tensors in DDR. Ternary 1x1 convolutions run on adder trees; the depthwise
  convolutions use DSP lanes.
- **Head.** Three 4x4 stride-2 transposed convolutions (32 channels, INT8) and a final 1x1 to 16
  channels (14 used) produce 64 x 64 heatmaps. The head engine works on frame k-1 while the backbone
  works on frame k, on separate AXI ports. With the backbone-to-head direct write (BB2HD, on by
  default) the last backbone block writes straight into the head's input slot.
- **Processor side.** Linux on the ARM cores reaches the accelerator through the kernel driver
  `twn_fuse` (v1.1; UIO and `/dev/mem` in v1.0.0). The board apps write the input image into the
  driver's DMA buffer, start the frame with an ioctl that sleeps until the accelerator's interrupt,
  and take the arg-max of each heatmap.
- **Verification.** A C reference of the fused execution order (`golden/`) produces golden vectors;
  every RTL module has a unit test with deliberate defects that must make it fail; a whole-frame
  simulation compares every byte written to DDR; on the board, four fixtures must match the reference
  bit for bit.

Details: [`docs/DESIGN.md`](DESIGN.md) (architecture, registers, memory map, hard-wired
assumptions) and [`docs/VERIFICATION.md`](VERIFICATION.md) (the gates and what each one proves).

## Repository layout

| path | content |
|---|---|
| [`rtl/`](../rtl/README.md) | the 33 Verilog modules of the accelerator, the IP wrapper, testbenches, case generators and PowerShell test runners |
| [`vivado/`](../vivado/README.md) | IP packaging, block design, implementation and bitstream (`build.cmd`), PS configuration, constraints |
| [`golden/`](../golden/README.md) | bit-exact C reference of the fused execution order and the golden-vector generator |
| [`sw/`](../sw/README.md) | integer C implementation of the network and the board apps (driver, test, throughput, accuracy, camera) |
| [`linux/`](../linux/README.md) | PetaLinux 2023.2 project overlay and build script; `driver/twn_fuse`, the kernel driver, which the image loads at boot |
| [`board/`](../board/README.md) | BOOT.BIN assembly, cross-build of the apps, the board kit, deployment over the network, SD-card writing |
| [`models/`](../models/README.md) | the exported network's metadata (`models/mbv2_pose`); its weight files come from the release |
| [`train/`](../train/README.md) | training, quantisation and export code, one workspace per task |
| [`tools/`](../tools/README.md) | weight packing, descriptor-table and DDR-map generators, the release fetcher, other host utilities |
| [`results/`](../results/README.md) | measured numbers with their provenance (JSON) and the raw evidence they cite |
| [`docs/`](./) | [`QUICKSTART.md`](QUICKSTART.md), [`DESIGN.md`](DESIGN.md), [`REBUILD.md`](REBUILD.md), [`VERIFICATION.md`](VERIFICATION.md), [`RESULTS.md`](RESULTS.md), [`DATASETS.md`](DATASETS.md), this page, `figures/`; `zh-TW/`: two study handouts on the kernel driver (Traditional Chinese, LaTeX) |
| `artifacts/`, `build/` | created locally: release assets and build outputs (ignored by git) |

## Glossary

| name | meaning |
|---|---|
| `probe_tern_dc32` | the deployed pose model: ternary (`tern`) backbone, 32-channel deconvolution head (`dc32`), trained with the "head probe" recipe (backbone frozen, head retrained alone) |
| `pw_stem` | the set of ternary layers: every pointwise 1x1 convolution plus the 3x3 stem, 34 layers |
| BB2HD | backbone-to-head direct write: the last backbone block writes its output into the head's input slot (register `A_BB2HD`, app variable `FUSE_BB2HD`) |
| fixture | one test image with its expected integer output, used by every bit-exact gate |
| P0, P1 | the C reference gate (fused order against the plain integer network) and the golden-vector generator |
| ruler | the exact measurement protocol behind a number: dataset split, metric, script |
