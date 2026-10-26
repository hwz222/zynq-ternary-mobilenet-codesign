#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Launch one stage of the board model's recipe from its config file.

The entry point (src.probe_head_capacity) takes its data sources from environment variables
that the caller has to set; getting them wrong silently drops a source (see the notes in
probe_head_capacity.py). This launcher sets them from the config, and
protects the final checkpoint: training writes best.pth/last.pth into the work directory and
RESUMES from last.pth when it exists, so it never runs inside checkpoints/.

    python -m src.run_recipe configs/probe_tern_dc32.json --stage B --workdir runs/probe_tern_dc32

The checkpoints a stage needs (config "needs") are copied from checkpoints/<name>/best.pth into
the work directory first; the stage writes <workdir>/<produces>/ (for probe_tern_dc32:
<workdir>/probe_tern_dc32/, starting from checkpoints/sports_r2_w3/best.pth).
--epochs N overrides the epoch count (smoke tests only; the recipe value is in the config).
"""
import argparse
import json
import os
import runpy
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))    # train/mbv2_pose
sys.path.insert(0, REPO)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    ap.add_argument("--stage", required=True, choices=["A", "B"])
    ap.add_argument("--workdir", default=None)
    ap.add_argument("--epochs", type=int, default=None)
    a = ap.parse_args()
    cfg = json.load(open(a.config, encoding="utf-8"))
    st = cfg["stages"][a.stage]
    work = os.path.abspath(a.workdir or os.path.join(REPO, "runs", cfg["exp_id"]))
    if os.path.abspath(work) == os.path.join(REPO, "checkpoints"):
        sys.exit("refusing to train inside checkpoints/ (it would resume from or overwrite the shipped files)")
    os.makedirs(work, exist_ok=True)
    os.environ["TWN_EXP_DIR"] = work          # read by src.config at import: set it first

    for role, name in st["needs"].items():
        dst = os.path.join(work, name, "best.pth")
        if not os.path.isfile(dst):
            src = os.path.join(REPO, "checkpoints", name, "best.pth")
            assert os.path.isfile(src), "missing %s (%s)" % (src, role)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
            print("[recipe] %s: copied %s -> %s" % (role, src, dst))
    out = os.path.join(work, st["produces"])
    if os.path.isfile(os.path.join(out, "last.pth")):
        print("[recipe] WARNING: %s exists, training will RESUME from it" % out)

    from src.config import SPORTS_ANNOT, SPORTS_IMAGES
    for k, v in st.get("env", {}).items():
        os.environ[k] = v
    if "extra_sources" in st:        # stage B: the caller must name every extra source
        src = {"sports": (SPORTS_ANNOT, SPORTS_IMAGES)}
        names = st["extra_sources"]
        os.environ["TWN_EXTRA_ANNOT"] = ",".join(src[n][0] for n in names)
        os.environ["TWN_EXTRA_IMAGE_DIR"] = ",".join(src[n][1] for n in names)
        os.environ["TWN_EXTRA_SPLITS"] = "train"
    argv = list(st["argv"])
    if a.epochs is not None:
        argv[2] = str(a.epochs)          # the entry point takes epochs as the third argument
    sys.argv = [st["entry"]] + argv
    print("[recipe] stage %s: python -m %s %s  (TWN_EXP_DIR=%s)" % (a.stage, st["entry"], " ".join(argv), work))
    runpy.run_module(st["entry"], run_name="__main__", alter_sys=True)


if __name__ == "__main__":
    main()
