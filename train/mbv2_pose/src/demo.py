"""Render the pose model's skeleton on images or a video (host model, fake-quantised; not the board).

The input is prepared as the board's camera app does it (sw/app/main_cam.c): the centre square of
the frame, shifted down by 6 % of its side, resized to 256x256. Joints are the arg-max of each
heatmap with the quarter-pixel shift towards the higher neighbour.

  python -m src.demo --ckpt checkpoints/probe_tern_dc32/best.pth --video in.mp4 --out out.mp4
"""
import argparse
import os

import cv2
import numpy as np
import torch

from src.build_model import build_quant, region_keys
from src.config import IMAGE_MEAN, IMAGE_STD

EDGES = [(0, 1), (1, 2), (1, 3), (2, 4), (4, 6), (3, 5), (5, 7), (2, 8), (3, 9), (8, 9),
         (8, 10), (10, 12), (9, 11), (11, 13)]
RIGHT = {2, 4, 6, 8, 10, 12}


def load(ckpt, device="cuda"):
    twn, pc = region_keys("mbv2", 1.0, None, 32, "pw_stem")
    m = build_quant("mbv2", 1.0, None, 32, twn, pc)
    m.eval()
    with torch.no_grad():
        m(torch.zeros(1, 3, 256, 256))
    sd = torch.load(ckpt, map_location="cpu")
    m.load_state_dict(sd.get("model", sd))
    return m.to(device).eval()


def crop_box(w, h, shift=0.06):
    side = min(w, h)
    cx, cy = w / 2, h / 2 + shift * side
    return cx - side / 2, cy - side / 2, side


@torch.no_grad()
def keypoints(model, rgb, device="cuda"):
    h, w = rgb.shape[:2]
    x0, y0, side = crop_box(w, h)
    s = 256 / side
    M = np.array([[s, 0, -x0 * s], [0, s, -y0 * s]], np.float32)
    inp = cv2.warpAffine(rgb, M, (256, 256), flags=cv2.INTER_LINEAR)
    t = (inp.astype(np.float32) / 255 - np.array(IMAGE_MEAN, np.float32)) / np.array(IMAGE_STD, np.float32)
    hm = model(torch.from_numpy(t.transpose(2, 0, 1).copy())[None].to(device))[0].float().cpu().numpy()
    K, H, W = hm.shape
    pts = []
    for k in range(K):
        i = int(hm[k].argmax())
        py, px = divmod(i, W)
        fx, fy = float(px), float(py)
        if 0 < px < W - 1:
            fx += 0.25 * np.sign(hm[k, py, px + 1] - hm[k, py, px - 1])
        if 0 < py < H - 1:
            fy += 0.25 * np.sign(hm[k, py + 1, px] - hm[k, py - 1, px])
        pts.append((x0 + fx * 4 / s, y0 + fy * 4 / s, float(hm[k, py, px])))
    return pts


def draw(rgb, pts, thr=0.2):
    img = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    th = max(2, img.shape[1] // 300)
    for a, b in EDGES:
        if pts[a][2] > thr and pts[b][2] > thr:
            col = (0, 140, 255) if (a in RIGHT or b in RIGHT) else (255, 200, 0)
            cv2.line(img, (int(pts[a][0]), int(pts[a][1])), (int(pts[b][0]), int(pts[b][1])), col, th, cv2.LINE_AA)
    for x, y, c in pts:
        if c > thr:
            cv2.circle(img, (int(x), int(y)), th + 2, (0, 0, 255), -1, cv2.LINE_AA)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--video")
    ap.add_argument("--images", nargs="*")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--width", type=int, default=960)
    a = ap.parse_args()
    m = load(a.ckpt)
    if a.images:
        os.makedirs(a.out, exist_ok=True)
        for p in a.images:
            rgb = cv2.cvtColor(cv2.imread(p), cv2.COLOR_BGR2RGB)
            cv2.imwrite(os.path.join(a.out, os.path.splitext(os.path.basename(p))[0] + "_pose.jpg"),
                        draw(rgb, keypoints(m, rgb)))
        return
    cap = cv2.VideoCapture(a.video)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    cap.set(cv2.CAP_PROP_POS_MSEC, a.start * 1000)
    wr, n = None, 0
    while n < a.seconds * fps:
        ok, bgr = cap.read()
        if not ok:
            break
        if bgr.shape[1] > a.width:
            bgr = cv2.resize(bgr, (a.width, round(bgr.shape[0] * a.width / bgr.shape[1])), interpolation=cv2.INTER_AREA)
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        frame = draw(rgb, keypoints(m, rgb))
        if wr is None:
            wr = cv2.VideoWriter(a.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (frame.shape[1], frame.shape[0]))
        wr.write(frame)
        n += 1
    if wr:
        wr.release()
    print(f"{n} frames -> {a.out}")


if __name__ == "__main__":
    main()
