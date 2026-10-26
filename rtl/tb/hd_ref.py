"""hd_ref.py -- exact-integer reference math for the head engine's two operators.

  deconv_ref / deconv_ref_phase  transposed conv 4x4 stride 2 pad 1, per-output-channel
                                 requant (acc*M0 + BIAS, round-shift, relu, clamp)
  final_ref                      1x1 conv, weights [OC][IC], raw int32, no requant
Imported by rtl/tb/gen_hd_op.py (and tools/hd_ref_export.py's self-check). Python
ints are exact and int32 accumulation does not saturate, so the summation order
does not matter. Running this file as a script checks the direct loop against the
phase decomposition on a random small case; it reads and writes no files.
"""


def rshift_round(t, s):
    if s <= 0:
        return t
    half = 1 << (s - 1)
    # python ints are arbitrary precision; >> is arithmetic, as C on int64
    return (t + half) >> s


def requant1(acc, m0, bias, sh, relu, lo, hi):
    r = rshift_round(acc * m0 + bias, sh)
    if relu and r < 0:
        r = 0
    if r < lo:
        r = lo
    if r > hi:
        r = hi
    return r


def deconv_ref(x, w, H, W, IC, OC, rq, relu, lo, hi, pad=1):
    """type 2. x[iy][ix][ic] int8-domain ints; w[ic][oc][ky][kx] int8;
    rq = (m0[oc], bias[oc], sh[oc]). Returns out[oy][ox][oc], OH=2H, OW=2W."""
    OH, OW = H * 2, W * 2
    m0, bias, sh = rq
    out = [[[0] * OC for _ in range(OW)] for _ in range(OH)]
    for oy in range(OH):
        for ox in range(OW):
            for oc in range(OC):
                acc = 0
                for ky in range(4):
                    iyn = oy + pad - ky
                    if iyn < 0 or (iyn & 1):
                        continue
                    iy = iyn >> 1
                    if iy >= H:
                        continue
                    for kx in range(4):
                        ixn = ox + pad - kx
                        if ixn < 0 or (ixn & 1):
                            continue
                        ix = ixn >> 1
                        if ix >= W:
                            continue
                        for ic in range(IC):
                            acc += x[iy][ix][ic] * w[ic][oc][ky][kx]
                out[oy][ox][oc] = requant1(acc, m0[oc], bias[oc], sh[oc], relu, lo, hi)
    return out


def phase_taps(pad=1):
    """Subpixel decomposition: {(py, px): [(ky, kx, dy, dx), ...]} for each output
    phase (py, px) = (oy&1, ox&1), where iy = oyh + dy, ix = oxh + dx and
    oyh = oy>>1. Taps are those with (py + pad - ky) even; dy = (py + pad - ky)>>1."""
    ph = {}
    for py in range(2):
        for px in range(2):
            taps = []
            for ky in range(4):
                if ((py + pad - ky) & 1) != 0:
                    continue
                dy = (py + pad - ky) >> 1
                for kx in range(4):
                    if ((px + pad - kx) & 1) != 0:
                        continue
                    dx = (px + pad - kx) >> 1
                    taps.append((ky, kx, dy, dx))
            ph[(py, px)] = taps
    return ph


def deconv_ref_phase(x, w, H, W, IC, OC, rq, relu, lo, hi, pad=1):
    """Same result as deconv_ref, summed in phase/tap order; out-of-range taps contribute 0."""
    OH, OW = H * 2, W * 2
    m0, bias, sh = rq
    out = [[[0] * OC for _ in range(OW)] for _ in range(OH)]
    ph = phase_taps(pad)
    for py in range(2):
        for px in range(2):
            for oyh in range(H):
                for oxh in range(W):
                    oy, ox = oyh * 2 + py, oxh * 2 + px
                    for oc in range(OC):
                        acc = 0
                        for (ky, kx, dy, dx) in ph[(py, px)]:
                            iy, ix = oyh + dy, oxh + dx
                            if 0 <= iy < H and 0 <= ix < W:
                                for ic in range(IC):
                                    acc += x[iy][ix][ic] * w[ic][oc][ky][kx]
                        out[oy][ox][oc] = requant1(acc, m0[oc], bias[oc], sh[oc],
                                                   relu, lo, hi)
    return out


def final_ref(x, w, H, W, IC, OC):
    """w[oc][ic]. Raw int32 out, no requant."""
    return [[[sum(x[oy][ox][ic] * w[oc][ic] for ic in range(IC)) for oc in range(OC)]
             for ox in range(W)] for oy in range(H)]


if __name__ == "__main__":
    # self-check: direct valid-tap loop == phase decomposition, random small case
    import random
    random.seed(9)
    H = W = 5
    IC, OC = 6, 4
    x = [[[random.randint(-127, 127) for _ in range(IC)] for _ in range(W)] for _ in range(H)]
    w = [[[[random.randint(-128, 127) for _ in range(4)] for _ in range(4)]
          for _ in range(OC)] for _ in range(IC)]
    rq = ([random.randint(1 << 16, (1 << 17) - 1) for _ in range(OC)],
          [random.randint(-(1 << 39) + 1, (1 << 39) - 1) for _ in range(OC)],
          [random.randint(18, 24) for _ in range(OC)])
    a = deconv_ref(x, w, H, W, IC, OC, rq, 1, 0, 127)
    b = deconv_ref_phase(x, w, H, W, IC, OC, rq, 1, 0, 127)
    assert a == b, "phase decomposition mismatch"
    print("hd_ref self-check: direct == phase decomposition (%dx%d, IC=%d OC=%d)"
          % (2 * H, 2 * W, IC, OC))
