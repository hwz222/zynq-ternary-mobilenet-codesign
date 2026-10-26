#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""score_old_ckpts.py -- re-score checkpoints of the earlier research repository on the one ruler,
and count each network's weights and multiply-accumulates.

Reads   <old repo>/experiments/<name>/best.pth, result.json (layer lists and the orchestrator's
        figure) and metrics.jsonl (the training loop's figure); the old repository's model code
        (src/, experiments/); MPII val through the old repository's src/dataset.py.
Writes  the JSON named by --out: per experiment the standalone PCKh (mean, joint groups, per
        joint), the checkpoint's SHA-256, and the network's weight count, weight bytes at the
        precision each layer is built with, and multiply-accumulates (MACs) for one 256x256
        input, by layer kind. Nothing is written into the old repository (no bytecode either).

The ruler is the old repository's scripts/score_ckpt.py: MPII single-person val, 2,289 instances,
PCKh@0.5 over 14 joints, src/evaluate.py over a DataLoader, the checkpoint loaded on its own (not
the training loop's figure). That script builds only the MobileNetV2 family; this one also builds
ResNet-18 SimpleBaseline, its depthwise-separable and compressed variants, and MobileNetV2 with a
wider or skip-connected head, each from the old repository's own model classes.

Weight bytes count convolution weights only (2 bits per ternary weight, 1 byte per INT8 weight,
4 bytes per float weight); BatchNorm, biases and scales are excluded.

    python tools/score_old_ckpts.py --old-repo <path> --out results/raw/<file>.json [names...]

Run from the repository root in the training environment (conda env twn).
"""
import argparse
import hashlib
import json
import os
import sys
import time

sys.dont_write_bytecode = True

# name -> (family, options). Families are built by build() below.
SPECS = {
    "fp32_baseline": ("r18_float", {}),
    "int8_baseline": ("r18_quant", {}),
    "twn_s4b1": ("r18_quant", {}),
    "twn_s4": ("r18_quant", {}),
    "twn_s34": ("r18_quant", {}),
    "twn_s234": ("r18_quant", {}),
    "twn_s1234": ("r18_quant", {}),
    "twn_bk_stem": ("r18_quant", {}),
    "twn_bk_deconv": ("r18_quant", {}),
    "twn_no_final": ("r18_quant", {}),
    "twn_bk_final": ("r18_quant", {}),
    "twn_all": ("r18_quant", {}),
    "mbv2_fp": ("mbv2_float", {"dc": 256}),
    "mbv2_dc32_fp": ("mbv2_float", {"dc": 32}),
    "mbv2_dc32_pwstem": ("mbv2_quant", {"dc": 32, "region": "pw_stem"}),
    "mbv2_dc32_bbpc": ("mbv2_quant", {"dc": 32, "region": "backbone_pcdw"}),
    "probe_tern_dc128": ("mbv2_quant", {"dc": 128, "region": "pw_stem"}),
    "probe_int8_dc128": ("mbv2_quant", {"dc": 128, "region": "int8"}),
    "probe_skip_dc32": ("mbv2_skip", {"dc": 32, "region": "pw_stem"}),
    "dsc_fp": ("dsc_float", {}),
    "dsc_pw": ("dsc_quant", {}),
    "dsc_pwdw": ("dsc_quant", {}),
    "dsc_dc32_fp": ("dsc_float", {}),
    "dsc_dc32_pwstem": ("dsc_quant", {}),
    "dsc_dc32_bbpc": ("dsc_quant", {}),
    "c_dc64": ("comp_quant", {}),
    "h_dc64_i8": ("comp_quant", {}),
    "h_b2221_s4w256_dc32_i8": ("comp_quant", {}),
}

EXTRA_ENV = ("TWN_EXTRA_ANNOT", "TWN_EXTRA_IMAGE_DIR", "TWN_EXTRA_SPLITS")


def sha256_16(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def loop_best(exp_dir):
    """Highest PCKh the training loop printed into metrics.jsonl (None when absent)."""
    p = os.path.join(exp_dir, "metrics.jsonl")
    if not os.path.isfile(p):
        return None
    best = None
    with open(p, encoding="utf-8") as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            for k, v in r.items():
                if "pckh" in k.lower() and isinstance(v, (int, float)):
                    best = v if best is None else max(best, v)
    return best


def build(family, opt, result):
    """Construct the network an experiment was trained as, from the old repository's classes."""
    import torch.nn as nn  # noqa: F401
    if family == "r18_float":
        from src.model import PoseResNet18
        return PoseResNet18(deconv_ch=256)
    if family == "r18_quant":
        from src.quant_model import PoseResNet18Quant, QuantConfig
        return PoseResNet18Quant(QuantConfig(twn_keys=result["twn_keys"]), deconv_ch=256)
    if family in ("mbv2_float",):
        from src.mbv2_model import PoseMBV2
        return PoseMBV2(width_mult=1.0, deconv_ch=opt["dc"], pretrained=False)
    if family in ("mbv2_quant", "mbv2_skip"):
        from experiments.sep_orchestrate import build_quant, region_keys
        twn, pc = (set(), set()) if opt["region"] == "int8" else \
            region_keys("mbv2", 1.0, None, opt["dc"], opt["region"])
        m = build_quant("mbv2", 1.0, None, opt["dc"], twn, pc)
        if family == "mbv2_skip":
            import torch
            m.eval()
            with torch.no_grad():
                m(torch.zeros(1, 3, 256, 256))
            from experiments.probe_skip_head import SkipHead   # sets TWN_EXTRA_* on import
            for v in EXTRA_ENV:
                os.environ.pop(v, None)
            m = SkipHead(m, ch=opt["dc"])
        return m
    from src.compress_model import ArchSpec, PoseResNetC, PoseResNetCQuant, derive_arch
    from src.quant_model import QuantConfig
    a = result["arch"]
    sep = family.startswith("dsc")
    blocks = tuple(a["blocks"])
    override = None
    if not sep:
        derived = derive_arch(a["width_mult"], blocks, a["deconv_ch"], None)[0]
        if list(derived) != list(a["channels"]):
            override = list(a["channels"])
    arch = ArchSpec(a["width_mult"], blocks, a["deconv_ch"], channels_override=override,
                    separable=sep)
    if family == "dsc_float":
        return PoseResNetC(arch)
    return PoseResNetCQuant(arch, QuantConfig(twn_keys=result["twn_keys"],
                                              twn_pc_keys=result.get("twn_pc_keys", [])))


def count(model, dev):
    """Weights, weight bytes and MACs for one 256x256 input, by layer kind."""
    import torch
    import torch.nn as nn
    rows, seen_first = [], [False]

    def hook(name):
        def f(mod, inp, out):
            n_w = mod.weight.numel()
            if hasattr(mod, "quant_weight"):
                bits = float(mod.quant_weight().bit_width)
            else:
                bits = 32.0
            if isinstance(mod, nn.ConvTranspose2d):
                kind = "deconv"
                macs = inp[0].numel() // inp[0].shape[0] * (mod.out_channels // mod.groups) \
                    * mod.kernel_size[0] * mod.kernel_size[1]
            else:
                macs = out.numel() // out.shape[0] * (mod.in_channels // mod.groups) \
                    * mod.kernel_size[0] * mod.kernel_size[1]
                if "final_layer" in name:
                    kind = "output_1x1"
                elif not seen_first[0]:
                    kind = "stem"
                elif mod.groups > 1:
                    kind = "depthwise"
                elif mod.kernel_size == (1, 1):
                    kind = "conv1x1"
                else:
                    kind = "conv_kxk"
            seen_first[0] = True
            rows.append({"name": name, "kind": kind, "weights": n_w, "bits": bits, "macs": macs})
        return f

    hs = [m.register_forward_hook(hook(n)) for n, m in model.named_modules()
          if isinstance(m, (nn.Conv2d, nn.ConvTranspose2d))]
    with torch.no_grad():
        model(torch.zeros(1, 3, 256, 256, device=dev))
    for h in hs:
        h.remove()
    by_kind = {}
    for r in rows:
        k = by_kind.setdefault(r["kind"], {"layers": 0, "weights": 0, "weight_bytes": 0.0,
                                           "macs": 0, "bits": []})
        k["layers"] += 1
        k["weights"] += r["weights"]
        k["weight_bytes"] += r["weights"] * r["bits"] / 8.0
        k["macs"] += r["macs"]
        if r["bits"] not in k["bits"]:
            k["bits"].append(r["bits"])
    total = {"layers": len(rows), "weights": sum(r["weights"] for r in rows),
             "weight_bytes": sum(r["weights"] * r["bits"] / 8.0 for r in rows),
             "macs": sum(r["macs"] for r in rows),
             "ternary_weights": sum(r["weights"] for r in rows if r["bits"] == 2.0),
             "ternary_macs": sum(r["macs"] for r in rows if r["bits"] == 2.0)}
    return by_kind, total


def score_one(name, old, dev):
    import torch
    from src.dataset import MPIIDataset
    from src.evaluate import evaluate
    family, opt = SPECS[name]
    exp_dir = os.path.join(old, "experiments", name)
    ckpt = os.path.join(exp_dir, "best.pth")
    if os.path.getsize(ckpt) < 4096:
        raise SystemExit("%s is a Git LFS pointer, not the weights" % ckpt)
    rpath = os.path.join(exp_dir, "result.json")
    result = json.load(open(rpath, encoding="utf-8")) if os.path.isfile(rpath) else {}

    model = build(family, opt, result)
    model.eval()
    with torch.no_grad():
        model(torch.zeros(1, 3, 256, 256))          # materialise Brevitas lazy submodules
    sd = torch.load(ckpt, map_location="cpu", weights_only=False)
    sd = sd.get("model", sd)
    want = model.state_dict()
    bad = [k for k in sd if k in want and tuple(sd[k].shape) != tuple(want[k].shape)]
    absent = [k for k in want if (k.endswith(".weight") or k.endswith(".bias")) and k not in sd]
    if bad or absent:
        raise SystemExit("REFUSED %s: %d shape mismatches (e.g. %s), %d weights absent (e.g. %s)"
                         % (name, len(bad), bad[:2], len(absent), absent[:2]))
    inc = model.load_state_dict(sd, strict=False)
    model.to(dev).eval()

    for v in EXTRA_ENV:
        os.environ.pop(v, None)
    ds = MPIIDataset("valid", augment=False)
    if len(ds) != 2289:
        raise SystemExit("ruler broken: MPII val has %d instances, expected 2289" % len(ds))
    dl = torch.utils.data.DataLoader(ds, batch_size=32, shuffle=False, num_workers=0)
    t0 = time.time()
    res = evaluate(model, dl, dev)
    by_kind, total = count(model, dev)
    return {
        "family": family, "options": opt,
        "checkpoint": "experiments/%s/best.pth" % name,
        "checkpoint_sha256_16": sha256_16(ckpt),
        "n_val": len(ds),
        "pckh_mean": round(float(res["PCKh"]), 3),
        "groups": {g: round(float(v), 2) for g, v in res["groups"].items()},
        "per_joint": [round(float(v), 2) for v in res["per_joint"]],
        "orchestrator_figure": result.get("PCKh"),
        "training_loop_best": loop_best(exp_dir),
        "relay_from": result.get("relay_from"),
        "twn_keys": result.get("twn_keys"),
        "loaded_tensors": len(sd),
        "model_keys_missing": len(inc.missing_keys),
        "checkpoint_keys_unused": len(inc.unexpected_keys),
        "by_kind": by_kind, "total": total,
        "eval_seconds": round(time.time() - t0, 1),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--old-repo", required=True, help="root of the earlier research repository")
    ap.add_argument("--out", required=True, help="JSON file to write (merged if it exists)")
    ap.add_argument("names", nargs="*", help="experiments to score (default: all in SPECS)")
    a = ap.parse_args()
    old = os.path.abspath(a.old_repo)
    sys.path.insert(0, old)
    for v in EXTRA_ENV:
        os.environ.pop(v, None)
    import torch
    import brevitas
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    out = json.load(open(a.out, encoding="utf-8")) if os.path.isfile(a.out) else {}
    out["_env"] = {"torch": torch.__version__, "brevitas": brevitas.__version__, "device": dev,
                   "old_repo": old.replace(os.sep, "/")}
    for name in (a.names or list(SPECS)):
        r = score_one(name, old, dev)
        out[name] = r
        print("%-24s %8.3f   loop %s   orchestrator %s   weights %d   MACs %d"
              % (name, r["pckh_mean"], r["training_loop_best"], r["orchestrator_figure"],
                 r["total"]["weights"], r["total"]["macs"]), flush=True)
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
