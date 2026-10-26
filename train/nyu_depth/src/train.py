"""Train the depth model on the NYU Depth V2 training frames (FastDepth split, 47,584 frames).

  python -m src.train configs/<run>.json

Loss on valid pixels at the 256 input resolution (log-depth upsampled bilinearly):
scale-invariant log loss (lambda 0.85, x10, as in BTS/AdaBins) plus w_l1 * |log pred - log gt|;
channels 1..15 are pushed to zero. Resumes from last.pth; best.pth by val delta1.
"""
import json
import math
import os
import sys
import time

import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from src import config as C
from src.data import NYU
from src.evaluate import evaluate
from src.qmodel import Mbv2Quant, materialize, rebase, relay_backbone


def depth_loss(out, gt, w_l1=0.1, w_zero=0.01):
    lo = F.interpolate(out[:, C.CH_DEPTH:C.CH_DEPTH + 1].float(), size=gt.shape[-2:],
                       mode="bilinear", align_corners=False)[:, 0]
    v = (gt > C.MIN_DEPTH) & (gt <= C.MAX_DEPTH)
    d = (lo - torch.log(gt.clamp(min=C.MIN_DEPTH)))[v]
    silog = torch.sqrt((d ** 2).mean() - 0.85 * d.mean() ** 2 + 1e-8) * 10
    rest = out[:, C.CH_DEPTH + 1:].float()
    return silog + w_l1 * d.abs().mean() + w_zero * (rest ** 2).mean(), silog.item()


def main():
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
    exp = cfg["exp_id"]
    out = os.path.join(C.EXP_DIR, exp)
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "log.txt"), "a", encoding="utf-8")

    def log(s):
        print(s, flush=True)
        logf.write(s + "\n"); logf.flush()

    torch.manual_seed(cfg.get("seed", 42)); np.random.seed(cfg.get("seed", 42))
    torch.backends.cudnn.benchmark = True
    dev = "cuda"
    model = Mbv2Quant(ternary=cfg.get("ternary", True))
    init = cfg.get("init", "pose")
    if init == "pose":
        n, tot = relay_backbone(model, C.POSE_CKPT)
        log(f"[init] pose backbone: {n}/{tot} tensors from {os.path.normpath(C.POSE_CKPT)}")
        with torch.no_grad():
            model.final_layer.bias[C.CH_DEPTH] = math.log(2.5)   # start near the typical depth of the NYU scenes
    elif init == "rebase":                                    # new backbone under an already trained head
        nb, nh = rebase(model, os.path.join(C.ROOT, cfg["backbone_ckpt"]), os.path.join(C.ROOT, cfg["head_ckpt"]),
                        cfg.get("head_rows"))
        log(f"[init] backbone {nb} tensors from {cfg['backbone_ckpt']}, head {nh} tensors from {cfg['head_ckpt']}")
    elif init.endswith(".pth"):                                    # continue from an earlier run
        model.load_state_dict(torch.load(os.path.join(C.ROOT, init), map_location="cpu", weights_only=False)["model"])
        log(f"[init] all tensors from {init}")
    materialize(model)
    model.to(dev)

    head = [p for n, p in model.named_parameters() if n.startswith(("deconv_layers", "final_layer"))]
    body = [p for n, p in model.named_parameters() if not n.startswith(("deconv_layers", "final_layer"))]
    lr = cfg["lr"]
    opt = torch.optim.Adam([{"params": body, "lr": lr * cfg.get("backbone_lr_mult", 0.3)},
                            {"params": head, "lr": lr}])
    base_lrs = [g["lr"] for g in opt.param_groups]

    ds = NYU("train", augment=True)
    if cfg.get("pseudo_coco"):
        from torch.utils.data import ConcatDataset
        from src.data import PseudoCoco
        pc = PseudoCoco()
        log(f"[data] + {len(pc)} indoor COCO images with teacher depth")
        ds = ConcatDataset([ds, pc])
    dl = DataLoader(ds, batch_size=cfg["batch"], shuffle=True, num_workers=cfg["workers"],
                    pin_memory=True, drop_last=True, persistent_workers=False)
    epochs = cfg["epochs"]
    total = epochs * len(dl)
    warm = cfg.get("warmup_iters", 500)
    log(f"[data] {len(ds)} train frames, {len(dl)} iters/epoch, {epochs} epochs")

    start, best, it = 0, -1.0, 0
    last = os.path.join(out, "last.pth")
    if os.path.isfile(last):
        ck = torch.load(last, map_location="cpu", weights_only=False)
        model.load_state_dict(ck["model"]); model.to(dev)
        opt.load_state_dict(ck["opt"])
        start, best = ck["epoch"] + 1, ck["best"]
        it = start * len(dl)
        log(f"[resume] epoch {start}, best d1 {best:.4f}")

    for ep in range(start, epochs):
        model.train()
        t0, run, rs = time.time(), 0.0, 0.0
        for x, gt, _ in dl:
            f = it / warm if it < warm else 0.5 * (1 + math.cos(math.pi * (it - warm) / max(1, total - warm)))
            for g, b in zip(opt.param_groups, base_lrs):
                g["lr"] = b * max(f, 0.01)
            x, gt = x.to(dev, non_blocking=True), gt.to(dev, non_blocking=True)
            loss, sl = depth_loss(model(x), gt, cfg.get("w_l1", 0.1))
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 10.0)
            opt.step()
            run += loss.item(); rs += sl; it += 1
        n = len(dl)
        msg = f"epoch {ep:3d} | loss {run / n:.4f} silog {rs / n:.3f} | lr {opt.param_groups[1]['lr']:.2e} | {time.time() - t0:.0f}s"
        rec = {"epoch": ep, "loss": run / n, "silog": rs / n}
        if (ep + 1) % cfg.get("eval_every", 1) == 0 or ep >= epochs - 3:
            res = evaluate(model, dev)
            rec.update(res)
            if res["d1"] > best:
                best = float(res["d1"])
                torch.save({"model": model.state_dict(), "epoch": ep, "d1": best, "cfg": cfg},
                           os.path.join(out, "best.pth"))
            msg += f" | d1 {res['d1']:.4f} absrel {res['abs_rel']:.4f} rmse {res['rmse']:.3f} | best d1 {best:.4f}"
        log(msg)
        with open(os.path.join(out, "metrics.jsonl"), "a") as fh:
            fh.write(json.dumps(rec) + "\n")
        torch.save({"model": model.state_dict(), "opt": opt.state_dict(), "epoch": ep, "best": best}, last)
    tern = model.verify_all_ternary() if cfg.get("ternary", True) else []
    log(f"[done] best d1 {best:.4f}; ternary check {sum(r['ok'] for r in tern)}/{len(tern)}")


if __name__ == "__main__":
    main()
