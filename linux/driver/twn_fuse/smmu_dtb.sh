#!/bin/sh
# Make a device tree that puts the accelerator behind the SMMU: a copy of <in.dtb> with the SMMU
# node enabled and the accelerator node given the stream IDs of its DDR masters. Needs a kernel
# with CONFIG_ARM_SMMU (the v1.1 kernel) and fdtput/fdtget (package dtc).
#
#   sh smmu_dtb.sh system.dtb system_smmu.dtb
#
# Stream ID = TBU number [14:10] | master ID of the port [9:6] | AXI ID [5:0]. A PL master that
# enters through S_AXI_HP0_FPD goes through TBU 3, HP1 and HP2 through TBU 4, HP3 through TBU 5;
# the master ID of a PL port is 1010b. The block design puts gmem0 on HP0, gmem1 on HP1, gmem2
# on HP2 and gmem3 on HP3 (vivado/build_bd_fuse.tcl), and the masters drive AXI ID 0, so:
#   HP0 0x0e80   HP1/HP2 0x1280   HP3 0x1680
# A master whose stream ID is not listed is not translated (the v1.1 kernel leaves bypass on):
# it would use the buffer's I/O virtual address as a physical one, and the bit-exact check fails.
set -e
NODE=/amba_pl@0/twn_fuse@a0000000
SMMU=/axi/smmu@fd800000
[ $# = 2 ] || { echo "usage: $0 <in.dtb> <out.dtb>"; exit 2; }
cp "$1" "$2"
ph=$(fdtget -t x "$2" $SMMU phandle)
fdtput -t s "$2" $SMMU status okay
fdtput -t x "$2" $NODE iommus "$ph" e80 "$ph" 1280 "$ph" 1680
echo "$SMMU status: $(fdtget "$2" $SMMU status); $NODE iommus: $(fdtget -t x "$2" $NODE iommus)"
