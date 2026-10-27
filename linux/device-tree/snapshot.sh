#!/bin/bash
# Copy the device-tree sources that PetaLinux generated for a project, and the device tree that
# project compiled, into this folder, for reading. Nothing here is used by the build:
# build_linux.sh regenerates the sources from the XSA every time, and only project-spec/ (with
# system-user.dtsi) is the repository's input.
#
#   bash linux/device-tree/snapshot.sh <petalinux-project> [system.dtb]
#
# Writes generated/{system-top.dts,zynqmp.dtsi,zynqmp-clk-ccf.dtsi,pcw.dtsi,pl.dtsi,system-conf.dtsi}
# and system.dts (dtc -I dtb -O dts of the dtb; default <project>/images/linux/system.dtb), then
# prints the SHA-256 (first 16 hex digits) of the XSA, the bitstream and the dtb, for the README.
set -euo pipefail
P=${1:?usage: snapshot.sh <petalinux-project> [system.dtb]}
DTB=${2:-$P/images/linux/system.dtb}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$P/components/plnx_workspace/device-tree/device-tree
mkdir -p "$HERE/generated"
for f in system-top.dts zynqmp.dtsi zynqmp-clk-ccf.dtsi pcw.dtsi pl.dtsi system-conf.dtsi; do
    install -m 0644 "$SRC/$f" "$HERE/generated/$f"
done
dtc -q -I dtb -O dts -o "$HERE/system.dts" "$DTB"
h() { sha256sum "$1" | cut -c1-16; }
echo "XSA        $(h "$SRC/hardware_description.xsa")"
echo "bitstream  $(h "$(ls "$SRC"/*.bit | head -1)")"
echo "system.dtb $(h "$DTB")"
