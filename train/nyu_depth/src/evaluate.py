"""The ruler of this task: the standard NYU Depth V2 metrics on the 654 official test frames,
at 640x480 inside the Eigen crop, ground truth in (1e-3, 10] m, no scale alignment (metric).

  python -m src.evaluate checkpoints/<exp>/best.pth
"""
import json
import sys

import numpy as np
import torch
import torch.nn.functional as F

from src import config as C
from src.data import NYU, letterbox_matrix, normalise, to_input


def logits_to_depth(lo, w, h):
    """Output (16,64,64) -> metres at w x h: channel 0 is log-depth."""
    M = letterbox_matrix(w, h)
    s, tx, ty = M[0, 0], M[0, 2], M[1, 2]
    up = F.interpolate(lo[None, C.CH_DEPTH:C.CH_DEPTH + 1].float(), size=(C.INPUT, C.INPUT),
                       mode="bilinear", align_corners=False)[0, 0]
    x0, y0 = int(round(tx)), int(round(ty))
    cw, ch = int(round(w * s)), int(round(h * s))
    full = F.interpolate(up[y0:y0 + ch, x0:x0 + cw][None, None], size=(h, w), mode="bilinear",
                         align_corners=False)[0, 0]
    return torch.exp(full).clamp(C.MIN_DEPTH, C.MAX_DEPTH).cpu().numpy()


@torch.no_grad()
def predict_depth(model, rgb, device="cuda"):
    h, w = rgb.shape[:2]
    lo = model(normalise(to_input(rgb, letterbox_matrix(w, h)))[None].to(device))
    return logits_to_depth(lo[0], w, h)


@torch.no_grad()
def evaluate(model, device="cuda"):
    model.eval()
    ds = NYU("val", augment=False)
    y0, y1, x0, x1 = C.EIGEN_CROP
    acc = {"abs_rel": [], "sq_rel": [], "rmse": [], "rmse_log": [], "log10": [], "d1": [], "d2": [], "d3": []}
    for i in range(len(ds)):
        rgb, gt = ds.load(i)
        pred = predict_depth(model, rgb, device)
        g, p = gt[y0:y1, x0:x1], pred[y0:y1, x0:x1]
        v = (g > C.MIN_DEPTH) & (g <= C.MAX_DEPTH)
        g, p = g[v], p[v]
        th = np.maximum(g / p, p / g)
        acc["d1"].append((th < 1.25).mean()); acc["d2"].append((th < 1.25 ** 2).mean())
        acc["d3"].append((th < 1.25 ** 3).mean())
        acc["abs_rel"].append(np.mean(np.abs(g - p) / g)); acc["sq_rel"].append(np.mean((g - p) ** 2 / g))
        acc["rmse"].append(np.sqrt(np.mean((g - p) ** 2)))
        acc["rmse_log"].append(np.sqrt(np.mean((np.log(g) - np.log(p)) ** 2)))
        acc["log10"].append(np.mean(np.abs(np.log10(g) - np.log10(p))))
    return {k: float(np.mean(v)) for k, v in acc.items()} | {"n_images": len(ds)}


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
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
