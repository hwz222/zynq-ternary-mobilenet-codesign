"""Re-estimate the BatchNorm running statistics of a trained checkpoint (no weight changes).

During training the running mean/variance follow the most recent augmented batches with
momentum 0.1, so the statistics the evaluation uses drift from epoch to epoch. This pass resets
them and recomputes an exact average over `--batches` batches of un-augmented indoor training images,
with every weight and quantiser scale frozen.

  python -m src.recal_bn checkpoints/<exp>/best.pth [--batches 200]   -> checkpoints/<exp>/best_bn.pth
"""
import argparse
import os

import torch
from torch.utils.data import DataLoader

from src.data import CocoSeg
from src.qmodel import Mbv2Quant, materialize


@torch.no_grad()
def recalibrate(model, loader, batches, device="cuda"):
    bns = [m for m in model.modules() if isinstance(m, torch.nn.BatchNorm2d)]
    for m in bns:
        m.reset_running_stats()
        m.momentum = None                          # cumulative average over the pass
    model.train()
    for i, b in enumerate(loader):
        if i >= batches:
            break
        model(b[0].to(device, non_blocking=True))
    for m in bns:
        m.momentum = 0.1
    model.eval()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ckpt")
    ap.add_argument("--batches", type=int, default=200)
    a = ap.parse_args()
    m = Mbv2Quant()
    materialize(m)
    ck = torch.load(a.ckpt, map_location="cpu", weights_only=False)
    m.load_state_dict(ck["model"])
    m.to("cuda")
    ds = CocoSeg("train", augment=False)
    g = torch.Generator().manual_seed(0)
    dl = DataLoader(ds, batch_size=64, shuffle=True, generator=g, num_workers=8)
    recalibrate(m, dl, a.batches)
    ck["model"] = m.state_dict()
    ck["bn_recalibrated"] = {"batches": a.batches, "batch": 64, "augment": False}
    out = a.ckpt.replace(".pth", "_bn.pth")
    torch.save(ck, out)
    print("->", out)


if __name__ == "__main__":
    main()
