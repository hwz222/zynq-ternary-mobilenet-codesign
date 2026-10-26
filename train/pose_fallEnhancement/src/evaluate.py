"""PCKh@0.5 evaluation -- THE single ruler for every experiment (Discipline C).

Decode heatmaps -> original-image coords (inverse affine) -> compare to GT,
normalized by head-box size (SC_BIAS * head diagonal). Threshold = 0.5 * head size.
"""
import numpy as np
import torch

from src.config import HEATMAP_SIZE, NUM_JOINTS, PCKH_GROUPS, SC_BIAS
from src.heatmaps import decode_with_offset
from src.transforms import affine_transform, get_affine_transform


@torch.no_grad()
def evaluate(model, loader, device, use_offset=True):
    model.eval()
    K = NUM_JOINTS
    # per-joint accumulators
    correct = np.zeros(K, dtype=np.float64)
    count = np.zeros(K, dtype=np.float64)

    for inp, target, tw, meta in loader:
        inp = inp.to(device, non_blocking=True)
        out = model(inp)
        hm = out.detach().cpu().numpy().astype(np.float32)
        if use_offset:
            coords, _ = decode_with_offset(hm)
        else:
            from src.heatmaps import get_max_preds
            coords, _ = get_max_preds(hm)

        centers = meta["center"].numpy()
        scales = meta["scale"].numpy()
        joints_orig = meta["joints_orig"].numpy()
        joints_vis = meta["joints_vis"].numpy()
        head_box = meta["head_box"].numpy()
        N = inp.shape[0]
        for n in range(N):
            inv = get_affine_transform(centers[n], scales[n], 0, HEATMAP_SIZE, inv=True)
            hd = head_box[n]
            head_size = SC_BIAS * np.linalg.norm(hd[2:4] - hd[0:2])
            if head_size <= 0:
                continue
            for k in range(K):
                if joints_vis[n, k, 0] <= 0:
                    continue
                pred = affine_transform(coords[n, k], inv)
                d = np.linalg.norm(pred - joints_orig[n, k]) / head_size
                count[k] += 1
                if d <= 0.5:
                    correct[k] += 1

    per_joint = np.where(count > 0, correct / np.maximum(count, 1), 0.0)
    # overall = mean over all labeled joint instances
    overall = float(correct.sum() / max(count.sum(), 1)) * 100.0
    groups = {}
    for name, idxs in PCKH_GROUPS.items():
        c = correct[idxs].sum()
        n = count[idxs].sum()
        groups[name] = float(c / n) * 100.0 if n > 0 else 0.0
    return {
        "PCKh": overall,
        "groups": groups,
        "per_joint": (per_joint * 100.0).tolist(),
        "count": count.tolist(),
    }
