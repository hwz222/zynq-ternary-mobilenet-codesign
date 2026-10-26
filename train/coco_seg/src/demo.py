"""Render the 16-class segmentation on images or a video (host model, fake-quantised; not the board).

  python -m src.demo --ckpt checkpoints/<exp>/best.pth --video in.mp4 --out out.mp4 [--seconds 20]
  python -m src.demo --ckpt ... --images a.jpg b.jpg --out dir/
"""
import argparse
import os

import cv2
import numpy as np
import torch

from src import config as C
from src.evaluate import predict_label
from src.qmodel import Mbv2Quant, materialize

PAL = np.array(C.PALETTE, np.uint8)


def load(ckpt, device="cuda"):
    m = Mbv2Quant()
    materialize(m)
    sd = torch.load(ckpt, map_location="cpu", weights_only=False)
    m.load_state_dict(sd.get("model", sd))
    return m.to(device).eval()


def draw(rgb, lab, alpha=0.55, legend=True):
    col = PAL[lab].astype(np.float32)
    a = np.where(lab[..., None] == 0, 0.0, alpha)          # class 0 "other" is left uncoloured
    mix = (rgb.astype(np.float32) * (1 - a) + col * a).astype(np.uint8)
    img = cv2.cvtColor(mix, cv2.COLOR_RGB2BGR)
    if legend:
        present = [k for k in np.unique(lab) if k != 0 and (lab == k).mean() > 0.01]
        fs = 0.4 + img.shape[1] / 1800
        y = 8
        for k in present:
            (tw, th), _ = cv2.getTextSize(C.CLASSES[k][0], cv2.FONT_HERSHEY_SIMPLEX, fs, 1)
            cv2.rectangle(img, (6, y), (6 + th + 4, y + th + 4), tuple(int(v) for v in PAL[k][::-1]), -1)
            cv2.rectangle(img, (10 + th + 4, y), (14 + th + 4 + tw, y + th + 4), (0, 0, 0), -1)
            cv2.putText(img, C.CLASSES[k][0], (12 + th + 4, y + th + 1), cv2.FONT_HERSHEY_SIMPLEX, fs,
                        (255, 255, 255), 1, cv2.LINE_AA)
            y += th + 10
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
            cv2.imwrite(os.path.join(a.out, os.path.splitext(os.path.basename(p))[0] + "_seg.jpg"),
                        draw(rgb, predict_label(m, rgb)))
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
        frame = draw(rgb, predict_label(m, rgb))
        if wr is None:
            wr = cv2.VideoWriter(a.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (frame.shape[1], frame.shape[0]))
        wr.write(frame)
        n += 1
    if wr:
        wr.release()
    print(f"{n} frames -> {a.out}")


if __name__ == "__main__":
    main()
