"""Label indoor COCO images with metric depth from a teacher, for distillation.

Teacher: Depth Anything V2, metric indoor, Small (depth-anything/Depth-Anything-V2-Metric-Indoor-
Small-hf, fine-tuned on Hypersim; outputs metres). It needs `transformers`; the author ran it in a
separate copy of the training environment with `transformers` added:

  <teacher-env>/python -m src.pseudo_label [--limit N]

Images: COCO train2017 images with a couch, bed, toilet, tv, microwave, oven, sink or refrigerator,
or with at least two different indoor objects (adding chair, dining table, laptop, potted plant), from
data/coco/annotations/instances_train2017.json. Writes data/pseudo_coco/<image id>.npy: float16
metres, longer side 320 px, plus data/pseudo_coco/index.txt (file name per line).
"""
import argparse
import json
import os

import cv2
import numpy as np
import torch
from torch.utils.data import DataLoader, Dataset

from src import config as C

TEACHER = "depth-anything/Depth-Anything-V2-Metric-Indoor-Small-hf"
INDOOR_CATS = {62, 63, 64, 65, 67, 70, 72, 73, 78, 79, 81, 82}
STRONG = {63, 65, 70, 72, 78, 79, 81, 82}      # couch, bed, toilet, tv, microwave, oven, sink, fridge
OUT = os.path.join(C.DATA, "pseudo_coco")
COCO = os.path.join(C.DATA, "coco")
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)


def indoor_images():
    js = json.load(open(os.path.join(COCO, "annotations", "instances_train2017.json"), encoding="utf-8"))
    cats = {}
    for a in js["annotations"]:
        if a["category_id"] in INDOOR_CATS:
            cats.setdefault(a["image_id"], set()).add(a["category_id"])
    ids = {i for i, c in cats.items() if (c & STRONG) or len(c) >= 2}
    return sorted(im["file_name"] for im in js["images"] if im["id"] in ids)


class Imgs(Dataset):
    def __init__(self, names):
        self.names = names

    def __len__(self):
        return len(self.names)

    def __getitem__(self, i):
        bgr = cv2.imread(os.path.join(COCO, "train2017", self.names[i]))
        h, w = bgr.shape[:2]
        s = 518 / min(h, w)                                   # the teacher's input: short side 518,
        nh, nw = round(h * s / 14) * 14, round(w * s / 14) * 14   # both sides multiples of 14
        x = cv2.resize(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB), (nw, nh), interpolation=cv2.INTER_CUBIC)
        x = (x.astype(np.float32) / 255 - MEAN) / STD
        return torch.from_numpy(x.transpose(2, 0, 1).copy()), self.names[i], h, w


def main():
    from transformers import AutoModelForDepthEstimation
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    names = indoor_images()
    if a.limit:
        names = names[:a.limit]
    todo = [n for n in names if not os.path.isfile(os.path.join(OUT, n.replace(".jpg", ".npy")))]
    print(f"{len(names)} indoor images, {len(todo)} to label")
    model = AutoModelForDepthEstimation.from_pretrained(TEACHER).to("cuda").eval().half()
    dl = DataLoader(Imgs(todo), batch_size=1, num_workers=6)
    with torch.no_grad():
        for k, (x, n, h, w) in enumerate(dl):
            d = model(pixel_values=x.to("cuda").half()).predicted_depth[0].float().cpu().numpy()
            h, w = int(h), int(w)
            s = 320 / max(h, w)
            d = cv2.resize(d, (round(w * s), round(h * s)), interpolation=cv2.INTER_LINEAR)
            np.save(os.path.join(OUT, n[0].replace(".jpg", ".npy")), d.astype(np.float16))
            if k % 2000 == 0:
                print(k, n[0], d.shape, float(d.min()), float(d.max()), flush=True)
    open(os.path.join(OUT, "index.txt"), "w").write("\n".join(names))
    print("done")


if __name__ == "__main__":
    main()
