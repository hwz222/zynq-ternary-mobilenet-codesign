# twn_fuse: Linux platform driver for the accelerator

A kernel driver that owns the accelerator's control registers and DDR buffer. From v1.1 the Linux
image loads it at boot and is built around it; the user-space path of v1.0.0 (UIO + `/dev/mem`)
works only with the v1.0.0 boot files.

| | UIO path (v1.0.0, `sw/app/pl_hal_fuse.c`) | this driver (`sw/app/pl_hal_fuse_drv.c`) |
|---|---|---|
| control registers (64 KB at 0xA000_0000) | `/dev/uio4` mapped into the app | mapped only in the kernel (`devm_platform_ioremap_resource`) |
| DDR buffer the PL reads and writes | 256 MB reserved at a fixed physical address, `/dev/mem` | 8 MB from the DMA API (`dmam_alloc_coherent`), `mmap` of that buffer only |
| addresses the app hands to the PL | physical | offsets into the buffer, range-checked by the driver |
| register sequences (clear done, start, wait) | the app must get them right | inside one ioctl each |
| completion | user-space poll, `exit(1)` after 3 s | interrupt and completion (hardware 1.1), else `readl_poll_timeout`; `-ETIMEDOUT` after 3 s |
| who may use it | any process with access to `/dev/mem` | one open file at a time (a second `open` returns `-EBUSY`) |
| loading | `uio_pdrv_genirq` binds the node (`generic-uio`) | the v1.1 image loads `twn_fuse` at boot and the node says `wjhuang,twn-fuse-1.1` |

## Versions of the hardware

| compatible | bitstream | completion |
|---|---|---|
| `wjhuang,twn-fuse-1.1` | v1.1: a level-high interrupt (register IRQ, 0x0064) on `pl_ps_irq0` = GIC SPI 89; AXI masters issue Non-secure transactions, so the SMMU can translate them | interrupt |
| `wjhuang,twn-fuse-1.0` | v1.0.0: no interrupt line | polling |

The driver also falls back to polling when the node has no interrupt or `use_irq=0` is given.
The device-tree binding is `wjhuang,twn-fuse.yaml` in this directory.

## Files

| file | what it is |
|---|---|
| `twn_fuse.c` | the driver: probe, DMA buffer, `mmap`, nine ioctls, interrupt handler, sysfs and debugfs |
| `twn_fuse_ioctl.h` | the ioctl interface, shared with `sw/app/pl_hal_fuse_drv.c` |
| `wjhuang,twn-fuse.yaml` | device-tree binding (dt-schema) |
| `Kbuild`, `Makefile` | out-of-tree build against the PetaLinux kernel (the image builds it with `linux/project-spec/meta-user/recipes-modules/twn-fuse`) |
| `bind.sh` | on the board: unload and load the module (with parameters), or hand the device to UIO on a v1.0.0 image |
| `patch_dtb.sh` | v1.0.0 device tree: a copy whose node says `wjhuang,twn-fuse-1.0` |
| `smmu_dtb.sh` | a copy of a device tree with the SMMU enabled and the accelerator's stream IDs |
| `test/twn_errtest.c` | the driver's refusals: bad offsets, bad pointers, second open, the 3 s timeout (`timeout`), a mapping kept after close (`hold`) |
| `test/twn_bench.c` | ioctl round trip, backbone frame time split (app / driver / PL cycles), CPU time, CPU access to the buffer |
| `test/board_check.sh` | the board check: fixtures, refusals, unload/reload, throughput (UIO as well where the device tree still reserves its buffer) |
| `test/v11_check.sh` | the checks of v1.1: `ab`, `bench`, `irqcount`, `split`, `debugfs`, `synthetic`, `boot`, `smmu`, `irqfps`, `devmem` |
| `test/ab_measure.sh` | four-arm throughput A/B (UIO, UIO elsewhere, driver with Device mapping, driver) |
| `test/binding_check.py` | the parts of `dt_binding_check` that run without dtschema, and the node of a real `.dtb` |

## Build

The v1.1 image builds and installs the module itself (`linux/build_linux.sh`). By hand, in WSL /
Linux, with the PetaLinux project and its SDK:

    cd linux/driver/twn_fuse
    make prepare          # once: a private copy of the kernel build directory, made ready for modules
    make                  # twn_fuse.ko
    make test             # test/twn_errtest, test/twn_bench
    cd ../../..
    bash board/build_apps.sh            # the apps on the driver backend, into build/arm-drv
    bash board/make_kit.sh              # build/twn_board_kit.tar.gz: apps, tests, weights, fixtures

