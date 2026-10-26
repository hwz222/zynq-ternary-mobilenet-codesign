#!/usr/bin/env bash
# Put a BOOT.BIN and the board apps on the board, and check them.
#
# Run from Windows git-bash: WSL has no route to the board's subnet. Needs PuTTY
# (plink.exe, pscp.exe) and OpenSSH's ssh-keyscan / ssh-keygen on PATH.
#
#   bash board/deploy.sh <step> [file]
#
#   pin        keep a copy of the BOOT.BIN now on the card as BOOT_rollback.BIN (once, before the first push)
#   push <f>   copy BOOT.BIN <f> to the card, verify by hash, reboot, wait for a new boot
#   pushlinux [BOOT.BIN] [sd-dir]   BOOT.BIN and the four SD files (default build/BOOT.BIN, build/linux/sd);
#              the old ones are kept once in previous_linux/ on the card
#   data       copy apps, weights and fixtures to /home/root and hash-compare all nine files
#   verify     four fixtures, head in PL and head on the processor; every max|diff| must be 0
#   speed      pipeline throughput, three runs of 120 frames, with and without the PS copy
#   rollback   put BOOT_rollback.BIN back and reboot (then `data` again with the matching files)
#
# Environment:
#   BOARD_PW  root password of the board (required)
#   BOARD_IP  board address (default 192.168.10.2)
#   HK        pin the ssh host key fingerprint instead of reading it with ssh-keyscan
#   T         ssh timeout in seconds (default 600)
#   PLINK, PSCP  paths of plink.exe / pscp.exe (default: the PuTTY install under C:/Program Files)
#   HAL       drv (default): the apps for the twn_fuse driver, build/arm-drv (the v1.1 image);
#             uio: the UIO apps, build/arm (a v1.0.0 image)
#   FIX       mpii: models/mbv2_pose/fixtures (not in the public repository); synthetic:
#             models/mbv2_pose/fixtures_synthetic. Default: mpii if present, else synthetic
#
# The board's root file system is an initramfs: /home/root is empty after every reboot, so the
# order is always BOOT.BIN first, reboot, then `data`. The ssh host key changes at every boot,
# so it is read again after each reboot; a new key only shows that a boot happened, which is
# why wait_up also requires a new /proc/sys/kernel/random/boot_id.
set -u

PLINK="${PLINK:-/c/Program Files/PuTTY/plink.exe}"
PSCP="${PSCP:-/c/Program Files/PuTTY/pscp.exe}"
IP="${BOARD_IP:-192.168.10.2}"
PW="${BOARD_PW:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SD=/run/media/mmcblk0p1
RB=BOOT_rollback.BIN

die() { echo "ABORT: $*" >&2; exit 1; }
[ -n "$PW" ] || die "set BOARD_PW to the board's root password"

hostkey() {
    if [ -n "${HK:-}" ]; then echo "$HK"; return; fi
    local k
    k=$(timeout 30 ssh-keyscan -t ed25519 "$IP" 2>/dev/null | grep ssh-ed25519) \
        || die "ssh-keyscan got nothing from $IP -- is the board up?"
    printf '%s\n' "$k" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'
}
HKV=""
hk() { [ -n "$HKV" ] || HKV=$(hostkey); echo "$HKV"; }

