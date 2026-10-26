"""Recall of people lying down: of the 108 lying people in COCO val2017 (src/lying.py rule), how many
get a person box with IoU >= 0.5 at a score >= --thr.

  python -m src.lying_recall CKPT [--thr 0.3]      (DET_CLASSSET must match the checkpoint)
"""
import argparse
import json
import os

import cv2
import numpy as np
import torch

from src import config as C
from src.demo import detect, load


def lying_people():
    js = json.load(open(os.path.join(C.DATA, "annotations", "person_keypoints_val2017.json"), encoding="utf-8"))
    files = {im["id"]: im["file_name"] for im in js["images"]}
    out = []
    for a in js["annotations"]:
        if a.get("iscrowd") or a["num_keypoints"] < 8:
            continue
        k = np.array(a["keypoints"], np.float64).reshape(17, 3)
        sh, hp = k[[5, 6]], k[[11, 12]]
        if (sh[:, 2] > 0).sum() == 0 or (hp[:, 2] > 0).sum() == 0:
            continue
        v = sh[sh[:, 2] > 0, :2].mean(0) - hp[hp[:, 2] > 0, :2].mean(0)
        if np.degrees(np.arctan2(abs(v[0]), -v[1])) > 60:
            x, y, w, h = a["bbox"]
            out.append((files[a["image_id"]], (x, y, x + w, y + h)))
    return out


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    i = ix * iy
    return i / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i + 1e-9)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ckpt")
    ap.add_argument("--thr", type=float, default=0.3)
    a = ap.parse_args()
    m = load(a.ckpt)
    people = lying_people()
    hit = 0
    for f, gt in people:
        rgb = cv2.cvtColor(cv2.imread(os.path.join(C.VAL_IMAGES, f)), cv2.COLOR_BGR2RGB)
        boxes = [d for d in detect(m, rgb, a.thr) if d[5] == 0]
        hit += any(iou(d[:4], gt) >= 0.5 for d in boxes)
    print(json.dumps({"lying_people": len(people), "found": hit, "recall": hit / len(people), "thr": a.thr}))


if __name__ == "__main__":
    main()
