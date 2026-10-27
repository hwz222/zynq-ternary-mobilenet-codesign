# linux/device-tree

A snapshot, for reading, of the device tree that describes the board to Linux in the v1.1 release:
the sources PetaLinux generated from the hardware description, and the compiled `system.dtb`
turned back into text. Nothing here is used by the build: `build_linux.sh` regenerates the sources
from the XSA on every run, and the only device-tree file the repository feeds into the build is
[`../project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`](../project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi).

| file | what it is | written by |
|---|---|---|
| `generated/system-top.dts` | the top file: includes the chip, clock, PL and PS files and, last, `system-user.dtsi` (which includes `system-conf.dtsi`); adds the memory node and the boot console, and deletes CPUs 2 and 3 (the XCZU2CG has two A53 cores) | PetaLinux (XSCT), from the XSA |
| `generated/zynqmp.dtsi` | the ZynqMP chip itself: CPUs, GIC, SMMU, UART, SD, Ethernet, DMA ... | Xilinx (GPL-2.0+, see its header) |
| `generated/zynqmp-clk-ccf.dtsi` | the clock tree | Xilinx (GPL-2.0+, see its header) |
| `generated/pcw.dtsi` | which PS peripherals this board's PS configuration enables | PetaLinux, from the XSA |
| `generated/pl.dtsi` | the IP in the PL: the accelerator `fuse_0: twn_fuse@a0000000`, and `obs_gpio` | PetaLinux, from the XSA |
| `generated/system-conf.dtsi` | PetaLinux's own settings (default boot arguments, QSPI partitions), included by the first line of `system-user.dtsi` | PetaLinux, from its config |
| `system.dts` | the released `system.dtb`, decompiled (`dtc -I dtb -O dts`): all of the above merged, with `system-user.dtsi` applied | `snapshot.sh` |

The snapshot belongs to the v1.1.0 release (SHA-256, first 16 hex digits): XSA `253ca13d2e977247`,
bitstream `11b4d88f583b8e23`, `system.dtb` `bc4255b1c54ae27e` (the release asset, SMMU on). Taken on
2026-10-27 from the PetaLinux 2023.2 project that built the release, with

    bash linux/device-tree/snapshot.sh <petalinux-project>      # in WSL or Linux; needs dtc

A later build does not update these files; run the script again on its project to refresh them, and
update the hashes above from what it prints.

## How the pieces fit

```
Vivado block design ──► XSA ──► PetaLinux ──► system-top.dts + zynqmp.dtsi + ... + pl.dtsi
                                                     + system-user.dtsi (ours, included last)
                                                     │  C preprocessor, then dtc
                                                     ▼
                                                system.dtb ──► SD card ──► U-Boot ──► kernel
```

`.dts` and `.dtsi` are the same text format; a `.dtsi` is a fragment that a `.dts` includes, like a C
header. `dtc` compiles them into the binary `.dtb`, the only form the kernel reads. U-Boot loads
`system.dtb` into memory and hands its address to the kernel, which creates a `platform_device` for
every enabled node under a `simple-bus` such as `amba_pl`.

## The accelerator in each file

`generated/pl.dtsi` line 14, as PetaLinux wrote it from the block design:

```dts
fuse_0: twn_fuse@a0000000 {                  /* label : node name @ unit address */
	clock-names = "ap_clk";
	clocks = <&zynqmp_clk 71>;               /* PL0 clock (240 MHz) */
	compatible = "xlnx,twn-fuse-1.1";        /* from the IP's name; no driver knows it */
	interrupt-names = "interrupt";
	interrupt-parent = <&gic>;
	interrupts = <0 89 4>;                   /* SPI 89 (pl_ps_irq0), level high */
	reg = <0x0 0xa0000000 0x0 0x10000>;      /* 64 KB of registers at 0xA000_0000 */
};
```

`system-user.dtsi` changes it by label (`&fuse_0 { ... }` edits the existing node): the
`compatible` the [`twn_fuse` driver](../driver/twn_fuse/) matches, `status = "okay"`, and `iommus`,
the four HP ports' SMMU stream IDs; `&smmu { status = "okay"; }` enables the SMMU that
`zynqmp.dtsi` line 881 declares disabled.

`system.dts` line 1376, the merged result: the same properties, `compatible =
"wjhuang,twn-fuse-1.1"`, and labels replaced by phandles (`&zynqmp_clk` is `0x04`, `&gic` is `0x05`,
`&smmu` is `0x11`; each referenced node carries a matching `phandle` property, for example the GIC at
line 465 and the SMMU at line 984).

What the driver does with each property:

| property | used by |
|---|---|
| `compatible` | the platform bus, against `twn_of_match` in `twn_fuse.c`, to pick the driver |
| `reg` | `devm_platform_ioremap_resource(pdev, 0)` in `twn_probe()` |
| `interrupts` | `platform_get_irq_optional(pdev, 0)` in `twn_probe()`: GIC SPI 89, which Linux numbers at boot (55 on the released image; another device tree can give another number) |
| `iommus` | the kernel's IOMMU layer: the device joins an IOMMU group, `dma_alloc_coherent()` returns an IOVA; it also makes the SMMU a supplier of the device, so the SMMU probes first |
| `status` | the kernel skips a node whose `status` is anything other than `"okay"` or `"ok"`; a node without `status` counts as enabled (the generated `fuse_0` has none, so `system-user.dtsi` setting `"okay"` only makes it explicit) |
| `clocks` | not used by the driver; the kernel still links the clock controller as a supplier of the device. Nothing in the driver keeps the PL clock on; presumably the `clk_ignore_unused` boot argument does (not tested without it; see the handout, chapter 1) |

The boot arguments in `system.dts` (line 1413, from `system-conf.dtsi`) are not the ones the board
uses: U-Boot's `boot.scr` (built from [`../boot.cmd`](../boot.cmd)) sets its own `bootargs`, with the
initramfs as the root file system.

## On the board

The kernel shows the device tree it received under `/proc/device-tree/`, one file per property:

    ls /proc/device-tree/amba_pl@0/twn_fuse@a0000000/
    cat /proc/device-tree/amba_pl@0/twn_fuse@a0000000/compatible
    readlink /sys/bus/platform/devices/a0000000.twn_fuse/of_node

The study handout explains matching and probe in chapter 1 (Traditional Chinese,
[`docs/zh-TW/driver-handout/`](../../docs/zh-TW/driver-handout/)).
