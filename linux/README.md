# linux

The Linux side of the board: the PetaLinux 2023.2 project overlay and the script that turns the
accelerator's hardware description (XSA) into the boot files. No prebuilt image is kept here. The
kernel, device tree and boot script of the release build are release assets; the root file system is
always built locally, because it carries the board's root password.

## Contents

| path | what it is |
|---|---|
| `build_linux.sh` | creates a PetaLinux project outside the repository from the XSA, applies `project-spec/`, builds, and copies the eight boot files to `build/linux/boot` and `build/linux/sd` |
| `boot.cmd` | the U-Boot script: loads `Image`, the initramfs `rootfs.cpio.gz.u-boot` and `system.dtb` from the FAT partition, then `booti`; compiled into `boot.scr` by `build_linux.sh` |
| `project-spec/` | only the hand-written parts on top of a stock `zynqMP` PetaLinux project: kernel arguments (`configs/config.user`), device tree (`system-user.dtsi`: the reserved 256 MB DDR region and the accelerator's UIO node), image packages (`petalinuxbsp.conf`), a static-IP service, an sshd setting |

## How to run

In WSL or Linux, with PetaLinux 2023.2 installed:

    BOARD_PW=<root password for the board> bash linux/build_linux.sh
    BOARD_PW=<root password for the board> SDK=1 bash linux/build_linux.sh   # also the cross SDK for board/build_apps.sh

Variables (header of `build_linux.sh`): `PLNX_ROOT` (default `$HOME/petalinux`), `PLNX_SETTINGS`,
`PLNX_PROJ`, `XSA` (default `build/system_fuse_ternpose.xsa`, else the release copy
`artifacts/hw/system_fuse_ternpose.xsa`), `OFFLINE` and `CACHE_PROJ` (reuse an earlier project's
downloads without network access), `JOBS`, `CLEAN`, `SDK`, `SDK_DIR`.

## Outputs

`build/linux/boot/{zynqmp_fsbl,pmufw,bl31,u-boot}.elf` (inputs of `board/make_boot.sh`) and
`build/linux/sd/{Image,system.dtb,rootfs.cpio.gz.u-boot,boot.scr}` (the SD-card files), with their
SHA-256 printed at the end.

## Rules

- `BOARD_PW` is written into the image's root account as a SHA-512 crypt hash. Without it the image
  has no usable root password and `board/deploy.sh` cannot log in. Do not publish a built root file
  system: it contains that hash.
- Put in `project-spec/` only files a person edited; never commit generated parts (hardware
  description, `.Xil/`, logs).
- Files here are read by Linux tools: keep LF line endings (`.gitattributes` enforces it).
- The accelerator's device-tree node follows the block-design cell name, `fuse_0@a0000000`, exposed
  as a generic UIO device; `sw/app/pl_hal_fuse.c` and `board/deploy.sh` look the UIO up by name
  (`twn_fuse` or `fuse_0`; older names are accepted as fallbacks).
- The FSBL comes from the XSA: a change to `vivado/alinx_ps/ps_config.tcl` needs a new XSA, a new
  `build_linux.sh` run and a new BOOT.BIN.
- The root file system is an initramfs: nothing written on the board survives a reboot.
