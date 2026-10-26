# twn_fuse: Linux platform driver for the accelerator

**Status: in development on branch `linux-driver`.** The released apps still use the UIO path
(`sw/app/pl_hal_fuse.c`).

This driver replaces the user-space access path (UIO for the control registers, `/dev/mem` for the
DDR buffer) with a kernel driver that owns the hardware:

| | UIO path (v1.0.0) | this driver |
|---|---|---|
| control registers | mapped into the app | only the kernel touches them |
| DDR buffer | fixed physical address, `/dev/mem` | allocated with the DMA API, `mmap` of that buffer only |
| register sequence | the app must follow it | enforced by the driver |
| completion | user-space polling | kernel polling with timeout (no interrupt line in the bitstream) |

## Files

| file | what it is |
|---|---|
| `twn_fuse.c` | the driver |
| `twn_fuse_ioctl.h` | the ioctl interface, shared by the driver and `sw/app/pl_hal_fuse_drv.c` |
| `Kbuild`, `Makefile` | out-of-tree module build against the PetaLinux kernel |

## Build

In WSL / Linux, with the PetaLinux project built by `linux/build_linux.sh` and its SDK installed:

    cd linux/driver/twn_fuse
    make prepare      # once
    make              # -> twn_fuse.ko

Variables: `PLNX_ROOT` (default `$HOME/petalinux`), `PLNX_PROJ`, `SDK_DIR`, `KOUT` (the copied
kernel build directory, default `$HOME/twn_kbuild`).

A study handout in Traditional Chinese that explains each technique with this code is in
[`docs/zh-TW/driver-handout/`](../../../docs/zh-TW/driver-handout/).
