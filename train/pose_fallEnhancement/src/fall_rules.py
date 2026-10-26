"""Fall alarms from the per-frame track and joints of src/fall_features.py, and their score on the URFD
labels. Pure post-processing (what the processor would run after the accelerator), no network here.

A fall is a fast change from an upright person to a person low and lying, so the rule looks at the
change, not at one frame:
  reference height  median box height of the recent upright frames (box narrower than UP_ASPECT)
  down              box wider than DOWN_ASPECT, or box lower than DOWN_LOW x the reference height (a person
                    lying along the camera's line of sight stays narrow but becomes low), or (with --pose)
                    torso tilted more than DOWN_TILT degrees from vertical while the box is lower than
                    DOWN_HEIGHT x the reference height
  alarm             at least DEBOUNCE down frames among the last 10 (the box of a person on the floor
                    flickers between down and in-between), the person was upright at most WINDOW s before
                    the first of them, and the track has been upright for at least MIN_UP frames in all (a
                    track born on a cushion or a bag has no upright history), and between the last
                    upright frame and now the top of the box came down at MIN_DROP reference heights per
                    second or faster somewhere (over at most 0.2 s); the alarm stays until the track is
                    upright at 0.75 x the reference height or more for 0.5 s (a track that slid onto a
                    bag next to the fallen person does not clear it)
Every track of src/fall_features.py is judged on its own; the alarm is on while any track's is.

Score on URFD (labels per frame: -1 not lying, 0 falling, 1 lying on the floor):
  fall sequence  hit when the first alarm comes at or after (first falling frame - 0.5 s); an alarm
                 before that is a false alarm. Latency = alarm frame - first "lying" frame (negative:
                 the alarm came before the person was on the floor).
  ADL sequence   any alarm is a false alarm.

  python -m src.fall_rules runs/fall/track_rot --pose [--split odd|even|all] [--json out.json]
"""
import argparse
import csv
import glob
import json
import os

import numpy as np

URFD = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "urfd")

# Defaults = the parameters src.fall_tune chose for the track + rotation features with the box rule
# (runs/fall/tune/track_rot_box.json; results/task_results.json, entry fall_detect_urfd_20261013).
P = dict(UP_ASPECT=0.6, UP_TILT=35.0, DOWN_ASPECT=1.2, DOWN_LOW=0.0, DOWN_TILT=55.0, DOWN_HEIGHT=0.7,
         MIN_CONF=0.2, DEBOUNCE=3, WINDOW=1.0, REF_FRAMES=60, MIN_UP=10, MIN_DROP=1.0)
RECENT = 10


_CACHE = {}


def labels():
    lab = {}
    for f in ("falls", "adls"):
        p = os.path.join(URFD, f"urfall-cam0-{f}.csv")
        for r in csv.reader(open(p)):
            lab.setdefault(r[0], {})[int(r[1]) - 1] = int(r[2])
    return lab


def frame_states(frames, use_pose, p=P):
    """Per frame: 'up', 'down', 'mid' or 'none', plus the reference height used."""
    out, ups = [], []
    for f in frames:
        if f["how"] == "none":
            out.append(("none", None))
            continue
        x0, y0, x1, y1 = f["box"]
        w, h = x1 - x0, y1 - y0
        asp = w / max(h, 1e-6)
        pose_ok = use_pose and f["conf"] >= p["MIN_CONF"]
        tilt = f["tilt"] if pose_ok else None
        ref = float(np.median(ups[-p["REF_FRAMES"]:])) if len(ups) >= p["MIN_UP"] else None
        if asp < p["UP_ASPECT"] and (tilt is None or tilt < p["UP_TILT"]):
            ups.append(h)
            out.append(("up", ref))
            continue
        low = ref is not None and h < p["DOWN_HEIGHT"] * ref
        if (asp > p["DOWN_ASPECT"] or (ref is not None and h < p["DOWN_LOW"] * ref)
                or (tilt is not None and tilt > p["DOWN_TILT"] and low)):
            out.append(("down", ref))
        else:
            out.append(("mid", ref))
    return out


def drop_speed(frames, a, b, ref, fps):
    """Fastest descent of the top of the box between frames a and b, in reference heights per second,
    over spans of at most 0.2 s."""
    tops = [(k, frames[k]["box"][1]) for k in range(a, b + 1) if frames[k]["how"] != "none"]
    span = max(1, round(0.2 * fps))
    return max([(tops[m][1] - tops[k][1]) / ref * fps / (tops[m][0] - tops[k][0])
                for k in range(len(tops)) for m in range(k + 1, len(tops)) if tops[m][0] - tops[k][0] <= span],
               default=0.0)


