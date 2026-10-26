"""NYU Depth V2 frames (FastDepth h5: rgb 3x480x640 uint8, depth 480x640 float32 metres),
letterboxed to 256x256 (content 256x192, mean-pixel padding)."""
import os

import cv2
import h5py
import numpy as np
import torch
from torch.utils.data import Dataset

from src import config as C


def list_files(split):
    os.makedirs(C.CACHE, exist_ok=True)
    cache = os.path.join(C.CACHE, f"{split}.txt")
    if os.path.isfile(cache):
        return open(cache, encoding="utf-8").read().split("\n")
    root = C.TRAIN_DIR if split == "train" else C.VAL_DIR
    files = sorted(os.path.relpath(os.path.join(dp, f), root)
                   for dp, _, fs in os.walk(root) for f in fs if f.endswith(".h5"))
    open(cache, "w", encoding="utf-8").write("\n".join(files))
    return files


def letterbox_matrix(w, h, scale=1.0, dx=0.0, dy=0.0):
    s = C.INPUT / max(w, h) * scale
    return np.array([[s, 0, (C.INPUT - w * s) / 2 + dx], [0, s, (C.INPUT - h * s) / 2 + dy]], np.float32)


def normalise(rgb):
    t = rgb.astype(np.float32) / 255.0
    t = (t - np.array(C.MEAN, np.float32)) / np.array(C.STD, np.float32)
    return torch.from_numpy(t.transpose(2, 0, 1).copy())


def to_input(rgb, M):
    return cv2.warpAffine(rgb, M, (C.INPUT, C.INPUT), flags=cv2.INTER_LINEAR,
                          borderMode=cv2.BORDER_CONSTANT, borderValue=C.PAD_RGB)


class NYU(Dataset):
    def __init__(self, split, augment=None):
        self.split = split
        self.root = C.TRAIN_DIR if split == "train" else C.VAL_DIR
        self.files = list_files(split)
        self.augment = (split == "train") if augment is None else augment

    def __len__(self):
        return len(self.files)

    def load(self, i):
        with h5py.File(os.path.join(self.root, self.files[i]), "r") as f:
            rgb = np.ascontiguousarray(f["rgb"][:].transpose(1, 2, 0))
            depth = f["depth"][:].astype(np.float32)
        return rgb, depth

    def __getitem__(self, i):
        rgb, depth = self.load(i)
        h, w = depth.shape
        if self.augment:
            # crops and shifts only: zooming would change apparent size without changing depth
            M = letterbox_matrix(w, h, 1.0, np.random.uniform(-20, 20), np.random.uniform(-20, 20))
            if np.random.rand() < 0.5:
                rgb, depth = rgb[:, ::-1].copy(), depth[:, ::-1].copy()
            x = rgb.astype(np.float32)
            x = x * np.random.uniform(0.75, 1.25) + np.random.uniform(-20, 20)
            g = x.mean(axis=2, keepdims=True)
            rgb = np.clip(g + (x - g) * np.random.uniform(0.7, 1.3), 0, 255).astype(np.uint8)
        else:
            M = letterbox_matrix(w, h)
        xi = to_input(rgb, M)
        d = cv2.warpAffine(depth, M, (C.INPUT, C.INPUT), flags=cv2.INTER_NEAREST,
                           borderMode=cv2.BORDER_CONSTANT, borderValue=0.0)
        return normalise(xi), torch.from_numpy(d), i


class PseudoCoco(Dataset):
    """Indoor COCO images with the teacher's metric depth (src/pseudo_label.py), same augmentation
    as the NYU frames."""

    def __init__(self):
        root = os.path.join(C.DATA, "pseudo_coco")
        names = open(os.path.join(root, "index.txt"), encoding="utf-8").read().split()
        self.items = [(os.path.join(C.DATA, "coco", "train2017", n), os.path.join(root, n.replace(".jpg", ".npy")))
                      for n in names]

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        ip, dp = self.items[i]
        rgb = cv2.cvtColor(cv2.imread(ip), cv2.COLOR_BGR2RGB)
        h, w = rgb.shape[:2]
        depth = cv2.resize(np.load(dp).astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR)
        M = letterbox_matrix(w, h, 1.0, np.random.uniform(-20, 20), np.random.uniform(-20, 20))
        if np.random.rand() < 0.5:
            rgb, depth = rgb[:, ::-1].copy(), depth[:, ::-1].copy()
        x = rgb.astype(np.float32)
        x = x * np.random.uniform(0.75, 1.25) + np.random.uniform(-20, 20)
        g = x.mean(axis=2, keepdims=True)
        rgb = np.clip(g + (x - g) * np.random.uniform(0.7, 1.3), 0, 255).astype(np.uint8)
        xi = to_input(rgb, M)
        d = cv2.warpAffine(depth, M, (C.INPUT, C.INPUT), flags=cv2.INTER_NEAREST,
                           borderMode=cv2.BORDER_CONSTANT, borderValue=0.0)
        return normalise(xi), torch.from_numpy(d), i
