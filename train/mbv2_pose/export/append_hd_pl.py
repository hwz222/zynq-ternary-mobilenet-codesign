"""Append the hd_pl section to an existing packed blob (WP3 head-into-PL).

Standalone byte shuffler: reads model_mbv2_packed.bin + pack_meta_mbv2.h, and
appends the head weights REPACKED into the PL engine's stream order:
  - deconv ops (61/62/63): the weight-slice order every deconv runs on silicon
    (see rtl/tb/gen_hd_op.py, the order's single source of truth):
    for phase (py,px) in (0,0),(0,1),(1,0),(1,1): for ocg: for ic: for tap
    t={ty,tx} 0..3: 8 oc bytes, where ky = (0 if py else 1) if ty else
    (2 if py else 3), same in x. Source layout is [IC][OC][4][4].
  - final op (64): [OC][IC] padded OC 14 -> 16 with zero rows (the engine's
    beat count is OC/4 and the driver reads the int32 output at stride 16).
The original file bytes are preserved BY CONSTRUCTION (pure append); per-op
offsets (relative to the w8 section base, all 16-aligned) land in pack_meta as
HD_PL_OFF_* plus an HD_PL marker. Round-trip gate: the slice order is decoded
back and compared against the source weights before anything is written.

Usage: python tools/append_hd_pl.py [blob] [pack_meta] [pack_meta2 ...]
Defaults: runs/export/data/model_mbv2_packed.bin + runs/export/hls/pack_meta_mbv2.h
(the blob's grandparent directory must hold src/model_meta.c, see head_table)
"""
import hashlib
import os
import re
import sys

HERE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "runs", "export")
BLOB = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    HERE, "data", "model_mbv2_packed.bin")
METAS = sys.argv[2:] if len(sys.argv) > 2 else [
    os.path.join(HERE, "hls", "pack_meta_mbv2.h")]

