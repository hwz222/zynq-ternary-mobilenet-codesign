# Rebuilding from source

This is the full sequence from the sources in this repository to a measured board. Each step names
its inputs, the command, what it must print, and where its output goes. All commands run from the
repository root unless a step says otherwise. Outputs go to `build/` (ignored by git) unless named.

## 0. Prerequisites

| what | needed for |
|---|---|
| Windows 11, Git Bash with `gcc`, PowerShell 5.1 | steps 1, 2, 3, 5, 7 |
| AMD Vivado 2023.2 (default install `C:\Xilinx\Vivado\2023.2`; `VIVADO_BIN` / `VIVADO_SETTINGS` override it) | steps 1 (`xvlog`), 2, 3, 5 (`bootgen`) |
| Python 3 with numpy (`PYTHON` overrides the interpreter of the runners) | steps 1, 2, 3 |
| Ubuntu 22.04 (WSL2 works) with PetaLinux 2023.2 installed under `$PLNX_ROOT` (default `$HOME/petalinux`, settings script `$PLNX_ROOT/2023.2/settings.sh`) | steps 4, 6 |
| PuTTY (`plink.exe`, `pscp.exe`; `PLINK` / `PSCP` override the paths) and OpenSSH `ssh-keyscan`, `ssh-keygen` | step 7 |
| the four fixtures and the two weight files of `models/mbv2_pose/` | every step; see [`QUICKSTART.md`](QUICKSTART.md), "Release assets" and "Fixtures and dataset files" |

## 1. Golden vectors, weight image, descriptor table, DDR map (Git Bash, about 3 minutes)

    ( cd golden/p1_golden && bash run_p1.sh )      # must end: P1 GATE: PASS
    python tools/pack_fuse_weights.py
    python tools/gen_desctab.py
    python tools/gen_fuse_ddr.py                   # must end: gen_fuse_ddr verify: ALL PASS

`run_p1.sh` first re-runs the P0 gate (`golden/p0_fused/run_p0.sh`), then generates every block's
input, output, weights and requantisation for fixture 0 into `golden/p1_golden/vec/`, regenerates
them once more and requires identical hashes, checks all four fixtures, and emits the block
testbenches (syntax-checked with `xvlog`). The three tools then pack the backbone weights into the
DDR image the engine reads (`vec/fuse_weights.bin`), write the block descriptor table
(`tools/fuse_desctab.h` and testbench includes) and write the DDR image and expected output for the
whole-frame simulation (`rtl/fuse/tb/*.hex`).

`pack_fuse_weights.py --verify` is not part of the flow: its tail-pack check reports 6 false errors on
these weights (it mis-splits the tail-packed stages). The weight image itself is checked by
`gen_fuse_ddr.py` and by the whole-frame simulation.

## 2. Simulation (PowerShell, about 40 minutes)

    powershell -File rtl\fuse\sim\run_engine_tests.ps1 -Integration   # must end: === ENGINE TESTS: all 35 ok ===

