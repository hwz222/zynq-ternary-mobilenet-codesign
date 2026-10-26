"""COCO images that contain a person lying down (for oversampling in training).

A person counts as lying when it has >= 8 labelled keypoints, at least one shoulder and one hip, and
the torso (hip centre -> shoulder centre) is more than 60 degrees from upright: 2,346 people in
2,165 train2017 images. Reads annotations/person_keypoints_train2017.json from the COCO folder.
"""
import json
import os

import numpy as np


def lying_image_ids(coco_root, split="train"):
    js = json.load(open(os.path.join(coco_root, "annotations", f"person_keypoints_{split}2017.json"),
                        encoding="utf-8"))
    ids = set()
    for a in js["annotations"]:
        if a.get("iscrowd") or a["num_keypoints"] < 8:
            continue
        k = np.array(a["keypoints"], np.float64).reshape(17, 3)
        sh, hp = k[[5, 6]], k[[11, 12]]
        if (sh[:, 2] > 0).sum() == 0 or (hp[:, 2] > 0).sum() == 0:
            continue
        v = sh[sh[:, 2] > 0, :2].mean(0) - hp[hp[:, 2] > 0, :2].mean(0)
        if np.degrees(np.arctan2(abs(v[0]), -v[1])) > 60:
            ids.add(a["image_id"])
    return ids
