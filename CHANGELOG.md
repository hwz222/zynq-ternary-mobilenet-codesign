# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-10-27

The accelerator under a Linux kernel driver, on a ready-to-boot image.

### Added

- Hardware: a level-high interrupt (register `IRQ`, 0x0064, on `pl_ps_irq0` = GIC SPI 89); the IP is
  packaged as `twn:user:twn_fuse:1.1` with an interrupt interface. Unit gate `rtl/fuse/sim/run_csr_irq.ps1`
  with two planted defects.
- Driver: interrupt and completion (polling kept as the fallback, `use_irq=0`); debugfs (`regs`, `nblk`,
  `irq_count`, `dma_fault`); compatible `wjhuang,twn-fuse-1.1`; `map_device` (A/B measurements only).
- `linux/driver/twn_fuse/wjhuang,twn-fuse.yaml` (device-tree binding) and `test/binding_check.py`;
  `test/twn_bench.c`, `test/v11_check.sh`, `test/ab_measure.sh`, `smmu_dtb.sh`;
  `test/pw_expired_ssh.sh` and `test/first_login_serial.py` (the expired default password).
- PetaLinux: the driver's module recipe, loaded at boot; kernel options `STRICT_DEVMEM`,
  `IO_STRICT_DEVMEM`, `ARM_SMMU`; the SMMU enabled with the accelerator's four stream IDs; without
  `BOARD_PW` a published default password, expired at build (Yocto `passwd-expire`): the first
  login, serial console or ssh, must change it, and ssh commands and scp are refused until then.
- `tools/make_synthetic_fixtures.py` and `models/mbv2_pose/fixtures_synthetic/`: four formula images
  with their exact expected outputs, so board checks need no dataset.
- `board/make_kit.sh`: the board kit (apps, tests, weights, synthetic fixtures, `SHA256SUMS`).
- Release assets: the root file system, `system_nosmmu.dtb`, `fuse_weights.bin` and the board kit.
- `docs/zh-TW/driver-handout-2/`: the second study handout (Traditional Chinese).

### Changed

- The AXI masters issue Non-secure transactions (AxPROT 3'b010); with 3'b000 the SMMU could neither
  translate nor check the accelerator's traffic.
- The 256 MB reserved DDR region is gone (the driver allocates its buffer); the device-tree node is
  the driver's, not UIO's. The UIO path works only with the v1.0.0 boot files.
- `board/build_apps.sh`, `sw/app/Makefile.cross`: the driver backend is the default (`build/arm-drv`);
  `board/deploy.sh` recognises the driver's device and can use the synthetic fixtures.

### Measured

- v1.1 image: 232.6 fps, fixtures bit-exact, 10.7 us of CPU per backbone frame with the interrupt
  (465.8 us polling); on one boot, 233.13 fps with the interrupt against 231.26 fps polling;
  bitstream 44,157 LUT, WNS 0.000 ns at 240 MHz (`results/board_results.json`,
  `linux_driver_twn_fuse_v11_20261027`).
- `make W=1` and `checkpatch.pl --strict`: no warnings on the driver and its ioctl header.

### Fixed before the release (study handout 2, review round 1)

- The first image stopped only interactive logins with a `profile.d` script; ssh commands and scp
  worked with the published password. The password is now expired at build and the script is gone.
- Driver: `-EPROBE_DEFER` from the interrupt lookup is returned instead of falling back to polling;
  a failed `misc_register()` turns the interrupt enable off again.
- `/dev/mem` and SMMU wording: `STRICT_DEVMEM` refuses System RAM only (DDR above it stays
  readable), registers are readable again after `rmmod`, and the SMMU checks only Non-secure traffic
  with the listed stream IDs (the kernel leaves bypass on).

### Not done

- `make dt_binding_check` and sparse (`make C=1`): they need dtschema and sparse, not installed here.

### Driver v1.0, merged after 1.0.0 and first released here

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
- `sw/app/mbv2_fuse_ps.c` asks for the 6 MB its buffer map needs (`FUSE_ARENA_NEED`, checked at
  compile time) instead of the whole 256 MB reserved region.

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
