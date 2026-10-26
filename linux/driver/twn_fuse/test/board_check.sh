#!/bin/sh
# Board check of the twn_fuse driver against the UIO path. Run on the board, as root, in a
# directory that holds:
#   twn_fuse.ko  bind.sh  twn_errtest
#   mbv2_fuse_test_uio  mbv2_fuse_test_drv  mbv2_fuse_pipe_uio  mbv2_fuse_pipe_drv
#   data/{fuse_weights,model_mbv2,model_mbv2_packed}.bin  golden/fix_{0..3}.bin
# (the apps from `bash board/build_apps.sh` and `HAL=drv bash board/build_apps.sh`).
#
#   1. both backends, four fixtures, head in the PL and on the processor: max|diff| must be 0
#   2. the driver's refusals, and its 3 s timeout (twn_errtest timeout)
#   3. rmmod refused while the device is open, and while only a mapping is left; five unload/reload
#      cycles with the fixtures
#   4. pipeline throughput, three runs of 120 frames per backend, FUSE_BB2HD=1, each run's
#      keypoints checked against fixture 0
# Leaves the device bound to twn_fuse. Prints "BOARD CHECK: PASS" only if every check passed.
cd "$(dirname "$0")" || exit 1
fail=0
fixtures() {   # <app> -> number of fixtures that passed, for each head placement
    for pl in 1 0; do
        n=$(FUSE_HEAD_PL=$pl ./$1 . 2>&1 | grep -ac '^fixture .: PASS | final max|diff|=0')
        echo "  $1 FUSE_HEAD_PL=$pl: $n/4 fixtures bit-exact"
        [ "$n" = 4 ] || fail=1
    done
}

echo "== $(date -u '+%Y-%m-%d %H:%M UTC')  $(uname -r)  BOOT.BIN $(sha256sum /run/media/mmcblk0p1/BOOT.BIN | cut -c1-16)  twn_fuse.ko $(sha256sum twn_fuse.ko | cut -c1-16)"
echo "== 1. fixtures, both backends"
sh bind.sh uio && fixtures mbv2_fuse_test_uio
sh bind.sh drv ./twn_fuse.ko && fixtures mbv2_fuse_test_drv

echo "== 2. refusals and timeout"
./twn_errtest timeout || fail=1
dmesg | grep 'twn_fuse ' | tail -2       # the driver's own messages for the refused table and the timeout
fixtures mbv2_fuse_test_drv            # an app reloads the table after the refused one

echo "== 3. unload while open, while only mapped, then five unload/reload cycles"
(sleep 3 < /dev/twn_fuse &)
sleep 1
if msg=$(rmmod twn_fuse 2>&1); then echo "  rmmod while open: ALLOWED (wrong)"; fail=1; sh bind.sh drv >/dev/null
else echo "  rmmod while open: refused ($msg)"; fi
sleep 3
./twn_errtest hold &                     # mapped, but the device is closed
sleep 1
if msg=$(rmmod twn_fuse 2>&1); then echo "  rmmod while only mapped: ALLOWED (wrong)"; fail=1; sh bind.sh drv >/dev/null
else echo "  rmmod while only mapped: refused ($msg)"; fi
wait
for i in 1 2 3 4 5; do
    sh bind.sh uio >/dev/null && sh bind.sh drv >/dev/null || fail=1
    n=$(FUSE_HEAD_PL=1 ./mbv2_fuse_test_drv . 2>&1 | grep -ac '^fixture .: PASS | final max|diff|=0')
    echo "  cycle $i: $n/4 fixtures bit-exact"
    [ "$n" = 4 ] || fail=1
done

echo "== 4. pipeline throughput (120 frames, FUSE_BB2HD=1)"
for b in uio drv; do
    sh bind.sh $b >/dev/null
    for i in 1 2 3; do
        out=$(FUSE_BB2HD=1 FUSE_HEAD_PL=1 ./mbv2_fuse_pipe_$b . 120 0 2>&1)
        echo "$out" | grep -a 'fps ===' | sed "s/^/  $b run $i: /"
        echo "$out" | grep -aq 'correctness vs fixture 0 golden: PASS' ||
            { echo "  $b run $i: keypoints differ from fixture 0"; fail=1; }
    done
done

[ $fail = 0 ] && echo "BOARD CHECK: PASS" || echo "BOARD CHECK: FAIL"
