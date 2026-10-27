# linux

The Linux side of the board: the PetaLinux 2023.2 project overlay and the script that turns the
accelerator's hardware description (XSA) into the boot files. No prebuilt image is kept here. The
boot files of the release build, including a root file system with the published default password,
are release assets; an image built with your own password must not be published.

## Contents

| path | what it is |
|---|---|
| `build_linux.sh` | creates a PetaLinux project outside the repository from the XSA, applies `project-spec/`, builds, and copies the eight boot files to `build/linux/boot` and `build/linux/sd` |
| `boot.cmd` | the U-Boot script: loads `Image`, the initramfs `rootfs.cpio.gz.u-boot` and `system.dtb` from the FAT partition, then `booti`; compiled into `boot.scr` by `build_linux.sh` |
| `device-tree/` | a read-only snapshot of the v1.1 release's device tree: the sources PetaLinux generated from the XSA, the released `system.dtb` decompiled, and the script that takes the snapshot; not used by the build |
| `project-spec/` | only the hand-written parts on top of a stock `zynqMP` PetaLinux project: kernel arguments (`configs/config.user`), kernel options (`recipes-kernel`: `STRICT_DEVMEM`, `IO_STRICT_DEVMEM`, `ARM_SMMU`), the kernel driver's recipe (`recipes-modules/twn-fuse`, loaded at boot), device tree (`system-user.dtsi`: the accelerator's node for the driver, the SMMU and its stream IDs), image packages (`petalinuxbsp.conf`), a static-IP service, the first-login password change, an sshd setting |

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

- `BOARD_PW` is written into the image's root account as a SHA-512 crypt hash; do not publish a root
  file system built with it. Without `BOARD_PW` the image gets the published default password
  `twn-v1.1`, marked expired, so the first login (serial console or ssh) must set a new one, and ssh
  commands, scp and sftp are refused until then (the release image is built this way).
- Put in `project-spec/` only files a person edited; never commit generated parts (hardware
  description, `.Xil/`, logs) there. The one exception is `device-tree/`, a snapshot kept for reading,
  outside `project-spec/` so the build never sees it.
- Files here are read by Linux tools: keep LF line endings (`.gitattributes` enforces it).
- The accelerator's device-tree node is `twn_fuse@a0000000` with the label `fuse_0` (the block-design
  cell name). From v1.1 `system-user.dtsi` sets `compatible = "wjhuang,twn-fuse-1.1"`, so the
  kernel driver in [`driver/twn_fuse/`](driver/twn_fuse/README.md) binds it at boot; v1.0.0 exposed
  it as a generic UIO device instead.
- The FSBL comes from the XSA: a change to `vivado/alinx_ps/ps_config.tcl` needs a new XSA, a new
  `build_linux.sh` run and a new BOOT.BIN.
- The root file system is an initramfs: nothing written on the board survives a reboot.
