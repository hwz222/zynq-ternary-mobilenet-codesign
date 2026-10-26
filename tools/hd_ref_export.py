"""hd_ref_export.py -- per-operator golden vectors for the head engine (ops 61..64).

Recomputes the whole network from a fixture's input image and writes, in the byte
layouts twn_hd_compute consumes (one 128-bit beat per line):
    hd_op<NN>_in.hex / _w.hex / _out.hex    NN = 61..64
    hd_rq.hex                               requant entries, 128 bits per (op, oc)
    hd_vec_manifest.json                    shapes, descriptor fields, sha256_16 of files
Vectors are written only if the recomputation reproduces the fixture's own
per-operator checksums ck_ref, all acc_ref elements and the keypoints kp_ref
("pairing proof"); otherwise it exits 2. Consumed by rtl/fuse/tb/tb_hd_frame.v.

Reads:   models/mbv2_pose/model_meta.c, models/mbv2_pose/model_meta.h, models/mbv2_pose/model_mbv2.bin,
         models/mbv2_pose/fixtures/fix_<K>.bin,
         rtl/tb/hd_ref.py (self-check), golden/p1_golden/vec/b16_out.bin (optional),
         dev_records/fuse_session/dump_20260813_222423/fx0_bb_chw_i16.bin (optional)
Writes:  --out (default rtl/fuse/tb/hd_vec)
Needs:   numpy; git is queried for the manifest ("unknown" if unavailable).

    python tools/hd_ref_export.py [--fixture 0] [--out DIR]

Layouts (the code below is authoritative):
  input stream   NHWC bytes [iy][ix][ic], 16 per beat, first byte in the low byte;
                 IC is a multiple of 16. In mode A the testbench replays the input
                 file once per (phase, ocg) slice; the file is written once.
  weights, mode B (resident, op62/op63)  linear w[ky][kx][ic][oc], oc fastest.
  weights, mode A (slice, op61)  for phase (py,px) in (0,0),(0,1),(1,0),(1,1):
                 for ocg: for ic: for tap t = {ty,tx}: 8 oc bytes; tap t reads
                 kernel position kpos(ty, py), kpos(tx, px).
  weights, type 4 (op64)  linear w[oc][ic] with OC padded 14 -> 16 by zero rows
                 (the engine emits OC/4 beats per pixel).
  output         type 2: int8 NHWC, 16 per beat; type 4: raw int32 NHWC, 4 per
                 beat, at the padded channel stride 16.
  requant        per oc: m0 signed 18 bits, bias signed 40 bits, sh 6 bits; the
                 engine $finishes on violation, so they are asserted here.
  mode           mode_a = !type4 && slice, slice <=> IC*(OC/8) > 128; mode A also
                 needs 4*H*W*OC <= 8192 (whole output held in 1024 x 64-bit words,
                 asserted by twn_hd_seq).
op61's input is op 60's output computed from the fixture's image; op62..op64 take
the previous operator's output. It is not golden/p1_golden/vec/b16_out.bin, which comes
from a different stimulus.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(HERE, "models", "mbv2_pose")
META_C = os.path.join(MODEL, "model_meta.c")
BLOB_F = os.path.join(MODEL, "model_mbv2.bin")
FIX_F = os.path.join(MODEL, "fixtures", "fix_%d.bin")
B16_F = os.path.join(HERE, "golden", "p1_golden", "vec", "b16_out.bin")
BB_DUMP = os.path.join(HERE, "dev_records", "fuse_session",
                       "dump_20260813_222423", "fx0_bb_chw_i16.bin")

# model_meta.h values, asserted against the header in parse_meta().
N_OPS = 65
BLOB_BYTES = 1977216
NET_IN_C, NET_IN_H, NET_IN_W = 3, 256, 256
NET_OUT_C, NET_OUT_H, NET_OUT_W = 14, 64, 64

OP_FIELDS = ["type", "in_buf", "in2_buf", "out_buf", "ic", "oc", "kh", "kw",
             "stride", "pad", "w_off", "rq_off", "relu", "lo", "hi",
             "mp", "mq", "sh"]


# ---------------------------------------------------------------- model_meta
def parse_meta():
    """OPS / RQ_M0 / RQ_BIAS / RQ_SH parsed out of the generated model_meta.c, so
    there is no second hand-written copy of the op table."""
    src = open(META_C, encoding="utf-8", errors="replace").read()
    hdr = open(os.path.join(MODEL, "model_meta.h"),
               encoding="utf-8", errors="replace").read()
    for name, want in (("N_OPS", N_OPS), ("BLOB_BYTES", BLOB_BYTES),
                       ("NET_IN_H", NET_IN_H), ("NET_OUT_C", NET_OUT_C),
                       ("NET_OUT_H", NET_OUT_H)):
        got = int(re.search(r"#define %s (\d+)" % name, hdr).group(1))
        assert got == want, "model_meta.h %s = %d, this exporter assumes %d" % (
            name, got, want)

    body = src[src.index("const Op OPS["):]
    body = body[:body.index("};")]
    rows = [[int(v) for v in r.split(",")]
            for r in re.findall(r"\{([0-9 ,\-]+)\}", body)]
    assert len(rows) == N_OPS, "parsed %d ops, expected %d" % (len(rows), N_OPS)
    ops = [dict(zip(OP_FIELDS, r)) for r in rows]

    def arr(decl, cast):
        m = re.search(re.escape(decl) + r"\s*\{([^}]*)\}", src)
        txt = m.group(1).replace("LL", "").replace("\n", " ")
        return np.array([cast(v) for v in txt.split(",") if v.strip()],
                        dtype=np.int64)

    m0 = arr("const int32_t RQ_M0[] =", int)
    bias = arr("const int64_t RQ_BIAS[] =", int)
    sh = arr("const int8_t RQ_SH[] =", int)
    assert len(m0) == len(bias) == len(sh), \
        "RQ table lengths disagree: %d / %d / %d" % (len(m0), len(bias), len(sh))
    return ops, m0, bias, sh


# ---------------------------------------------------------------- arithmetic
def rshift_round(t, s):
    """As sw/net/mbv2_pose.c rshift_round: s <= 0 is a pass-through, otherwise
    (t + 2^(s-1)) >> s with an arithmetic shift (numpy's >> on int64)."""
    t = np.asarray(t, dtype=np.int64)
    if s <= 0:
        return t.astype(np.int64)
    return (t + (np.int64(1) << np.int64(s - 1))) >> np.int64(s)


def gemm(w, x):
    """Exact integer matmul (w: OCxIC int64, x: ICxN int64) via float64 BLAS.

    Every intermediate is an integer well inside float64's exact range, so BLAS
    reassociation cannot change the result; asserted below."""
    r = w.astype(np.float64) @ x.astype(np.float64)
    assert np.max(np.abs(r)) < float(1 << 50), \
        "accumulator %g exceeds the exact-float64 window" % np.max(np.abs(r))
    return np.rint(r).astype(np.int64)


def requant(acc, rq_off, relu, lo, hi, m0, bias, sh):
    """Per-output-channel requant as in sw/net/mbv2_pose.c. acc is (OC, ...)."""
    oc = acc.shape[0]
    flat = acc.reshape(oc, -1)
    out = np.empty_like(flat)
    for c in range(oc):
        t = flat[c] * m0[rq_off + c] + bias[rq_off + c]
        r = rshift_round(t, int(sh[rq_off + c]))
        if relu:
            r = np.maximum(r, 0)
        out[c] = np.clip(r, lo, hi)
    return out.reshape(acc.shape)


def deconv_acc(w_icockykx, x, IC, OC, H, W, pad=1):
    """4x4 stride-2 transposed convolution accumulator, CHW in / CHW out.

    Scatter form: out[oc, 2*iy + ky - pad, 2*ix + kx - pad] += w[ic,oc,ky,kx] * x[ic,iy,ix].
    Same values as rtl/tb/hd_ref.py's deconv_ref; selfcheck_against_hd_ref()
    compares them on random data."""
    OH, OW = 2 * H, 2 * W
    acc = np.zeros((OC, OH, OW), dtype=np.int64)
    xf = x.reshape(IC, H * W)
    for ky in range(4):
        for kx in range(4):
            wk = w_icockykx[:, :, ky, kx].T          # (OC, IC)
            p = gemm(wk, xf).reshape(OC, H, W)
            oy0, ox0 = ky - pad, kx - pad
            iy_lo = max(0, -(oy0 // 2) if oy0 < 0 else 0)
            iy_hi = min(H - 1, (OH - 1 - oy0) // 2)
            ix_lo = max(0, -(ox0 // 2) if ox0 < 0 else 0)
            ix_hi = min(W - 1, (OW - 1 - ox0) // 2)
            if iy_lo > iy_hi or ix_lo > ix_hi:
                continue
            acc[:, oy0 + 2 * iy_lo: oy0 + 2 * iy_hi + 1: 2,
                   ox0 + 2 * ix_lo: ox0 + 2 * ix_hi + 1: 2] += \
                p[:, iy_lo:iy_hi + 1, ix_lo:ix_hi + 1]
    return acc


def forward(ops, blob, m0, bias, sh, x_in, capture):
    """All 65 operators, CHW, as the C model runs them.

    `capture` collects the head tensors on the way past. Returns
    (final_acc CHW int64, keypoints, checksums[65])."""
    bufs = {0: x_in.astype(np.int64)}
    ck = [0] * N_OPS
    final_acc = None
    kp = None
    for oi, op in enumerate(ops):
        x = bufs[op["in_buf"]]
        C, H, W = x.shape
        t = op["type"]
        if t == 4:                                    # final 1x1, raw int32
            w = blob[op["w_off"]: op["w_off"] + op["oc"] * op["ic"]] \
                .astype(np.int64).reshape(op["oc"], op["ic"])
            capture["op%d_in" % oi] = x
            capture["op%d_w" % oi] = w
            final_acc = gemm(w, x.reshape(op["ic"], H * W)).reshape(op["oc"], H, W)
            ck[oi] = int(final_acc.sum())
            capture["op%d_out" % oi] = final_acc
            kp = []
            for k in range(op["oc"]):
                a = final_acc[k].reshape(-1)
                best = int(np.argmax(a))              # C takes the FIRST maximum
                kp += [best % W, best // W]
            break
        if t == 3:                                    # residual seam add
            p, xin = bufs[op["in_buf"]], bufs[op["in2_buf"]]
            r = rshift_round(p * op["mp"] + xin * op["mq"], op["sh"])
            out = np.clip(r, op["lo"], op["hi"])
        elif t == 0:                                  # conv (1x1 or the 3x3 stem)
            KH, KW, S, P = op["kh"], op["kw"], op["stride"], op["pad"]
            OH = (H + 2 * P - KH) // S + 1
            OW = (W + 2 * P - KW) // S + 1
            w = blob[op["w_off"]: op["w_off"] + op["oc"] * op["ic"] * KH * KW] \
                .astype(np.int64).reshape(op["oc"], op["ic"], KH, KW)
            if KH == 1 and KW == 1 and S == 1 and P == 0:
                acc = gemm(w[:, :, 0, 0], x.reshape(op["ic"], H * W)) \
                    .reshape(op["oc"], OH, OW)
            else:
                xp = np.pad(x, ((0, 0), (P, P), (P, P)))
                acc = np.zeros((op["oc"], OH, OW), dtype=np.int64)
                for ky in range(KH):
                    for kx in range(KW):
                        sl = xp[:, ky:ky + OH * S:S, kx:kx + OW * S:S]
                        acc += gemm(w[:, :, ky, kx],
                                    sl.reshape(op["ic"], OH * OW)).reshape(op["oc"], OH, OW)
            out = requant(acc, op["rq_off"], op["relu"], op["lo"], op["hi"], m0, bias, sh)
        elif t == 1:                                  # depthwise 3x3
            KH, KW, S, P = op["kh"], op["kw"], op["stride"], op["pad"]
            OH = (H + 2 * P - KH) // S + 1
            OW = (W + 2 * P - KW) // S + 1
            w = blob[op["w_off"]: op["w_off"] + op["oc"] * KH * KW] \
                .astype(np.int64).reshape(op["oc"], KH, KW)
            xp = np.pad(x, ((0, 0), (P, P), (P, P)))
            acc = np.zeros((op["oc"], OH, OW), dtype=np.int64)
            for ky in range(KH):
                for kx in range(KW):
                    acc += w[:, ky, kx][:, None, None] * \
                        xp[:, ky:ky + OH * S:S, kx:kx + OW * S:S]
            out = requant(acc, op["rq_off"], op["relu"], op["lo"], op["hi"], m0, bias, sh)
        elif t == 2:                                  # transposed conv (head)
            IC, OC = op["ic"], op["oc"]
            w = blob[op["w_off"]: op["w_off"] + IC * OC * 16] \
                .astype(np.int64).reshape(IC, OC, 4, 4)
            capture["op%d_in" % oi] = x
            capture["op%d_w" % oi] = w
            acc = deconv_acc(w, x, IC, OC, H, W, op["pad"])
            out = requant(acc, op["rq_off"], op["relu"], op["lo"], op["hi"], m0, bias, sh)
            capture["op%d_out" % oi] = out
        else:
            raise SystemExit("unknown op type %d at %d" % (t, oi))
        bufs[op["out_buf"]] = out
        ck[oi] = int(out.sum())
        if oi == 60:
            capture["op60_out"] = out
    return final_acc, kp, ck


# ---------------------------------------------------------------- byte orders
def beats16(byts):
    """16 bytes -> one 128-bit beat, byte j at bits [8j+7:8j]."""
    assert len(byts) % 16 == 0, "%d bytes is not a whole number of beats" % len(byts)
    out = []
    for i in range(0, len(byts), 16):
        v = 0
        for j in range(16):
            v |= (int(byts[i + j]) & 0xFF) << (8 * j)
        out.append(v)
    return out


def beats_i32(vals):
    """4 int32 -> one 128-bit beat, word j at bits [32j+31:32j]."""
    assert len(vals) % 4 == 0
    out = []
    for i in range(0, len(vals), 4):
        v = 0
        for j in range(4):
            v |= (int(vals[i + j]) & 0xFFFFFFFF) << (32 * j)
        out.append(v)
    return out


def nhwc_bytes(chw):
    """CHW int tensor -> NHWC byte list [iy][ix][ic]."""
    a = np.ascontiguousarray(np.transpose(chw, (1, 2, 0)))
    assert a.min() >= -128 and a.max() <= 127, \
        "activation %d..%d does not fit int8 -- the strict export is violated" % (
            a.min(), a.max())
    return (a.reshape(-1).astype(np.int64) & 0xFF).tolist()


def kpos(hi, parity):
    """Kernel position for tap half `hi` and output parity."""
    return (0 if parity else 1) if hi else (2 if parity else 3)


def weight_bytes_slice(w, IC, OC):
    """mode A order (see the module header)."""
    out = []
    for (py, px) in ((0, 0), (0, 1), (1, 0), (1, 1)):
        for g in range(OC // 8):
            for ic in range(IC):
                for t in range(4):
                    ky, kx = kpos(t >> 1, py), kpos(t & 1, px)
                    for l in range(8):
                        out.append(int(w[ic, g * 8 + l, ky, kx]) & 0xFF)
    assert len(out) == IC * OC * 16
    return out


def weight_bytes_resident(w, IC, OC):
    """mode B order (see the module header)."""
    out = []
    for ky in range(4):
        for kx in range(4):
            for ic in range(IC):
                for oc in range(OC):
                    out.append(int(w[ic, oc, ky, kx]) & 0xFF)
    assert len(out) == IC * OC * 16
    return out


def weight_bytes_final(w, IC, OC_pad):
    """type 4, [OC][IC] with OC padded to 16 by zero rows."""
    out = []
    for oc in range(OC_pad):
        for ic in range(IC):
            out.append(int(w[oc, ic]) & 0xFF if oc < w.shape[0] else 0)
    assert len(out) == OC_pad * IC
    return out


def write_hex(path, beats, width_nibbles=32):
    with open(path, "w", newline="\n") as f:
        for v in beats:
            f.write("%0*x\n" % (width_nibbles, v))
    return len(beats)


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 16), b""):
            h.update(c)
    return h.hexdigest()[:16]


# ---------------------------------------------------------------- self-checks
def selfcheck_against_hd_ref():
    """This exporter's deconv/final must agree with rtl/tb/hd_ref.py on a small
    random case, compared exhaustively."""
    sys.path.insert(0, os.path.join(HERE, "rtl", "tb"))
    from hd_ref import deconv_ref, final_ref                       # noqa: E402
    rng = np.random.RandomState(20260815)
    H, W, IC, OC = 5, 4, 16, 8
    x = rng.randint(-127, 128, size=(IC, H, W)).astype(np.int64)
    w = rng.randint(-128, 128, size=(IC, OC, 4, 4)).astype(np.int64)
    rqm = rng.randint(1 << 16, 1 << 17, size=OC, dtype=np.int64)
    # the full signed-40-bit bias range on purpose: widths are contract-asserted
    rqb = rng.randint(-(1 << 39) + 1, 1 << 39, size=OC, dtype=np.int64)
    rqs = rng.randint(18, 25, size=OC, dtype=np.int64)
    acc = deconv_acc(w, x, IC, OC, H, W, 1)
    mine = np.empty_like(acc)
    for c in range(OC):
        r = rshift_round(acc[c] * rqm[c] + rqb[c], int(rqs[c]))
        mine[c] = np.clip(np.maximum(r, 0), 0, 127)
    xl = [[[int(x[ic, iy, ix]) for ic in range(IC)] for ix in range(W)] for iy in range(H)]
    wl = [[[[int(w[ic, oc, ky, kx]) for kx in range(4)] for ky in range(4)]
           for oc in range(OC)] for ic in range(IC)]
    ref = deconv_ref(xl, wl, H, W, IC, OC,
                     (rqm.tolist(), rqb.tolist(), rqs.tolist()), 1, 0, 127)
    for oy in range(2 * H):
        for ox in range(2 * W):
            for oc in range(OC):
                assert int(mine[oc, oy, ox]) == ref[oy][ox][oc], \
                    "deconv disagrees with hd_ref at (%d,%d,%d)" % (oy, ox, oc)
    wf = rng.randint(-128, 128, size=(OC, IC)).astype(np.int64)
    fm = gemm(wf, x.reshape(IC, H * W)).reshape(OC, H, W)
    fr = final_ref(xl, wf.tolist(), H, W, IC, OC)
    for oy in range(H):
        for ox in range(W):
            for oc in range(OC):
                assert int(fm[oc, oy, ox]) == fr[oy][ox][oc], "final disagrees with hd_ref"
    return "deconv + final == rtl/tb/hd_ref.py on a %dx%d IC=%d OC=%d random case" % (
        H, W, IC, OC)


def head_only(ops, blob, m0, bias, sh, x_chw):
    """Ops 61..64 from a CHW boundary tensor -> final_acc, flat CHW int64."""
    x = x_chw
    for oi in (61, 62, 63):
        op = ops[oi]
        IC, OC = op["ic"], op["oc"]
        H, W = x.shape[1], x.shape[2]
        w = blob[op["w_off"]: op["w_off"] + IC * OC * 16] \
            .astype(np.int64).reshape(IC, OC, 4, 4)
        acc = deconv_acc(w, x, IC, OC, H, W, op["pad"])
        x = requant(acc, op["rq_off"], op["relu"], op["lo"], op["hi"], m0, bias, sh)
    op = ops[64]
    w = blob[op["w_off"]: op["w_off"] + op["oc"] * op["ic"]] \
        .astype(np.int64).reshape(op["oc"], op["ic"])
    return gemm(w, x.reshape(op["ic"], -1)).reshape(-1)


def check_b16_pairing(ops, blob, m0, bias, sh, op61_in_chw, acc_ref):
    """Compare golden/p1_golden/vec/b16_out.bin with op 61's input, and run the head on it
    in two layouts (NHWC-transposed, and CHW bytes handed over raw) against
    acc_ref. Returns report lines."""
    if not os.path.exists(B16_F):
        return ["golden/p1_golden/vec/b16_out.bin absent (regenerable, not in git)"]
    b16 = np.fromfile(B16_F, dtype=np.int8).astype(np.int64)
    ref = op61_in_chw.reshape(-1)
    if b16.size != ref.size:
        return ["b16_out.bin is %d bytes, boundary is %d" % (b16.size, ref.size)]
    d = np.abs(b16 - ref)
    n = int((d != 0).sum())
    out = ["b16_out.bin vs op61 input: %d / %d bytes differ, max|diff| = %d%s"
           % (n, ref.size, int(d.max()), "   <== IDENTICAL" if n == 0 else "")]
    C, H, W = op61_in_chw.shape
    for tag, xc in (("b16 -> NHWC then head (head_from_b16.c mode 1)",
                     b16.reshape(C, H * W)),
                    ("b16 handed over raw    (head_from_b16.c mode 0)",
                     np.ascontiguousarray(
                         b16.reshape(H * W, C).reshape(H, W, C).transpose(2, 0, 1))
                     .reshape(C, H * W))):
        got = head_only(ops, blob, m0, bias, sh, xc.reshape(C, H, W))
        dd = np.abs(got - acc_ref)
        nn = int((dd != 0).sum())
        first = int(np.argmax(dd != 0)) if nn else -1
        out.append("  %s: %d / %d differ, max|diff| = %d%s"
                   % (tag, nn, acc_ref.size, int(dd.max()),
                      "   <== EXACT" if nn == 0 else
                      ", first at %d (got %d want %d)"
                      % (first, got[first], acc_ref[first])))
    return out


def check_board_dump(op61_in_chw):
    """Compare the optional board-dump file with op 61's input (a boundary-tensor
    check; the dump is int16 CHW)."""
    if not os.path.exists(BB_DUMP):
        return "fx0_bb_chw_i16.bin absent"
    bb = np.fromfile(BB_DUMP, dtype=np.int16).astype(np.int64)
    ref = op61_in_chw.reshape(-1)
    if bb.size != ref.size:
        return "fx0_bb_chw_i16.bin is %d values, boundary is %d" % (bb.size, ref.size)
    d = np.abs(bb - ref)
    n = int((d != 0).sum())
    return ("fx0_bb_chw_i16.bin vs op61 input: %d / %d differ, max|diff| = %d%s"
            % (n, ref.size, int(d.max()), "   <== IDENTICAL" if n == 0 else ""))


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture", type=int, default=0)
    ap.add_argument("--out", default=os.path.join(HERE, "rtl", "fuse", "tb", "hd_vec"))
    args = ap.parse_args()

    t0 = time.time()
    print("hd_ref_export -- head golden vectors for tb_hd_frame")
    print("  tree     %s" % HERE)
    print("  utc      %s" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    print("  numpy    %s   python %s" % (np.__version__, sys.version.split()[0]))
    print("[selfcheck] %s" % selfcheck_against_hd_ref())

    ops, m0, bias, sh = parse_meta()
    blob = np.fromfile(BLOB_F, dtype=np.int8)
    assert blob.size == BLOB_BYTES, "blob is %d bytes, expected %d" % (blob.size, BLOB_BYTES)

    fd = next(i for i, o in enumerate(ops) if o["type"] == 2)   # first transposed conv
    head = list(range(fd, N_OPS))
    assert head == [61, 62, 63, 64], "head ops are %s, this exporter assumes 61..64" % head

    # ---- fixture: input image, acc_ref, kp_ref, ck_ref
    fx = open(FIX_F % args.fixture, "rb").read()
    n_in = NET_IN_C * NET_IN_H * NET_IN_W
    n_acc = NET_OUT_C * NET_OUT_H * NET_OUT_W
    want = n_in + 4 * n_acc + 4 * NET_OUT_C * 2 + 8 * N_OPS
    assert len(fx) == want, "fix_%d.bin is %d bytes, expected %d" % (
        args.fixture, len(fx), want)
    o = 0
    x_in = np.frombuffer(fx, np.int8, n_in, o).reshape(NET_IN_C, NET_IN_H, NET_IN_W)
    o += n_in
    acc_ref = np.frombuffer(fx, np.int32, n_acc, o).astype(np.int64)
    o += 4 * n_acc
    kp_ref = np.frombuffer(fx, np.int32, NET_OUT_C * 2, o)
    o += 4 * NET_OUT_C * 2
    ck_ref = np.frombuffer(fx, np.int64, N_OPS, o)

    # ---- the pairing proof ----
    cap = {}
    final_acc, kp, ck = forward(ops, blob, m0, bias, sh, x_in, cap)
    bad_ck = [(i, ck[i], int(ck_ref[i])) for i in range(N_OPS) if ck[i] != int(ck_ref[i])]
    d = np.abs(final_acc.reshape(-1) - acc_ref)
    n_bad = int((d != 0).sum())
    kp_bad = [i for i in range(NET_OUT_C * 2) if kp[i] != int(kp_ref[i])]

    print("\n=== PAIRING PROOF (fixture %d) ===" % args.fixture)
    print("  per-operator checksums   %d / %d match ck_ref%s"
          % (N_OPS - len(bad_ck), N_OPS,
             "" if not bad_ck else "   FIRST BAD: op%d got %d want %d" % bad_ck[0]))
    print("  final_acc elements       %d / %d differ, max|diff| = %d"
          % (n_bad, n_acc, int(d.max())))
    print("  keypoints                %d / %d match" % (NET_OUT_C * 2 - len(kp_bad),
                                                        NET_OUT_C * 2))
    print("  head checksums 61..64    got %s" % [ck[i] for i in head])
    print("                           ref %s" % [int(ck_ref[i]) for i in head])
    for ln in check_b16_pairing(ops, blob, m0, bias, sh, cap["op61_in"], acc_ref):
        print("  %s" % ln)
    print("  %s" % check_board_dump(cap["op61_in"]))
    if bad_ck or n_bad or kp_bad:
        print("\nREFEREE NOT VALIDATED -- refusing to write vectors. The reference "
              "does not reproduce the fixture, so any gate built on it would be "
              "scoring against an unknown.")
        return 2
    print("  => VALIDATED. op61's input is OPS[60]'s output for fix_%d.bin;"
          % args.fixture)
    print("     op62/63/64's inputs are the previous operator's output.")

    # ---- descriptor derivation ----
    os.makedirs(args.out, exist_ok=True)
    man = {"generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "fixture": args.fixture, "tree": HERE, "files": {}, "ops": []}
    try:
        man["git"] = subprocess.check_output(
            ["git", "-C", HERE, "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        man["git"] = "unknown"

    rq_words = []
    print("\n=== VECTORS ===")
    for oi in head:
        op = ops[oi]
        IC, OC = op["ic"], op["oc"]
        x = cap["op%d_in" % oi]
        w = cap["op%d_w" % oi]
        y = cap["op%d_out" % oi]
        H, W = x.shape[1], x.shape[2]
        type4 = (op["type"] == 4)
        # same rule as twn_hd_seq (slice flag)
        slice_mode = (IC * (OC // 8) > 128) if not type4 else False
        mode_a = (not type4) and slice_mode
        if type4:
            OC_eng = 16                       # the engine emits OC/4 beats per pixel
            assert OC_eng <= 16, "twn_hd_compute.v:867 requires OC <= 16"
            assert IC == 32, "twn_hd_compute.v:870 requires IC == 32 for type 4"
            wb = weight_bytes_final(w, IC, OC_eng)
            xb = nhwc_bytes(x)
            # padded to 16 channels: lanes 14/15 are zero because their weights are
            pad = np.zeros((OC_eng, H, W), dtype=np.int64)
            pad[:OC] = y
            flat = np.transpose(pad, (1, 2, 0)).reshape(-1)
            assert np.max(np.abs(flat)) < (1 << 31)
            ob = beats_i32(flat.tolist())
            in_beats, out_beats, passes = len(xb) // 16, len(ob), 1
            OH, OW = H, W
        else:
            OC_eng = OC
            assert 4 * H * W * OC <= 8192 or not mode_a, \
                ("twn_hd_compute.v:861 / twn_hd_seq.v:151: mode A needs "
                 "4*H*W*OC <= 8192, op%d asks for %d" % (oi, 4 * H * W * OC))
            assert mode_a or IC * (OC // 8) <= 128, \
                "twn_hd_compute.v:399: resident mode needs 4*IC*OCG <= 512"
            wb = (weight_bytes_slice(w, IC, OC) if mode_a
                  else weight_bytes_resident(w, IC, OC))
            xb = nhwc_bytes(x)
            ob = beats16(nhwc_bytes(y))
            passes = 4 * (OC // 8) if mode_a else 1
            in_beats, out_beats = len(xb) // 16, len(ob)
            OH, OW = 2 * H, 2 * W
        base = os.path.join(args.out, "hd_op%d_" % oi)
        n_in_b = write_hex(base + "in.hex", beats16(xb))
        n_w_b = write_hex(base + "w.hex", beats16(wb))
        n_o_b = write_hex(base + "out.hex", ob)
        for tag, n in (("in", n_in_b), ("w", n_w_b), ("out", n_o_b)):
            p = base + tag + ".hex"
            man["files"][os.path.basename(p)] = {"beats": n, "sha256_16": sha(p)}
        # requant entries -- checked against the engine's own width assertions
        if not type4:
            for c in range(OC):
                mm, bb, ss = int(m0[op["rq_off"] + c]), int(bias[op["rq_off"] + c]), \
                    int(sh[op["rq_off"] + c])
                assert -(1 << 17) <= mm < (1 << 17), \
                    "twn_hd_compute.v:96 m0=%d does not fit signed 18 bits" % mm
                assert -(1 << 39) <= bb < (1 << 39), \
                    "twn_hd_compute.v:99 bias=%d does not fit signed 40 bits" % bb
                assert 0 <= ss < 64
                rq_words.append((mm & 0xFFFFFFFF) << 96 | (bb & 0xFFFFFFFFFFFFFFFF) << 32 | ss)
            for c in range(OC, 32):
                rq_words.append(0)
        else:
            rq_words += [0] * 32              # type 4 never reads the rq tables
        man["ops"].append(dict(
            op=oi, type=op["type"], ic=IC, oc=OC, oc_engine=OC_eng, h=H, w=W,
            oh=OH, ow=OW, mode_a=int(mode_a), type4=int(type4), slice=int(slice_mode),
            relu=op["relu"], lo=op["lo"], hi=op["hi"], rq_off=op["rq_off"],
            in_beats=in_beats, w_beats=n_w_b, out_beats=n_o_b, input_passes=passes))
        print("  op%d  %s  IC=%-3d OC=%-2d %2dx%-2d -> %2dx%-2d  "
              "in %5d beats x%-2d  w %5d  out %5d"
              % (oi, "modeA " if mode_a else ("type4 " if type4 else "modeB "),
                 IC, OC_eng, H, W, OH, OW, in_beats, passes, n_w_b, n_o_b))
    p = os.path.join(args.out, "hd_rq.hex")
    write_hex(p, rq_words)
    man["files"]["hd_rq.hex"] = {"beats": len(rq_words), "sha256_16": sha(p)}
    man["rq_word"] = "{m0[31:0], bias[63:0], sh[31:0]} -- 4 ops x 32 oc, op64 zero"
    with open(os.path.join(args.out, "hd_vec_manifest.json"), "w", newline="\n") as f:
        json.dump(man, f, indent=2)
    print("  rq   %d entries" % len(rq_words))
    print("\nwrote %s  (%.1f s)" % (args.out, time.time() - t0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