bssh() { timeout "${T:-600}" "$PLINK" -hostkey "$(hk)" -batch -ssh -l root -pw "$PW" "$IP" "$@"; }
bscp() { timeout 900 "$PSCP" -hostkey "$(hk)" -batch -q -pw "$PW" "$1" "root@$IP:$2"; }
sha16() { sha256sum "$1" | cut -c1-16; }
bsha() { bssh "sha256sum '$1' 2>/dev/null | cut -c1-16"; }
boot_id() { bssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n'; }

# wait_up <boot_id before the reboot> <host epoch of the reboot request>
# Returns after a new boot_id is seen or, if the old one could not be read, an uptime shorter
# than the time since the request: an answering sshd may still be the old system.
wait_up() {
    local old_id="${1:-}" t0="${2:-0}" n=0 id="" up el why=""
    while :; do
        if timeout 20 ssh-keyscan -t ed25519 "$IP" 2>/dev/null | grep -q ssh-ed25519; then
            HKV=""
            id=$(T=30 boot_id)
            if [ -n "$old_id" ] && [ -n "$id" ]; then
                [ "$id" != "$old_id" ] && break
                why="it answers, but boot_id is still $old_id -- it has not rebooted"
            else
                up=$(T=30 bssh "cut -d' ' -f1 /proc/uptime" 2>/dev/null | tr -d '\r\n')
                up=${up%%.*}; el=$(( $(date +%s) - t0 ))
                if [ -n "$up" ] && [ "$t0" -gt 0 ] && [ "$up" -le "$el" ]; then break; fi
                why="it answers, but its uptime ${up:-?} s is not shorter than the $el s since the reboot request"
            fi
        else
            why="no ssh-keyscan answer"
        fi
        n=$((n+1)); [ $n -gt 40 ] && die "the board did not come back with a new boot: $why"
        sleep 10
    done
    echo "board up after a real reboot (boot_id ${id:-?}), host key $(hk)"
}

reboot_and_wait() {
    local old t0
    old=$(boot_id); t0=$(date +%s)
    bssh "sync; (sleep 1; reboot) >/dev/null 2>&1 &" || true
    sleep 20
    wait_up "$old" "$t0"
}

# The accelerator's device tells this card from a second card that answers on the same address:
# /dev/twn_fuse on a v1.1 image, or a UIO device with one of the accelerator's names on a v1.0.0
# image (the uio number is not fixed, so the names of all uio devices are read). It does not show
# that the bitstream is loaded (`verify` does).
assert_card() {
    local l n="" u
    if bssh '[ -c /dev/twn_fuse ]' 2>/dev/null; then echo "board: /dev/twn_fuse (twn_fuse driver)"; return 0; fi
    l=$(bssh 'for d in /sys/class/uio/uio*; do [ -e "$d/name" ] && echo "$(basename $d) $(cat $d/name)"; done' 2>/dev/null | tr -d '\r')
    while read -r u n; do
        case "$n" in twn_fuse|fuse_0|twn_fuse_top|mbv2_fuse|twn_top|mbv2_layer) echo "board: $u = $n"; return 0;; esac
    done <<UIO
$l
UIO
    die "no /dev/twn_fuse and no uio device named twn_fuse/fuse_0/twn_fuse_top/mbv2_fuse/twn_top/mbv2_layer (got: $(echo $l)) -- wrong board; nothing was written"
}

if [ "${HAL:-drv}" = drv ]; then APPS="$ROOT/build/arm-drv"; else APPS="$ROOT/build/arm"; fi
VEC="$ROOT/golden/p1_golden/vec"
MODEL="$ROOT/models/mbv2_pose"
case "${FIX:-}" in
    mpii)      FIXDIR="$MODEL/fixtures" ;;
    synthetic) FIXDIR="$MODEL/fixtures_synthetic" ;;
    *) if [ -f "$MODEL/fixtures/fix_0.bin" ]; then FIXDIR="$MODEL/fixtures"; else FIXDIR="$MODEL/fixtures_synthetic"; fi ;;
esac

case "${1:-help}" in

pin)
    bssh "cd $SD && cp -n BOOT.BIN $RB && sync && sha256sum BOOT.BIN $RB | cut -c1-16"
    ;;

push)
    LOCAL="${2:-}"
    [ -n "$LOCAL" ] && [ -f "$LOCAL" ] || die "usage: deploy.sh push <BOOT.BIN>"
    WANT=$(sha16 "$LOCAL")
    echo "new BOOT.BIN sha16 $WANT"
    assert_card
    bssh "cd $SD && [ -f $RB ]" || die "no rollback copy on the card -- run: deploy.sh pin"
    bscp "$LOCAL" "$SD/BOOT.BIN.new"
    GOT=$(bsha "$SD/BOOT.BIN.new")
    [ "$GOT" = "$WANT" ] || die "the copy on the card is $GOT, not $WANT -- nothing was changed"
    echo "copy verified $GOT"
    bssh "cd $SD && mv BOOT.BIN.new BOOT.BIN && sync && sha256sum BOOT.BIN | cut -c1-16"
    echo "rebooting: the PL is loaded only at boot, and /home/root is wiped"
    reboot_and_wait
    echo "now run: bash board/deploy.sh data"
    ;;

pushlinux)
    # BOOT.BIN plus the four SD files (Image, boot.scr, system.dtb, rootfs) in one step. The files
    # they replace are copied once to previous_linux/ on the card (cp -n: the first copy is kept).
    LOCAL="${2:-$ROOT/build/BOOT.BIN}"
    SDSET="${3:-$ROOT/build/linux/sd}"
    LFILES="Image boot.scr system.dtb rootfs.cpio.gz.u-boot"
    [ -f "$LOCAL" ] || die "usage: deploy.sh pushlinux [BOOT.BIN] [sd-dir]; $LOCAL not found"
    for f in $LFILES; do [ -f "$SDSET/$f" ] || die "$SDSET/$f not found"; done
    assert_card
    bssh "cd $SD && [ -f $RB ]" || die "no rollback copy on the card -- run: deploy.sh pin"
    bssh "cd $SD && mkdir -p previous_linux && for f in BOOT.BIN $LFILES; do [ -f \$f ] && cp -n \$f previous_linux/\$f; done; sync; ls -la previous_linux | tail -n +2"
    for f in BOOT.BIN $LFILES; do
        if [ "$f" = BOOT.BIN ]; then src="$LOCAL"; else src="$SDSET/$f"; fi
        WANT=$(sha16 "$src")
        bscp "$src" "$SD/$f.new"
        GOT=$(bsha "$SD/$f.new")
        [ "$GOT" = "$WANT" ] || die "$f on the card is $GOT, not $WANT -- the .new files are left, the set is unchanged"
        echo "copy verified $f $GOT"
    done
    bssh "cd $SD && for f in BOOT.BIN $LFILES; do mv \$f.new \$f; done; sync; echo moved"
    echo "rebooting: new BOOT.BIN, kernel, device tree and root file system"
    reboot_and_wait
    echo "now run: bash board/deploy.sh data"
    ;;

