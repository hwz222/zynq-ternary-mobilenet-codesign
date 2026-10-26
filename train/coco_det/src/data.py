"""COCO detection data: compact annotation cache, letterbox to 256, CenterNet targets."""
import json
import math
import os
import pickle

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

from src import config as C


def build_cache(split):
    """instances_<split>2017.json -> list of (file, w, h, boxes[n,4] xywh, cls[n]) for the 12
    classes, crowd boxes dropped. Images with none of the 12 classes are kept only for val."""
    os.makedirs(C.CACHE, exist_ok=True)
    out = os.path.join(C.CACHE, f"{split}_{C.CLASSSET}.pkl")
    if os.path.isfile(out):
        return pickle.load(open(out, "rb"))
    js = json.load(open(C.TRAIN_JSON if split == "train" else C.VAL_JSON, encoding="utf-8"))
    cat2ch = {c: i for i, c in enumerate(C.CAT_IDS)}
    per = {im["id"]: (im["file_name"], im["width"], im["height"], [], []) for im in js["images"]}
    for a in js["annotations"]:
        if a["category_id"] in cat2ch and not a.get("iscrowd", 0):
            per[a["image_id"]][3].append(a["bbox"])
            per[a["image_id"]][4].append(cat2ch[a["category_id"]])
    recs = []
    for iid, (f, w, h, b, c) in sorted(per.items()):
        if split == "train" and not b:
            continue
        recs.append((iid, f, w, h, np.array(b, np.float32).reshape(-1, 4), np.array(c, np.int64)))
    pickle.dump(recs, open(out, "wb"))
    return recs


def letterbox_matrix(w, h, scale=1.0, dx=0.0, dy=0.0):
    """2x3 affine: original image -> 256x256 input. scale=1, dx=dy=0 is the plain centred
    letterbox used at test time and on the board."""
    s = C.INPUT / max(w, h) * scale
    tx = (C.INPUT - w * s) / 2 + dx
    ty = (C.INPUT - h * s) / 2 + dy
    return np.array([[s, 0, tx], [0, s, ty]], np.float32)


def to_input(img_rgb, M):
    x = cv2.warpAffine(img_rgb, M, (C.INPUT, C.INPUT), flags=cv2.INTER_LINEAR,
                       borderMode=cv2.BORDER_CONSTANT, borderValue=C.PAD_RGB)
    t = x.astype(np.float32) / 255.0
    t = (t - np.array(C.MEAN, np.float32)) / np.array(C.STD, np.float32)
    return x, torch.from_numpy(t.transpose(2, 0, 1).copy())


def gaussian_radius(h, w, min_overlap=0.7):
    """CenterNet's radius: the largest centre shift that keeps IoU >= min_overlap."""
    a1, b1, c1 = 1, h + w, w * h * (1 - min_overlap) / (1 + min_overlap)
    r1 = (b1 + math.sqrt(b1 ** 2 - 4 * a1 * c1)) / 2
    a2, b2, c2 = 4, 2 * (h + w), (1 - min_overlap) * w * h
    r2 = (b2 + math.sqrt(b2 ** 2 - 4 * a2 * c2)) / 2
    a3, b3, c3 = 4 * min_overlap, -2 * min_overlap * (h + w), (min_overlap - 1) * w * h
    r3 = (b3 + math.sqrt(b3 ** 2 - 4 * a3 * c3)) / 2
    return min(r1, r2, r3)


def draw_gaussian(hm, cx, cy, r):
    d = 2 * r + 1
    sigma = d / 6
    ys, xs = np.ogrid[-r:r + 1, -r:r + 1]
    g = np.exp(-(xs * xs + ys * ys) / (2 * sigma * sigma))
    H, W = hm.shape
    l, ri = min(cx, r), min(W - cx, r + 1)
    t, b = min(cy, r), min(H - cy, r + 1)
    hm_s = hm[cy - t:cy + b, cx - l:cx + ri]
    g_s = g[r - t:r + b, r - l:r + ri]
    np.maximum(hm_s, g_s, out=hm_s)


class CocoDet(Dataset):
    def __init__(self, split, augment=None):
        self.split = split
        self.recs = build_cache(split)
        self.images = C.TRAIN_IMAGES if split == "train" else C.VAL_IMAGES
        self.augment = (split == "train") if augment is None else augment

    def __len__(self):
        return len(self.recs)

    def load_rgb(self, i):
        img = cv2.imread(os.path.join(self.images, self.recs[i][1]), cv2.IMREAD_COLOR)
        return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

    def __getitem__(self, i):
        iid, f, w, h, boxes, cls = self.recs[i]
        img = self.load_rgb(i)
        boxes = boxes.copy()
        if self.augment:
            sc = np.random.uniform(0.6, 1.4)
            span = C.INPUT * max(sc - 1, 0) / 2 + C.INPUT * 0.15
            M = letterbox_matrix(w, h, sc, np.random.uniform(-span, span), np.random.uniform(-span, span))
            if np.random.rand() < 0.5:
                img = img[:, ::-1].copy()
                boxes[:, 0] = w - boxes[:, 0] - boxes[:, 2]
            img = self.color_jitter(img)
        else:
            M = letterbox_matrix(w, h)
        _, x = to_input(img, M)
        s, tx, ty = M[0, 0], M[0, 2], M[1, 2]
        x0 = boxes[:, 0] * s + tx
        y0 = boxes[:, 1] * s + ty
        x1 = (boxes[:, 0] + boxes[:, 2]) * s + tx
        y1 = (boxes[:, 1] + boxes[:, 3]) * s + ty
        x0, x1 = np.clip(x0, 0, C.INPUT - 1), np.clip(x1, 0, C.INPUT - 1)
        y0, y1 = np.clip(y0, 0, C.INPUT - 1), np.clip(y1, 0, C.INPUT - 1)
        hm = np.zeros((C.NUM_CLASSES, C.OUT, C.OUT), np.float32)
        wh = np.zeros((C.MAX_OBJ, 2), np.float32)
        off = np.zeros((C.MAX_OBJ, 2), np.float32)
        ind = np.zeros(C.MAX_OBJ, np.int64)
        msk = np.zeros(C.MAX_OBJ, np.float32)
        k = 0
        for j in range(len(cls)):
            bw, bh = x1[j] - x0[j], y1[j] - y0[j]
            if bw < 2 or bh < 2 or k >= C.MAX_OBJ:
                continue
            cx, cy = (x0[j] + x1[j]) / 2 / C.STRIDE, (y0[j] + y1[j]) / 2 / C.STRIDE
            ix, iy = int(cx), int(cy)
            r = max(0, int(gaussian_radius(math.ceil(bh / C.STRIDE), math.ceil(bw / C.STRIDE))))
            draw_gaussian(hm[cls[j]], ix, iy, r)
            wh[k] = (bw / C.WH_UNIT, bh / C.WH_UNIT)
            off[k] = (cx - ix, cy - iy)
            ind[k] = iy * C.OUT + ix
            msk[k] = 1
            k += 1
        return x, torch.from_numpy(hm), torch.from_numpy(wh), torch.from_numpy(off), \
            torch.from_numpy(ind), torch.from_numpy(msk), i

    @staticmethod
    def color_jitter(img):
        x = img.astype(np.float32)
        x = x * np.random.uniform(0.7, 1.3) + np.random.uniform(-25, 25)          # contrast, brightness
        g = x.mean(axis=2, keepdims=True)
        x = g + (x - g) * np.random.uniform(0.6, 1.4)                               # saturation
        return np.clip(x, 0, 255).astype(np.uint8)
