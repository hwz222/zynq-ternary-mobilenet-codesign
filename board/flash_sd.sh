#!/usr/bin/env bash
# Write a boot set to the FAT partition of the board's SD card (card plugged into this PC).
# Use it when the board cannot be reached over the network, for instance when a new kernel
# does not boot. It does not format or partition anything; it copies files.
#
#   bash board/flash_sd.sh <drive> [boot.BIN] [sd-dir]       e.g.  bash board/flash_sd.sh E:
#
#   <drive>     Windows drive letter of the card's FAT partition (E: or /e), or any mounted directory
#   boot.BIN    default build/BOOT.BIN
#   sd-dir      directory with Image, boot.scr, system.dtb, rootfs.cpio.gz.u-boot;
#               default build/linux/sd (made by linux/build_linux.sh), else artifacts/linux/sd
#
# What it does: refuses a drive that does not already hold BOOT.BIN and Image (so it cannot be
# pointed at another disk by a typo; add INIT=1 for a blank card), moves the existing files of
# the set into <drive>/previous_<date>/, copies the new ones, and compares SHA-256 of every file
# read back from the card. To undo, copy the files of previous_<date>/ back with the same script
# (pass that directory's BOOT.BIN as boot.BIN and the directory itself as sd-dir).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="${1:?usage: flash_sd.sh <drive> [boot.BIN] [sd-dir]}"
case "$D" in
    [A-Za-z]:|[A-Za-z]:/|[A-Za-z]:\\) D="/$(echo "${D:0:1}" | tr 'A-Z' 'a-z')";;
esac
BOOT="${2:-$ROOT/build/BOOT.BIN}"
SD="${3:-}"
if [ -z "$SD" ]; then
    if [ -f "$ROOT/build/linux/sd/Image" ]; then SD="$ROOT/build/linux/sd"; else SD="$ROOT/artifacts/linux/sd"; fi
fi
FILES="Image boot.scr system.dtb rootfs.cpio.gz.u-boot"
[ -d "$D" ] || { echo "ABORT: $D is not a directory / drive"; exit 1; }
[ -f "$BOOT" ] || { echo "ABORT: $BOOT not found"; exit 1; }
for f in $FILES; do [ -f "$SD/$f" ] || { echo "ABORT: $SD/$f not found"; exit 1; }; done
if [ "${INIT:-0}" != 1 ]; then
    [ -f "$D/BOOT.BIN" ] && [ -f "$D/Image" ] || {
        echo "ABORT: $D does not look like the board's card (no BOOT.BIN and Image). Check the drive letter; INIT=1 overrides."; exit 1; }
fi
sha() { sha256sum "$1" | cut -c1-16; }
echo "drive $D"
echo "  BOOT.BIN  $BOOT  $(sha "$BOOT")"
for f in $FILES; do echo "  $f  $(sha "$SD/$f")"; done
if [ "${YES:-0}" != 1 ]; then
    printf 'copy these to %s? [y/N] ' "$D"; read -r a; [ "$a" = y ] || { echo "cancelled"; exit 1; }
fi
PREV="$D/previous_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$PREV"
for f in BOOT.BIN $FILES; do [ -f "$D/$f" ] && cp "$D/$f" "$PREV/$f"; done
sync
cp "$BOOT" "$D/BOOT.BIN"
for f in $FILES; do cp "$SD/$f" "$D/$f"; done
sync
bad=0
[ "$(sha "$D/BOOT.BIN")" = "$(sha "$BOOT")" ] || { echo "MISMATCH BOOT.BIN"; bad=1; }
for f in $FILES; do [ "$(sha "$D/$f")" = "$(sha "$SD/$f")" ] || { echo "MISMATCH $f"; bad=1; }; done
[ $bad = 0 ] || { echo "FAILED: the card holds a mixed set; previous files are in $PREV"; exit 1; }
echo "OK: 5 files on the card read back identical. Previous set kept in $PREV"
echo "Eject the card from Windows before pulling it out."
