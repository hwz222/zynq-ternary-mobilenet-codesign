#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PCKh of the integer network as it runs on the board, on the same ruler as score_ckpt.py.

score_ckpt.py scores the quantisation-aware training model (Brevitas, float arithmetic with
simulated quantisation). The board runs the exported integer network, whose heatmaps are not the
same numbers. This script measures the integer network itself: it writes the MPII validation set
as the board's int8 inputs, and scores the raw outputs that come back with the evaluation code of
score_ckpt.py (src/evaluate.py, same dataset order, same decoding, same PCKh).

    python -m src.score_board inputs  --meta <model_meta.c> --out <dir> [--chunk 300]
        writes <dir>/in_NN.bin (N x int8[3*256*256]); the input of image i is
        clip(round(x_i / INPUT_SCALE), -127, 127) exactly as the exporter makes its fixtures,
        and the four fixture inputs are checked against --fixtures if given.
    python -m src.score_board score   --meta <model_meta.c> --outs <dir> [--prefix out_]
        reads <dir>/<prefix>NN.bin (N x [int32 acc 14*64*64, int32 kp 14*2], the record of
        sw/app/mbv2_fuse_eval and golden/ref_batch), heatmap = acc * FINAL_OUT_MULT + FINAL_BIAS,
        and prints the PCKh.
    python -m src.score_board compare --a <dir> --pa out_ --b <dir> --pb ref_
        counts the images whose records are byte-identical in the two sets.