def alarms(frames, fps, use_pose, p=P):
    """Per frame: True while the fall alarm is on."""
    st = frame_states(frames, use_pose, p)
    on, last_up, stood, res = False, None, 0, []
    for i, (s, ref) in enumerate(st):
        if s == "up":
            last_up = i
            h = frames[i]["box"][3] - frames[i]["box"][1]
            stood = stood + 1 if ref is None or h >= 0.75 * ref else 0
        else:
            stood = 0
        if on and stood >= round(0.5 * fps):        # standing again, at full height, for 0.5 s: clear
            on = False
        downs = [k for k in range(max(0, i - RECENT + 1), i + 1) if st[k][0] == "down"]
        if (not on and s == "down" and len(downs) >= p["DEBOUNCE"] and last_up is not None
                and downs[0] - last_up <= p["WINDOW"] * fps and ref is not None
                and (p["MIN_DROP"] <= 0 or drop_speed(frames, last_up, i, ref, fps) >= p["MIN_DROP"])):
            on = True
        res.append(on)
    return res


def per_track(frames):
    """{track id: per-frame list of that track's record, {"how": "none"} where it is absent}."""
    ids = sorted({t["id"] for f in frames for t in f})
    out = {i: [{"how": "none"}] * len(frames) for i in ids}
    for n, f in enumerate(frames):
        for t in f:
            out[t["id"]][n] = t
    return out


def alarms_all(frames, fps, use_pose, p=P):
    """(per-frame alarm of any track, {track id: per-frame states}, {track id: per-frame alarms})."""
    tr = per_track(frames)
    st = {i: frame_states(s, use_pose, p) for i, s in tr.items()}
    al = {i: alarms(s, fps, use_pose, p) for i, s in tr.items()}
    anyal = [any(al[i][n] for i in al) for n in range(len(frames))]
    return anyal, st, al


def score(folder, use_pose, split="all", p=P, verbose=False):
    if "labels" not in _CACHE:
        _CACHE["labels"] = labels()
    lab = _CACHE["labels"]
    rows = []
    for jf in sorted(glob.glob(os.path.join(folder, "*.json"))):
        name = os.path.splitext(os.path.basename(jf))[0]
        num = int(name.split("-")[1])
        if split == "odd" and num % 2 == 0 or split == "even" and num % 2 == 1:
            continue
        if jf not in _CACHE:
            _CACHE[jf] = json.load(open(jf))
        J = _CACHE[jf]
        al = alarms_all(J["frames"], J["fps"], use_pose, p)[0]
        first = next((i for i, a in enumerate(al) if a), None)
        r = {"seq": name, "frames": len(al), "first_alarm": first}
        if name.startswith("fall"):
            L = lab[name]
            f0 = min(i for i, v in L.items() if v == 0)
            f1 = min((i for i, v in L.items() if v == 1), default=None)
            early = [i for i, a in enumerate(al) if a and i < f0 - 0.5 * J["fps"]]
            hit = next((i for i, a in enumerate(al) if a and i >= f0 - 0.5 * J["fps"]), None)
            r.update(falling_from=f0, lying_from=f1, false_alarm=bool(early), hit=hit is not None,
                     alarm=hit, latency_s=None if hit is None or f1 is None else round((hit - f1) / J["fps"], 2),
                     after_onset_s=None if hit is None else round((hit - f0) / J["fps"], 2))
        else:
            r.update(false_alarm=first is not None)
        rows.append(r)
        if verbose:
            print(r)
    falls = [r for r in rows if r["seq"].startswith("fall")]
    adls = [r for r in rows if r["seq"].startswith("adl")]
    lat = [r["latency_s"] for r in falls if r["latency_s"] is not None]
    aft = [r["after_onset_s"] for r in falls if r["after_onset_s"] is not None]
    summ = {"falls": len(falls), "hits": sum(r["hit"] for r in falls),
            "fall_seq_false_alarm": sum(r["false_alarm"] for r in falls),
            "adls": len(adls), "adl_false_alarm": sum(r["false_alarm"] for r in adls),
            "latency_vs_lying_median_s": float(np.median(lat)) if lat else None,
            "latency_vs_lying_max_s": float(np.max(lat)) if lat else None,
            "after_falling_onset_median_s": float(np.median(aft)) if aft else None}
    return summ, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--pose", action="store_true", help="use the torso tilt from the joints, not only the box")
    ap.add_argument("--split", choices=["odd", "even", "all"], default="all")
    ap.add_argument("--set", nargs="*", default=[], help="override a parameter: NAME=value")
    ap.add_argument("--json")
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    p = dict(P)
    for kv in a.set:
        k, v = kv.split("=")
        p[k] = type(P[k])(v)
    summ, rows = score(a.folder, a.pose, a.split, p, a.v)
    print(json.dumps(summ))
    if a.json:
        json.dump({"folder": a.folder, "pose": a.pose, "split": a.split, "params": p, "summary": summ, "rows": rows},
                  open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
