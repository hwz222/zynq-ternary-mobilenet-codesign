#!/usr/bin/env bash
# Rebuild the Linux side of the board (FSBL, PMU firmware, ATF, U-Boot, kernel, device tree,
# initramfs root file system, boot script) from source with PetaLinux 2023.2.
# Run in WSL / Linux, not in git-bash. Outputs go to build/linux/{boot,sd}, the layout that
# board/make_boot.sh reads through LINUX_DIR.
#
#   bash linux/build_linux.sh            # build, copy the eight files, print their hashes
#   SDK=1 bash linux/build_linux.sh      # also `petalinux-build --sdk` and install it (see below)
#
# What it does
#   1. petalinux-create -t project --template zynqMP in $PLNX_PROJ (outside the repo)
#   2. petalinux-config --get-hw-description <XSA>   (psu_init, device tree, memory map come from the XSA)
#   3. lays linux/project-spec over the project: the meta-user recipes, system-user.dtsi, and the
#      key=value choices of project-spec/configs/config.user
#   4. optional offline settings: sources from $CACHE_PROJ/build/downloads, shared-state from
#      $CACHE_PROJ/build/sstate-cache, no network sstate feed, bitbake without network
#   5. petalinux-build, then boot.scr from linux/boot.cmd (see that file), then copy + hash.
# It is resumable: running it again keeps the project and lets bitbake continue.
#
# Environment (all optional)
#   PLNX_ROOT   directory that holds the PetaLinux install and the projects (default $HOME/petalinux)
#   PLNX_SETTINGS  settings.sh of PetaLinux 2023.2 (default $PLNX_ROOT/2023.2/settings.sh)
#   PLNX_PROJ   project directory to create (default $PLNX_ROOT/proj/ternpose); never inside the repo
#   XSA         hardware description (default build/system_fuse_ternpose.xsa, else artifacts/hw/system_fuse_ternpose.xsa from the release)
#   OFFLINE     0 (default): PetaLinux defaults (sources and shared state from the public mirrors);
#               1: use the local caches of CACHE_PROJ below and never touch the network
#   CACHE_PROJ  an earlier PetaLinux 2023.2 project whose build/downloads and build/sstate-cache are
#               used read-only as mirrors when OFFLINE=1 (no default; required with OFFLINE=1)
#   BOARD_PW    root password of the board (what board/deploy.sh calls BOARD_PW). Without it the image
#               gets the published default password "twn-v1.1", and an interactive root login must
#               set a new one before it gets a shell (recipes-core/board-config/files/twn-firstlogin.sh).
#   JOBS        bitbake threads and make -j (default 6; each of them can take ~1.5 GB)
#   CLEAN       1: delete $PLNX_PROJ first and start from nothing
#   SDK         1: also build the cross SDK and install it to $SDK_DIR (default $PLNX_ROOT/sdk, which
#               board/build_apps.sh reads). An existing non-empty $SDK_DIR is never overwritten
#               unless SDK_FORCE=1.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PLNX_ROOT="${PLNX_ROOT:-$HOME/petalinux}"
PLNX_SETTINGS="${PLNX_SETTINGS:-$PLNX_ROOT/2023.2/settings.sh}"
PLNX_PROJ="${PLNX_PROJ:-$PLNX_ROOT/proj/ternpose}"
CACHE_PROJ="${CACHE_PROJ:-}"
OFFLINE="${OFFLINE:-0}"
JOBS="${JOBS:-6}"
OUT="${OUT:-$REPO/build/linux}"
SDK_DIR="${SDK_DIR:-$PLNX_ROOT/sdk}"

die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "=== $(date '+%H:%M:%S') $*"; }

