"""COCO-Stuff segmentation data: label remap to 16 classes, indoor filter, letterbox to 256."""
import os
import pickle
from concurrent.futures import ThreadPoolExecutor

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

from src import config as C


def lut():
    """PNG value v (0..181, 255) -> our class. The maps store label id - 1; 255 = unlabelled."""
    t = np.zeros(256, np.uint8)                      # labelled but not listed -> 0 "other"
    for k, (_, ids) in enumerate(C.CLASSES):
        for i in ids:
            t[i - 1] = k
    t[255] = C.IGNORE
    return t


LUT = lut()


def _hist(path):
    m = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    return np.bincount(LUT[m].ravel(), minlength=256)[:C.NUM_CLASSES]


def build_index(split):
    """[(file stem, class pixel histogram)], cached; used for the indoor filter."""
    os.makedirs(C.CACHE, exist_ok=True)
    out = os.path.join(C.CACHE, f"{split}.pkl")
    if os.path.isfile(out):
        return pickle.load(open(out, "rb"))
    names = sorted(f[:-4] for f in os.listdir(C.MAPS[split]) if f.endswith(".png"))
    with ThreadPoolExecutor(16) as ex:
        hists = list(ex.map(_hist, [os.path.join(C.MAPS[split], n + ".png") for n in names]))
    idx = list(zip(names, hists))
    pickle.dump(idx, open(out, "wb"))
    return idx


def indoor(idx):
    keep = []
    for n, h in idx:
        tot = h.sum()
        if tot and h[list(C.INDOOR_CLASSES)].sum() / tot >= C.INDOOR_MIN_FRAC:
            keep.append(n)
    return keep


def letterbox_matrix(w, h, scale=1.0, dx=0.0, dy=0.0):
    s = C.INPUT / max(w, h) * scale
    return np.array([[s, 0, (C.INPUT - w * s) / 2 + dx], [0, s, (C.INPUT - h * s) / 2 + dy]], np.float32)


def normalise(rgb):
    t = rgb.astype(np.float32) / 255.0
    t = (t - np.array(C.MEAN, np.float32)) / np.array(C.STD, np.float32)
    return torch.from_numpy(t.transpose(2, 0, 1).copy())


class CocoSeg(Dataset):
    def __init__(self, split, augment=None, names=None):
        self.split = split
        self.names = names if names is not None else indoor(build_index(split))
        self.augment = (split == "train") if augment is None else augment

    def __len__(self):
        return len(self.names)

    def load(self, i):
        n = self.names[i]
        img = cv2.cvtColor(cv2.imread(os.path.join(C.IMAGES[self.split], n + ".jpg")), cv2.COLOR_BGR2RGB)
        lab = LUT[cv2.imread(os.path.join(C.MAPS[self.split], n + ".png"), cv2.IMREAD_GRAYSCALE)]
        return img, lab

    def __getitem__(self, i):
        img, lab = self.load(i)
        h, w = lab.shape
        if self.augment:
            sc = np.random.uniform(0.7, 1.5)
            span = C.INPUT * max(sc - 1, 0) / 2 + C.INPUT * 0.1
            M = letterbox_matrix(w, h, sc, np.random.uniform(-span, span), np.random.uniform(-span, span))
            if np.random.rand() < 0.5:
                img, lab = img[:, ::-1].copy(), lab[:, ::-1].copy()
            x = img.astype(np.float32)
            x = x * np.random.uniform(0.7, 1.3) + np.random.uniform(-25, 25)
            g = x.mean(axis=2, keepdims=True)
            img = np.clip(g + (x - g) * np.random.uniform(0.6, 1.4), 0, 255).astype(np.uint8)
        else:
            M = letterbox_matrix(w, h)
        xi = cv2.warpAffine(img, M, (C.INPUT, C.INPUT), flags=cv2.INTER_LINEAR,
                            borderMode=cv2.BORDER_CONSTANT, borderValue=C.PAD_RGB)
        yl = cv2.warpAffine(lab, M, (C.INPUT, C.INPUT), flags=cv2.INTER_NEAREST,
                            borderMode=cv2.BORDER_CONSTANT, borderValue=C.IGNORE)
        return normalise(xi), torch.from_numpy(yl.astype(np.int64)), i
