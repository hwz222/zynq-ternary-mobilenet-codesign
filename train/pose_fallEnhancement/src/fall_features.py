"""Per-frame person track and joints for the fall detector (host model, fake-quantised; not the board).

Input: the frames (zip of images or mp4) and the per-frame person boxes written by
train/coco_det's src/video_boxes.py. Output: one JSON per sequence with, per frame, the tracked box,
how it was obtained, the crop rotation used and the 14 joints in frame pixels. src/fall_rules.py turns
this into fall alarms; nothing here decides about falls. Per frame: a list of tracks
{id, how (det | joints | hold), score, box, rot, conf, tilt, kp}.

Three ways to get the person, so their effect can be measured separately:
  --mode best    the best box >= 0.3 of each frame, no memory between frames (the earlier two-stage demo)
  --mode track   person tracks (up to 4): a weaker box (>= 0.1) next to a track is accepted; with no box a
                 track follows the joints of the previous frame for up to --hold seconds (see associate)
  --rot          also run the pose model on the crop turned by +-90 degrees when the person is wide or
                 tilted, and keep the orientation with the higher joint confidence

  python -m src.fall_features --boxes ../coco_det/runs/urfd_boxes --frames data/urfd --mode track --rot \
      --out runs/fall/track_rot
"""
import argparse
import glob
import json
import os
import zipfile

import cv2
import numpy as np
import torch

from src.config import IMAGE_MEAN, IMAGE_STD
from src.demo import load

MEAN = np.array(IMAGE_MEAN, np.float32)
STD = np.array(IMAGE_STD, np.float32)
BODY = [2, 3, 8, 9, 10, 11, 12, 13, 1]          # shoulders, hips, knees, ankles, neck: the joints the rules use


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


def crop_matrix(box, rot):
    """Frame -> 256x256 crop: a square 1.25 x the longer box side around the box centre (the MPII
    crop margin, as src/demo.py), turned by rot degrees (counter-clockwise on screen)."""
    x0, y0, x1, y1 = box[:4]
    side = max(x1 - x0, y1 - y0) * 1.25
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    M = cv2.getRotationMatrix2D((cx, cy), rot, 256.0 / side)
    M[0, 2] += 128 - cx
    M[1, 2] += 128 - cy
    return M.astype(np.float32)


@torch.no_grad()
def pose(model, rgb, box, rots, device="cuda"):
    """Joints for each crop rotation: list of (14 x 3 array [x, y, conf] in frame pixels, mean body conf)."""
    Ms = [crop_matrix(box, r) for r in rots]
    x = np.stack([(cv2.warpAffine(rgb, M, (256, 256), flags=cv2.INTER_LINEAR).astype(np.float32) / 255 - MEAN) / STD
                  for M in Ms]).transpose(0, 3, 1, 2)
    hm = model(torch.from_numpy(np.ascontiguousarray(x)).to(device)).float().cpu().numpy()
    out = []
    for M, h in zip(Ms, hm):
        K, H, W = h.shape
        idx = h.reshape(K, -1).argmax(1)
        py, px = np.divmod(idx, W)
        fx, fy = px.astype(np.float32), py.astype(np.float32)
        for k in range(K):
            if 0 < px[k] < W - 1:
                fx[k] += 0.25 * np.sign(h[k, py[k], px[k] + 1] - h[k, py[k], px[k] - 1])
            if 0 < py[k] < H - 1:
                fy[k] += 0.25 * np.sign(h[k, py[k] + 1, px[k]] - h[k, py[k] - 1, px[k]])
        conf = h[np.arange(K), py, px]
        Mi = cv2.invertAffineTransform(M)
        pts = np.stack([fx * 4, fy * 4, np.ones(K, np.float32)], 1) @ Mi.T
        out.append((np.concatenate([pts, conf[:, None]], 1), float(conf[BODY].mean())))
    return out


def iou(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    i = ix * iy
    return i / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i + 1e-9)


def joint_box(kp, w, h, thr=0.3, pad=0.15):
    """Box around the confident joints, padded; None when fewer than 6 joints are confident."""
    ok = kp[:, 2] > thr
    if ok.sum() < 6:
        return None
    x0, y0 = kp[ok, 0].min(), kp[ok, 1].min()
    x1, y1 = kp[ok, 0].max(), kp[ok, 1].max()
    p = pad * max(x1 - x0, y1 - y0)
    return [max(0.0, x0 - p), max(0.0, y0 - p), min(w - 1.0, x1 + p), min(h - 1.0, y1 + 2 * p)]


