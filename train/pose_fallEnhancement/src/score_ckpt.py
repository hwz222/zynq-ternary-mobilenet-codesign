#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Score one checkpoint on the project's one ruler, and optionally hold it to a recorded value.

THE RULER. MPII single-person val, 2,289 instances, PCKh@0.5 over 14 joints, decoded with the
quarter-pixel offset, computed by src/evaluate.py over a DataLoader. Every host PCKh in
results/ was produced this way. (A different protocol -- 12 joints on a 393-instance subset
of MPII val with no image shared with training -- gives different numbers; the two are not
comparable.)

WHY THIS FILE EXISTS. Until 2026-09-30 there was no standalone way to ask "what does this
checkpoint score". The number came out of whichever training or analysis script happened to
load the model, so re-checking a recorded PCKh meant finding that script and its environment.
This is the one command for it.

    python -m src.score_ckpt probe_tern_dc32               (checkpoints/<name>/best.pth)
    python -m src.score_ckpt checkpoints/probe_tern_dc32/best.pth --expect 85.992
    python -m src.score_ckpt <name> --int8

Architecture: MobileNetV2 width 1.0, deconvolution head of --dc channels (default 32), the
region named by --region ternary (default pw_stem: every pointwise convolution and the stem).
--int8 builds the same network with no ternary layer. Those defaults are the deployed architecture and
everything descended from it; an experiment from another family needs its own flags.

A checkpoint that does not fit the architecture is refused, not scored: load_state_dict runs
with strict=False because Brevitas adds and drops buffers between versions, so a wrong --dc or
--region would otherwise load partially and print a plausible low number.

--expect X exits non-zero unless the mean is within --tol (default 0.005) of X. Run from
train/mbv2_pose/ in the `twn` conda environment. Takes about a minute on the GPU.
"""
import argparse
import os
import sys


import torch

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

# The ruler is MPII val and nothing else: an inherited TWN_EXTRA_* would silently add records.
for _v in ("TWN_EXTRA_ANNOT", "TWN_EXTRA_IMAGE_DIR", "TWN_EXTRA_SPLITS"):
    os.environ.pop(_v, None)

from src.config import EXP_DIR, INPUT_SIZE, PCKH_GROUPS  # noqa: E402
from src.dataset import MPIIDataset  # noqa: E402
from src.evaluate import evaluate  # noqa: E402
from src.build_model import build_quant, region_keys  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("ckpt", help="experiment directory name, or a path to a .pth")
    ap.add_argument("--dc", type=int, default=32, help="deconvolution head channels")
    ap.add_argument("--region", default="pw_stem", help="ternary region (build_model.region_keys)")
    ap.add_argument("--int8", action="store_true", help="no ternary layer")
    ap.add_argument("--expect", type=float, default=None, help="recorded mean PCKh to hold it to")
    ap.add_argument("--tol", type=float, default=0.005)
    ap.add_argument("--batch", type=int, default=32)
    a = ap.parse_args()

    ckpt = a.ckpt if a.ckpt.endswith(".pth") else os.path.join(EXP_DIR, a.ckpt, "best.pth")
    if not os.path.isfile(ckpt):
        sys.exit("no such checkpoint: %s" % ckpt)
    if os.path.getsize(ckpt) < 4096:
        sys.exit("%s is %d bytes -- a Git LFS pointer, not the weights. Run: git lfs pull --include \"%s\""
                 % (ckpt, os.path.getsize(ckpt), os.path.relpath(ckpt, REPO).replace(os.sep, "/")))

    twn, pc = (set(), set()) if a.int8 else region_keys("mbv2", 1.0, None, a.dc, a.region)
    model = build_quant("mbv2", 1.0, None, a.dc, twn, pc)
    model.eval()
    res_in = INPUT_SIZE if isinstance(INPUT_SIZE, int) else INPUT_SIZE[0]
    with torch.no_grad():
        model(torch.zeros(1, 3, res_in, res_in))      # materialise Brevitas lazy submodules first
    sd = torch.load(ckpt, map_location="cpu", weights_only=False)
    sd = sd.get("model", sd)
    want = model.state_dict()
    bad_shape = [k for k in sd if k in want and tuple(sd[k].shape) != tuple(want[k].shape)]
    weights = [k for k in want if k.endswith(".weight") or k.endswith(".bias")]
    absent = [k for k in weights if k not in sd]
    if bad_shape or absent:
        sys.exit("REFUSED: %s does not fit mbv2 dc=%d region=%s%s.\n  shape mismatches: %d (e.g. %s)\n"
                 "  weights the checkpoint lacks: %d (e.g. %s)\n  pass the right --dc / --region / --int8."
                 % (os.path.relpath(ckpt, REPO), a.dc, a.region, " int8" if a.int8 else "",
                    len(bad_shape), bad_shape[:2], len(absent), absent[:2]))
    inc = model.load_state_dict(sd, strict=False)
    print("loaded      %d tensors; model keys the checkpoint lacks: %d, checkpoint keys unused: %d"
          % (len(sd), len(inc.missing_keys), len(inc.unexpected_keys)))
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    model.to(dev)

    ds = MPIIDataset("valid", augment=False)
    dl = torch.utils.data.DataLoader(ds, batch_size=a.batch, shuffle=False, num_workers=0)
    res = evaluate(model, dl, dev)
    # evaluate() weights by labelled joint instances, not by joint; take its own figures so this
    # prints exactly what every recorded number was.
    groups = {g: float(res["groups"][g]) for g in PCKH_GROUPS}
    mean = float(res["PCKh"])
    print("checkpoint  %s" % os.path.relpath(ckpt, REPO).replace(os.sep, "/"))
    print("ruler       MPII val, %d instances, PCKh@0.5, 14 joints, input %d, %s"
          % (len(ds), res_in, dev))
    print("mean        %.3f" % mean)
    print("groups      " + "  ".join("%s %.2f" % (g, v) for g, v in groups.items()))
    if a.expect is not None:
        ok = abs(mean - a.expect) <= a.tol
        print("expected    %.3f  ->  %s (difference %+.4f, tolerance %.3f)"
              % (a.expect, "MATCH" if ok else "MISMATCH", mean - a.expect, a.tol))
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
