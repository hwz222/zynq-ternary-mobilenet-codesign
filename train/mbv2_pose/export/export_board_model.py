#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Checkpoint -> the file set of models/mbv2_pose/ (the FUSED streaming board toolchain).

This is the export script of the earlier, non-public research code base, second half ("fused (board) export chain"),
reduced to the three steps that produce models/mbv2_pose, in the same order and with the same
environment variables:

  1. extract_mbv2.py --strict-int8 --ckpt CKPT
       TWN_OUT_SRC/DATA/GOLD -> model_meta.c, model_meta.h, model_mbv2.bin, fix_0..3.bin
  2. pack_ternary.py            (TWN_OUT_DATA, TWN_OUT_HLS)
       -> model_mbv2_packed.bin (2-bit ternary ROM + int8 section), pack_meta_mbv2.h
  3. append_hd_pl.py            -> head weights appended in the engine's stream order
       (blob 1,222,880 B -> 1,420,000 B; HD_PL_* defines added to pack_meta_mbv2.h)

That script's other steps (the per-layer "twn_top" line: extract_mbv2.py without
--strict-int8, build.bat, mbv2_pose.exe; and the downstream P1 gate, pack_fuse_weights.py,
gen_desctab.py, gen_fuse_ddr.py) are not part of what lands in models/mbv2_pose. The
downstream tools live in the project's tools/ and golden/ directories.

Before exporting, the ternary check of train/README.md runs on the checkpoint: every ternarised
layer must have weights in {-1,0,+1} before the scale, with zeros present. A failing model is
not exported.

  python export/export_board_model.py --ckpt checkpoints/probe_tern_dc32/best.pth --out <dir>

Writes <dir>/models_layout/{model_mbv2.bin, model_mbv2_packed.bin, model_meta.c, model_meta.h,
pack_meta_mbv2.h, fixtures/fix_0..3.bin}. Pass --install to write straight into models/mbv2_pose
of the project.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)                         # train/mbv2_pose
PROJECT = os.path.dirname(os.path.dirname(REPO))     # project root
sys.path.insert(0, REPO)


def sha16(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()[:16]


def ternary_gate(ckpt):
    import torch
    from src.build_model import build_quant, region_keys
    tk, pk = region_keys("mbv2", 1.0, None, 32, "pw_stem")
    m = build_quant("mbv2", 1.0, None, 32, tk, pk)
    m.eval()
    with torch.no_grad():
        m(torch.zeros(1, 3, 256, 256))
    m.load_state_dict(torch.load(ckpt, map_location="cpu", weights_only=False)["model"])
    rep = m.verify_all_ternary()
    bad = [r["name"] for r in rep if not r["ok"]]
    nz = sum(1 for r in rep if r["frac_zero"] > 0)
    print(f"[ternary gate] {len(rep)} ternary layers, all in {{-1,0,+1}}+zeros: "
          f"{'PASS' if not bad else 'FAIL ' + str(bad)}  (layers with zeros: {nz}; "
          f"zero fraction min {min(r['frac_zero'] for r in rep):.3f} "
          f"max {max(r['frac_zero'] for r in rep):.3f})")
    if bad or len(rep) != len(tk):
        sys.exit("GATE FAIL: ternary check (%d layers verified, %d expected)" % (len(rep), len(tk)))


def run(args, env):
    print("+", " ".join(args))
    r = subprocess.run([sys.executable] + args, env=env, cwd=REPO)
    if r.returncode != 0:
        sys.exit("GATE FAIL: %s exited %d" % (args[0], r.returncode))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=os.path.join(REPO, "checkpoints", "probe_tern_dc32", "best.pth"))
    ap.add_argument("--out", default=None, help="scratch output directory (default runs/export/<name>)")
    ap.add_argument("--install", action="store_true",
                    help="write into <project>/models/mbv2_pose instead of --out")
    a = ap.parse_args()
    ckpt = os.path.abspath(a.ckpt)
    assert os.path.isfile(ckpt), ckpt
    out = os.path.abspath(a.out or os.path.join(REPO, "runs", "export",
                                                os.path.basename(os.path.dirname(ckpt))))
    iso = os.path.join(out, "export_strict_int8")
    for d in ("src", "data", "golden", "hls"):
        os.makedirs(os.path.join(iso, d), exist_ok=True)

    print("checkpoint", ckpt, sha16(ckpt))
    ternary_gate(ckpt)

    env = dict(os.environ)
    env["PYTHONUTF8"] = "1"
    env["PYTHONPATH"] = REPO
    env["TWN_CKPT"] = ckpt
    for v in ("TWN_EXTRA_ANNOT", "TWN_EXTRA_IMAGE_DIR", "TWN_EXTRA_SPLITS", "TWN_HEAD_PROJ",
              "TWN_INPUT_SIZE"):
        env.pop(v, None)
    e1 = dict(env, TWN_OUT_SRC=os.path.join(iso, "src"), TWN_OUT_DATA=os.path.join(iso, "data"),
              TWN_OUT_GOLD=os.path.join(iso, "golden"))
    run([os.path.join(HERE, "extract_mbv2.py"), "--strict-int8", "--ckpt", ckpt], e1)
    e2 = dict(env, TWN_OUT_DATA=os.path.join(iso, "data"), TWN_OUT_HLS=os.path.join(iso, "hls"))
    run([os.path.join(HERE, "pack_ternary.py")], e2)
    run([os.path.join(HERE, "append_hd_pl.py"),
         os.path.join(iso, "data", "model_mbv2_packed.bin"),
         os.path.join(iso, "hls", "pack_meta_mbv2.h")], env)

    dst = os.path.join(PROJECT, "models", "mbv2_pose") if a.install else os.path.join(out, "models_layout")
    os.makedirs(os.path.join(dst, "fixtures"), exist_ok=True)
    mapping = [("data/model_mbv2.bin", "model_mbv2.bin"),
               ("data/model_mbv2_packed.bin", "model_mbv2_packed.bin"),
               ("src/model_meta.c", "model_meta.c"), ("src/model_meta.h", "model_meta.h"),
               ("hls/pack_meta_mbv2.h", "pack_meta_mbv2.h")] + \
              [("golden/fix_%d.bin" % k, "fixtures/fix_%d.bin" % k) for k in range(4)]
    for s, d in mapping:
        shutil.copyfile(os.path.join(iso, s), os.path.join(dst, d))
        print("  %-28s %s" % (d, sha16(os.path.join(dst, d))))
    print("[export done]", dst)


if __name__ == "__main__":
    main()
