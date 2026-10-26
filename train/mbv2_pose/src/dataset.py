"""MPII single-person dataset: affine crop -> input tensor + gaussian heatmaps."""
import json
import os

import cv2
import numpy as np
import torch
from torch.utils.data import Dataset

# Disable OpenCV's OpenCL/UMat path: in some process launch contexts warpAffine
# returns a cv2.UMat (no .astype), crashing DataLoader workers. Force the CPU
# ndarray path; set at import so every spawned worker inherits it.
cv2.ocl.setUseOpenCL(False)

from src.config import (ANNOT_DIR, FLIP_PAIRS, IMAGE_DIR, IMAGE_MEAN, IMAGE_STD,
                        INPUT_SIZE, KEEP_MPII_IDS, NUM_JOINTS)
from src.heatmaps import generate_target
from src.transforms import affine_transform, fliplr_joints, get_affine_transform


class MPIIDataset(Dataset):
    """MPII, optionally mixed with extra annotation sources of the same schema.

    The extra sources are opt-in through env vars so no existing call site changes and a run
    without them is bit-identical to before:
      TWN_EXTRA_ANNOT      directory holding {split}.json in the MPII record schema. A
                           COMMA-SEPARATED LIST mixes several sources at once (sports and
                           a second set, say); one entry behaves exactly as it always did.
      TWN_EXTRA_IMAGE_DIR  image root each source's "image" fields are relative to, in the
                           same order and of the same length as TWN_EXTRA_ANNOT
      TWN_EXTRA_SPLITS     which splits to mix into, default "train" only -- the MPII
                           validation set is the project's one ruler and must stay clean
    Records carry their own image root, so the sources' filenames cannot collide.

    `bounds` reports [(annot_dir, start, end)] per extra source so a caller can give each
    source its own sampling weight; without it a two-source mix could only be weighted as
    one block, which is the knob the whole experiment turns.
    """

    def __init__(self, split, augment=None, source="mix"):
        assert split in ("train", "valid")
        assert source in ("mix", "extra_only")
        self.split = split
        self.augment = (split == "train") if augment is None else augment
        if source == "extra_only":
            self.db, self.roots, self.n_mpii = [], [], 0
        else:
            with open(os.path.join(ANNOT_DIR, f"{split}.json")) as f:
                self.db = json.load(f)
            self.roots = [IMAGE_DIR] * len(self.db)
            self.n_mpii = len(self.db)
        extra = os.environ.get("TWN_EXTRA_ANNOT", "")
        splits = os.environ.get("TWN_EXTRA_SPLITS", "train").split(",")
        self.bounds = []
        if extra and (split in splits or source == "extra_only"):
            dirs = [d for d in extra.split(",") if d]
            roots = [r for r in os.environ.get("TWN_EXTRA_IMAGE_DIR", "").split(",") if r]
            assert roots, "TWN_EXTRA_ANNOT set but TWN_EXTRA_IMAGE_DIR is not"
            assert len(roots) == len(dirs), (
                "TWN_EXTRA_ANNOT has %d entries and TWN_EXTRA_IMAGE_DIR has %d -- a "
                "mismatch would silently pair a source with the wrong image root"
                % (len(dirs), len(roots)))
            for d, root in zip(dirs, roots):
                with open(os.path.join(d, f"{split}.json")) as f:
                    more = json.load(f)
                start = len(self.db)
                self.db += more
                self.roots += [root] * len(more)
                self.bounds.append((d, start, len(self.db)))
                print("[dataset] %s: +%d from %s" % (split, len(more), d))
            print("[dataset] %s: %d MPII + %d extra" % (split, self.n_mpii,
                                                        len(self.db) - self.n_mpii))
        self.keep = np.array(KEEP_MPII_IDS, dtype=np.int64)
        # augmentation hyper-params (standard SimpleBaseline / MPII)
        self.scale_factor = 0.25
        self.rot_factor = 30.0
        self.flip = True
        self.mean = np.array(IMAGE_MEAN, dtype=np.float32).reshape(3, 1, 1)
        self.std = np.array(IMAGE_STD, dtype=np.float32).reshape(3, 1, 1)

    def __len__(self):
        return len(self.db)

    def _load_image(self, name, root=None):
        path = os.path.join(root or IMAGE_DIR, name)
        img = cv2.imread(path, cv2.IMREAD_COLOR)
        if img is None:
            raise FileNotFoundError(path)
        return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)

    def __getitem__(self, idx):
        rec = self.db[idx]
        img = self._load_image(rec["image"], self.roots[idx])

        joints16 = np.array(rec["joints"], dtype=np.float32)        # (16,2)
        vis16 = np.array(rec["joints_vis"], dtype=np.float32)        # (16,)
        joints = joints16[self.keep].copy()                         # (K,2)
        joints_vis = vis16[self.keep].reshape(-1, 1).copy()         # (K,1)
        # MATLAB 1-indexed -> 0-indexed
        joints[joints_vis[:, 0] > 0] -= 1.0
        joints_orig = joints.copy()                                 # for PCKh (original coords)

        c = np.array(rec["center"], dtype=np.float32) - 1.0          # 0-indexed
        s = np.array([rec["scale"], rec["scale"]], dtype=np.float32)
        # MPII-specific crop adjustment (avoid cutting off limbs)
        c[1] = c[1] + 15.0 * s[1]
        s = s * 1.25
        head_box = np.array(rec["head_box"], dtype=np.float32)

        r = 0.0
        if self.augment:
            sf, rf = self.scale_factor, self.rot_factor
            # HALF-BODY aug (env HALFBODY_AUG=prob, off by default): recenter the crop on the
            # upper or lower body only -- HRNet-style; teaches truncated-person robustness.
            hb_p = float(os.environ.get("HALFBODY_AUG", "0"))
            if hb_p > 0 and np.random.rand() < hb_p:
                upper = [0, 1, 2, 3, 4, 5, 6, 7]
                lower = [8, 9, 10, 11, 12, 13]
                sel = upper if np.random.rand() < 0.6 else lower
                pts = np.array([joints[k, :2] for k in sel if joints_vis[k, 0] > 0])
                if len(pts) >= 3:
                    lo, hi = pts.min(0), pts.max(0)
                    c = ((lo + hi) / 2).astype(np.float32)
                    wh = (hi - lo) * 1.5
                    s = np.array([max(wh[0], wh[1] * INPUT_SIZE[0] / INPUT_SIZE[1]) / 200.0] * 2,
                                 dtype=np.float32) * 1.25
            s = s * np.clip(np.random.randn() * sf + 1, 1 - sf, 1 + sf)
            r = np.clip(np.random.randn() * rf, -2 * rf, 2 * rf) if np.random.rand() <= 0.6 else 0.0
            if self.flip and np.random.rand() <= 0.5:
                img = img[:, ::-1, :]
                joints, joints_vis = fliplr_joints(joints, joints_vis, img.shape[1], FLIP_PAIRS)
                c[0] = img.shape[1] - c[0] - 1

        trans = get_affine_transform(c, s, r, INPUT_SIZE)
        inp = cv2.warpAffine(img, trans, (int(INPUT_SIZE[0]), int(INPUT_SIZE[1])),
                             flags=cv2.INTER_LINEAR)

        # joints -> input coords
        for k in range(NUM_JOINTS):
            if joints_vis[k, 0] > 0:
                joints[k, 0:2] = affine_transform(joints[k, 0:2], trans)

        # COLOR JITTER (env COLOR_AUG=prob, off by default): brightness/contrast/saturation
        # +-25% on the uint8 crop -- the pipeline previously had NO photometric augmentation.
        cj_p = float(os.environ.get("COLOR_AUG", "0"))
        if self.augment and cj_p > 0 and np.random.rand() < cj_p:
            f = inp.astype(np.float32)
            f = f * np.random.uniform(0.75, 1.25)                       # brightness
            mean_l = f.mean()
            f = (f - mean_l) * np.random.uniform(0.75, 1.25) + mean_l   # contrast
            gray = f.mean(axis=2, keepdims=True)
            f = (f - gray) * np.random.uniform(0.75, 1.25) + gray       # saturation
            inp = np.clip(f, 0, 255).astype(np.uint8)

        # LIMB-OCCLUSION aug (env OCC_AUG=prob, off by default): paste 1-2 gray/noise patches
        # over visible distal joints in the CROP; the GT heatmap still supervises, so the model
        # must learn to INFER occluded joints from context (attacks the 'lost' miss mode).
        occ_p = float(os.environ.get("OCC_AUG", "0"))
        if self.augment and occ_p > 0 and np.random.rand() < occ_p:
            distal = [k for k in (4, 5, 6, 7, 10, 11, 12, 13) if joints_vis[k, 0] > 0]
            np.random.shuffle(distal)
            for k in distal[:np.random.randint(1, 3)]:
                jx, jy = joints[k, 0:2]
                if not (0 <= jx < INPUT_SIZE[0] and 0 <= jy < INPUT_SIZE[1]):
                    continue
                w = np.random.randint(24, 64); h = np.random.randint(24, 64)
                x0 = int(np.clip(jx - w // 2 + np.random.randint(-8, 9), 0, INPUT_SIZE[0] - 1))
                y0 = int(np.clip(jy - h // 2 + np.random.randint(-8, 9), 0, INPUT_SIZE[1] - 1))
                x1 = min(x0 + w, int(INPUT_SIZE[0])); y1 = min(y0 + h, int(INPUT_SIZE[1]))
                if np.random.rand() < 0.5:
                    inp[y0:y1, x0:x1] = np.random.randint(60, 190)
                else:
                    inp[y0:y1, x0:x1] = np.random.randint(0, 255, (y1 - y0, x1 - x0, 3),
                                                          dtype=np.uint8)

        target, target_weight = generate_target(joints, joints_vis)

        # normalize image -> CHW tensor
        inp = inp.astype(np.float32) / 255.0
        inp = inp.transpose(2, 0, 1)
        inp = (inp - self.mean) / self.std
        inp = torch.from_numpy(np.ascontiguousarray(inp))

        target = torch.from_numpy(target)
        target_weight = torch.from_numpy(target_weight)

        meta = {
            "image": rec["image"],
            "index": idx,
            "joints": joints.astype(np.float32),   # cropped-input coords (for soft-argmax loss)
            "center": c.astype(np.float32),
            "scale": s.astype(np.float32),
            "joints_orig": joints_orig.astype(np.float32),
            "joints_vis": joints_vis.astype(np.float32),
            "head_box": head_box.astype(np.float32),
        }
        return inp, target, target_weight, meta
