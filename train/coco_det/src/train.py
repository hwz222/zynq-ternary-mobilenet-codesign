"""Train the 12-class detector on COCO train2017.

  python -m src.train configs/<run>.json

Resumes from checkpoints/<exp_id>/last.pth when it exists; writes best.pth (by val AP),
metrics.jsonl and log.txt in the same folder.
"""
import json
import math
import os
import sys
import time

import numpy as np
import torch
from torch.utils.data import DataLoader

from src import config as C
from src.centernet import loss_fn
from src.data import CocoDet
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
        sd = torch.load(os.path.join(C.ROOT, init), map_location="cpu", weights_only=False)["model"]
        model.load_state_dict(sd)
        log(f"[init] all tensors from {init}")
    elif init == "imagenet":
        from torchvision.models import MobileNet_V2_Weights, mobilenet_v2
        ref = mobilenet_v2(weights=MobileNet_V2_Weights.IMAGENET1K_V1).features[:18].state_dict()
        own = model.state_dict()
        take = {"features." + k: v for k, v in ref.items()
                if "features." + k in own and own["features." + k].shape == v.shape}
        model.load_state_dict(take, strict=False)
        log(f"[init] ImageNet MobileNetV2: {len(take)} tensors")
    if init in ("pose", "imagenet", "none"):
        with torch.no_grad():                               # heatmap prior p = 0.1
            model.final_layer.bias[:C.NUM_CLASSES].fill_(-2.19)
    elif init == "rebase":                                  # only the rows of classes that changed
        with torch.no_grad():
            for i, j in enumerate(cfg.get("head_rows") or []):
                if j < 0 and i < C.NUM_CLASSES:
                    model.final_layer.bias[i] = -2.19
    materialize(model)
    model.to(dev)

    head = [p for n, p in model.named_parameters() if n.startswith(("deconv_layers", "final_layer"))]
    body = [p for n, p in model.named_parameters() if not n.startswith(("deconv_layers", "final_layer"))]
    lr = cfg["lr"]
    opt = torch.optim.Adam([{"params": body, "lr": lr * cfg.get("backbone_lr_mult", 0.3)},
                            {"params": head, "lr": lr}])
    base_lrs = [g["lr"] for g in opt.param_groups]

    train_ds = CocoDet(cfg.get("train_split", "train"), augment=True)
    if cfg.get("max_train"):                                # fixed random subset, for short comparisons
        keep = np.random.RandomState(0).permutation(len(train_ds.recs))[:cfg["max_train"]]
        train_ds.recs = [train_ds.recs[i] for i in sorted(keep)]
    sampler = None
    if cfg.get("nonperson_weight") or cfg.get("lying_weight"):   # oversample furniture / lying people
        w = np.ones(len(train_ds.recs))
        if cfg.get("nonperson_weight"):
            m = np.array([(r[5] != 0).any() for r in train_ds.recs])
            w[m] = np.maximum(w[m], cfg["nonperson_weight"])
            log(f"[data] {int(m.sum())} images with a non-person class sampled x{cfg['nonperson_weight']}")
        if cfg.get("lying_weight"):
            from src.lying import lying_image_ids
            ly = lying_image_ids(C.DATA)
            m = np.array([r[0] in ly for r in train_ds.recs])
            w[m] = np.maximum(w[m], cfg["lying_weight"])
            log(f"[data] {int(m.sum())} images with a person lying down sampled x{cfg['lying_weight']}")
        sampler = torch.utils.data.WeightedRandomSampler(torch.as_tensor(w, dtype=torch.double),
                                                         num_samples=len(w), replacement=True)
    dl = DataLoader(train_ds, batch_size=cfg["batch"], shuffle=sampler is None, sampler=sampler,
                    num_workers=cfg["workers"], pin_memory=True, drop_last=True, persistent_workers=False)
    epochs = cfg["epochs"]
    total = epochs * len(dl)
    warm = cfg.get("warmup_iters", 1000)
    log(f"[data] {len(train_ds)} train images, {len(dl)} iters/epoch, {epochs} epochs")

    start, best, it = 0, -1.0, 0
    last = os.path.join(out, "last.pth")
    if os.path.isfile(last):
        ck = torch.load(last, map_location="cpu", weights_only=False)
        model.load_state_dict(ck["model"]); model.to(dev)
        opt.load_state_dict(ck["opt"])
        start, best = ck["epoch"] + 1, ck["best"]
        it = start * len(dl)
        log(f"[resume] epoch {start}, best AP {best:.2f}")

    for ep in range(start, epochs):
        model.train()
        t0, run, parts = time.time(), 0.0, np.zeros(3)
        for x, hm, wh, off, ind, msk, _ in dl:
            f = it / warm if it < warm else 0.5 * (1 + math.cos(math.pi * (it - warm) / max(1, total - warm)))
            for g, b in zip(opt.param_groups, base_lrs):
                g["lr"] = b * max(f, 0.01)
            x, hm, wh, off = (t.to(dev, non_blocking=True) for t in (x, hm, wh, off))
            ind, msk = ind.to(dev, non_blocking=True), msk.to(dev, non_blocking=True)
            loss, p = loss_fn(model(x), hm, wh, off, ind, msk, cfg.get("w_wh", 1.0), cfg.get("w_off", 1.0))
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 10.0)
            opt.step()
            run += loss.item(); parts += p; it += 1
        n = len(dl)
        msg = (f"epoch {ep:3d} | loss {run / n:.4f} (hm {parts[0] / n:.4f} wh {parts[1] / n:.4f} "
               f"off {parts[2] / n:.4f}) | lr {opt.param_groups[1]['lr']:.2e} | {time.time() - t0:.0f}s")
        rec = {"epoch": ep, "loss": run / n, "hm": parts[0] / n, "wh": parts[1] / n, "off": parts[2] / n}
        if (ep + 1) % cfg.get("eval_every", 2) == 0 or ep >= epochs - 3:
            res = evaluate(model, dev)
            rec.update({"AP": res["AP"], "AP50": res["AP50"], "per_class": res["per_class"]})
            if res["AP"] > best:
                best = float(res["AP"])
                torch.save({"model": model.state_dict(), "epoch": ep, "AP": best, "cfg": cfg},
                           os.path.join(out, "best.pth"))
            msg += f" | AP {res['AP']:.2f} AP50 {res['AP50']:.2f} | best {best:.2f}"
        log(msg)
        with open(os.path.join(out, "metrics.jsonl"), "a") as fh:
            fh.write(json.dumps(rec) + "\n")
        torch.save({"model": model.state_dict(), "opt": opt.state_dict(), "epoch": ep, "best": best}, last)
    tern = model.verify_all_ternary() if cfg.get("ternary", True) else []
    log(f"[done] best AP {best:.2f}; ternary check {sum(r['ok'] for r in tern)}/{len(tern)}")


if __name__ == "__main__":
    main()
