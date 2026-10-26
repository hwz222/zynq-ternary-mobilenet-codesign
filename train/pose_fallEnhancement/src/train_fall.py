"""Fine-tune the deployed pose model (probe_tern_dc32) so it also handles people lying down.

  python -m src.train_fall configs/<run>.json

Starts from every tensor of artifacts/mbv2_pose/probe_tern_dc32_best.pth (nothing is trained from
scratch) and fine-tunes the whole network on MPII + Penn Action sports (the data probe_tern_dc32 was
trained on) + the COCO lying people of src/build_coco_lying.py, oversampled `lying_weight` times,
with an optional +-90 degree rotation of the crop (ROT90_AUG) so upright people are also seen lying.

Two rulers every epoch, both on held-out data:
  MPII val 2,289 people, PCKh@0.5, 14 joints  (the project ruler; must not fall much)
  COCO-lying val 108 people, a joint is correct within 0.1 x the longer side of the person box,
  12 joints (no head top / neck in COCO)
Writes checkpoints/<exp_id>/{best,last}.pth (best = highest MPII + lying sum), log.txt, metrics.jsonl.
"""
import json
import os
import sys
import time

import numpy as np
import torch
from torch.utils.data import DataLoader

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = json.load(open(sys.argv[1], encoding="utf-8"))
DATA = os.path.join(ROOT, "data")
SOURCES = {"sports": (os.path.join(DATA, "sports", "annot"),
                      os.environ.get("TWN_SPORTS_IMAGES", os.path.join(DATA, "sports", "images"))),
           "coco_lying": (os.path.join(DATA, "coco_lying", "annot"), os.path.join(DATA, "coco"))}
os.environ.setdefault("TWN_MPII_IMAGES", os.path.join(DATA, "mpii", "images"))
os.environ["TWN_EXTRA_ANNOT"] = ",".join(SOURCES[k][0] for k in ("sports", "coco_lying"))
os.environ["TWN_EXTRA_IMAGE_DIR"] = ",".join(SOURCES[k][1] for k in ("sports", "coco_lying"))
os.environ["TWN_EXTRA_SPLITS"] = "train"
os.environ["ROT90_AUG"] = str(CFG.get("rot90_aug", 0.0))
os.environ["COLOR_AUG"] = str(CFG.get("color_aug", 0.0))

from src.build_model import build_quant, region_keys, set_seed  # noqa: E402
from src.config import EXP_DIR, INPUT_SIZE  # noqa: E402
from src.dataset import MPIIDataset  # noqa: E402
from src.evaluate import evaluate  # noqa: E402
from src.train import JointsMSELoss  # noqa: E402

PROBE = os.path.join(ROOT, "..", "..", "artifacts", "mbv2_pose", "probe_tern_dc32_best.pth")


def lying_val_loader(batch, workers):
    keep = {k: os.environ[k] for k in ("TWN_EXTRA_ANNOT", "TWN_EXTRA_IMAGE_DIR")}
    os.environ["TWN_EXTRA_ANNOT"], os.environ["TWN_EXTRA_IMAGE_DIR"] = SOURCES["coco_lying"]
    ds = MPIIDataset("valid", augment=False, source="extra_only")
    os.environ.update(keep)
    return DataLoader(ds, batch_size=batch, shuffle=False, num_workers=workers)


