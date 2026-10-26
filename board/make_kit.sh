#!/usr/bin/env bash
# Pack the board kit: everything the v1.1 image needs to check the accelerator, with no toolchain
# on the user's side. Run in WSL or Git Bash after board/build_apps.sh (HAL=drv) and
# `make test` in linux/driver/twn_fuse.
#
#   bash board/make_kit.sh [output.tar.gz]          (default build/twn_board_kit.tar.gz)
#
# On the board (the v1.1 image, as root):
#   tar xzf twn_board_kit.tar.gz && cd twn_board_kit && sh board_check.sh
#
# Contents: the apps on the driver backend (named *_drv, as board_check.sh expects), twn_bench and
# twn_errtest, bind.sh, board_check.sh, v11_check.sh; data/ = the backbone weights in the
# engine's layout and the two exported model files; golden/ = the four synthetic fixtures
# (no images of people); syn -> . so that `v11_check.sh synthetic` finds them too.
# Environment: FUSE_WEIGHTS = fuse_weights.bin (default golden/p1_golden/vec/fuse_weights.bin,
# the output of tools/pack_fuse_weights.py, else artifacts/model/fuse_weights.bin from the release).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/twn_board_kit.tar.gz}"
DRV="$ROOT/linux/driver/twn_fuse"
W="${FUSE_WEIGHTS:-}"
if [ -z "$W" ]; then
    for c in "$ROOT/golden/p1_golden/vec/fuse_weights.bin" "$ROOT/artifacts/model/fuse_weights.bin"; do
        [ -f "$c" ] && { W="$c"; break; }
    done
fi
[ -n "$W" ] && [ -f "$W" ] || { echo "ABORT: no fuse_weights.bin (set FUSE_WEIGHTS)"; exit 1; }

STAGE="$(mktemp -d)"
K="$STAGE/twn_board_kit"
mkdir -p "$K/data" "$K/golden"
cp "$ROOT/build/arm-drv/mbv2_fuse_test" "$K/mbv2_fuse_test_drv"
cp "$ROOT/build/arm-drv/mbv2_fuse_pipe" "$K/mbv2_fuse_pipe_drv"
cp "$DRV/test/twn_bench" "$DRV/test/twn_errtest" "$DRV/test/board_check.sh" "$DRV/test/v11_check.sh" \
   "$DRV/bind.sh" "$K/"
cp "$W" "$K/data/fuse_weights.bin"
cp "$ROOT/models/mbv2_pose/model_mbv2.bin" "$ROOT/models/mbv2_pose/model_mbv2_packed.bin" "$K/data/"
cp "$ROOT/models/mbv2_pose/fixtures_synthetic/"fix_[0-3].bin "$K/golden/"
ln -s . "$K/syn"
chmod +x "$K/mbv2_fuse_test_drv" "$K/mbv2_fuse_pipe_drv" "$K/twn_bench" "$K/twn_errtest"
# The binaries carry debug information, and with it the build machine's paths: strip them with
# the SDK's strip, then refuse to pack if any file still names a build path.
SDKENV=$(ls "${PLNX_ROOT:-$HOME/petalinux}"/sdk/environment-setup-* 2>/dev/null | head -1 || true)
[ -n "$SDKENV" ] && . "$SDKENV"
${STRIP:-aarch64-xilinx-linux-strip} --strip-all "$K/mbv2_fuse_test_drv" "$K/mbv2_fuse_pipe_drv" \
    "$K/twn_bench" "$K/twn_errtest"
if grep -r -l -a -E '/home/[a-z]|/mnt/[a-z]/|[A-Z]:[/\\]' "$K"; then
    echo "ABORT: the files above still contain a build path"; rm -rf "$STAGE"; exit 1
fi
cat > "$K/README.txt" <<'EOF'
twn_board_kit: check the accelerator on the v1.1 image of zynq-ternary-mobilenet-codesign.

  tar xzf twn_board_kit.tar.gz && cd twn_board_kit
  sh board_check.sh          the four fixtures (head in the PL and on the processor), the
                             driver's refusals and 3 s timeout, unload/reload, throughput;
                             prints BOARD CHECK: PASS
  sh v11_check.sh            the other checks of v1.1 (interrupt, debugfs, boot state, ...)

golden/ holds synthetic fixtures (formula images, no people); data/ the model.
SHA256SUMS lists every file.
EOF
(cd "$K" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
mkdir -p "$(dirname "$OUT")"
tar -C "$STAGE" -czf "$OUT" twn_board_kit
rm -rf "$STAGE"
echo "$OUT  $(sha256sum "$OUT" | cut -c1-16)"
tar -tzf "$OUT"
