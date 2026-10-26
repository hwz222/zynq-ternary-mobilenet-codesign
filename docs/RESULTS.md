# Results

All measured numbers of the release build, each with the entry of `results/` it is copied from.

## Board and host results of the pose model

Measured on the ALINX AXU2CGB board with the release bitstream (SHA-256 prefix `52b400785924efe0`,
inside `BOOT.BIN` `690d87cc5f4b6897`) and the deployed model `probe_tern_dc32` (see the
[glossary](REPOSITORY.md#glossary)). Every number is copied from [`results/board_results.json`](../results/board_results.json);
the last column names the entry.

| quantity | value | measured on / how | entry |
|---|---|---|---|
| Throughput | **228.7 fps** (runs: 228.73, 228.98, 228.42) | board, `mbv2_fuse_pipe`, three 120-frame runs, head in the PL, backbone-to-head direct write on (`FUSE_BB2HD=1`), 240 MHz | `thesis_model_probe_tern_dc32_board_20261012` |
| Throughput, direct write off | 223.7 fps (runs: 224.11, 223.46, 223.55) | same boot and bitstream, `FUSE_BB2HD=0` (the processor copies the head input) | same |
| Accuracy on the board | **PCKh@0.5 = 85.715** | the integer network on the board over all 2,289 instances of the MPII validation split, 14 joints; all 2,289 outputs byte-identical to the C reference | same |
| Accuracy of the trained model, host | PCKh@0.5 = 85.992 | the quantisation-aware PyTorch model (simulated quantisation), same split and metric | `thesis_model_probe_tern_dc32_host_20261012` |
| Same recipe with an all-INT8 network, host | PCKh@0.5 = 87.878 | host only; this network was not exported or run on the board | same |
| Ternary weights | 1,715,936 in 34 layers, 44.54 % of them zero | counted from the checkpoint; every ternary layer checked to hold only {-1, 0, +1} with zeros present | same |
| Correctness | 4 of 4 test fixtures bit-exact (max abs diff 0, 14/14 keypoints) | board, head in the PL and head on the processor | `deploy_probe_tern_dc32_20261012` |
| Resources | 44,057 LUT (93.3 %), 36,339 FF (38.5 %), 145 block-RAM tiles (96.7 %), 217 DSP (90.4 %) | Vivado 2023.2 utilisation report of the routed design, XCZU2CG | `resources_bitstream_52b400785924efe0` |
| Timing | 240 MHz, WNS 0.000 ns, WHS +0.002 ns | Vivado 2023.2 timing summary of the same routed design | `timing_bitstream_52b400785924efe0` |
| Power | 7.66 W, whole board | at the board's 12 V input during continuous inference, measured on an **earlier bitstream of the same design**; not re-measured on the release bitstream and not recorded in `results/` | (none) |

The board scores 0.277 PCKh points below the host model: the host figure is of the
quantisation-aware model computed in floating point, the board figure of the exported integer
network. Host-side accuracy of the other models trained for the same hardware (object detection,
indoor segmentation, depth, a pose model for people lying down, a fall-alarm prototype) is in
[`results/task_results.json`](../results/task_results.json); those models have not yet been exported to
the board's integer format or run on the board.

## The kernel driver and the v1.1 image

Release v1.1 runs the same model through the kernel driver `linux/driver/twn_fuse` on a new
bitstream (SHA-256 prefix `11b4d88f583b8e23`: the v1.0.0 design plus an interrupt and Non-secure AXI
masters) in `BOOT.BIN` `5d226057efc8760b`. Entry `linux_driver_twn_fuse_v11_20261027` of
[`results/board_results.json`](../results/board_results.json); raw logs in
`results/raw/linux_driver_v11_20261027/`.

| quantity | value | measured on / how |
|---|---|---|
| Throughput | 232.3 fps on the released files (runs: 232.22, 232.39, 232.21); 232.6 fps (232.55, 232.60, 232.59) with the same boot files and the release candidate's root file system; 232.2 fps with the SMMU off | board, the v1.1 image, `mbv2_fuse_pipe` as above, kernel driver with the interrupt and the SMMU on |
| Correctness | 4 of 4 synthetic and 4 of 4 MPII fixtures bit-exact | board, head in the PL and on the processor, SMMU on and off |
| CPU time per backbone frame | 10.7 us with the interrupt, 465.8 us polling | `twn_bench`, same boot, `use_irq=0` for polling |
| Interrupt vs polling, throughput | 233.13 fps with the interrupt, 231.26 fps polling | the released image, same boot, three alternating 120-frame runs of each |
| ioctl round trip | 1.62 us | `twn_bench`, 100,000 calls |
| Resources | 44,157 LUT (93.5 %), 36,203 FF, 145 block-RAM tiles, 217 DSP | Vivado 2023.2, routed design |
| Timing | 240 MHz, WNS 0.000 ns, WHS +0.008 ns | after the post-route recovery of `vivado/build_bd_fuse.tcl` (first routing -0.032 ns) |
| Isolation | `/dev/mem` refused for System RAM and for the registers while the driver holds them (still readable: the top 1 MB of DDR outside System RAM, and the registers after `rmmod`); an out-of-buffer read by the PL ends in an SMMU context fault (Non-secure traffic with the listed stream IDs; other stream IDs bypass the SMMU) | board, the v1.1 image |
| Default password | expired at build: ssh commands and scp refused until the first login sets a new one | board, the released image |

The headline numbers above stay those of the v1.0.0 bitstream. On the v1.0.0 boot files the driver
path was 1.2 % faster than the UIO path; the four-arm comparison in the same entry attributes it to
the processor's mapping of the buffer (Normal non-cacheable instead of Device memory).

## Reproducibility and provenance

Every number quoted in this README or in the documentation is copied from an entry of
`results/board_results.json` or `results/task_results.json`. Each entry records the date, the
**ruler** (what was measured and how: app, frame count, dataset split, metric, clock), the **build**
(SHA-256 prefixes of the BOOT.BIN, bitstream, weights and apps involved), the **source** (the raw logs
and reports under `results/raw/`) and **measured_by** (the command that repeats it). Entries are
append-only: a superseded entry stays, marked `current: false`. A PCKh is always PCKh@0.5 over 14
joints on the same 2,289-instance MPII validation split, scored by `train/mbv2_pose/src/score_ckpt.py`
(host model) or `src/score_board.py` (board outputs). See [`results/README.md`](../results/README.md)
for the format and for what the commit and branch names inside the entries refer to.
