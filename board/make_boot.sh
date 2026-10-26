#!/usr/bin/env bash
# Assemble BOOT.BIN from the boot components in $LINUX_DIR/boot (FSBL, PMU firmware, ATF, U-Boot)
# plus $LINUX_DIR/sd/system.dtb and a bitstream. Needs only `bootgen`, which comes with Vivado; no
# PetaLinux. Run from git-bash or WSL.
#
#   bash board/make_boot.sh [bitstream.bit] [output.BIN]
#
# Defaults: build/system_fuse_ternpose.bit (output of vivado/build.cmd) and build/BOOT.BIN.
# Environment: BOOTGEN (path of bootgen; default: bootgen from PATH, then C:/Xilinx/Vivado/2023.2/bin).
#              LINUX_DIR (directory with boot/ and sd/; default build/linux, the output of
#              linux/build_linux.sh, if it exists, else artifacts/linux).
#
# The FSBL contains psu_init for the PS configuration in vivado/alinx_ps/ps_config.tcl (with the
# fourth high-performance port enabled). It has to be regenerated from the XSA if that
# configuration changes.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
BIT="${1:-$ROOT/build/system_fuse_ternpose.bit}"
OUT="${2:-$ROOT/build/BOOT.BIN}"
if [ -z "${LINUX_DIR:-}" ]; then
    if [ -d "$ROOT/build/linux/boot" ] && [ -d "$ROOT/build/linux/sd" ]; then LINUX_DIR="$ROOT/build/linux"
    else LINUX_DIR="$ROOT/artifacts/linux"; fi
fi
[ -f "$LINUX_DIR/boot/zynqmp_fsbl.elf" ] && [ -f "$LINUX_DIR/sd/system.dtb" ] || { echo "ABORT: no boot components in $LINUX_DIR (run linux/build_linux.sh, or set LINUX_DIR)"; exit 1; }
echo "Linux components: $LINUX_DIR"
BOOTGEN="${BOOTGEN:-$(command -v bootgen || true)}"
[ -n "$BOOTGEN" ] || BOOTGEN=/c/Xilinx/Vivado/2023.2/bin/bootgen
[ -f "$BIT" ] || { echo "ABORT: bitstream $BIT not found"; exit 1; }
mkdir -p "$(dirname "$OUT")"
# the Windows bootgen needs Windows paths (cygpath in git-bash, wslpath in WSL)
winpath() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1";
    elif command -v wslpath >/dev/null 2>&1; then wslpath -m "$1";
    else echo "$1"; fi
}
H="$(winpath "$LINUX_DIR")"
BIF="$(dirname "$OUT")/boot.bif"
cat > "$BIF" <<BIF
the_ROM_image:
{
	[bootloader, destination_cpu=a53-0] $H/boot/zynqmp_fsbl.elf
	[pmufw_image] $H/boot/pmufw.elf
	[destination_device=pl] $(winpath "$BIT")
	[destination_cpu=a53-0, exception_level=el-3, trustzone] $H/boot/bl31.elf
	[destination_cpu=a53-0, load=0x00100000] $H/sd/system.dtb
	[destination_cpu=a53-0, exception_level=el-2] $H/boot/u-boot.elf
}
BIF
"$BOOTGEN" -arch zynqmp -image "$(winpath "$BIF")" -w -o "$(winpath "$OUT")"
echo "BOOT.BIN: $OUT  sha16 $(sha256sum "$OUT" | cut -c1-16)"
