"""Synthetic test fixtures: four images with no people in them, and their exact expected outputs.

    python3 tools/make_synthetic_fixtures.py            # writes models/mbv2_pose/fixtures_synthetic/

The MPII fixtures (models/mbv2_pose/fixtures/, regenerated from your own MPII copy) cannot be
published. These four are drawn from formulas (gradients, a checkerboard with discs, stripes,
smoothed noise), so they can be. Their expected outputs come from the integer reference of
tools/hd_ref_export.py (forward(): all 65 operators, the way the C model and the accelerator
compute them), and they use the same file layout as the MPII fixtures:
    int8 input [3*256*256] | int32 final accumulators [14*64*64] | int32 keypoints [14*2]
    | int64 per-operator checksums [65]
so the board apps read them as golden/fix_<k>.bin.

If an MPII fixture is present, the script first recomputes it from its input and requires the
same accumulators, keypoints and checksums: the reference that makes the synthetic goldens is
then the one the board is checked against.
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hd_ref_export as ref  # noqa: E402

OUT = os.path.join(ref.MODEL, "fixtures_synthetic")
LO, HI = -127, 127


def images():
    """Four int8 CHW images, 3 x 256 x 256, built from formulas only."""
    y, x = np.mgrid[0:256, 0:256].astype(np.float64) / 255.0
    rng = np.random.default_rng(20261027)
    out = []
    # 0: smooth colour gradients
    out.append(np.stack([x, y, 1.0 - (x + y) / 2]))
    # 1: checkerboard with three discs
    cb = ((np.floor(x * 8) + np.floor(y * 8)) % 2) * 0.6 + 0.2
    disc = np.zeros_like(x)
    for cx, cy, r in ((0.3, 0.3, 0.15), (0.7, 0.4, 0.2), (0.5, 0.75, 0.12)):
        disc = np.maximum(disc, ((x - cx) ** 2 + (y - cy) ** 2 < r * r).astype(np.float64))
    out.append(np.stack([cb, np.clip(cb + disc * 0.5, 0, 1), disc]))
    # 2: stripes at three angles and frequencies
    out.append(np.stack([0.5 + 0.5 * np.sin(2 * np.pi * (6 * x + 2 * y)),
                         0.5 + 0.5 * np.sin(2 * np.pi * (3 * x - 5 * y)),
                         0.5 + 0.5 * np.sin(2 * np.pi * 9 * y)]))
    # 3: smoothed noise (box blur, 9 x 9)
    n = rng.random((3, 256 + 8, 256 + 8))
    c = np.cumsum(np.cumsum(n, axis=1), axis=2)
    c = np.pad(c, ((0, 0), (1, 0), (1, 0)))
    blur = (c[:, 9:, 9:] - c[:, :-9, 9:] - c[:, 9:, :-9] + c[:, :-9, :-9]) / 81.0
    blur = (blur - blur.min()) / (blur.max() - blur.min())
    out.append(blur)
    return [np.clip(np.round(im * (HI - LO) + LO), LO, HI).astype(np.int8) for im in out]


def golden(ops, blob, m0, bias, sh, x_in):
    acc, kp, ck = ref.forward(ops, blob, m0, bias, sh, x_in, {})
    return acc.astype(np.int32), np.asarray(kp, dtype=np.int32), np.asarray(ck, dtype=np.int64)


def main():
    ops, m0, bias, sh = ref.parse_meta()
    blob = np.fromfile(ref.BLOB_F, dtype=np.int8)
    assert blob.size == ref.BLOB_BYTES, "model_mbv2.bin is %d bytes, expected %d" % (blob.size, ref.BLOB_BYTES)
    n_in = ref.NET_IN_C * ref.NET_IN_H * ref.NET_IN_W
    n_acc = ref.NET_OUT_C * ref.NET_OUT_H * ref.NET_OUT_W

    mpii = ref.FIX_F % 0
    if os.path.exists(mpii):
        fx = open(mpii, "rb").read()
        x_in = np.frombuffer(fx, np.int8, n_in).reshape(ref.NET_IN_C, ref.NET_IN_H, ref.NET_IN_W)
        acc, kp, ck = golden(ops, blob, m0, bias, sh, x_in)
        same = fx[n_in:] == acc.tobytes() + kp.tobytes() + ck.tobytes()
        print("reference reproduces the MPII fixture 0 byte for byte: %s" % ("PASS" if same else "FAIL"))
        if not same:
            sys.exit(1)
    else:
        print("no MPII fixture present: reference self-check skipped")

    os.makedirs(OUT, exist_ok=True)
    for k, im in enumerate(images()):
        acc, kp, ck = golden(ops, blob, m0, bias, sh, im)
        path = os.path.join(OUT, "fix_%d.bin" % k)
        with open(path, "wb") as f:
            f.write(im.tobytes() + acc.tobytes() + kp.tobytes() + ck.tobytes())
        assert os.path.getsize(path) == n_in + 4 * n_acc + 4 * ref.NET_OUT_C * 2 + 8 * ref.N_OPS
        print("synthetic fixture %d: acc sum %d, keypoints %s" % (k, int(acc.sum()), kp[:6].tolist()))
    print("written to %s" % OUT)


if __name__ == "__main__":
    main()
