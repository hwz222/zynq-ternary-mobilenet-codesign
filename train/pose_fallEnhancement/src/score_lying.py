"""Score a pose checkpoint on the COCO-lying ruler (108 people lying down in COCO val2017; a joint is
correct within 0.1 x the longer side of the person box; 12 joints). Standalone counterpart of the
second ruler printed by src/train_fall.py.

  python -m src.score_lying CKPT
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
os.environ["TWN_EXTRA_ANNOT"] = os.path.join(DATA, "coco_lying", "annot")
os.environ["TWN_EXTRA_IMAGE_DIR"] = os.path.join(DATA, "coco")

import torch  # noqa: E402
from torch.utils.data import DataLoader  # noqa: E402

from src.build_model import build_quant, region_keys  # noqa: E402
from src.config import INPUT_SIZE  # noqa: E402
from src.dataset import MPIIDataset  # noqa: E402
from src.evaluate import evaluate  # noqa: E402


def main():
    twn, pc = region_keys("mbv2", 1.0, None, 32, "pw_stem")
    m = build_quant("mbv2", 1.0, None, 32, twn, pc)
    ck = torch.load(sys.argv[1], map_location="cpu", weights_only=False)
    m.load_state_dict(ck.get("model", ck))
    m.eval()
    with torch.no_grad():
        m(torch.zeros(1, 3, INPUT_SIZE[1], INPUT_SIZE[0]))
    m.to("cuda")
    ds = MPIIDataset("valid", augment=False, source="extra_only")
    r = evaluate(m, DataLoader(ds, batch_size=64, num_workers=4), "cuda")
    tern = m.verify_all_ternary()
    print(f"COCO-lying PCK {r['PCKh']:.3f} on {len(ds)} people | groups "
          + "  ".join(f"{k} {v:.1f}" for k, v in r["groups"].items() if k not in ("Head",))
          + f" | ternary {sum(t['ok'] for t in tern)}/{len(tern)}")


if __name__ == "__main__":
    main()
