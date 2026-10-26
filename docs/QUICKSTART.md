# Quick start

From the release assets to a verified board: what you need, how to get the binaries, how to
regenerate the test fixtures, and the commands that put the design on the board. To rebuild
everything from source instead, see [`REBUILD.md`](REBUILD.md).

## What you need

| item | version used |
|---|---|
| Board | ALINX AXU2CGB (Zynq UltraScale+ XCZU2CG-SFVC784-1-E), microSD boot, Ethernet link to the host |
| FPGA tools | AMD Vivado 2023.2, including `xvlog`, `xelab`, `xsim` and `bootgen` |
| Linux | PetaLinux 2023.2 on Ubuntu 22.04 (WSL2 works) |
| Host | Windows 11 with Git Bash (with `gcc`), PowerShell, Python 3 with numpy, PuTTY (`plink`, `pscp`) and OpenSSH (`ssh-keyscan`, `ssh-keygen`). The Vivado and simulation runners are `.cmd`/`.ps1` scripts; the board scripts run in Git Bash |
| Training | Python 3.11, PyTorch 2.11.0 with CUDA 12.8, torchvision 0.26.0, Brevitas 0.12.1, numpy 1.26.4, OpenCV 4.10; one NVIDIA RTX 5080 |

Another Zynq UltraScale+ board needs its own PS configuration (`vivado/alinx_ps/ps_config.tcl`) and
device tree. The design uses four high-performance AXI ports, one AXI4-Lite port and one interrupt
(`pl_ps_irq0`); from v1.1 the kernel driver takes an 8 MB DMA buffer from the kernel (v1.0.0 reserved
256 MB of DDR at 0x6000_0000 instead).

## The shortest path: the v1.1 image and the board kit

No toolchain, no MPII download. From the GitHub release **v1.1.0**:

1. Copy `BOOT.BIN`, `Image`, `boot.scr`, `system.dtb` and `rootfs.cpio.gz.u-boot` to the FAT
   partition of the microSD card (`INIT=1 bash board/flash_sd.sh E: BOOT.BIN <folder with the four
   others>` does it with hashes), insert it and power the board. The board takes 192.168.10.2/24 on
   eth0.
2. Log in as `root` with the published default password `twn-v1.1`, on the serial console
   (115200 baud) or with `ssh -t root@192.168.10.2`. The password is expired: the first login makes
   you set a new one, and until then ssh commands and `scp` are refused ("Password change required
   but no TTY available"). If an ssh session shows nothing more after the change, close it (Enter,
   then `~.`) and log in again with the new password. The root file system is an initramfs: after a
   reboot the expired default password is back, and the next login asks again.
3. Copy `twn_board_kit.tar.gz` to the board (`scp`, with the new password), then:

       tar xzf twn_board_kit.tar.gz && cd twn_board_kit
       sha256sum -c SHA256SUMS
       sh board_check.sh          # must end: BOARD CHECK: PASS

   The kit holds the apps on the kernel driver, the weights and four synthetic fixtures (formula
   images, no people); `sh v11_check.sh` lists the other checks of v1.1.

The driver is loaded at boot (`/dev/twn_fuse`), with the interrupt and behind the SMMU.
`system_nosmmu.dtb` in the release is the same device tree with the SMMU off.

## Release assets

Large binaries are not in git. They are attached to the GitHub release **v1.1.0** and listed, with
their SHA-256 and destination, in [`tools/release_assets.json`](../tools/release_assets.json):

| group | files |
|---|---|
| `boot` | `BOOT.BIN`, `system_fuse_ternpose.bit`, `system_fuse_ternpose.xsa`, `Image`, `system.dtb`, `system_nosmmu.dtb`, `boot.scr`, `rootfs.cpio.gz.u-boot` |
| `kit` | `twn_board_kit.tar.gz`: the board apps on the kernel driver, the test programs, the weights and the synthetic fixtures |
| `model` | `model_mbv2.bin`, `model_mbv2_packed.bin`: the exported integer network of `models/mbv2_pose`; `fuse_weights.bin`: its backbone weights in the accelerator's layout |
| `checkpoints` | the deployed pose checkpoint `probe_tern_dc32_best.pth`, its training input `sports_r2_w3_best.pth`, and the detection, segmentation, depth and lying-pose checkpoints built on the deployed backbone |

