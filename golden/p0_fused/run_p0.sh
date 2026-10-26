#!/bin/bash
# Builds p0_fused.c and runs it on the four golden fixtures (positive runs), then rebuilds
# it with deliberately broken ring depths / constant widths and checks that it fails
# exactly where it should (negative runs).
#
# Usage: ./run_p0.sh   (from golden/p0_fused/; needs gcc)
# Reads: ../../models/mbv2_pose/model_mbv2.bin, ../../models/mbv2_pose/fixtures/fix_{0..3}.bin
# Writes: ./p0_fused (binary), ./p0_neg (temporary). Exit 0 only if every run is as expected.
set -u
BLOB=../../models/mbv2_pose/model_mbv2.bin
SRC="p0_fused.c ../../models/mbv2_pose/model_meta.c ../../sw/net/mbv2_pose.c"
CC="gcc -O2 -I../../sw/net -I../../models/mbv2_pose -I."

echo "=============== build ==============="
$CC -o p0_fused $SRC -lm || exit 2

fail=0
echo
echo "=============== positive: all four golden fixtures, 11 items each ==============="
for f in 0 1 2 3; do
    out=$(./p0_fused "$BLOB" "../../models/mbv2_pose/fixtures/fix_$f.bin" 2>&1)
    v=$(echo "$out" | grep -E "^P0 ")
    d=$(echo "$out" | grep -oE "= [0-9]+ rows")
    n=$(echo "$out" | sed -n '/10.2 checklist/,$p' | grep -cE "^ *[0-9]+ .*PASS")
    printf "  fixture %d : %-24s ring demand %-8s items passing %s/11\n" "$f" "$v" "$d" "$n"
    echo "$v" | grep -q PASSED || fail=1
done

echo
echo "  measured once (model-dependent, printed by item 10):"
./p0_fused "$BLOB" "../../models/mbv2_pose/fixtures/fix_0.bin" 2>&1 \
  | grep -A1 -E "width the DATA|headroom|constants checked|round-tripped|sharing one table|planted peaks|window ALONE" \
  | grep -v "^--$" | sed 's/^ */    /'

echo
echo "=============== negative: the gate must be able to fail ==============="
printf "  %-34s %-6s %s\n" "how it is broken" "exit" "verdict"
neg() {   # $1 = -D flags, $2 = expected PASS/FAIL, $3 = label
    $CC $1 -o p0_neg $SRC -lm 2>/dev/null || { echo "  build failed: $1"; fail=1; return; }
    ./p0_neg "$BLOB" ../../models/mbv2_pose/fixtures/fix_0.bin >/dev/null 2>&1
    rc=$?
    got=$([ $rc -eq 0 ] && echo PASS || echo FAIL)
    ok=$([ "$got" = "$2" ] && echo "as expected" || echo "*** UNEXPECTED, wanted $2 ***")
    printf "  %-34s %-6s %s (%s)\n" "$3" "$rc" "$got" "$ok"
    [ "$got" = "$2" ] || fail=1
}
neg "-DEDEPTH=4 -DELOOK=1" PASS "ring 4 rows, expand 1 row ahead"
neg "-DEDEPTH=3 -DELOOK=1" FAIL "ring 3 rows, expand 1 row ahead"
neg "-DEDEPTH=3 -DELOOK=0" PASS "ring 3 rows, strictly sequential"
neg "-DEDEPTH=2 -DELOOK=0" FAIL "ring 2 rows, strictly sequential"
neg "-DNB_M0=12"           FAIL "requant multiplier cut to 12 bits"
neg "-DNB_M0=17"           PASS "requant multiplier cut to 17 bits"
neg "-DNB_BIAS=32"         PASS "requant bias cut to 32 bits"
neg "-DNB_BIAS=24"         FAIL "requant bias cut to 24 bits"
neg "-DNB_SH=4"            FAIL "requant shift cut to 4 bits"
rm -f p0_neg

echo
if [ $fail -eq 0 ]; then
    echo "P0 GATE: PASS"
    echo "  the fused row-streamed order is bit-identical to the 65-op flow on all four"
    echo "  fixtures, through to the final keypoints, and every check has been observed"
    echo "  to fail when the thing it guards is broken"
else
    echo "P0 GATE: FAIL"
fi
exit $fail
