#!/usr/bin/env python3
"""Put demo videos of the same clip side by side in a grid, each with a title bar.

  python tools/demo_montage.py --out grid.mp4 --cols 2 a.mp4:"Pose" b.mp4:"Detection" d.mp4:"Depth":right ...

A third field `right` keeps only the part of the frame right of its middle (minus a 36-px scale bar on
the right), for side-by-side image|map videos such as train/nyu_depth's demo output.

Every input is scaled to the first one's height; the grid stops at the shortest input.
Only composes finished videos; it runs no model.
"""
import argparse

import cv2
import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--cols", type=int, default=2)
    ap.add_argument("--cell-height", type=int, default=360)
    ap.add_argument("inputs", nargs="+", help="path:title")
    a = ap.parse_args()
    caps, titles, crops = [], [], []
    for s in a.inputs:
        p, _, rest = s.partition(":")
        t, _, crop = rest.partition(":")
        caps.append(cv2.VideoCapture(p)); titles.append(t or p); crops.append(crop)
    fps = caps[0].get(cv2.CAP_PROP_FPS) or 30
    H = a.cell_height
    bar = max(24, H // 12)
    wr = None
    n = 0
    while True:
        cells = []
        for c, t, crop in zip(caps, titles, crops):
            ok, f = c.read()
            if not ok:
                cells = None
                break
            if crop == "right":
                f = f[:, (f.shape[1] - 36) // 2:]
            f = cv2.resize(f, (round(f.shape[1] * H / f.shape[0]), H), interpolation=cv2.INTER_AREA)
            head = np.full((bar, f.shape[1], 3), 32, np.uint8)
            cv2.putText(head, t, (8, int(bar * 0.72)), cv2.FONT_HERSHEY_SIMPLEX, bar / 40, (255, 255, 255), 1, cv2.LINE_AA)
            cells.append(np.concatenate([head, f], 0))
        if cells is None:
            break
        W = max(x.shape[1] for x in cells)
        cells = [np.pad(x, ((0, 0), (0, W - x.shape[1]), (0, 0))) for x in cells]
        while len(cells) % a.cols:
            cells.append(np.zeros_like(cells[0]))
        rows = [np.concatenate(cells[i:i + a.cols], 1) for i in range(0, len(cells), a.cols)]
        frame = np.concatenate(rows, 0)
        if wr is None:
            wr = cv2.VideoWriter(a.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (frame.shape[1], frame.shape[0]))
        wr.write(frame)
        n += 1
    if wr:
        wr.release()
    print(f"{n} frames -> {a.out}")


if __name__ == "__main__":
    main()
