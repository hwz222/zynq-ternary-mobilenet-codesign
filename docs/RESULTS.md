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
