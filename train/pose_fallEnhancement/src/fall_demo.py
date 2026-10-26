"""Fall-detection demo video: the tracked person, the joints, the state of src/fall_rules.py and a time
strip of box shape and torso tilt (host models, fake-quantised; not the board).

  python -m src.fall_demo runs/fall/track_rot/fall-01.json --pose --out runs/fall/demo/fall-01.mp4
"""
import argparse
import json
import os

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from src.demo import draw
from src.fall_features import frames
from src.fall_rules import P, alarms_all, labels, per_track

# Banner font: FALL_DEMO_FONT if set, else the first TrueType font found, else PIL's built-in font.
FONT = os.environ.get("FALL_DEMO_FONT", "")
COL = {"up": (60, 200, 60), "mid": (0, 200, 255), "down": (0, 0, 255), "none": (128, 128, 128)}   # BGR
STRIP = 110


def _font(size):
    for f in (FONT, "DejaVuSans.ttf", "arial.ttf"):
        if f:
            try:
                return ImageFont.truetype(f, size)
            except OSError:
                pass
    return ImageFont.load_default()


def text(img, xy, s, size, fill):
    im = Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    ImageDraw.Draw(im).text(xy, s, font=_font(size), fill=fill)
    return cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)


def strip(frames_, al, i, w, lab):
    """Time strip: box width/height (white) and torso tilt / 90 (cyan) per frame, alarm frames red,
    URFD 'lying' frames marked grey along the bottom; the cursor is the current frame."""
    s = np.full((STRIP, w, 3), 24, np.uint8)
    n = len(frames_)
    xs = lambda k: int(k * (w - 1) / max(n - 1, 1))
    base, top = STRIP - 14, 8
    ys = lambda v: int(base - min(v, 2.0) / 2.0 * (base - top))
    for k in range(n):
        if al[k]:
            cv2.line(s, (xs(k), top), (xs(k), base), (0, 0, 110), max(1, w // n + 1))
        if lab.get(k) == 1:
            cv2.line(s, (xs(k), base + 4), (xs(k), STRIP - 2), (150, 150, 150), max(1, w // n + 1))
    cv2.line(s, (0, ys(1.0)), (w, ys(1.0)), (70, 70, 70), 1)
    pa = pt = None
    for k in range(n):
        f = frames_[k]
        if f["how"] == "none":
            pa = pt = None
            continue
        x0, y0, x1, y1 = f["box"]
        a = (x1 - x0) / max(y1 - y0, 1e-6)
        t = f["tilt"] / 90.0 if f["conf"] >= P["MIN_CONF"] else None
        if pa is not None:
            cv2.line(s, pa, (xs(k), ys(a)), (230, 230, 230), 1, cv2.LINE_AA)
        pa = (xs(k), ys(a))
        if t is not None and pt is not None:
            cv2.line(s, pt, (xs(k), ys(t)), (255, 220, 0), 1, cv2.LINE_AA)
        pt = (xs(k), ys(t)) if t is not None else None
    cv2.line(s, (xs(i), 0), (xs(i), STRIP), (0, 255, 255), 1)
    cv2.putText(s, "box w/h", (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (230, 230, 230), 1, cv2.LINE_AA)
    cv2.putText(s, "torso tilt/90", (80, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 220, 0), 1, cv2.LINE_AA)
    cv2.putText(s, "alarm", (200, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (60, 60, 230), 1, cv2.LINE_AA)
    cv2.putText(s, "URFD lying", (255, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (150, 150, 150), 1, cv2.LINE_AA)
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("features", help="<seq>.json from src.fall_features")
    ap.add_argument("--pose", action="store_true")
    ap.add_argument("--params", help="JSON from src.fall_tune (its 'params'); default: fall_rules.P")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    p = json.load(open(a.params))["params"] if a.params else P
    J = json.load(open(a.features))
    fr, fps = J["frames"], J["fps"]
    al, st, tal = alarms_all(fr, fps, a.pose, p)
    tr = per_track(fr)

    def motion(i):          # the strip shows the track that alarms first, else the one whose shape changes most
        first = next((n for n, v in enumerate(tal[i]) if v), None)
        asp = [(t["box"][2] - t["box"][0]) / max(t["box"][3] - t["box"][1], 1e-6) for t in tr[i] if t["how"] != "none"]
        return (first is None, first or 0, -np.std(asp) if asp else 0)
    main_id = min(tr, key=motion) if tr else None
    name = os.path.splitext(os.path.basename(a.features))[0]
    lab = labels().get(name, {})
    t_alarm = next((k for k, v in enumerate(al) if v), None)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    wr = None
    for i, rgb in enumerate(frames(J["source"])):
        img = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
        shown = sorted(fr[i], key=lambda t: t["id"] == main_id)
        for t in shown:
            if t["id"] == main_id:
                img = draw(cv2.cvtColor(img, cv2.COLOR_BGR2RGB), [tuple(p) for p in t["kp"]], thr=0.15)
            x0, y0, x1, y1 = map(int, t["box"])
            cv2.rectangle(img, (x0, y0), (x1, y1), COL[st[t["id"]][i][0]], 2 if t["id"] == main_id else 1)
        h, w = img.shape[:2]
        if al[i]:
            cv2.rectangle(img, (0, 0), (w, 44), (0, 0, 200), -1)
            img = text(img, (10, 4), f"FALL DETECTED  {(i - t_alarm) / fps:4.1f} s", 30, (255, 255, 255))
        else:
            cv2.rectangle(img, (0, 0), (w, 44), (40, 40, 40), -1)
            s = st[main_id][i][0] if main_id is not None else "none"
            msg = {"up": "upright", "mid": "posture change", "down": "low", "none": "no person"}[s]
            img = text(img, (10, 4), msg, 30, (255, 255, 255))
        img = text(img, (w - 190, 50), f"{name}  {i / fps:5.1f} s", 18, (255, 255, 0))
        sfr = tr[main_id] if main_id is not None else [{"how": "none"}] * len(fr)
        frame = np.vstack([img, strip(sfr, al, i, w, lab)])
        if wr is None:
            wr = cv2.VideoWriter(a.out, cv2.VideoWriter_fourcc(*"mp4v"), fps, (frame.shape[1], frame.shape[0]))
        wr.write(frame)
    if wr:
        wr.release()
    print(f"{len(fr)} frames -> {a.out}; first alarm at frame {t_alarm}")


if __name__ == "__main__":
    main()