Variables: `PLNX_ROOT` (default `$HOME/petalinux`), `PLNX_PROJ`, `SDK_DIR`, `KOUT` (default
`$HOME/twn_kbuild`). A module loads only on the kernel of the same PetaLinux build.

## Use on the board

On the v1.1 image nothing has to be done: the driver is loaded at boot and `/dev/twn_fuse` exists.
`sh bind.sh drv <path-of-twn_fuse.ko> <param>=<value>` reloads it with module parameters.

Module parameters:

| parameter | default | what it does |
|---|---|---|
| `arena_mb` | 8 | size of the DMA buffer in MB (the pose app needs 6 MB, `FUSE_ARENA_NEED` in `sw/app/mbv2_fuse_ps.c`) |
| `use_irq` | 1 | 0: poll even when the device tree gives an interrupt |
| `map_device` | 0 | 1: map the buffer to user space as Device memory, like `/dev/mem` (A/B measurement only; refused behind an IOMMU) |

debugfs, under `/sys/kernel/debug/twn_fuse/` (root only, not a stable interface): `regs` (the debug
registers by name), `nblk` (run only the first n blocks, 1..17), `irq_count` (interrupts handled),
`dma_fault` (write 1: one frame that reads its input from the first byte after the buffer, a test
of the SMMU; the output is meaningless).

sysfs, under `/sys/bus/platform/devices/a0000000.twn_fuse/`: `cycles_total`, `cycles_array`,
`cycles_dw`, `cycles_stall`, `cycles_idle_pre`, `cycles_idle_post`, `status`, `nblk`.

On a v1.0.0 image: `sh bind.sh drv ./twn_fuse.ko` takes the device from UIO and `sh bind.sh uio`
gives it back; or boot a device tree made with `patch_dtb.sh`.

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

## Verified

v1.0 (polling, first handout): `results/board_results.json`, entry `linux_driver_twn_fuse_20261026`;
logs in `results/raw/linux_driver_20261026/`.

v1.1: `results/board_results.json`, entry `linux_driver_twn_fuse_v11_20261027`; logs in
`results/raw/linux_driver_v11_20261027/` (README there). In short, on the v1.1 image: the driver
bound at boot with the interrupt; four MPII and four synthetic fixtures bit-exact with the head in
the PL and on the processor; the board check (refusals, 3 s timeout, unload/reload, throughput)
passes; one interrupt per frame and none extra; CPU time per backbone frame 10.7 us with the
interrupt and 465.8 us polling, and on the same boot 233.13 fps with the interrupt against 231.26 fps
polling; `/dev/mem` refused for System RAM and for the registers while the driver is loaded (it
still reaches DDR outside System RAM, and the registers after `rmmod`); the 256 MB reservation
returned to the kernel; with the SMMU on (the default of the image), an out-of-buffer read by the PL
ends in an SMMU context fault, at the same throughput as without it (232.58 vs 232.17 fps). The
SMMU translates Non-secure transactions with the four listed stream IDs; the kernel leaves bypass
on, so other stream IDs (a nonzero AXI ID) and Secure transactions are not checked.
`make W=1` and `checkpatch.pl --strict` report nothing (`S6_static_checks.log`).

Limits: `dt_binding_check` and sparse (`make C=1`) were not run (they need dtschema and sparse
installed); the driver does not claim the PL clock (`clocks = <&zynqmp_clk 71>`) and relies on
the `clk_ignore_unused` boot argument.

## License

`twn_fuse.c` is `GPL-2.0-only OR MIT` (a kernel module must be GPL-compatible); `twn_fuse_ioctl.h`
is MIT so that Apache-2.0 user-space code can include it. The rest of this directory follows the
repository's Apache-2.0 license.

Study handouts in Traditional Chinese that explain each technique with this code:
[`docs/zh-TW/driver-handout/`](../../../docs/zh-TW/driver-handout/) (v1.0) and
[`docs/zh-TW/driver-handout-2/`](../../../docs/zh-TW/driver-handout-2/) (v1.1).
