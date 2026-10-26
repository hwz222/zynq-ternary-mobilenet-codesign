"""The ruler of this task: COCO box AP on val2017 (5,000 images), restricted to the 12 classes,
pycocotools COCOeval. Run standalone on a checkpoint:

  python -m src.evaluate checkpoints/<exp>/best.pth
"""
import contextlib
import io
import json
import sys

import numpy as np
import torch
from pycocotools.coco import COCO
from pycocotools.cocoeval import COCOeval
from torch.utils.data import DataLoader

from src import config as C
from src.centernet import decode
from src.data import CocoDet, letterbox_matrix


@torch.no_grad()
def predict(model, ds, device="cuda", batch=64, workers=6, k=100):
    model.eval()
    dl = DataLoader(ds, batch_size=batch, shuffle=False, num_workers=workers, pin_memory=True)
    dets = []
    for x, *_, idx in dl:
        out = decode(model(x.to(device, non_blocking=True)), k=k).cpu().numpy()
        for b, i in enumerate(idx.tolist()):
            iid, f, w, h = ds.recs[i][:4]
            M = letterbox_matrix(w, h)
            s, tx, ty = M[0, 0], M[0, 2], M[1, 2]
            for x0, y0, x1, y1, sc, c in out[b]:
                if sc < 0.01:
                    continue
                X0, Y0 = (x0 - tx) / s, (y0 - ty) / s
                X1, Y1 = (x1 - tx) / s, (y1 - ty) / s
                X0, Y0, X1, Y1 = max(0, X0), max(0, Y0), min(w, X1), min(h, Y1)
                if X1 <= X0 or Y1 <= Y0:
                    continue
                dets.append({"image_id": int(iid), "category_id": int(C.CAT_IDS[int(c)]),
                             "bbox": [float(X0), float(Y0), float(X1 - X0), float(Y1 - Y0)],
                             "score": float(sc)})
    return dets


def coco_ap(dets, img_ids):
    with contextlib.redirect_stdout(io.StringIO()):
        gt = COCO(C.VAL_JSON)
        if not dets:
            return {"AP": 0.0, "AP50": 0.0, "per_class": {}}
        dt = gt.loadRes(dets)
        ev = COCOeval(gt, dt, "bbox")
        ev.params.imgIds = img_ids
        ev.params.catIds = C.CAT_IDS
        ev.evaluate(); ev.accumulate(); ev.summarize()
    prec = ev.eval["precision"]            # T x R x K x A x M
    per = {}
    for k, (name, _) in enumerate(C.CLASSES):
        p = prec[:, :, k, 0, -1]
        per[name] = float(np.mean(p[p > -1])) * 100 if (p > -1).any() else 0.0
    st = ev.stats
    return {"AP": st[0] * 100, "AP50": st[1] * 100, "AP75": st[2] * 100,
            "AP_small": st[3] * 100, "AP_medium": st[4] * 100, "AP_large": st[5] * 100,
            "per_class": per}


def evaluate(model, device="cuda", workers=6):
    ds = CocoDet("val", augment=False)
    dets = predict(model, ds, device, workers=workers)
    return coco_ap(dets, [r[0] for r in ds.recs])


def main():
    from src.qmodel import Mbv2Quant, materialize
    ck = sys.argv[1]
    ternary = "--int8" not in sys.argv
    m = Mbv2Quant(ternary=ternary)
    materialize(m)
    sd = torch.load(ck, map_location="cpu", weights_only=False)
    m.load_state_dict(sd.get("model", sd))
    m.to("cuda")
    res = evaluate(m)
    tern = m.verify_all_ternary() if ternary else []
    res["ternary_check"] = (f"{sum(r['ok'] for r in tern)}/{len(tern)} ok, zero fraction "
                            f"{np.mean([r['frac_zero'] for r in tern]):.3f}") if tern else "int8 model"
    print(json.dumps(res, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