data)
    for f in mbv2_fuse_test mbv2_fuse_pipe; do
        [ -f "$APPS/$f" ] || die "$APPS/$f missing -- run board/build_apps.sh (in WSL)"
    done
    [ -f "$VEC/fuse_weights.bin" ] || die "$VEC/fuse_weights.bin missing -- run the host-side steps in README.md"
    assert_card
    bssh "mkdir -p /home/root/data /home/root/golden"
    bscp "$APPS/mbv2_fuse_test"                "/home/root/mbv2_fuse_test"
    bscp "$APPS/mbv2_fuse_pipe"                "/home/root/mbv2_fuse_pipe"
    bscp "$VEC/fuse_weights.bin"               "/home/root/data/fuse_weights.bin"
    bscp "$MODEL/model_mbv2.bin"               "/home/root/data/model_mbv2.bin"
    # holds the head's weights for the PL engine; without it the head refuses to start
    bscp "$MODEL/model_mbv2_packed.bin"        "/home/root/data/model_mbv2_packed.bin"
    echo "apps from $APPS, fixtures from $FIXDIR"
    for i in 0 1 2 3; do bscp "$FIXDIR/fix_$i.bin" "/home/root/golden/fix_$i.bin"; done
    bssh "chmod +x /home/root/mbv2_fuse_test /home/root/mbv2_fuse_pipe; sync"
    echo "== board against tree, sha16 -- all 9 files must match =="
    bad=0; n=0
    for f in mbv2_fuse_test mbv2_fuse_pipe data/fuse_weights.bin data/model_mbv2.bin data/model_mbv2_packed.bin \
             golden/fix_0.bin golden/fix_1.bin golden/fix_2.bin golden/fix_3.bin; do
        case $f in
          mbv2_fuse_*)         l="$APPS/$f";;
          data/fuse_weights.bin) l="$VEC/fuse_weights.bin";;
          data/*)              l="$MODEL/${f#data/}";;
          golden/*)            l="$FIXDIR/${f#golden/}";;
        esac
        b=$(bsha "/home/root/$f"); t=$(sha16 "$l"); n=$((n+1))
        if [ -n "$b" ] && [ "$b" = "$t" ]; then r=ok; else r=MISMATCH; bad=$((bad+1)); fi
        printf '%-28s board %s  tree %s  %s\n' "$f" "${b:-<none>}" "$t" "$r"
    done
    [ "$n" -eq 9 ] || die "compared $n files, expected 9"
    [ "$bad" -eq 0 ] || die "$bad of 9 file(s) differ -- do not measure"
    echo "all 9 files match"
    ;;

verify)
    for pl in 1 0; do
        echo "===== FUSE_HEAD_PL=$pl ====="
        T=900 bssh "cd /home/root && FUSE_HEAD_PL=$pl ./mbv2_fuse_test . 2>&1 | grep -aE 'fixture|BIT-EXACT|FAIL'"
    done
    ;;

speed)
    # launched once per run, not polled: ssh polling during a run lowers the measured fps
    for r in 1 2 3; do
        for bb in 1 0; do
            echo "===== run $r FUSE_BB2HD=$bb ====="
            T=900 bssh "cd /home/root && FUSE_BB2HD=$bb FUSE_HEAD_PL=1 PIPE_TIMING=1 ./mbv2_fuse_pipe . 120 0 2>&1 | grep -aE 'fps|correctness|producer split'"
        done
    done
    ;;

rollback)
    bssh "cd $SD && [ -f $RB ]" || die "no rollback copy on the card"
    bssh "cd $SD && cp -f $RB BOOT.BIN && sync && sha256sum BOOT.BIN | cut -c1-16"
    echo "rebooting into the rollback BOOT.BIN"
    reboot_and_wait
    echo "/home/root is empty again: run \`data\` with the apps and files that belong to that image"
    ;;

*) sed -n '2,24p' "$0" ;;
esac
