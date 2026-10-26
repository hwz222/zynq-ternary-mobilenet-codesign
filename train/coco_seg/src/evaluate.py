"""The ruler of this task: mean IoU over the 16 classes on the indoor subset of COCO-Stuff
val2017 (the same indoor rule as training), computed at each image's ORIGINAL resolution
(64x64 logits -> bilinear to the 256 input -> the letterbox's content region -> nearest to w x h).

  python -m src.evaluate checkpoints/<exp>/best.pth
"""
import json
import sys

import numpy as np
import torch
import torch.nn.functional as F

from src import config as C
from src.data import CocoSeg, letterbox_matrix, normalise


@torch.no_grad()
def predict_label(model, img_rgb, device="cuda"):
    """RGB uint8 image -> class map at the image's own resolution."""
    import cv2
    h, w = img_rgb.shape[:2]
    M = letterbox_matrix(w, h)
    x = cv2.warpAffine(img_rgb, M, (C.INPUT, C.INPUT), flags=cv2.INTER_LINEAR,
                       borderMode=cv2.BORDER_CONSTANT, borderValue=C.PAD_RGB)
    lo = model(normalise(x)[None].to(device))
    return logits_to_label(lo[0], w, h)


def logits_to_label(lo, w, h):
    M = letterbox_matrix(w, h)
    s, tx, ty = M[0, 0], M[0, 2], M[1, 2]
    up = F.interpolate(lo[None].float(), size=(C.INPUT, C.INPUT), mode="bilinear", align_corners=False)[0]
    x0, y0 = int(round(tx)), int(round(ty))
    cw, ch = max(1, int(round(w * s))), max(1, int(round(h * s)))
    crop = up[:, y0:y0 + ch, x0:x0 + cw]
    full = F.interpolate(crop[None], size=(h, w), mode="bilinear", align_corners=False)[0]
    return full.argmax(0).cpu().numpy().astype(np.uint8)


@torch.no_grad()
def evaluate(model, device="cuda", limit=None):
    model.eval()
    ds = CocoSeg("val", augment=False)
    n = len(ds) if limit is None else min(limit, len(ds))
    inter = np.zeros(C.NUM_CLASSES, np.int64)
    union = np.zeros(C.NUM_CLASSES, np.int64)
    correct = total = 0
    for i in range(n):
        img, lab = ds.load(i)
        pred = predict_label(model, img, device)
        v = lab != C.IGNORE
        p, g = pred[v].astype(np.int64), lab[v].astype(np.int64)
        cm = np.bincount(g * C.NUM_CLASSES + p, minlength=C.NUM_CLASSES ** 2).reshape(C.NUM_CLASSES, -1)
        inter += np.diag(cm)
        union += cm.sum(0) + cm.sum(1) - np.diag(cm)
        correct += int(np.diag(cm).sum()); total += int(v.sum())
    iou = inter / np.maximum(union, 1)
    present = union > 0
    return {"mIoU": float(iou[present].mean() * 100), "pixel_acc": correct / max(total, 1) * 100,
            "n_images": n, "per_class": {C.CLASSES[k][0]: float(iou[k] * 100) for k in range(C.NUM_CLASSES)}}


def main():
    from src.qmodel import Mbv2Quant, materialize
    m = Mbv2Quant(ternary="--int8" not in sys.argv)
    materialize(m)
    sd = torch.load(sys.argv[1], map_location="cpu", weights_only=False)
    m.load_state_dict(sd.get("model", sd))
    m.to("cuda")
    res = evaluate(m)
    tern = m.verify_all_ternary()
    res["ternary_check"] = f"{sum(r['ok'] for r in tern)}/{len(tern)} ok" if tern else "int8 model"
    print(json.dumps(res, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
