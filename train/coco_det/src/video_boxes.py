"""Person boxes for every frame of a video or a zip of frames, for train/pose_fallEnhancement's fall
detector (host model, fake-quantised; not the board). Keeps every person box down to --thr so the
tracker on the other side can pick up weak detections next to a known person.

  python -m src.video_boxes --ckpt ../../artifacts/coco_det/det12v2_tern_probe_cont_best_bn.pth \
      --inputs <urfd-dir>/*-cam0-rgb.zip --out-dir runs/urfd_boxes

Output, one JSON per input: {"source", "width", "height", "thr", "frames": [[[x0,y0,x1,y1,score], ...], ...]}
in frame pixels, frame order as read (zip members sorted by name).
"""
import argparse
import glob
import json
import os
import zipfile

import cv2
import numpy as np

from src.demo import detect, load


def frames(path):
    """RGB frames of an .mp4 or of a .zip of images (sorted by name)."""
    if path.lower().endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            for n in sorted(n for n in z.namelist() if n.lower().endswith((".png", ".jpg"))):
                bgr = cv2.imdecode(np.frombuffer(z.read(n), np.uint8), cv2.IMREAD_COLOR)
                yield cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    else:
        cap = cv2.VideoCapture(path)
        while True:
            ok, bgr = cap.read()
            if not ok:
                break
            yield cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--inputs", nargs="+", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--thr", type=float, default=0.05)
    a = ap.parse_args()
    m = load(a.ckpt)
    os.makedirs(a.out_dir, exist_ok=True)
    paths = sorted(p for g in a.inputs for p in glob.glob(g))
    for p in paths:
        name = os.path.basename(p).replace("-cam0-rgb", "").rsplit(".", 1)[0]
        out = os.path.join(a.out_dir, name + ".json")
        if os.path.exists(out):
            continue
        fr, hw = [], None
        for rgb in frames(p):
            hw = rgb.shape[:2]
            fr.append([[round(float(v), 1) for v in d[:4]] + [round(d[4], 3)]
                       for d in detect(m, rgb, a.thr) if d[5] == 0])
        json.dump({"source": p, "width": hw[1], "height": hw[0], "thr": a.thr, "frames": fr}, open(out, "w"))
        print(f"{name}: {len(fr)} frames, {sum(len(f) > 0 for f in fr)} with a person box")


if __name__ == "__main__":
    main()