def main():
    exp = CFG["exp_id"]
    out = os.path.join(EXP_DIR, exp)
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "log.txt"), "a", encoding="utf-8")

    def log(s):
        print(s, flush=True); logf.write(s + "\n"); logf.flush()

    set_seed(CFG.get("seed", 42))
    torch.backends.cudnn.benchmark = True
    dev = "cuda"
    twn, pc = region_keys("mbv2", 1.0, None, 32, "pw_stem")
    model = build_quant("mbv2", 1.0, None, 32, twn, pc)
    sd = torch.load(PROBE, map_location="cpu", weights_only=False)
    model.load_state_dict(sd.get("model", sd))
    log(f"[init] all tensors from {os.path.normpath(PROBE)}")
    model.eval()
    with torch.no_grad():
        model(torch.zeros(1, 3, INPUT_SIZE[1], INPUT_SIZE[0]))
    model.to(dev)

    train_ds = MPIIDataset("train")
    w = np.ones(len(train_ds))
    for d, lo, hi in train_ds.bounds:
        if os.path.normpath(d) == os.path.normpath(SOURCES["coco_lying"][0]):
            w[lo:hi] = CFG.get("lying_weight", 4.0)
            log(f"[data] {hi - lo} COCO lying people sampled x{CFG.get('lying_weight', 4.0)}")
    sampler = torch.utils.data.WeightedRandomSampler(torch.as_tensor(w), num_samples=len(w), replacement=True)
    dl = DataLoader(train_ds, batch_size=CFG["batch"], sampler=sampler, num_workers=CFG["workers"],
                    pin_memory=True, drop_last=True)
    mpii_val = DataLoader(MPIIDataset("valid"), batch_size=64, shuffle=False, num_workers=CFG["workers"])
    lying_val = lying_val_loader(64, CFG["workers"])
    log(f"[data] {len(train_ds)} train records, {len(dl)} iters/epoch, rot90_aug {CFG.get('rot90_aug', 0)}")

    head = [p for n, p in model.named_parameters() if n.startswith(("deconv_layers", "final_layer"))]
    body = [p for n, p in model.named_parameters() if not n.startswith(("deconv_layers", "final_layer"))]
    opt = torch.optim.Adam([{"params": body, "lr": CFG["lr"] * CFG.get("backbone_lr_mult", 0.5)},
                            {"params": head, "lr": CFG["lr"]}])
    base = [g["lr"] for g in opt.param_groups]
    crit = JointsMSELoss().to(dev)
    E, best, it = CFG["epochs"], -1.0, 0
    total = E * len(dl)
    r0 = evaluate(model, mpii_val, dev)["PCKh"]; l0 = evaluate(model, lying_val, dev)["PCKh"]
    log(f"[start] probe_tern_dc32: MPII PCKh {r0:.3f} | COCO-lying PCK {l0:.3f}")
    for ep in range(E):
        model.train()
        if CFG.get("freeze_bn"):                       # keep the starting model's BatchNorm statistics
            for mod in model.modules():
                if isinstance(mod, torch.nn.BatchNorm2d):
                    mod.eval()
        t0, run = time.time(), 0.0
        for x, t, tw, _ in dl:
            f = 0.5 * (1 + np.cos(np.pi * it / total))
            for g, b in zip(opt.param_groups, base):
                g["lr"] = b * max(f, 0.01)
            x, t, tw = x.to(dev, non_blocking=True), t.to(dev, non_blocking=True), tw.to(dev, non_blocking=True)
            loss = crit(model(x), t, tw)
            opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
            run += loss.item(); it += 1
        rm = evaluate(model, mpii_val, dev); rl = evaluate(model, lying_val, dev)
        score = rm["PCKh"] + rl["PCKh"]
        if score > best:
            best = score
            torch.save({"model": model.state_dict(), "epoch": ep, "mpii": rm["PCKh"], "lying": rl["PCKh"], "cfg": CFG},
                       os.path.join(out, "best.pth"))
        log(f"epoch {ep:2d} | loss {run / len(dl):.6f} | {time.time() - t0:.0f}s | MPII PCKh {rm['PCKh']:.3f} "
            f"| COCO-lying PCK {rl['PCKh']:.3f}")
        with open(os.path.join(out, "metrics.jsonl"), "a") as fh:
            fh.write(json.dumps({"epoch": ep, "loss": run / len(dl), "mpii": rm["PCKh"], "lying": rl["PCKh"],
                                 "mpii_groups": rm["groups"], "lying_groups": rl["groups"]}) + "\n")
        torch.save({"model": model.state_dict(), "epoch": ep, "cfg": CFG}, os.path.join(out, "last.pth"))
    tern = model.verify_all_ternary()
    log(f"[done] ternary check {sum(r['ok'] for r in tern)}/{len(tern)}")


if __name__ == "__main__":
    main()
