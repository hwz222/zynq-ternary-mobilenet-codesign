"""Convert the official MPII Human Pose .mat file into the train/valid JSON files of this workspace.

    python -m src.build_mpii_annot --mat <dir>/mpii_human_pose_v1_u12_1.mat [--out data/mpii/annot]

Output (default data/mpii/annot/, relative to train/mbv2_pose/):
  train.json, valid.json  -- list of person instances:
      { "image": str, "center": [x,y], "scale": float,
        "head_box": [x1,y1,x2,y2],
        "joints": [[x,y] x16],      # raw MPII 16-joint order; [-1,-1] if unlabelled
        "joints_vis": [0/1 x16] }   # 1 if the joint is labelled
  meta.json -- counts, split seed, the 16-joint id->name map.

The split is by IMAGE (no image appears in both splits). Only `single_person` instances of
img_train==1 images are used. 12 % of those images (seed 42) form the validation split: 2,289
instances, the "MPII val" of every PCKh in results/. The expected SHA-256 of the three output files
is listed in train/mbv2_pose/README.md; a different hash means a different ruler.

Needs numpy and scipy. The .mat file is part of the MPII annotation download
(mpii_human_pose_v1_u12_2.zip, Simplified BSD licence, Max Planck Institute for Informatics).
"""
import argparse
import json
import os

import numpy as np
import scipy.io as sio

VAL_IMAGE_FRACTION = 0.12
SEED = 42

# Raw MPII 16-joint id -> name
MPII_ID2NAME = {
    0: "r_ankle", 1: "r_knee", 2: "r_hip", 3: "l_hip", 4: "l_knee", 5: "l_ankle",
    6: "pelvis", 7: "thorax", 8: "upper_neck", 9: "head_top",
    10: "r_wrist", 11: "r_elbow", 12: "r_shoulder", 13: "l_shoulder",
    14: "l_elbow", 15: "l_wrist",
}


def as_list(x):
    if isinstance(x, np.ndarray):
        if x.size == 0:
            return []
        return list(x.ravel())
    return [x]


def safe_float(v):
    try:
        if isinstance(v, np.ndarray):
            if v.size == 0:
                return None
            v = v.ravel()[0]
        return float(v)
    except (TypeError, ValueError):
        return None


def parse_rect(r):
    """Return an instance dict, or None if it lacks center/scale/points."""
    if not hasattr(r, "annopoints") or r.annopoints is None:
        return None
    if not hasattr(r.annopoints, "point"):
        return None
    op = getattr(r, "objpos", None)
    if op is None:
        return None
    cx, cy = safe_float(getattr(op, "x", None)), safe_float(getattr(op, "y", None))
    s = safe_float(getattr(r, "scale", None))
    if cx is None or cy is None or s is None or s <= 0:
        return None
    x1, y1 = safe_float(getattr(r, "x1", None)), safe_float(getattr(r, "y1", None))
    x2, y2 = safe_float(getattr(r, "x2", None)), safe_float(getattr(r, "y2", None))
    if None in (x1, y1, x2, y2):
        return None

    joints = [[-1.0, -1.0] for _ in range(16)]
    joints_vis = [0] * 16
    for p in as_list(r.annopoints.point):
        pid = int(safe_float(p.id))
        px, py = safe_float(p.x), safe_float(p.y)
        if pid is None or px is None or py is None or not (0 <= pid <= 15):
            continue
        joints[pid] = [px, py]
        joints_vis[pid] = 1
    if sum(joints_vis) == 0:
        return None
    return {
        "center": [cx, cy], "scale": s, "head_box": [x1, y1, x2, y2],
        "joints": joints, "joints_vis": joints_vis,
    }


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mat", required=True, help="path of mpii_human_pose_v1_u12_1.mat")
    ap.add_argument("--out", default=os.path.join(here, "data", "mpii", "annot"),
                    help="output directory (default: data/mpii/annot of this workspace)")
    a = ap.parse_args()

    mat = sio.loadmat(a.mat, struct_as_record=False, squeeze_me=True)
    release = mat["RELEASE"]
    annolist = release.annolist
    img_train = np.asarray(release.img_train)
    single_person = release.single_person

    # Gather instances grouped by image.
    by_image = {}
    n_inst = 0
    for i in range(len(annolist)):
        if img_train[i] != 1:
            continue
        an = annolist[i]
        name = str(an.image.name)
        rects = as_list(an.annorect)
        sp = as_list(single_person[i])
        for ridx in sp:
            ridx = int(safe_float(ridx)) - 1  # 1-indexed in MATLAB
            if ridx < 0 or ridx >= len(rects):
                continue
            inst = parse_rect(rects[ridx])
            if inst is None:
                continue
            inst["image"] = name
            by_image.setdefault(name, []).append(inst)
            n_inst += 1

    images = sorted(by_image.keys())
    rng = np.random.RandomState(SEED)
    rng.shuffle(images)
    n_val_img = int(round(len(images) * VAL_IMAGE_FRACTION))
    val_images = set(images[:n_val_img])

    train, valid = [], []
    for name, insts in by_image.items():
        (valid if name in val_images else train).extend(insts)

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "train.json"), "w") as f:
        json.dump(train, f)
    with open(os.path.join(a.out, "valid.json"), "w") as f:
        json.dump(valid, f)
    meta = {
        "source_mat": os.path.basename(a.mat),
        "protocol": "single_person, img_train==1, split-by-image",
        "seed": SEED, "val_image_fraction": VAL_IMAGE_FRACTION,
        "num_images_total": len(images),
        "num_val_images": n_val_img,
        "num_instances_total": n_inst,
        "num_train": len(train), "num_valid": len(valid),
        "mpii_id2name": MPII_ID2NAME,
    }
    with open(os.path.join(a.out, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    print(f"images with single-person: {len(images)}")
    print(f"total instances          : {n_inst}")
    print(f"train instances          : {len(train)}")
    print(f"valid instances          : {len(valid)}  (from {n_val_img} held-out images)")
    print(f"wrote train.json / valid.json / meta.json to {a.out}")


if __name__ == "__main__":
    main()