[ "$(uname -s)" = Linux ] || die "run this in WSL/Linux"
[ -f "$PLNX_SETTINGS" ] || die "PetaLinux settings script not found: $PLNX_SETTINGS (set PLNX_SETTINGS)"
case "$PLNX_PROJ" in "$REPO"|"$REPO"/*) die "PLNX_PROJ must be outside the repo";; esac
case "$PLNX_PROJ" in /mnt/*) die "PLNX_PROJ must be on the Linux file system, not /mnt/*";; esac

if [ -z "${XSA:-}" ]; then
    for c in "$REPO/build/system_fuse_ternpose.xsa" "$REPO/artifacts/hw/system_fuse_ternpose.xsa"; do
        [ -f "$c" ] && { XSA="$c"; break; }
    done
fi
[ -n "${XSA:-}" ] && [ -f "$XSA" ] || die "no XSA found (build it with vivado/build.cmd or set XSA)"
echo "XSA   : $XSA  sha16 $(sha256sum "$XSA" | cut -c1-16)"
echo "PROJ  : $PLNX_PROJ"
echo "OFFLINE=$OFFLINE JOBS=$JOBS"

if [ "$OFFLINE" = 1 ]; then
    [ -n "$CACHE_PROJ" ] || die "OFFLINE=1 needs CACHE_PROJ (an earlier PetaLinux 2023.2 project)"
    [ -d "$CACHE_PROJ/build/downloads" ]     || die "no $CACHE_PROJ/build/downloads (set CACHE_PROJ, or OFFLINE=0)"
    [ -d "$CACHE_PROJ/build/sstate-cache" ]  || die "no $CACHE_PROJ/build/sstate-cache (set CACHE_PROJ, or OFFLINE=0)"
fi

# shellcheck disable=SC1090
source "$PLNX_SETTINGS" >/dev/null 2>&1 || die "sourcing $PLNX_SETTINGS failed"
command -v petalinux-build >/dev/null || die "petalinux-build not on PATH after sourcing settings"

# --- 1. project -------------------------------------------------------------------------------
[ "${CLEAN:-0}" = 1 ] && rm -rf "$PLNX_PROJ"
if [ ! -d "$PLNX_PROJ/project-spec" ]; then
    step "create project"
    mkdir -p "$(dirname "$PLNX_PROJ")"
    (cd "$(dirname "$PLNX_PROJ")" && petalinux-create -t project --template zynqMP -n "$(basename "$PLNX_PROJ")")
fi
cd "$PLNX_PROJ"

# --- 2. hardware description --------------------------------------------------------------------
XSA_STAMP=project-spec/hw-description/.xsa_sha256
if [ "$(cat "$XSA_STAMP" 2>/dev/null)" != "$(sha256sum "$XSA" | cut -d' ' -f1)" ]; then
    step "import XSA"
    D="$(mktemp -d)"; cp "$XSA" "$D/"
    petalinux-config --get-hw-description="$D" --silentconfig
    rm -rf "$D"
    sha256sum "$XSA" | cut -d' ' -f1 > "$XSA_STAMP"
fi

# --- 3. overlay ---------------------------------------------------------------------------------
step "apply overlay linux/project-spec"
(cd "$HERE/project-spec" && find . -type f ! -name config.user -print0) |
    while IFS= read -r -d '' f; do
        install -D -m 0644 "$HERE/project-spec/$f" "project-spec/$f"
    done
# the kernel driver's recipe builds the repository's own source (one copy, in linux/driver/twn_fuse)
for f in twn_fuse.c twn_fuse_ioctl.h; do
    install -D -m 0644 "$HERE/driver/twn_fuse/$f" "project-spec/meta-user/recipes-modules/twn-fuse/files/$f"
done

CFG=project-spec/configs/config
setcfg() {   # setcfg KEY VALUE   (VALUE already quoted when it is a string)
    sed -i -e "/^$1=/d" -e "/^# $1 is not set\$/d" "$CFG"
    echo "$1=$2" >> "$CFG"
}
unsetcfg() { sed -i -e "/^$1=/d" -e "/^# $1 is not set\$/d" "$CFG"; echo "# $1 is not set" >> "$CFG"; }
while IFS= read -r line; do
    case "$line" in
        "# CONFIG_"*" is not set") unsetcfg "$(echo "$line" | awk '{print $2}')" ;;
        CONFIG_*=*)                setcfg "${line%%=*}" "${line#*=}" ;;
    esac
done < "$HERE/project-spec/configs/config.user"

if [ "$OFFLINE" = 1 ]; then
    setcfg CONFIG_PRE_MIRROR_URL "\"file://$CACHE_PROJ/build/downloads/\""
    setcfg CONFIG_YOCTO_LOCAL_SSTATE_FEEDS_URL "\"$CACHE_PROJ/build/sstate-cache\""
    # gen-machine-conf (xilinx_mirrors.py) drops the local feed whenever the network feed is off,
    # so the feed stays "on" and its URL is the same local directory: no server is ever contacted.
    setcfg CONFIG_YOCTO_NETWORK_SSTATE_FEEDS y
    setcfg CONFIG_YOCTO_NETWORK_SSTATE_FEEDS_URL "\"file://$CACHE_PROJ/build/sstate-cache\""
    setcfg CONFIG_YOCTO_BB_NO_NETWORK y
fi
setcfg CONFIG_YOCTO_BB_NUMBER_THREADS "\"$JOBS\""
setcfg CONFIG_YOCTO_PARALLEL_MAKE "\"$JOBS\""

# root password: kept out of the repo, written only into the project's own conf
BSP=project-spec/meta-user/conf/petalinuxbsp.conf
sed -i '/^# BOARD_PW begin/,/^# BOARD_PW end/d' "$BSP"
FORCE_PW=0
if [ -z "${BOARD_PW:-}" ]; then
    BOARD_PW=twn-v1.1; FORCE_PW=1
    echo "NOTE: BOARD_PW not set: published default password '$BOARD_PW', changed at the first interactive login"
fi
case "$BOARD_PW" in *\'*|*\"*|*\\*|*\;*|*\$*) die "BOARD_PW must not contain ' \" \\ ; or \$";; esac
{ echo "# BOARD_PW begin"
  # usermod -p takes a crypt hash; the $ signs are escaped for the extrausers class
  echo "EXTRA_USERS_PARAMS:append = \" usermod -p '$(openssl passwd -6 "$BOARD_PW" | sed 's/\$/\\$/g')' root;\""
  echo "TWN_FORCE_PW_CHANGE = \"$FORCE_PW\""
  echo "# BOARD_PW end"; } >> "$BSP"

step "petalinux-config --silentconfig"
petalinux-config --silentconfig

# --- 4. build -----------------------------------------------------------------------------------
step "petalinux-build"
petalinux-build

if [ "${SDK:-0}" = 1 ]; then
    step "petalinux-build --sdk"
    petalinux-build --sdk
    if [ -n "$(ls -A "$SDK_DIR" 2>/dev/null)" ] && [ "${SDK_FORCE:-0}" != 1 ]; then
        echo "SDK_DIR $SDK_DIR is not empty: not installing. sdk.sh is at $PLNX_PROJ/images/linux/sdk.sh;"
        echo "install it with:  $PLNX_PROJ/images/linux/sdk.sh -y -d <dir>   (or SDK_FORCE=1)"
    else
        "$PLNX_PROJ/images/linux/sdk.sh" -y -d "$SDK_DIR"
    fi
fi

# --- 5. boot script and outputs ------------------------------------------------------------------
IMG="$PLNX_PROJ/images/linux"
MKIMAGE="$(ls "$PLNX_PROJ"/build/tmp/sysroots-components/x86_64/u-boot-tools-xlnx-native/usr/bin/mkimage 2>/dev/null | head -1 || true)"
[ -n "$MKIMAGE" ] || MKIMAGE="$(command -v mkimage || true)"
[ -n "$MKIMAGE" ] || die "no mkimage (apt install u-boot-tools)"
step "boot.scr from linux/boot.cmd with $MKIMAGE"
SOURCE_DATE_EPOCH=1785790000 "$MKIMAGE" -c none -A arm -T script -d "$HERE/boot.cmd" "$IMG/boot.scr.ternpose" >/dev/null

step "copy to $OUT"
mkdir -p "$OUT/boot" "$OUT/sd"
for f in zynqmp_fsbl.elf pmufw.elf bl31.elf u-boot.elf; do
    [ -f "$IMG/$f" ] || die "missing $IMG/$f"
    cp -f "$IMG/$f" "$OUT/boot/$f"
done
for f in Image system.dtb rootfs.cpio.gz.u-boot; do
    [ -f "$IMG/$f" ] || die "missing $IMG/$f"
    cp -f "$IMG/$f" "$OUT/sd/$f"
done
cp -f "$IMG/boot.scr.ternpose" "$OUT/sd/boot.scr"

echo
echo "built from XSA sha16 $(sha256sum "$XSA" | cut -c1-16)"
for f in boot/zynqmp_fsbl.elf boot/pmufw.elf boot/bl31.elf boot/u-boot.elf \
         sd/Image sd/boot.scr sd/system.dtb sd/rootfs.cpio.gz.u-boot; do
    printf '%-28s %10d  sha16 %s\n' "$f" "$(stat -c %s "$OUT/$f")" "$(sha256sum "$OUT/$f" | cut -c1-16)"
done