def associate(tracks, dets, w, h, hold_s, fps, max_tracks):
    """One step of the tracker. Each track takes the free box (>= 0.1) that overlaps it most (IoU >= 0.2,
    weighted by score); a track without a box follows its joints of the previous frame, else its last
    box, for up to hold_s; a box >= 0.3 that overlaps no track starts a new one. Several tracks run at
    once because a fixed camera also sees person-like things (a chair with a coat) that score as high as
    the person; a static thing never shows the change of a fall, so every track is judged on its own."""
    free = [d for d in sorted(dets, key=lambda d: -d[4]) if d[4] >= 0.1]
    area = lambda b: max(b[2] - b[0], 1.0) * max(b[3] - b[1], 1.0)
    for t in sorted(tracks, key=lambda t: t["held"]):
        # a person's box changes gradually even in a fall; a box half or twice the size in one frame is
        # another object next to the person (a bag on the floor, the couch the person sits on)
        cand = [(iou(d, t["box"]), d) for d in free if 0.5 <= area(d) / area(t["box"]) <= 2.0]
        cand = [(o, d) for o, d in cand if o >= 0.2]
        if cand:
            _, d = max(cand, key=lambda c: c[0] * c[1][4])
            free.remove(d)
            t.update(box=list(map(float, d[:4])), score=float(d[4]), how="det", held=0)
        elif t["held"] < hold_s * fps:
            jb = joint_box(t["kp"], w, h) if t["kp"] is not None else None
            t.update(box=jb if jb is not None else t["box"], score=0.0, how="joints" if jb is not None else "hold",
                     held=t["held"] + 1)
        else:
            t["how"] = "gone"
    tracks[:] = [t for t in tracks if t["how"] != "gone"]
    keep = []                                        # two tracks on one person: keep the older
    for t in sorted(tracks, key=lambda t: t["id"]):
        if all(iou(t["box"], k["box"]) < 0.6 for k in keep):
            keep.append(t)
    tracks[:] = keep
    for d in free:
        if d[4] >= 0.3 and len(tracks) < max_tracks and all(iou(d, t["box"]) < 0.3 for t in tracks):
            tracks.append({"id": associate.next_id, "box": list(map(float, d[:4])), "score": float(d[4]),
                           "how": "det", "held": 0, "kp": None, "tilt": 0.0})
            associate.next_id += 1


def run(model, src, boxes, mode, rot, fps, hold_s, max_tracks=4):
    seq, tracks = [], []
    associate.next_id = 0
    for n, rgb in enumerate(frames(src)):
        h, w = rgb.shape[:2]
        dets = boxes[n] if n < len(boxes) else []
        if mode == "best":
            good = [d for d in dets if d[4] >= 0.3]
            d = max(good, key=lambda d: d[4]) if good else None
            tracks = [] if d is None else [{"id": 0, "box": list(map(float, d[:4])), "score": float(d[4]),
                                            "how": "det", "held": 0, "kp": None, "tilt": 0.0}]
        else:
            associate(tracks, dets, w, h, hold_s, fps, max_tracks)
        out = []
        for t in tracks:
            box = t["box"]
            bw, bh = box[2] - box[0], box[3] - box[1]
            rots = [0, 90, -90] if rot and (bw > 0.8 * bh or t["tilt"] > 40) else [0]
            res = pose(model, rgb, box, rots)
            k = int(np.argmax([c for _, c in res]))
            kp, conf = res[k]
            v = kp[[2, 3], :2].mean(0) - kp[[8, 9], :2].mean(0)
            t["kp"], t["tilt"] = kp, float(np.degrees(np.arctan2(abs(v[0]), -v[1])))
            out.append({"id": t["id"], "how": t["how"], "score": round(t["score"], 3),
                        "box": [round(float(v), 1) for v in box], "rot": rots[k], "conf": round(conf, 3),
                        "tilt": round(t["tilt"], 1),
                        "kp": [[round(float(a), 1), round(float(b), 1), round(float(c), 3)] for a, b, c in kp]})
        seq.append(out)
    return seq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=os.path.join("..", "..", "artifacts", "pose_fallEnhancement",
                                                   "pose_fallEnhancement_best.pth"))
    ap.add_argument("--boxes", required=True, help="folder of <seq>.json from train/coco_det's src/video_boxes.py")
    ap.add_argument("--frames", required=True, help="folder holding <seq>-cam0-rgb.zip or <seq>.mp4")
    ap.add_argument("--mode", choices=["best", "track"], default="track")
    ap.add_argument("--rot", action="store_true")
    ap.add_argument("--hold", type=float, default=1.5, help="seconds a track survives without a box")
    ap.add_argument("--fps", type=float, default=30)
    ap.add_argument("--only", nargs="*", help="sequence names to run (default: every box file)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    model = load(a.ckpt)
    os.makedirs(a.out, exist_ok=True)
    for bf in sorted(glob.glob(os.path.join(a.boxes, "*.json"))):
        name = os.path.splitext(os.path.basename(bf))[0]
        if a.only and name not in a.only:
            continue
        srcs = glob.glob(os.path.join(a.frames, name + "-cam0-rgb.zip")) + glob.glob(os.path.join(a.frames, name + ".mp4"))
        if not srcs:
            print(f"{name}: no frames found, skipped")
            continue
        seq = run(model, srcs[0], json.load(open(bf))["frames"], a.mode, a.rot, a.fps, a.hold)
        json.dump({"source": srcs[0], "mode": a.mode, "rot": a.rot, "fps": a.fps, "frames": seq},
                  open(os.path.join(a.out, name + ".json"), "w"))
        print(f"{name}: {len(seq)} frames, {len({t['id'] for f in seq for t in f})} tracks, track-frames " + ", ".join(
            f"{k} {sum(t['how'] == k for f in seq for t in f)}" for k in ("det", "joints", "hold")))


if __name__ == "__main__":
    main()
