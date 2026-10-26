"""Render detections on images or a video (host model, fake-quantised; not the board).

  python -m src.demo --ckpt checkpoints/<exp>/best.pth --video in.mp4 --out out.mp4 [--seconds 20]
  python -m src.demo --ckpt ... --images a.jpg b.jpg --out dir/
"""
import argparse
import os

import cv2
import numpy as np
import torch

from src import config as C
from src.centernet import decode
from src.data import letterbox_matrix, to_input
from src.qmodel import Mbv2Quant, materialize

COLORS = [(220, 20, 60), (0, 140, 255), (0, 200, 200), (250, 170, 30), (230, 90, 160),
          (120, 60, 200), (110, 200, 110), (60, 110, 160), (40, 40, 220), (200, 200, 0),
          (0, 200, 120), (180, 120, 60)]          # RGB per class


def load(ckpt, device="cuda"):
    m = Mbv2Quant()
    materialize(m)
    sd = torch.load(ckpt, map_location="cpu", weights_only=False)
    m.load_state_dict(sd.get("model", sd))
    return m.to(device).eval()


@torch.no_grad()
def detect(model, rgb, thr=0.3, device="cuda"):
    h, w = rgb.shape[:2]
    M = letterbox_matrix(w, h)
    _, x = to_input(rgb, M)
    d = decode(model(x[None].to(device)), k=50)[0].cpu().numpy()
    s, tx, ty = M[0, 0], M[0, 2], M[1, 2]
    out = []
    for x0, y0, x1, y1, sc, c in d:
        if sc >= thr:
            out.append(((x0 - tx) / s, (y0 - ty) / s, (x1 - tx) / s, (y1 - ty) / s, float(sc), int(c)))
    return out


def draw(rgb, dets):
    img = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    th = max(2, img.shape[1] // 320)
    for x0, y0, x1, y1, sc, c in dets:
        col = COLORS[c][::-1]
        p0, p1 = (int(x0), int(y0)), (int(x1), int(y1))
        cv2.rectangle(img, p0, p1, col, th)
        lab = f"{C.CLASSES[c][0]} {sc:.2f}"
        fs = 0.4 + img.shape[1] / 1600
        (tw, tht), _ = cv2.getTextSize(lab, cv2.FONT_HERSHEY_SIMPLEX, fs, 1)
        cv2.rectangle(img, (p0[0], max(0, p0[1] - tht - 6)), (p0[0] + tw + 4, max(tht + 6, p0[1])), col, -1)
        cv2.putText(img, lab, (p0[0] + 2, max(tht + 2, p0[1] - 4)), cv2.FONT_HERSHEY_SIMPLEX, fs,
                    (255, 255, 255), 1, cv2.LINE_AA)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--video")
    ap.add_argument("--images", nargs="*")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--thr", type=float, default=0.3)
    ap.add_argument("--width", type=int, default=960)
    ap.add_argument("--boxes-out", help="write per-frame person boxes [x0,y0,x1,y1,score] (frame pixels) to this JSON")
    a = ap.parse_args()
    m = load(a.ckpt)
    if a.images:
        os.makedirs(a.out, exist_ok=True)
        for p in a.images:
            rgb = cv2.cvtColor(cv2.imread(p), cv2.COLOR_BGR2RGB)
            cv2.imwrite(os.path.join(a.out, os.path.splitext(os.path.basename(p))[0] + "_det.jpg"),
                        draw(rgb, detect(m, rgb, a.thr)))
        return
    cap = cv2.VideoCapture(a.video)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    cap.set(cv2.CAP_PROP_POS_MSEC, a.start * 1000)
    wr, n, boxes = None, 0, []
    while n < a.seconds * fps:
        ok, bgr = cap.read()
        if not ok:
            break
        if bgr.shape[1] > a.width:
            bgr = cv2.resize(bgr, (a.width, round(bgr.shape[0] * a.width / bgr.shape[1])), interpolation=cv2.INTER_AREA)
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        dets = detect(m, rgb, a.thr)
        boxes.append([[round(float(v), 1) for v in d[:5]] for d in dets if d[5] == 0])
        frame = draw(rgb, dets)
        if wr is None:
            wr = cv2.VideoWriter(a.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (frame.shape[1], frame.shape[0]))
        wr.write(frame)
        n += 1
    if wr:
        wr.release()
    if a.boxes_out:
        import json
        json.dump({"video": a.video, "start": a.start, "width": a.width, "frames": boxes}, open(a.boxes_out, "w"))
    print(f"{n} frames -> {a.out}")


if __name__ == "__main__":
    main()
