# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased] - planned for v1.1

### Added

- `linux/driver/twn_fuse/`: a Linux platform driver for the accelerator, replacing the UIO +
  `/dev/mem` access path (which is kept): registers mapped only in the kernel, an 8 MB DMA buffer
  from the DMA API that is the only thing user space can `mmap`, nine ioctls taking range-checked
  offsets instead of physical addresses, kernel-side polling with a 3 s timeout, sysfs counters,
  one process at a time. Tools: `bind.sh` (switch between UIO and the driver without a reboot),
  `patch_dtb.sh`, `test/twn_errtest.c`, `test/board_check.sh`.
- `sw/app/pl_hal_fuse_drv.c`: the apps on the driver, selected with `HAL=drv` in
  `board/build_apps.sh`; register-free helpers moved unchanged into `sw/app/pl_hal_fuse_enc.c`.
- `docs/zh-TW/driver-handout/`: a study handout in Traditional Chinese that explains each technique
  with the driver's own code and board output.

### Changed

- `sw/app/mbv2_fuse_ps.c` asks for the 6 MB its buffer map needs (`FUSE_ARENA_NEED`, checked at
  compile time) instead of the whole 256 MB reserved region.

### Planned

- A ready-to-boot root file system image with a documented default password that must be changed at
  first login.
- Synthetic (non-person) test fixtures, so that board verification does not need an MPII download.

## [1.0.0] - 2026-10-26

First public release of zynq-ternary-mobilenet-codesign: a ternary-weight MobileNetV2 hardware/software co-design on
Zynq UltraScale+, with pose estimation as the reference task on the board and detection,
segmentation and depth models for the same fixed network (host results).

### Hardware

- Fused, row-streaming accelerator for a ternary-weight MobileNetV2 pose network on the ALINX AXU2CGB
  (Zynq UltraScale+ XCZU2CG): 17 backbone blocks and a 4-operator INT8 heatmap head in the PL at
  240 MHz, controlled over AXI4-Lite, four HP ports to a reserved 256 MB DDR region.
- Backbone-to-head direct write (BB2HD): the last backbone block writes into the head's input slot.
- Release bitstream `52b400785924efe0` (in `BOOT.BIN` `690d87cc5f4b6897`): 228.7 fps, board
  PCKh@0.5 85.715 on the 2,289-instance MPII validation split, 4/4 fixtures bit-exact; 44,057 LUT,
  145 block-RAM tiles, 217 DSP; WNS 0.000 ns at 240 MHz (`results/board_results.json`).

### Software and flow

- Bit-exact C reference (P0) and golden-vector generator (P1); unit tests with planted defects,
  17-block and whole-frame simulations (`run_engine_tests.ps1 -Integration`: 35 tests).
- Vivado 2023.2 build script, PetaLinux 2023.2 overlay and build script, BOOT.BIN assembly,
  deployment and verification scripts for the board, board apps for test, throughput, accuracy and a
  USB camera.
- Training, quantisation (Brevitas) and export code for the deployed pose model `probe_tern_dc32`,
  plus host-side workspaces for detection, segmentation, depth and a pose model for people lying down.
- `tools/fetch_release.py`: downloads and verifies the release assets.
- `train/mbv2_pose/src/build_mpii_annot.py`: rebuilds the MPII train/validation split from the official
  annotation file, byte-identical to the split used for every reported PCKh.

### Release assets

- Boot files (BOOT.BIN, bitstream, XSA, kernel, device tree, boot script), the exported model weights,
  and six PyTorch checkpoints (the deployed pose model, its training input `sports_r2_w3`, and four
  task models on the deployed backbone), listed with SHA-256 in `tools/release_assets.json`.
- The root file system is built by the user with `linux/build_linux.sh`; no image is released.
- The four test fixtures are regenerated from the user's own MPII download with the exporter; they
  are not released.
