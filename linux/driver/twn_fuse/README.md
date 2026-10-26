# twn_fuse: Linux platform driver for the accelerator

A kernel driver that owns the accelerator's control registers and DDR buffer. It replaces the
user-space access path of v1.0.0, which is kept and still works:

| | UIO path (v1.0.0, `sw/app/pl_hal_fuse.c`) | this driver (`sw/app/pl_hal_fuse_drv.c`) |
|---|---|---|
| control registers (64 KB at 0xA000_0000) | `/dev/uio4` mapped into the app | mapped only in the kernel (`devm_platform_ioremap_resource`) |
| DDR buffer the PL reads and writes | 256 MB at a fixed physical address, `/dev/mem` | 8 MB from the DMA API (`dmam_alloc_coherent`), `mmap` of that buffer only |
| addresses the app hands to the PL | physical | offsets into the buffer, range-checked by the driver |
| register sequences (clear done, start, wait) | the app must get them right | inside one ioctl each |
| completion | user-space poll, `exit(1)` after 3 s | `readl_poll_timeout`, `-ETIMEDOUT` after 3 s |
| who may use it | any process with access to `/dev/mem` | one open file at a time (a second `open` returns `-EBUSY`; `fork`/`dup` share the open file) |

There is no interrupt: the bitstream ties `pl_ps_irq0` to 0, so the driver polls the done bits.
The DMA buffer is not isolated by an IOMMU (the SMMU is not used): the driver checks every base
address it writes, but the PL itself can still reach any DDR address a descriptor points it to.

## Files

| file | what it is |
|---|---|
| `twn_fuse.c` | the driver: probe, DMA buffer, `mmap`, nine ioctls, sysfs attributes |
| `twn_fuse_ioctl.h` | the ioctl interface, shared with `sw/app/pl_hal_fuse_drv.c` |
| `Kbuild`, `Makefile` | out-of-tree build against the PetaLinux kernel |
| `bind.sh` | on the board: hand the device to `twn_fuse` or back to UIO without a reboot |
| `patch_dtb.sh` | a copy of `system.dtb` whose accelerator node has `compatible = "wjhuang,twn-fuse-1.0"` |
| `test/twn_errtest.c` | the driver's refusals: bad offsets, bad pointers, second open, the 3 s timeout (`timeout`), a mapping kept after close (`hold`) |
| `test/board_check.sh` | the board check: fixtures on both paths, refusals, unload/reload, throughput; expects the apps renamed `mbv2_fuse_{test,pipe}_{uio,drv}` |

## Build

In WSL / Linux, with the PetaLinux project built by `linux/build_linux.sh` and its SDK installed:

    cd linux/driver/twn_fuse
    make prepare          # once: a private copy of the kernel build directory, made ready for modules
    make                  # twn_fuse.ko
    make test             # test/twn_errtest
    cd ../../..
    HAL=drv bash board/build_apps.sh     # the apps on the driver backend, into build/arm-drv

Variables: `PLNX_ROOT` (default `$HOME/petalinux`), `PLNX_PROJ`, `SDK_DIR`, `KOUT` (default
`$HOME/twn_kbuild`). The module loads only on the kernel of the same PetaLinux build: compare
`modinfo twn_fuse.ko | grep vermagic` with `uname -r` on the board.

## Use on the board

With the release `system.dtb` (the node says `generic-uio`), switch at run time:

    sh bind.sh drv ./twn_fuse.ko     # a0000000.twn_fuse -> twn_fuse, /dev/twn_fuse appears
    sh bind.sh uio                   # back to /dev/uio4 (fails while an app has the driver open)

To have the device matched by the driver itself, boot a patched device tree:

    sh patch_dtb.sh system.dtb system_twn_fuse.dtb      # on the host (needs fdtput)

Keep the original on the card and copy the patched one over `system.dtb`; after the reboot,
`insmod twn_fuse.ko` binds the device with no `driver_override`. The module is not in the root file
system image, so it is loaded by hand after every boot. To go back, copy the original over
`system.dtb` and reboot.

Module parameter: `arena_mb` (default 8), the size of the DMA buffer. The pose app needs 6 MB
(`FUSE_ARENA_NEED` in `sw/app/mbv2_fuse_ps.c`).

## Interface

| ioctl | argument | what the driver does |
|---|---|---|
| `TWN_IOC_STATUS` | `struct twn_status` (out) | buffer size and six status registers |
| `TWN_IOC_SET_TABLE` | `struct twn_table` | writes the block descriptor table and NBLK, runs the PL's table check; `-EINVAL` if refused |
| `TWN_IOC_SET_BASES` | `struct twn_bases` | weight and activation base offsets |
| `TWN_IOC_BB_RUN` | `struct twn_bb_run` (in/out) | one backbone frame: wait idle, clear done, start, wait done; returns time and six cycle counters |
| `TWN_IOC_BB2HD` | `__u32` (in/out) | writes the BB2HD register, returns it read back |
| `TWN_IOC_HD_SET_RQ` | `struct twn_hd_rq` | the head's 256 requantisation words |
| `TWN_IOC_HD_COMMIT` | `struct twn_hd_desc` | one head descriptor; every range is checked with its length |
| `TWN_IOC_HD_START` | none | starts the head; `-EBUSY` if it is still running |
| `TWN_IOC_HD_WAIT` | `__u64` (out) | waits for the head; returns the wait time |

`mmap(fd, size, offset 0)` maps the DMA buffer (`size` up to the buffer size). Every offset must be
16-byte aligned and inside the buffer.

sysfs, under `/sys/bus/platform/devices/a0000000.twn_fuse/`: `cycles_total`, `cycles_array`,
`cycles_dw`, `cycles_stall`, `cycles_idle_pre`, `cycles_idle_post`, `status`, `nblk`.

## Verified

On the board, same bitstream, under both device trees: the four fixtures bit-exact on both paths
with the head in the PL and on the processor; 14/14 checks of `twn_errtest` as expected (12 refusals,
2 successes), the 3 s timeout returning after 3.01 s; rmmod refused while the device is open and
while only a mapping is left; five unload/reload cycles; pipeline throughput for both paths (the
driver path is not slower; the difference, 0.8 % and 1.0 % on the two boots, is not attributed).
Under the original device tree also: ten reloads with a 64 MB buffer (640 MB in all, CMA is 256 MB).
Numbers: `results/board_results.json`, entry `linux_driver_twn_fuse_20261026`; logs:
`results/raw/linux_driver_20261026/`.

Limits: the kernel has `CONFIG_STRICT_DEVMEM` off, so a root process can still map the registers
through `/dev/mem`; without an SMMU the driver checks the addresses it writes, not where the PL's
descriptors send it; the driver does not claim the PL clock (`clocks = <&zynqmp_clk 71>`) and relies
on the `clk_ignore_unused` boot argument.

## License

`twn_fuse.c` is `GPL-2.0-only OR MIT` (a kernel module must be GPL-compatible); `twn_fuse_ioctl.h`
is MIT so that Apache-2.0 user-space code can include it. The rest of this directory follows the
repository's Apache-2.0 license.

A study handout in Traditional Chinese that explains each technique with this code is in
[`docs/zh-TW/driver-handout/`](../../../docs/zh-TW/driver-handout/).