# the four head ops of THIS model (asserted against the meta's offsets below)
# kind: "slice"  = the weight-slice (mode A) order -- ONLY for ops whose weights cannot
#                   stay resident in the engine's four tap banks (IC > 64). Mode A
#                   assembles the whole output tensor in a 1024-word buffer, so it is
#                   also the only mode that FITS op61's output.
#       "resident" = linear w[ky][kx][ic][oc], the resident-weight (mode B) order, which
#                   streams the output row by row -- required for op62/op63, whose
#                   whole-tensor assembly would overflow 4x and 16x (board, 2026-08-08).
#       "final"    = [OC][IC] padded to OC=16.
#
# The table is DERIVED from the export's own op table, not hard-coded: a model whose
# head sits at different op indices or different channel counts (the 320->64 projection
# model moves every head op by one and shrinks deconv0's IC from 320 to 64) must not need
# this file edited. The slice/resident split uses the SAME capacity rule the engine and
# twn_top derive it from: resident mode addresses 4*IC*OCG words of a 512-deep tap bank,
# so it needs IC*OCG <= 128. Above that the address wraps and aliases silently.
def head_table(export_dir, w8off):
    src = open(os.path.join(export_dir, "src", "model_meta.c"),
               encoding="utf-8", errors="replace").read()
    body = src[src.index("OPS["):]
    rows = [[int(v) for v in r.split(",")]
            for r in re.findall(r"\{([0-9 ,\-]+)\}", body)]
    head = []
    for oi, r in enumerate(rows):
        t, ic, oc = r[0], r[4], r[5]
        if t == 2:
            kind = "slice" if ic * (oc // 8) > 128 else "resident"
        elif t == 4:
            kind = "final"
        else:
            continue
        head.append((oi, kind, ic, oc, w8off[oi]))
    assert head, "no type 2/4 ops in the op table -- is this a head-in-PL export?"
    idx = [h[0] for h in head]
    assert idx == list(range(idx[0], idx[0] + len(idx))), \
        f"the head ops must be contiguous, got {idx}"
    assert idx[-1] == len(rows) - 1, \
        f"the last head op {idx[-1]} is not the last op {len(rows) - 1}"
    return head


def kpos(hi, parity):
    return (0 if parity else 1) if hi else (2 if parity else 3)


def main():
    meta = open(METAS[0], encoding="utf-8").read()
    w2al = int(re.search(r"#define W2_AL (\d+)", meta).group(1))
    w2hw = int(re.search(r"#define W2HW_BYTES (\d+)", meta).group(1))
    w8b = int(re.search(r"#define W8_BYTES (\d+)", meta).group(1))
    w8off = [int(v) for v in re.search(
        r"W8_OFF\[\] = \{([^}]*)\}", meta).group(1).split(",")]
    HEAD = head_table(os.path.dirname(os.path.dirname(os.path.abspath(BLOB))), w8off)
    print("[head] " + "  ".join(
        f"op{oi}:{kind}({ic}x{oc})" for (oi, kind, ic, oc, _) in HEAD))

    blob = open(BLOB, "rb").read()
    sec = w2al + w2hw                     # w8 section file base
    assert len(blob) == sec + w8b, f"blob size {len(blob)} != {sec}+{w8b} (already appended?)"
    assert "HD_PL" not in meta, "pack_meta already carries HD_PL (double append?)"

    def sgn(b):
        return b - 256 if b >= 128 else b

    out = bytearray()
    offs = {}
    for (oi, kind, ic, oc, off) in HEAD:
        base = sec + off
        assert len(out) % 16 == 0
        offs[oi] = w8b + len(out)         # relative to the w8 section base
        if kind in ("slice", "resident"):
            src = blob[base:base + ic * oc * 16]
            def wv(i, o, ky, kx):
                return src[((i * oc) + o) * 16 + ky * 4 + kx]
            sl = bytearray()
            if kind == "slice":
                for (py, px) in ((0, 0), (0, 1), (1, 0), (1, 1)):
                    for g in range(oc // 8):
                        for i in range(ic):
                            for t in range(4):
                                ky, kx = kpos(t >> 1, py), kpos(t & 1, px)
                                for l in range(8):
                                    sl.append(wv(i, g * 8 + l, ky, kx))
            else:                                   # resident: linear [ky][kx][ic][oc]
                for ky in range(4):
                    for kx in range(4):
                        for i in range(ic):
                            for o in range(oc):
                                sl.append(wv(i, o, ky, kx))
            assert len(sl) == ic * oc * 16
            # round-trip gate: decode THE ORDER JUST EMITTED back to (ic, oc, ky, kx)
            pos = 0
            if kind == "slice":
                for (py, px) in ((0, 0), (0, 1), (1, 0), (1, 1)):
                    for g in range(oc // 8):
                        for i in range(ic):
                            for t in range(4):
                                ky, kx = kpos(t >> 1, py), kpos(t & 1, px)
                                for l in range(8):
                                    assert sl[pos] == wv(i, g * 8 + l, ky, kx), \
                                        f"op{oi} slice roundtrip at {pos}"
                                    pos += 1
            else:
                for ky in range(4):
                    for kx in range(4):
                        for i in range(ic):
                            for o in range(oc):
                                assert sl[pos] == wv(i, o, ky, kx), \
                                    f"op{oi} resident roundtrip at {pos}"
                                pos += 1
            out += sl
        else:
            src = blob[base:base + oc * ic]           # [OC=14][IC]
            padded = bytearray(src) + bytearray(2 * ic)   # zero rows 14,15
            assert len(padded) == 16 * ic
            out += padded
        while len(out) % 16:
            out.append(0)

    new = blob + bytes(out)
    h_old = hashlib.sha256(blob).hexdigest()[:16]
    h_new = hashlib.sha256(new).hexdigest()[:16]
    assert new[:len(blob)] == blob                      # prefix preserved
    open(BLOB, "wb").write(new)
    print(f"[hd_pl] {BLOB}")
    print(f"[hd_pl] prefix sha {h_old} preserved; new blob sha {h_new} "
          f"({len(blob)} -> {len(new)} B, +{len(out)})")

    lines = [f"#define HD_PL 1",
             f"#define HD_PL_BYTES {len(out)}"]
    for oi in sorted(offs):
        lines.append(f"#define HD_PL_OFF_{oi} {offs[oi]}")
    # Index-agnostic form: the driver indexes it as [oi - first_head_op], so a model whose
    # head sits at other op numbers (the projection model's head starts at 62, not 61)
    # needs no driver edit. The per-op defines above stay for readability/greppability.
    lines.append("#define HD_PL_OFF_LIST " +
                 ", ".join(str(offs[oi]) for oi in sorted(offs)))
    lines.append(f"#define HD_PL_FIRST_OP {min(offs)}")
    ins = "\n".join(lines) + "\n#endif\n"
    for mp in METAS:
        s = open(mp, encoding="utf-8").read()
        assert "HD_PL" not in s, f"{mp} already has HD_PL"
        assert s.rstrip().endswith("#endif")
        # the loader memcpys W8_BYTES: it must cover the appended tail or the
        # hd_pl section never reaches the arena (found as w0=0 on the twin)
        s = re.sub(r"#define W8_BYTES \d+",
                   f"#define W8_BYTES {w8b + len(out)}   /* incl. hd_pl tail */", s)
        s = s.rstrip()[: -len("#endif")] + ins
        # header comment of the file as it is kept in models/mbv2_pose (comment only; the
        # old text of this line is what pack_ternary.py writes, and it must not contain
        # "HD_PL" or the double-append check above would trip on a rerun)
        s = s.replace("/* AUTO-GENERATED by tools/pack_ternary.py -- packed-weight offsets */\n",
                      "/* Packed-weight offsets, generated by tools/pack_ternary.py; the HD_PL_* entries are\n"
                      " * added by tools/append_hd_pl.py. Do not edit by hand.\n"
                      " *   W2_OFF[op]   element index in the linear ternary section, -1 if none\n"
                      " *   W2HW_OFF[op] byte offset in the hardware-ordered pointwise section, -1 if none\n"
                      " *   W8_OFF[op]   byte offset in the int8 section, -1 if none */\n", 1)
        open(mp, "w", newline="\n").write(s)
        print(f"[hd_pl] meta updated: {mp}")
    print("[hd_pl] offsets (w8-section-relative):",
          ", ".join(f"op{k}={v}" for k, v in sorted(offs.items())))


if __name__ == "__main__":
    main()
