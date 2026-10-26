#!/bin/bash
# Cross-build the board apps (mbv2_fuse_test, mbv2_fuse_pipe, mbv2_cam_fuse) into build/arm-drv
# (HAL=drv, the default) or build/arm (HAL=uio).
# Run inside WSL. Needs the PetaLinux 2023.2 SDK (the sysroot of the board's Linux) installed
# at $PLNX_ROOT/sdk; it is produced by `petalinux-build --sdk` and installed from sdk.sh.
#
#   bash board/build_apps.sh
#
# Environment:
#   PLNX_ROOT      directory that holds sdk/ (default $HOME/petalinux)
#   HAL            drv (default, the twn_fuse driver of the v1.1 image; output build/arm-drv) or uio
#                  (UIO and /dev/mem, a v1.0.0 image; output build/arm): which backend of pl_hal_fuse.h
#                  to link (see sw/app/Makefile.cross)
#   FUSE_CLK_MHZ   PL clock used to convert cycle counters to milliseconds (default 240.0). Set it to
#                  the clock the board really runs (pl0_ref_div1 in /sys/kernel/debug/clk/clk_summary);
#                  a wrong value silently rescales every printed time, not the wall-clock frame time.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${PLNX_ROOT:-$HOME/petalinux}/sdk"
ENV=$(ls "$SDK"/environment-setup-* | head -1)
source "$ENV"
cd "$ROOT/sw/app"
# HAL=drv (default) builds the apps for the twn_fuse kernel driver into build/arm-drv
if [ "${HAL:-drv}" = drv ]; then OUTDIR="$ROOT/build/arm-drv"; else OUTDIR="$ROOT/build/arm"; fi
make -f Makefile.cross HAL="${HAL:-drv}" DEF="-DFUSE_CLK_MHZ=${FUSE_CLK_MHZ:-240.0}" OUT="$OUTDIR"
ls -la "$OUTDIR"
