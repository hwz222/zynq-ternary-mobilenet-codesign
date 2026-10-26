"""Train the 16-class indoor segmenter on the indoor subset of COCO-Stuff train2017.

  python -m src.train configs/<run>.json

Loss: cross entropy on the logits upsampled (bilinear) from 64x64 to the 256 input, unlabelled
pixels ignored. Resumes from checkpoints/<exp_id>/last.pth; best.pth by val mIoU.
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
from src.data import CocoSeg
from src.evaluate import evaluate
from src.qmodel import Mbv2Quant, materialize, rebase, relay_backbone


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
    elif init == "rebase":                                    # new backbone under an already trained head
        nb, nh = rebase(model, os.path.join(C.ROOT, cfg["backbone_ckpt"]), os.path.join(C.ROOT, cfg["head_ckpt"]),
                        cfg.get("head_rows"))
        log(f"[init] backbone {nb} tensors from {cfg['backbone_ckpt']}, head {nh} tensors from {cfg['head_ckpt']}")
    elif init.endswith(".pth"):                               # continue from an earlier run of this task
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

    ds = CocoSeg("train", augment=True)
    sampler = None
    if cfg.get("lying_weight"):                              # oversample images with a person lying down
        from src.lying import lying_image_ids
        ly = lying_image_ids(C.COCO)
        w = np.array([cfg["lying_weight"] if int(n) in ly else 1.0 for n in ds.names])
        sampler = torch.utils.data.WeightedRandomSampler(torch.as_tensor(w, dtype=torch.double),
                                                         num_samples=len(w), replacement=True)
        log(f"[data] {int((w > 1).sum())} indoor images with a person lying down sampled x{cfg['lying_weight']}")
    dl = DataLoader(ds, batch_size=cfg["batch"], shuffle=sampler is None, sampler=sampler,
                    num_workers=cfg["workers"], pin_memory=True, drop_last=True, persistent_workers=False)
    epochs = cfg["epochs"]
    total = epochs * len(dl)
    warm = cfg.get("warmup_iters", 500)
    log(f"[data] {len(ds)} indoor train images, {len(dl)} iters/epoch, {epochs} epochs")

    start, best, it = 0, -1.0, 0
    last = os.path.join(out, "last.pth")
    if os.path.isfile(last):
        ck = torch.load(last, map_location="cpu", weights_only=False)
        model.load_state_dict(ck["model"]); model.to(dev)
        opt.load_state_dict(ck["opt"])
        start, best = ck["epoch"] + 1, ck["best"]
        it = start * len(dl)
        log(f"[resume] epoch {start}, best mIoU {best:.2f}")

    for ep in range(start, epochs):
        model.train()
        t0, run = time.time(), 0.0
        for x, y, _ in dl:
            f = it / warm if it < warm else 0.5 * (1 + math.cos(math.pi * (it - warm) / max(1, total - warm)))
            for g, b in zip(opt.param_groups, base_lrs):
                g["lr"] = b * max(f, 0.01)
            x, y = x.to(dev, non_blocking=True), y.to(dev, non_blocking=True)
            lo = F.interpolate(model(x).float(), size=y.shape[-2:], mode="bilinear", align_corners=False)
            loss = F.cross_entropy(lo, y, ignore_index=C.IGNORE)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 10.0)
            opt.step()
            run += loss.item(); it += 1
        msg = f"epoch {ep:3d} | loss {run / len(dl):.4f} | lr {opt.param_groups[1]['lr']:.2e} | {time.time() - t0:.0f}s"
        rec = {"epoch": ep, "loss": run / len(dl)}
        if (ep + 1) % cfg.get("eval_every", 2) == 0 or ep >= epochs - 3:
            res = evaluate(model, dev)
            rec.update({"mIoU": res["mIoU"], "pixel_acc": res["pixel_acc"], "per_class": res["per_class"]})
            if res["mIoU"] > best:
                best = float(res["mIoU"])
                torch.save({"model": model.state_dict(), "epoch": ep, "mIoU": best, "cfg": cfg},
                           os.path.join(out, "best.pth"))
            msg += f" | mIoU {res['mIoU']:.2f} pixacc {res['pixel_acc']:.1f} | best {best:.2f}"
        log(msg)
        with open(os.path.join(out, "metrics.jsonl"), "a") as fh:
            fh.write(json.dumps(rec) + "\n")
        torch.save({"model": model.state_dict(), "opt": opt.state_dict(), "epoch": ep, "best": best}, last)
    tern = model.verify_all_ternary() if cfg.get("ternary", True) else []
    log(f"[done] best mIoU {best:.2f}; ternary check {sum(r['ok'] for r in tern)}/{len(tern)}")


if __name__ == "__main__":
    main()
