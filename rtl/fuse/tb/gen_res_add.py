# -*- coding: utf-8 -*-
"""gen_res_add.py -- stimulus and expected values for tb_res_add.v.

The expected value is computed here in Python, after add_requant_row in
golden/p0_fused/p0_fused.c, so the reference is independent of the Verilog under test.

Reads:   golden/p1_golden/vec/p1_manifest.json (residual mp, mq, sh, clamp of every block
         that has a residual; from golden/p1_golden/run_p1.sh)
Writes (next to this file): tb_res_add_vec.hex, tb_res_add_n.vh
Run:     python rtl/fuse/tb/gen_res_add.py

Vectors per residual block:
  rounding boundary   for each target output v, the p that puts t on the rounding
                      threshold, then p-2 .. p+2 (a defect here touches a tiny part
                      of the operand space, so it has to be aimed at)
  clamp edges         v = lo-1, lo, lo+1, hi-1, hi, hi+1
  operand extremes    p and x at +-32768 (34-bit product, 35-bit sum)
  random spread       a deterministic LCG, so a regression is reproducible
"""
import io, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
VEC = os.path.join(ROOT, "golden", "p1_golden", "vec")

LANES = 4


def sfit(v, bits):
    m = 1 << (bits - 1)
    return ((v + m) & ((1 << bits) - 1)) - m


def ref(p, x, mp, mq, sh, lo, hi):
    """p0_fused.c's add_requant_row, one element."""
    t = p * sfit(mp, 18) + x * sfit(mq, 18)
    r = t if sh <= 0 else (t + (1 << (sh - 1))) >> sh
    if r < lo:
        r = lo
    if r > hi:
        r = hi
    return r


man = json.load(io.open(os.path.join(VEC, "p1_manifest.json"), encoding="utf-8"))
blocks = [(b["block"], b["residual"]) for b in man["blocks"] if b["has_residual"]]

lines, per_block = [], []
for bi, r in blocks:
    mp, mq, sh = r["mp"], r["mq"], r["sh"]
    lo, hi = r["clamp"]
    vecs = []

    # the rounding boundary and the clamp edges, aimed at through p with x = 0
    for v in (lo - 1, lo, lo + 1, -1, 0, 1, hi - 1, hi, hi + 1):
        base = (v << sh) // sfit(mp, 18) if mp else 0
        for d in range(-2, 3):
            for x in (0, 1, -1, 127, -127):
                p = base + d
                if -32768 <= p <= 32767:
                    vecs.append((p, x))
    # the exact half, walked: t + half must cross a power of two
    for v in (0, 1, hi, lo):
        tgt = (v << sh) - (1 << (sh - 1)) if sh else v
        base = tgt // sfit(mp, 18) if mp else 0
        for d in range(-3, 4):
            p = base + d
            if -32768 <= p <= 32767:
                vecs.append((p, 0))
                vecs.append((p, 32767))
                vecs.append((p, -32768))
    # the operand extremes, where the 34-bit product and 35-bit sum are needed
    for p in (-32768, -32767, -1, 0, 1, 32766, 32767):
        for x in (-32768, -127, 0, 127, 32767):
            vecs.append((p, x))
    # a deterministic spread
    seed = 0x1234_5678 ^ (bi * 2654435761)
    for _ in range(600):
        seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF
        p = ((seed >> 8) & 0xFFFF) - 32768
        seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF
        x = ((seed >> 8) & 0xFF) - 128
        vecs.append((p, x))

    while len(vecs) % LANES:
        vecs.append((0, 0))
    per_block.append((bi, len(vecs)))
    for p, x in vecs:
        e = ref(p, x, mp, mq, sh, lo, hi)
        w = ((p & 0xFFFF)
             | ((x & 0xFFFF) << 16)
             | ((e & 0xFF) << 32)
             | ((mp & 0x3FFFF) << 40)
             | ((mq & 0x3FFFF) << 58)
             | ((sh & 0x3F) << 76)
             | ((lo & 0xFFFF) << 82)
             | ((hi & 0xFFFF) << 98))
        lines.append("%032x" % w)

io.open(os.path.join(HERE, "tb_res_add_vec.hex"), "w", newline="\n").write(
    "\n".join(lines) + "\n")
io.open(os.path.join(HERE, "tb_res_add_n.vh"), "w", newline="\n").write(
    "localparam integer NVEC = %d;\nlocalparam integer NGRP = %d;\n"
    % (len(lines), len(lines) // LANES))

print("%d vectors over %d residual blocks (%d groups of %d lanes)"
      % (len(lines), len(blocks), len(lines) // LANES, LANES))
for bi, n in per_block:
    print("   block %2d  %5d" % (bi, n))
