setenv bootargs "earlycon console=ttyPS0,115200 clk_ignore_unused root=/dev/ram0 rw uio_pdrv_genirq.of_id=generic-uio"
echo "== zynq-ternary-mobilenet-codesign: kernel, initramfs and device tree from the FAT partition =="
fatload ${devtype} ${devnum}:${distro_bootpart} 0x00200000 Image
fatload ${devtype} ${devnum}:${distro_bootpart} 0x04000000 rootfs.cpio.gz.u-boot
fatload ${devtype} ${devnum}:${distro_bootpart} 0x00100000 system.dtb
booti 0x00200000 0x04000000 0x00100000