Run from train/mbv2_pose/ in the `twn` conda environment, with TWN_MPII_IMAGES set.
"""
import argparse
import glob
import os
import re
import sys

import numpy as np
import torch

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)
for _v in ("TWN_EXTRA_ANNOT", "TWN_EXTRA_IMAGE_DIR", "TWN_EXTRA_SPLITS"):
    os.environ.pop(_v, None)

from src.config import PCKH_GROUPS  # noqa: E402
from src.dataset import MPIIDataset  # noqa: E402
from src.evaluate import evaluate  # noqa: E402

IN_SHAPE = (3, 256, 256)
K, H, W = 14, 64, 64
REC_I32 = K * H * W + K * 2               # int32 words per output record
IN_LO = -127                              # strict-int8 export: -128 is never used


def read_meta(path):
    s = open(path, encoding="utf-8").read()
    def num(name):
        m = re.search(r"const double %s = ([^;]+);" % name, s)
        if not m:
            sys.exit("%s: no %s" % (path, name))
        return float(m.group(1))
    m = re.search(r"const double FINAL_BIAS\[14\] = \{([^}]*)\}", s)
    if not m:
        sys.exit("%s: no FINAL_BIAS" % path)
    bias = np.array([float(v) for v in m.group(1).replace("\n", " ").split(",") if v.strip()])
    assert bias.size == K, bias.size
    return num("INPUT_SCALE"), num("FINAL_OUT_MULT"), bias


def chunks(d, prefix):
    fs = sorted(glob.glob(os.path.join(d, prefix + "[0-9][0-9].bin")))
    if not fs:
        sys.exit("no %s*.bin in %s" % (prefix, d))
    return fs


def load_records(d, prefix):
    parts = [np.fromfile(f, dtype=np.int32) for f in chunks(d, prefix)]
    for f, p in zip(chunks(d, prefix), parts):
        if p.size % REC_I32:
            sys.exit("%s: %d int32 words is not a whole number of records" % (f, p.size))
    return np.concatenate(parts).reshape(-1, REC_I32)


def cmd_inputs(a):
    s0, _, _ = read_meta(a.meta)
    ds = MPIIDataset("valid", augment=False)
    os.makedirs(a.out, exist_ok=True)
    for f in glob.glob(os.path.join(a.out, "in_[0-9][0-9].bin")):
        os.remove(f)
    n = len(ds)
    xs = []
    ci = 0
    for i in range(n):
        inp = ds[i][0]
        xi = np.clip(np.round(inp.numpy() / s0), IN_LO, 127).astype(np.int8)  # as extract_mbv2.py
        assert xi.shape == IN_SHAPE, xi.shape
        xs.append(xi)
        if len(xs) == a.chunk or i == n - 1:
            np.stack(xs).tofile(os.path.join(a.out, "in_%02d.bin" % ci))
            print("in_%02d.bin  %d images (up to image %d)" % (ci, len(xs), i))
            ci += 1
            xs = []
    print("inputs: %d images in %d chunks, INPUT_SCALE %r" % (n, ci, s0))
    if a.fixtures:
        allin = np.concatenate([np.fromfile(f, dtype=np.int8) for f in chunks(a.out, "in_")])
        allin = allin.reshape(n, -1)
        bad = 0
        for k in range(4):
            idx = (k * 137) % n                                      # extract_mbv2.py's choice
            fx = np.fromfile(os.path.join(a.fixtures, "fix_%d.bin" % k), dtype=np.int8)[:allin.shape[1]]
            same = bool((fx == allin[idx]).all())
            bad += 0 if same else 1
            print("fixture %d = image %d input: %s" % (k, idx, "IDENTICAL" if same else "DIFFERENT"))
        if bad:
            sys.exit("the inputs are not made the way the exporter made its fixtures")


class Replay(torch.nn.Module):
    """Returns the recorded heatmaps in dataset order, one batch per call."""
    def __init__(self, hm):
        super().__init__()
        self.hm, self.i = hm, 0

    def forward(self, inp):
        n = inp.shape[0]
        out = torch.from_numpy(np.ascontiguousarray(self.hm[self.i:self.i + n]))
        self.i += n
        return out


def cmd_score(a):
    _, mult, bias = read_meta(a.meta)
    rec = load_records(a.outs, a.prefix)
    ds = MPIIDataset("valid", augment=False)
    if rec.shape[0] != len(ds):
        sys.exit("%d records for %d validation instances" % (rec.shape[0], len(ds)))
    acc = rec[:, :K * H * W].reshape(-1, K, H, W)
    hm = (acc.astype(np.float64) * mult + bias[None, :, None, None]).astype(np.float32)
    dl = torch.utils.data.DataLoader(ds, batch_size=32, shuffle=False, num_workers=0)
    model = Replay(hm)
    res = evaluate(model, dl, "cpu")
    assert model.i == len(ds), (model.i, len(ds))
    print("records     %s/%s*.bin, %d images" % (a.outs, a.prefix, rec.shape[0]))
    print("ruler       MPII val, %d instances, PCKh@0.5, 14 joints (src/evaluate.py)" % len(ds))
    print("mean        %.3f" % res["PCKh"])
    print("groups      " + "  ".join("%s %.2f" % (g, res["groups"][g]) for g in PCKH_GROUPS))


def cmd_compare(a):
    ra, rb = load_records(a.a, a.pa), load_records(a.b, a.pb)
    if ra.shape != rb.shape:
        sys.exit("record counts differ: %s vs %s" % (ra.shape, rb.shape))
    acc_same = (ra[:, :K * H * W] == rb[:, :K * H * W]).all(1)
    kp_same = (ra[:, K * H * W:] == rb[:, K * H * W:]).all(1)
    both = acc_same & kp_same
    print("images      %d" % ra.shape[0])
    print("acc identical      %d" % int(acc_same.sum()))
    print("keypoints identical %d" % int(kp_same.sum()))
    print("records identical  %d" % int(both.sum()))
    if not both.all():
        bad = np.nonzero(~both)[0]
        d = np.abs(ra[bad[0], :K * H * W].astype(np.int64) - rb[bad[0], :K * H * W])
        print("first differing image %d, max|diff| %d, differing elements %d"
              % (bad[0], int(d.max()), int((d > 0).sum())))
    return 0 if both.all() else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("inputs")
    p.add_argument("--meta", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--chunk", type=int, default=300)
    p.add_argument("--fixtures", default=None, help="folder of fix_0..3.bin to check against")
    p = sp.add_parser("score")
    p.add_argument("--meta", required=True)
    p.add_argument("--outs", required=True)
    p.add_argument("--prefix", default="out_")
    p = sp.add_parser("compare")
    p.add_argument("--a", required=True)
    p.add_argument("--pa", default="out_")
    p.add_argument("--b", required=True)
    p.add_argument("--pb", default="ref_")
    a = ap.parse_args()
    return {"inputs": cmd_inputs, "score": cmd_score, "compare": cmd_compare}[a.cmd](a) or 0


if __name__ == "__main__":
    sys.exit(main())