Seven engine suites (ternary array, depthwise, head, residual, data movers, weight fetch, control),
each with deliberate-defect ("break") runs that must fail, then with `-Integration` the 17-block
bit-exact run (`run_p5.ps1`) and the whole-frame AXI simulation (`run_fuse_axi_boost.ps1 -Only
tb_fuse_frame`). Work directories are under `%TEMP%\twn_sim\`. What each gate proves:
[`VERIFICATION.md`](VERIFICATION.md).

## 3. Bitstream (Windows, about 1 hour)

    vivado\build.cmd

Runs the multiply-driven-signal lint, elaborates the IP wrapper, packages `rtl/` as the IP
`twn:user:twn_fuse`, builds the block design (processing system, four HP ports, interconnects, the
accelerator `fuse_0`, an observation GPIO), synthesises and implements at 240 MHz with the
`Performance_NetDelay_high` strategy, runs the post-route recovery, and writes
`build/system_fuse_ternpose.bit`, `build/system_fuse_ternpose.xsa` and the `util_*`, `timing_*` and
`dpcheck_*` reports. The variables set in `build.cmd` are the build recipe; it is the only recipe that
closes timing at 240 MHz.

Check before using the bitstream: `build/timing_impl_fuse_ternpose.rpt` must say "All user specified
timing constraints are met" (WNS >= 0), and `build/dpcheck_impl_fuse_ternpose.rpt` must list every
datapath instance with a non-zero cell count.

## 4. Linux (WSL or Linux, PetaLinux 2023.2; about 20 minutes with a warm cache)

    BOARD_PW=<root password for the board> bash linux/build_linux.sh          # build/linux/{boot,sd}
    BOARD_PW=<root password for the board> SDK=1 bash linux/build_linux.sh    # also the cross SDK

Creates a PetaLinux project outside the repository (`$PLNX_PROJ`, default
`$PLNX_ROOT/proj/ternpose`), imports the XSA (`build/system_fuse_ternpose.xsa`, else the release copy
in `artifacts/hw/`, or `XSA=<file>`), lays `linux/project-spec/` over it, builds, compiles
`linux/boot.cmd` into `boot.scr`, and copies eight files: `build/linux/boot/{zynqmp_fsbl,pmufw,bl31,u-boot}.elf`
and `build/linux/sd/{Image,system.dtb,rootfs.cpio.gz.u-boot,boot.scr}`. `BOARD_PW` becomes the root
password of the image; without it `deploy.sh` cannot log in. By default (`OFFLINE=0`) PetaLinux
fetches sources from the public mirrors; `OFFLINE=1 CACHE_PROJ=<earlier project>` reuses the
downloads and shared state of an earlier PetaLinux 2023.2 project without network access. The
script header lists the other variables. It can be re-run: the project is kept and bitbake resumes.

Run it again whenever the XSA changes: the FSBL is generated from the XSA (it carries the PS
configuration, including the fourth HP port).

## 5. BOOT.BIN (Git Bash or WSL; needs only `bootgen`)

    bash board/make_boot.sh [bitstream.bit] [output.BIN]    # default build/system_fuse_ternpose.bit -> build/BOOT.BIN

Assembles FSBL, PMU firmware, ARM trusted firmware, the device tree, U-Boot and the bitstream from
`build/linux/` (or `LINUX_DIR`). To put a new bitstream on the board without rebuilding Linux, rebuild
only this file; the Linux files stay valid as long as the XSA's PS configuration is unchanged.

## 6. Board apps (WSL)

    bash board/build_apps.sh          # build/arm/mbv2_fuse_test, mbv2_fuse_pipe, mbv2_cam_fuse, mbv2_fuse_eval

Cross-compiles `sw/app` with the SDK installed by step 4 (`$PLNX_ROOT/sdk`). `FUSE_CLK_MHZ` (default
240.0) is the PL clock used to convert cycle counters to milliseconds.

## 7. Board (Git Bash; the board on the network at `BOARD_IP`, default 192.168.10.2)

First time, or after a Linux rebuild: put `build/BOOT.BIN` (or the release `BOOT.BIN`) and the four
files of `build/linux/sd/` on the card's FAT partition, either with the card in the host

    INIT=1 bash board/flash_sd.sh E: build/BOOT.BIN build/linux/sd     # E: = drive letter of the card

or over the network once the board runs (`pushlinux` keeps the replaced files in `previous_linux/`):

    export BOARD_PW=<root password>
    bash board/deploy.sh pin                         # once: keep the current BOOT.BIN as BOOT_rollback.BIN
    bash board/deploy.sh pushlinux                   # BOOT.BIN and the four Linux files, reboot
    bash board/deploy.sh push build/BOOT.BIN         # a new BOOT.BIN only, reboot

Then, after every boot:

    bash board/deploy.sh data       # apps, weights, fixtures to /home/root; all 9 hashes must match
    bash board/deploy.sh verify     # 4 fixtures, head in the PL and on the processor; max|diff| must be 0
    bash board/deploy.sh speed      # mbv2_fuse_pipe, three runs of 120 frames with FUSE_BB2HD=1 and 0

A reading is valid only when `verify` printed max abs diff 0 on the same boot. Do not poll the board
with repeated ssh commands during `speed`: it lowers the measured frame rate. `deploy.sh rollback`
puts `BOOT_rollback.BIN` back. If the board does not come up, write a known-good set with
`flash_sd.sh`; it keeps the replaced files in `previous_<date>/` on the card.

Record the result as a new entry of `results/board_results.json` (see [`../results/README.md`](../results/README.md)).

## Accuracy on the board

    cd train/mbv2_pose
    python -m src.score_board inputs  --meta ../../models/mbv2_pose/model_meta.c --out <dir>
    # copy <dir>/in_NN.bin and build/arm/mbv2_fuse_eval to the board; for each chunk run
    #   FUSE_HEAD_PL=1 ./mbv2_fuse_eval /home/root in_NN.bin out_NN.bin
    # and copy the out_NN.bin files back into <dir>
    python -m src.score_board score   --meta ../../models/mbv2_pose/model_meta.c --outs <dir>
    python -m src.score_board compare --a <dir> --pa out_ --b <ref-dir> --pb ref_

`score` prints the PCKh@0.5 of the board's raw outputs; `compare` counts the images whose outputs are
byte-identical to those of the C reference `golden/ref_batch` (build line in the header of
`golden/ref_batch/ref_batch.c`). The module docstring of `train/mbv2_pose/src/score_board.py` gives
every option.

## Running the apps by hand

On the board, in `/home/root`: `FUSE_HEAD_PL=1|0` runs the head in the PL or on the processor;
`FUSE_BB2HD=1|0` (default 1) switches the backbone-to-head direct write; `PIPE_TIMING=1` prints
per-stage times. `mbv2_cam_fuse` reads a USB camera (V4L2) and draws the keypoints; `--selftest
golden/fix_N.bin` runs it on a fixture instead.

## Using the accelerator for another network

The bitstream fixes the shape of the network: 17 backbone blocks with the descriptor-table geometry,
weight memories of 8,160 / 240 / 600 / 240 words, a head of three 4x4 stride-2 transposed
convolutions and a 1x1 with at most 16 output channels, and the DDR map of [`DESIGN.md`](DESIGN.md).
What another task supplies is data: ternary backbone weights with their requantisation, INT8 head
weights, the model description, fixtures, and its own post-processing on the processor.
`tools/gen_desctab.py` and the capacity guards stop at generation when a network does not fit.
Train in `train/<task>/`, export into `models/<task>/` (the file set of `models/mbv2_pose`), and give
the scripts that name `models/mbv2_pose` (`golden/*/run_p*.sh`, `tools/gen_input_qlut.py`,
`tools/hd_ref_export.py`, `sw/app/Makefile.cross`, `board/deploy.sh`) the new directory.

## Summary of the steps

All commands run from the repository root; the sections above give each step with its expected
output and run time. In short:

| step | command | output |
|---|---|---|
| 1. golden vectors | `( cd golden/p1_golden && bash run_p1.sh )`, then `python tools/pack_fuse_weights.py`, `tools/gen_desctab.py`, `tools/gen_fuse_ddr.py` | `golden/p1_golden/vec/`, test vectors in `rtl/fuse/tb/` |
| 2. simulation | `powershell -File rtl\fuse\sim\run_engine_tests.ps1 -Integration` (about 40 min) | must end `all 35 ok` |
| 3. bitstream | `vivado\build.cmd` (about 1 hour) | `build/system_fuse_ternpose.bit`, `.xsa`, reports |
| 4. Linux | `BOARD_PW=... bash linux/build_linux.sh` (WSL, PetaLinux 2023.2) | `build/linux/{boot,sd}` |
| 5. BOOT.BIN | `bash board/make_boot.sh` (needs only `bootgen`) | `build/BOOT.BIN` |
| 6. board apps | `bash board/build_apps.sh` (WSL, PetaLinux SDK) | `build/arm/` |
| 7. deploy and verify | `bash board/deploy.sh pushlinux`, then `data`, `verify`, `speed` | the figures recorded in `results/` |

A rebuilt bitstream is not bit-identical to the release one; it counts as the same design when timing
is met, the four fixtures are bit-exact on the board and the frame rate is in the range above. The
build has no timing margin: the first routing ends about 30 ps below zero slack and the post-route
step in `vivado/build_bd_fuse.tcl` recovers it.

## Training and export

Training code lives in `train/<task>/`, one self-contained workspace per task, each with a README
giving its data, commands and accuracy ruler. The deployed pose model is retrained with

    cd train/mbv2_pose
    python -m src.run_recipe configs/probe_tern_dc32.json --stage B --workdir runs/probe_tern_dc32

starting from `checkpoints/sports_r2_w3/best.pth` (a release asset), scored with
`python -m src.score_ckpt <checkpoint>` and exported with `export/export_board_model.py`. Training is
not bit-reproducible (cuDNN autotuning, data-loader order): a retrain gives a nearby PCKh, not the
same checkpoint. See [`train/README.md`](../train/README.md).
