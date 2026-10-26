"""COCO people lying down -> MPII-schema records, for the fall-enhanced pose model.

  python -m src.build_coco_lying

A person counts as lying when it has >= 8 labelled keypoints, at least one shoulder and one hip,
and the torso (hip centre -> shoulder centre) is more than 60 degrees away from upright.
COCO train2017 gives 2,346 such people, val2017 108.

Writes data/coco_lying/annot/{train,valid}.json in the schema of train/mbv2_pose's MPII records,
so src.dataset.MPIIDataset reads them as an extra source (TWN_EXTRA_ANNOT / TWN_EXTRA_IMAGE_DIR):
  joints     16 MPII joints, 1-indexed pixels (the dataset subtracts 1); COCO has no head top,
             upper neck, pelvis or thorax, so those four are marked invisible (zero loss weight)
  center     bbox centre, shifted up by 15*scale and +1, which the dataset's MPII crop rule undoes
  scale      max(bbox w, h) / 200
  head_box   a square whose diagonal is max(bbox w, h) / 3, so the dataset's PCKh@0.5 on these
             records means "within 0.1 x the longer side of the person box" (the lying ruler)
"""
import json
import os

import numpy as np

from src.config import DATA_ROOT

COCO = os.path.join(DATA_ROOT, "coco")
OUT = os.path.join(DATA_ROOT, "coco_lying", "annot")
# MPII index <- COCO index (person's own left/right in both)
MPII_FROM_COCO = {0: 16, 1: 14, 2: 12, 3: 11, 4: 13, 5: 15, 10: 10, 11: 8, 12: 6, 13: 5, 14: 7, 15: 9}


def lying(kp):
    sh, hp = kp[[5, 6]], kp[[11, 12]]
    if (sh[:, 2] > 0).sum() == 0 or (hp[:, 2] > 0).sum() == 0:
        return False
    v = sh[sh[:, 2] > 0, :2].mean(0) - hp[hp[:, 2] > 0, :2].mean(0)
    return np.degrees(np.arctan2(abs(v[0]), -v[1])) > 60


def build(split):
    js = json.load(open(os.path.join(COCO, "annotations", f"person_keypoints_{split}2017.json"), encoding="utf-8"))
    files = {im["id"]: im["file_name"] for im in js["images"]}
    recs = []
    for a in js["annotations"]:
        if a.get("iscrowd") or a["num_keypoints"] < 8:
            continue
        kp = np.array(a["keypoints"], np.float64).reshape(17, 3)
        if not lying(kp):
            continue
        joints = np.zeros((16, 2)); vis = np.zeros(16, np.int64)
        for m, c in MPII_FROM_COCO.items():
            if kp[c, 2] > 0:
                joints[m] = kp[c, :2] + 1.0
                vis[m] = 1
        x, y, w, h = a["bbox"]
        s = max(w, h) / 200.0
        d = max(w, h) / 3.0 / np.sqrt(2)
        cx, cy = x + w / 2, y + h / 2
        recs.append({"image": f"{split}2017/" + files[a["image_id"]],
                     "center": [cx + 1.0, cy - 15.0 * s + 1.0], "scale": s,
                     "head_box": [cx, cy, cx + d, cy + d],
                     "joints": joints.round(2).tolist(), "joints_vis": vis.tolist(),
                     "coco_ann_id": a["id"]})
    return recs


def main():
    os.makedirs(OUT, exist_ok=True)
    for split, name in (("train", "train"), ("val", "valid")):
        r = build(split)
        json.dump(r, open(os.path.join(OUT, f"{name}.json"), "w"))
        print(name, len(r), "lying people")


if __name__ == "__main__":
    main()
