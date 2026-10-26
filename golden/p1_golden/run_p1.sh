#!/bin/bash
# Generates the per-block golden vectors (gen_p1.c) and checks them.
#
#   0. re-runs ../p0_fused/run_p0.sh and stops if it fails
#   1. builds gen_p1 and writes vec/ for fixture 0 (vec/p1_manifest.json)
#   2. regenerates into vec_recheck/ and requires every sha256 to match
#   3. runs gen_p1 on all four fixtures and requires checks 0..3 to PASS
#   4. emits the Verilog testbenches (gen_tb.py) and syntax-checks them with xvlog
#   5. prints the block table (gen_tb.py --list)
#
# Usage: ./run_p1.sh   (from golden/p1_golden/; needs gcc, python, Vivado xvlog)
# Env:   PYTHON  interpreter for gen_tb.py (default: the conda env `twn` if present, else python)
# Writes: gen_p1, vec/, tb_p1_*.v, tb_p1_*_in.hex, /tmp/p1_p0.log. Exit 0 only if all steps pass.
set -u
BLOB=../../models/mbv2_pose/model_mbv2.bin
SRC="gen_p1.c ../../models/mbv2_pose/model_meta.c ../../sw/net/mbv2_pose.c"
CC="gcc -O2 -I../../sw/net -I../../models/mbv2_pose -I. -I../p0_fused"
fail=0

# Interpreter: $PYTHON if set, else `python` from PATH.
PY="${PYTHON:-python}"
echo "  python: $PY"

echo "=============== 0. the vectors are only as good as P0 ==============="
( cd ../p0_fused && bash run_p0.sh >/tmp/p1_p0.log 2>&1 )
if grep -q "^P0 GATE: PASS" /tmp/p1_p0.log; then
    echo "  P0 GATE: PASS (re-run just now; see ../p0_fused for the full log)"
else
    echo "  *** P0 GATE FAILED -- the vectors below would be invalid. Stopping. ***"
    tail -20 /tmp/p1_p0.log
    exit 2
fi

echo
echo "=============== 1. build and generate (fixture 0) ==============="
$CC -o gen_p1 $SRC -lm || exit 2
mkdir -p vec
./gen_p1 "$BLOB" ../../models/mbv2_pose/fixtures/fix_0.bin vec || fail=1

echo
echo "=============== 2. regeneration is deterministic ==============="
# Generate a second time into a different directory and require every hash to match.
rm -rf vec_recheck && mkdir -p vec_recheck
./gen_p1 "$BLOB" ../../models/mbv2_pose/fixtures/fix_0.bin vec_recheck >/dev/null || fail=1
a=$(grep -o '"sha256": "[0-9a-f]*"' vec/p1_manifest.json | sort)
b=$(grep -o '"sha256": "[0-9a-f]*"' vec_recheck/p1_manifest.json | sort)
n=$(echo "$a" | wc -l)
if [ "$a" = "$b" ]; then
    echo "  all $n file hashes reproduce exactly"
else
    echo "  *** $n hashes, and they DIFFER between two runs of the same generator ***"
    diff <(echo "$a") <(echo "$b") | head
    fail=1
fi
rm -rf vec_recheck

echo
echo "=============== 3. the checks hold for all four fixtures ==============="
printf "  %-10s %-8s %-8s %-8s %-8s\n" fixture coverage int8 weights fused
for f in 0 1 2 3; do
    rm -rf vec_f && mkdir -p vec_f
    out=$(./gen_p1 "$BLOB" "../../models/mbv2_pose/fixtures/fix_$f.bin" vec_f 2>&1)
    g=$(echo "$out" | grep "check 0" | grep -o "PASS\|FAIL")
    i=$(echo "$out" | grep "check 1" | grep -o "PASS\|FAIL")
    w=$(echo "$out" | grep "check 2" | grep -o "PASS\|FAIL")
    u=$(echo "$out" | grep "check 3" | grep -o "PASS\|FAIL")
    printf "  %-10s %-8s %-8s %-8s %-8s\n" "$f" "$g" "$i" "$w" "$u"
    for v in "$g" "$i" "$w" "$u"; do [ "$v" = "PASS" ] || fail=1; done
done
rm -rf vec_f

echo
echo "=============== 4. the emitted testbenches actually compile ==============="
# Compile every emitted testbench so a syntax error in the generator shows up here.
rm -f tb_p1_*.v
# Last row of block 0's expand output, read from the manifest (mid.h - 1) so it follows the
# input size.
E0LAST=$("$PY" -c "import json;print(json.load(open('vec/p1_manifest.json'))['blocks'][0]['mid']['h']-1)")
CASES="--tern|0|e --tern|0|e|--row|$E0LAST --tern|1|e --tern|2|p --tern|14|e --tern|16|p
       --dw|1 --dw|1|--row|31 --dw|2 --dw|16"
for c in $CASES; do
    "$PY" gen_tb.py $(echo "$c" | tr '|' ' ') >/dev/null || { echo "  emit failed: $c"; fail=1; }
done
ntb=$(ls tb_p1_*.v 2>/dev/null | wc -l)
XVLOG=$(command -v xvlog.bat || command -v xvlog || ls /c/Xilinx/Vivado/*/bin/xvlog.bat 2>/dev/null | head -1)
if [ -n "$XVLOG" ]; then
    bad=0
    work=$(mktemp -d)
    for f in tb_p1_*.v; do
        if ( cd "$work" && "$XVLOG" --nolog "$OLDPWD/$f" 2>&1 | grep -q ERROR ); then
            echo "  xvlog FAIL: $f"; bad=$((bad+1))
        fi
    done
    rm -rf "$work"
    echo "  xvlog: $((ntb-bad)) of $ntb testbenches compile clean"
    [ $bad -eq 0 ] || fail=1
else
    echo "  *** xvlog NOT FOUND -- the $ntb testbenches were emitted but NOT syntax-checked."
    echo "  *** This is a hole in the gate, not a pass. Install Vivado or run the check by hand."
    fail=1
fi

echo
echo "=============== 5. what P2 and P3 can now be built against ==============="
"$PY" gen_tb.py --list 2>/dev/null || echo "  (gen_tb.py not run)"

echo
if [ $fail -eq 0 ]; then
    echo "P1 GATE: PASS"
    echo "  vectors in vec/, manifest vec/p1_manifest.json, hashes reproduce, and every"
    echo "  unit-test case in §10.3 has a block that supplies it"
else
    echo "P1 GATE: FAIL"
fi
exit $fail
