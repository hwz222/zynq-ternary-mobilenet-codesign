"""Re-estimate BatchNorm running statistics of a pose checkpoint (weights unchanged), then score it
on both rulers (MPII val PCKh@0.5 and COCO-lying val).

  python -m src.recal_bn checkpoints/<exp>/best.pth [--batches 200] [--with-lying]
  -> checkpoints/<exp>/best_bn.pth

Statistics come from un-augmented training crops of MPII + Penn Action sports (+ the COCO lying
people with --with-lying), so they describe the images the model will see, not the augmented ones.
"""
import argparse
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
os.environ.setdefault("TWN_MPII_IMAGES", os.path.join(DATA, "mpii", "images"))
SPORTS_IMAGES = os.environ.get("TWN_SPORTS_IMAGES", os.path.join(DATA, "sports", "images"))

import torch  # noqa: E402
from torch.utils.data import DataLoader  # noqa: E402

from src.build_model import build_quant, region_keys  # noqa: E402
from src.config import INPUT_SIZE  # noqa: E402
from src.dataset import MPIIDataset  # noqa: E402
from src.evaluate import evaluate  # noqa: E402


def dataset_with(sources):
    os.environ["TWN_EXTRA_ANNOT"] = ",".join(s[0] for s in sources)
    os.environ["TWN_EXTRA_IMAGE_DIR"] = ",".join(s[1] for s in sources)
    os.environ["TWN_EXTRA_SPLITS"] = "train"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ckpt")
    ap.add_argument("--batches", type=int, default=200)
    ap.add_argument("--with-lying", action="store_true")
    a = ap.parse_args()
    twn, pc = region_keys("mbv2", 1.0, None, 32, "pw_stem")
    m = build_quant("mbv2", 1.0, None, 32, twn, pc)
    ck = torch.load(a.ckpt, map_location="cpu", weights_only=False)
    m.load_state_dict(ck.get("model", ck))
    m.eval()
    with torch.no_grad():
        m(torch.zeros(1, 3, INPUT_SIZE[1], INPUT_SIZE[0]))
    m.to("cuda")
    src = [(os.path.join(DATA, "sports", "annot"), SPORTS_IMAGES)]
    if a.with_lying:
        src.append((os.path.join(DATA, "coco_lying", "annot"), os.path.join(DATA, "coco")))
    dataset_with(src)
    ds = MPIIDataset("train", augment=False)
    g = torch.Generator().manual_seed(0)
    dl = DataLoader(ds, batch_size=64, shuffle=True, generator=g, num_workers=8)
    bns = [x for x in m.modules() if isinstance(x, torch.nn.BatchNorm2d)]
    with torch.no_grad():
        for b in bns:
            b.reset_running_stats(); b.momentum = None
        m.train()
        for i, (x, *_) in enumerate(dl):
            if i >= a.batches:
                break
            m(x.to("cuda"))
        for b in bns:
            b.momentum = 0.1
    m.eval()
    out = a.ckpt.replace(".pth", "_bn.pth")
    ck["model"] = m.state_dict()
    ck["bn_recalibrated"] = {"batches": a.batches, "batch": 64, "augment": False, "with_lying": a.with_lying}
    torch.save(ck, out)
    mpii = evaluate(m, DataLoader(MPIIDataset("valid"), batch_size=64, num_workers=8), "cuda")["PCKh"]
    dataset_with([(os.path.join(DATA, "coco_lying", "annot"), os.path.join(DATA, "coco"))])
    lying = evaluate(m, DataLoader(MPIIDataset("valid", augment=False, source="extra_only"), batch_size=64,
                                   num_workers=8), "cuda")["PCKh"]
    print(f"-> {out} | MPII PCKh {mpii:.3f} | COCO-lying PCK {lying:.3f}")


if __name__ == "__main__":
    main()
