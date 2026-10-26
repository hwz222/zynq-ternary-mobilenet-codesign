#!/bin/sh
# Board checks for the v1.1 items. Run on the board, as root, in the board_check.sh directory
# (twn_fuse.ko, bind.sh, the apps, data/, golden/; twn_bench; syn/ = the synthetic fixtures).
# Every command is printed on a line starting with "# " before its output.
#
#   sh v11_check.sh ab          fps of four arms (test/ab_measure.sh); needs UIO and /dev/mem,
#                               i.e. the v1.0.0 boot files
#   sh v11_check.sh bench       ioctl cost, backbone time split, CPU access to the buffer (test/
#                               twn_bench); with use_irq=0 too if the node has an interrupt, and
#                               with map_device=1 (the buffer mapped as Device memory)
#   sh v11_check.sh irqcount    1000 frames: one interrupt each, no extra (IRQ_NONE) calls
#   sh v11_check.sh split       the pipeline's stage times (PIPE_TIMING=1), both mappings
#   sh v11_check.sh debugfs     the debugfs files, a short frame through nblk, a refused value,
#                               dma_fault without the SMMU
#   sh v11_check.sh synthetic   the four synthetic fixtures, both head placements, on every
#                               backend this boot offers
#   sh v11_check.sh boot        the v1.1 image: module loaded at boot, interrupt, /dev/mem
#                               refused, memory, the first-login script
#   sh v11_check.sh smmu        the accelerator behind the SMMU: group, fixtures, fps, dma_fault
cd "$(dirname "$0")" || exit 1
x() { echo "# $*"; sh -c "$*" 2>&1; }
ko() {   # the module this boot uses: the file given to bind.sh, or the one installed in the image
    if [ -f ./twn_fuse.ko ]; then echo ./twn_fuse.ko; else modinfo -n twn_fuse 2>/dev/null; fi
}
sha() { [ -n "$1" ] && [ -f "$1" ] && sha256sum "$1" | cut -c1-16; }
fixtures() {   # <app> <dir>: the four fixtures in <dir>, head in the PL and on the processor
    for pl in 1 0; do
        x "FUSE_HEAD_PL=$pl ./$1 $2 2>&1 | grep -a -E '^fixture|BIT-EXACT|MISMATCH'"
    done
}
# the UIO backend needs the reserved buffer of the v1.0.0 device tree (and /dev/mem access to it)
has_uio() { [ -d /proc/device-tree/reserved-memory/pl_arena@60000000 ]; }

echo "== $(date -u '+%Y-%m-%d %H:%M UTC')  $(uname -r)  BOOT.BIN $(sha /run/media/mmcblk0p1/BOOT.BIN)  system.dtb $(sha /run/media/mmcblk0p1/system.dtb)  twn_fuse.ko $(sha "$(ko)")"
case "$1" in
ab)
    x "sh test/ab_measure.sh 2>/dev/null || sh ab_measure.sh" ;;
bench)
    sh bind.sh drv "$(ko)" >/dev/null
    x "dmesg | grep 'twn_fuse a0000000' | tail -1"
    x "FUSE_HEAD_PL=1 ./mbv2_fuse_test_drv . 2>&1 | grep -a -c 'final max|diff|=0'"   # loads table and weights
    x "./twn_bench 1000"
    if grep -q twn_fuse /proc/interrupts; then
        x "grep twn_fuse /proc/interrupts"
        x "rmmod twn_fuse; insmod $(ko) use_irq=0"
        x "dmesg | grep 'twn_fuse a0000000' | tail -1"
        x "FUSE_HEAD_PL=1 ./mbv2_fuse_test_drv . 2>&1 | grep -a -c 'final max|diff|=0'"
        x "./twn_bench 1000"
    fi
    # part 3 of twn_bench again, with the buffer mapped as Device memory (what /dev/mem gives)
    x "rmmod twn_fuse; insmod $(ko) map_device=1"
    x "FUSE_HEAD_PL=1 ./mbv2_fuse_test_drv . 2>&1 | grep -a -c 'final max|diff|=0'"
    x "./twn_bench 1000"
    x "rmmod twn_fuse; insmod $(ko)" ;;
