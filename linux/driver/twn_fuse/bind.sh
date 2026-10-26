#!/bin/sh
# Hand the accelerator to the twn_fuse driver, or back to UIO, without a reboot (run on the board).
#
#   sh bind.sh drv [path/to/twn_fuse.ko [param=value ...]]   bind the device to twn_fuse (loads
#                                          the module, with its module parameters if given; without
#                                          that file, the module installed in the image, v1.1)
#   sh bind.sh uio                         bind it to uio_pdrv_genirq, the v1.0.0 path (unloads twn_fuse)
#
# driver_override names the one driver allowed to take the device, whatever its compatible
# string says, so this works with either device tree (generic-uio or wjhuang,twn-fuse-1.0).
# twn_fuse has no sysfs unbind (suppress_bind_attrs); it lets go of the device only through
# rmmod, which fails while a process has the device open.
DEV=a0000000.twn_fuse
P=/sys/bus/platform
cur=$(basename "$(readlink $P/devices/$DEV/driver 2>/dev/null)" 2>/dev/null)

case "$1" in
drv)
    shift
    ko=${1:-./twn_fuse.ko}
    [ $# -gt 0 ] && shift
    [ "$cur" = uio_pdrv_genirq ] && echo $DEV > $P/drivers/uio_pdrv_genirq/unbind
    echo twn_fuse > $P/devices/$DEV/driver_override
    if lsmod | grep -q '^twn_fuse '; then
        echo $DEV > $P/drivers_probe
    elif [ -f "$ko" ]; then
        insmod "$ko" "$@" || exit 1     # probes the device on load
    else
        modprobe twn_fuse "$@" || exit 1
    fi ;;
uio)
    if lsmod | grep -q '^twn_fuse '; then rmmod twn_fuse || exit 1; fi
    echo uio_pdrv_genirq > $P/devices/$DEV/driver_override
    echo $DEV > $P/drivers_probe ;;
*)
    echo "usage: $0 drv [twn_fuse.ko] | uio"; exit 2 ;;
esac
echo "$DEV -> $(basename "$(readlink $P/devices/$DEV/driver)")"