Download and verify them into the places the scripts expect (`artifacts/`, `models/mbv2_pose/`,
`train/mbv2_pose/checkpoints/`; all ignored by git):

    python tools/fetch_release.py                     # all groups, about 95 MB
    python tools/fetch_release.py --group boot model  # only what the board needs
    python tools/fetch_release.py --check             # verify what is in place

If you downloaded the files by hand, `python tools/fetch_release.py --from-dir <folder>` checks them
and puts them in place; `sha256sum -c SHA256SUMS` in that folder checks them against the list
attached to the release.

**What is not released.** The four MPII fixtures of `models/mbv2_pose/fixtures/` contain images of
people; the next section regenerates them from your own MPII copy. The synthetic fixtures in
`models/mbv2_pose/fixtures_synthetic/` (in the repository and in the kit) need no dataset. The
released root file system carries only the published default password; an image built with
`BOARD_PW=<password> bash linux/build_linux.sh` carries yours and must not be published. Checkpoints
of the superseded pose model deployed before 2026-10-12, and of the earlier task models built on its
backbone, are not released.

## Fixtures and dataset files

The bit-exact gates (golden vectors, simulation, `deploy.sh verify`) use four fixtures: images from
the MPII validation split with the integer network's expected output. Regenerate them from your own
copy of MPII (the images, and the annotation file `mpii_human_pose_v1_u12_1.mat`) in the training
environment of `train/mbv2_pose`:

    cd train/mbv2_pose
    python -m src.build_mpii_annot --mat <mpii>/mpii_human_pose_v1_u12_1.mat   # writes data/mpii/annot/
    export TWN_MPII_IMAGES=<mpii>/images
    python ../../tools/fetch_release.py --group checkpoints
    python export/export_board_model.py --ckpt ../../artifacts/mbv2_pose/probe_tern_dc32_best.pth --install

`build_mpii_annot` writes the train/validation split behind every PCKh in this repository. The
exporter calibrates on 32 validation images and writes the nine files of `models/mbv2_pose/`,
including the fixtures; the two weight files it writes are byte-identical to the release assets.
The expected SHA-256 of the fixtures and of the split files are listed under
`regenerated_not_released` in `tools/release_assets.json`. Details:
[`train/mbv2_pose/README.md`](../train/mbv2_pose/README.md).

## Board

You need the board with a microSD card (FAT32 boot partition), an Ethernet link from the host,
PetaLinux 2023.2 for the root file system, and the fixtures from the previous section.

1. Assets: `python tools/fetch_release.py --group boot model`.
2. Linux (WSL or Linux with PetaLinux 2023.2; without a bitstream build of your own it uses the
   release XSA in `artifacts/hw/`; with `SDK=1` it also installs the cross SDK for step 3; without
   `BOARD_PW` the image gets the published default password and asks for a new one at the first
   login):

       BOARD_PW=<root password for the board> SDK=1 bash linux/build_linux.sh   # build/linux/{boot,sd}

3. Board apps (WSL): `bash board/build_apps.sh` (the apps on the kernel driver, `build/arm-drv/`;
   `HAL=uio` builds the UIO apps of a v1.0.0 image into `build/arm/`).
4. Golden vectors and the weight image (Git Bash, with Vivado's `xvlog` on the PATH or installed under
   `C:\Xilinx`):

       ( cd golden/p1_golden && bash run_p1.sh )        # must end: P1 GATE: PASS
       python tools/pack_fuse_weights.py
       python tools/gen_desctab.py
       python tools/gen_fuse_ddr.py                     # must end: gen_fuse_ddr verify: ALL PASS

5. SD card: put the release `BOOT.BIN` and the four files of `build/linux/sd/` on the card's FAT
   partition, for example `INIT=1 bash board/flash_sd.sh E: artifacts/boot/BOOT.BIN build/linux/sd`
   (`INIT=1` only for a card without a boot set). Insert the card and power the board. The board
   takes 192.168.10.2/24 on eth0; give the host an address in that subnet.
6. Deploy and check (Git Bash):

       export BOARD_PW=<the same password>
       bash board/deploy.sh pin       # once: keep the BOOT.BIN on the card as the rollback copy
       bash board/deploy.sh data      # apps, weights and fixtures to the board, hash-compared
       bash board/deploy.sh verify    # 4 fixtures, head in the PL and on the processor: max|diff| must be 0
       bash board/deploy.sh speed     # throughput, three runs each with FUSE_BB2HD=1 and 0

The root file system is an initramfs: after every reboot, run `deploy.sh data` again.