irqcount)
    # one interrupt per backbone frame, none extra: the handler's count and the kernel's count
    # (/proc/interrupts, which also counts calls that returned IRQ_NONE) must both grow by 1000
    sh bind.sh drv "$(ko)" >/dev/null
    D=/sys/kernel/debug/twn_fuse
    x "FUSE_HEAD_PL=1 ./mbv2_fuse_test_drv . 2>&1 | grep -a -c 'final max|diff|=0'"
    x "cat $D/irq_count; grep twn_fuse /proc/interrupts"
    x "./twn_bench 1000 | grep BB_RUN"
    x "cat $D/irq_count; grep twn_fuse /proc/interrupts" ;;
split)
    # where the memory attribute shows: the pipeline's own stage times, in both mappings
    sh bind.sh drv "$(ko)" >/dev/null
    for m in "" map_device=1; do
        x "rmmod twn_fuse; insmod $(ko) $m"
        for i in 1 2 3; do
            x "FUSE_BB2HD=1 FUSE_HEAD_PL=1 PIPE_TIMING=1 ./mbv2_fuse_pipe_drv . 120 0 2>&1 | grep -a -E 'producer split|fps ==='"
        done
    done
    x "rmmod twn_fuse; insmod $(ko)" ;;
debugfs)
    sh bind.sh drv "$(ko)" >/dev/null
    D=/sys/kernel/debug/twn_fuse
    x "mount | grep -c debugfs || mount -t debugfs none /sys/kernel/debug"
    x "ls $D"
    x "cat $D/regs"
    x "cat $D/nblk $D/irq_count"
    x "FUSE_NBLK=5 FUSE_HEAD_PL=1 ./mbv2_fuse_test_drv . 2>&1 | grep -a -E 'SHORT FRAME|pix_nz|arr_cap' | head -3"
    x "cat $D/nblk"
    x "echo 99 > $D/nblk; echo exit \$?"
    x "echo 17 > $D/nblk; cat $D/nblk"
    x "echo 1 > $D/dma_fault; echo exit \$?"    # no SMMU here: the out-of-buffer read goes unnoticed
    x "dmesg | grep -i -E 'context fault|dma_fault' | tail -2"
    x "FUSE_HEAD_PL=1 ./mbv2_fuse_test_drv . 2>&1 | grep -a -c 'final max|diff|=0'" ;;
synthetic)
    x "sha256sum syn/golden/fix_*.bin | cut -c1-16,65-"
    if has_uio; then
        sh bind.sh uio >/dev/null && fixtures mbv2_fuse_test_uio syn
    else
        echo "  (no reserved buffer in this device tree: the UIO backend cannot run)"
    fi
    sh bind.sh drv "$(ko)" >/dev/null && fixtures mbv2_fuse_test_drv syn ;;
boot)
    x "cat /proc/cmdline"
    x "lsmod | grep twn_fuse"
    x "modinfo -n twn_fuse; grep -h twn_fuse /etc/modules-load.d/* 2>/dev/null"
    x "readlink /sys/bus/platform/devices/a0000000.twn_fuse/driver"
    x "dmesg | grep 'twn_fuse a0000000'"
    x "grep twn_fuse /proc/interrupts"
    x "grep -E 'MemTotal|CmaTotal|CmaFree' /proc/meminfo"
    x "ls /proc/device-tree/reserved-memory 2>/dev/null || echo no reserved-memory node"
    x "zcat /proc/config.gz 2>/dev/null | grep -E 'STRICT_DEVMEM|ARM_SMMU=' || echo no /proc/config.gz"
    x "devmem 0x60000000 32; echo exit \$?"      # DDR (the v1.0.0 buffer address)
    x "devmem 0xa0000008 32; echo exit \$?"      # the accelerator's NBLK register
    x "ls -l /etc/profile.d/twn-firstlogin.sh" ;;
smmu)
    x "dmesg | grep -i -E 'arm-smmu|iommu' | head -8"
    x "ls /sys/kernel/iommu_groups/*/devices/ | grep -B1 twn_fuse"
    x "dmesg | grep 'twn_fuse a0000000' | tail -1"
    sh bind.sh drv "$(ko)" >/dev/null
    fixtures mbv2_fuse_test_drv .
    x "FUSE_BB2HD=1 FUSE_HEAD_PL=1 ./mbv2_fuse_pipe_drv . 120 0 2>&1 | grep -a 'fps ==='"
    x "echo 1 > /sys/kernel/debug/twn_fuse/dma_fault; echo exit \$?"
    x "dmesg | grep -i -E 'arm-smmu|context fault|dma_fault' | tail -6"
    fixtures mbv2_fuse_test_drv . ;;
*)
    sed -n '2,19p' "$0"; exit 2 ;;
esac
