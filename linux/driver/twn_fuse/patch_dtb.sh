#!/bin/sh
# Make a device tree that hands the accelerator to twn_fuse at boot: a copy of <in.dtb> whose
# accelerator node says compatible = "wjhuang,twn-fuse-1.0" instead of "generic-uio".
# Nothing else changes, and no PetaLinux rebuild is needed (needs fdtput/fdtget, package dtc).
#
#   sh patch_dtb.sh system.dtb system_twn_fuse.dtb
#
# On the card, keep the original next to it; to go back, copy the original over system.dtb.
set -e
NODE=/amba_pl@0/twn_fuse@a0000000
[ $# = 2 ] || { echo "usage: $0 <in.dtb> <out.dtb>"; exit 2; }
cp "$1" "$2"
fdtput -t s "$2" $NODE compatible "wjhuang,twn-fuse-1.0"
echo "$NODE compatible: \"$(fdtget "$1" $NODE compatible)\" -> \"$(fdtget "$2" $NODE compatible)\""
