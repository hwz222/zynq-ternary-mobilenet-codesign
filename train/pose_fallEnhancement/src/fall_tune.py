"""Choose the parameters of src/fall_rules.py on one half of URFD and report them on the other half.

The tuning half is the odd-numbered sequences (15 falls, 20 ADL), the test half the even-numbered ones.
Objective on the tuning half: hits - 2 x false alarms (a false alarm in a home costs more than a late
one), ties broken by the median delay after the falling onset.

  python -m src.fall_tune runs/fall/track_rot --pose --json runs/fall/tune_track_rot_pose.json
"""
import argparse
import itertools
import json

from src.fall_rules import P, score

GRID = dict(DOWN_ASPECT=[0.9, 1.0, 1.2], DOWN_LOW=[0.0, 0.35, 0.45], DOWN_TILT=[55.0, 65.0, 999.0],
            DOWN_HEIGHT=[0.5, 0.7], WINDOW=[1.0, 1.5, 2.0, 3.0], DEBOUNCE=[3, 6], MIN_DROP=[0.0, 0.5, 1.0])


def objective(s):
    return (s["hits"] - 2 * (s["adl_false_alarm"] + s["fall_seq_false_alarm"]),
            -(s["after_falling_onset_median_s"] if s["after_falling_onset_median_s"] is not None else 99))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--pose", action="store_true")
    ap.add_argument("--json")
    a = ap.parse_args()
    keys = list(GRID)
    if not a.pose:
        keys.remove("DOWN_TILT")
        keys.remove("DOWN_HEIGHT")
    best = None
    for vals in itertools.product(*(GRID[k] for k in keys)):
        p = dict(P, **dict(zip(keys, vals)))
        s, _ = score(a.folder, a.pose, "odd", p)
        if best is None or objective(s) > objective(best[1]):
            best = (p, s)
    p, s_tune = best
    s_test, rows = score(a.folder, a.pose, "even", p)
    s_all, rows_all = score(a.folder, a.pose, "all", p)
    print("params", json.dumps({k: p[k] for k in keys}))
    print("tune (odd) ", json.dumps(s_tune))
    print("test (even)", json.dumps(s_test))
    print("all        ", json.dumps(s_all))
    if a.json:
        json.dump({"folder": a.folder, "pose": a.pose, "grid": {k: GRID[k] for k in keys}, "params": p,
                   "tune_odd": s_tune, "test_even": s_test, "all": s_all, "rows_all": rows_all},
                  open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
