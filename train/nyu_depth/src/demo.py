"""Render predicted depth next to the image (host model, fake-quantised; not the board).
Colour map TURBO, near = red, far = blue, fixed 0-6 m range with a scale bar.

  python -m src.demo --ckpt checkpoints/<exp>/best.pth --video in.mp4 --out out.mp4 [--seconds 20]
  python -m src.demo --ckpt ... --images a.jpg b.jpg --out dir/
"""
import argparse
import os

import cv2
import numpy as np
import torch

from src.evaluate import predict_depth
from src.qmodel import Mbv2Quant, materialize

DMAX = 6.0


def load(ckpt, device="cuda"):
    m = Mbv2Quant()
    materialize(m)
    sd = torch.load(ckpt, map_location="cpu", weights_only=False)
    m.load_state_dict(sd.get("model", sd))
    return m.to(device).eval()


def colour(depth):
    v = np.clip(1.0 - depth / DMAX, 0, 1)                    # near -> 1 -> red end of TURBO
    return cv2.applyColorMap((v * 255).astype(np.uint8), cv2.COLORMAP_TURBO)


def scale_bar(h, w=36):
    v = np.linspace(1, 0, h)[:, None].repeat(w, 1)
    bar = cv2.applyColorMap((v * 255).astype(np.uint8), cv2.COLORMAP_TURBO)
    fs = 0.35 + h / 1600
    for m in range(0, int(DMAX) + 1, 2):
        y = int(m / DMAX * (h - 1))
        cv2.putText(bar, f"{m}m", (1, min(h - 3, max(12, y + 4))), cv2.FONT_HERSHEY_SIMPLEX, fs,
                    (255, 255, 255), 1, cv2.LINE_AA)
    return bar


def draw(rgb, depth):
    img = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    return np.concatenate([img, colour(depth), scale_bar(img.shape[0])], axis=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--video")
    ap.add_argument("--images", nargs="*")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--width", type=int, default=640)
    a = ap.parse_args()
    m = load(a.ckpt)
    if a.images:
        os.makedirs(a.out, exist_ok=True)
        for p in a.images:
            rgb = cv2.cvtColor(cv2.imread(p), cv2.COLOR_BGR2RGB)
            cv2.imwrite(os.path.join(a.out, os.path.splitext(os.path.basename(p))[0] + "_depth.jpg"),
                        draw(rgb, predict_depth(m, rgb)))
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
        frame = draw(rgb, predict_depth(m, rgb))
        if wr is None:
            wr = cv2.VideoWriter(a.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (frame.shape[1], frame.shape[0]))
        wr.write(frame)
        n += 1
    if wr:
        wr.release()
    print(f"{n} frames -> {a.out}")


if __name__ == "__main__":
    main()
