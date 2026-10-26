#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Is the remaining lower-body error in the backbone or in the head?

WHAT IS ALREADY SETTLED, from data in hand. The deployed ternary model and the INT8 control
have the SAME head -- three transposed convolutions at 32 channels plus a 1x1, INT8 in both
-- and differ only in how the backbone's pointwise weights are quantized. Ankle 75.13 vs
79.04. Same head, 3.91 points apart, so THAT gap lives in the backbone.

WHAT IS NOT SETTLED. The 32-channel head was cut down to save MACs (the compression study
called the deconv head the cheapest capacity to remove). It may be a ceiling sitting above
BOTH models, in which case improving the backbone further buys nothing until the head is
widened -- and widening it costs an RTL change, since the head engine is built for 32.

THE PROBE. Freeze the backbone, throw the head away, and fit a fresh head of a given width
on those frozen features. Whatever the head can reach is an upper bound on the information
the backbone actually passes forward. Run it at 32 (today's width) and at 128 on each
backbone:
    wide - narrow, same backbone   = how much the head is costing
    int8 - ternary, same width     = how much the quantization is costing
Comparing those two numbers answers the question quantitatively rather than by argument.

Deliberately NOT the champion recipe: no KD, no flip consistency, no mining. This is a
capacity probe, so the head should be fitted as directly as possible to the ground truth,
and dropping the teacher forward also makes it fast.

  python -m src.probe_head_capacity tern|int8 <deconv_ch> [epochs]
"""
import os
import sys

import torch

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))     # train/mbv2_pose
sys.path.insert(0, REPO)

from src.config import EXP_DIR, SPORTS_ANNOT, SPORTS_IMAGES              # noqa: E402
# setdefault, not assignment: a caller (src.run_recipe) may name further sources to mix in.
# Hard assignments would silently drop them and refit the head on a distribution the backbone
# was not trained for. With setdefault, calling it directly is unchanged.
os.environ.setdefault("TWN_EXTRA_ANNOT", SPORTS_ANNOT)
os.environ.setdefault("TWN_EXTRA_IMAGE_DIR", SPORTS_IMAGES)
os.environ.setdefault("TWN_EXTRA_SPLITS", "train")

from src.build_model import build_quant, region_keys, set_seed            # noqa: E402
from src.mbv2_model import _init_head                                      # noqa: E402
from src.train import train                                                # noqa: E402

SRC = {
    "tern": (os.path.join(EXP_DIR, "sports_r2_w3", "best.pth"), "pw_stem"),
    "int8": (os.path.join(EXP_DIR, "sports_r3_w3", "best.pth"), ""),
}


def main():
    which = (sys.argv[1] if len(sys.argv) > 1 else "tern").lower()
    ch = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    epochs = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    # TWN_HEAD_SRC names any backbone checkpoint; without it the two original probes resolve
    # exactly as they did, so their recorded numbers stay reproducible.
    override = os.environ.get("TWN_HEAD_SRC", "")
    if override:
        ckpt = override if os.path.isabs(override) else os.path.join(
            EXP_DIR, override, "best.pth")
        region = "" if which == "int8" else "pw_stem"
        assert os.path.exists(ckpt), ckpt
    else:
        assert which in SRC, __doc__
        ckpt, region = SRC[which]

    twn, pc = region_keys("mbv2", 1.0, None, ch, region) if region else (set(), set())
    set_seed()
    m = build_quant("mbv2", 1.0, None, ch, twn, pc)
    m.eval()
    with torch.no_grad():                     # materialise Brevitas buffers before loading
        m(torch.zeros(1, 3, 256, 256))

    sd = torch.load(ckpt, map_location="cpu", weights_only=False)
    sd = sd.get("model", sd)
    own = m.state_dict()
    # backbone only: the head is deliberately left at its fresh initialisation so that the
    # 32 and 128 runs start from the same place and the comparison is about capacity, not
    # about one of them inheriting a trained head
    keep = {k: v for k, v in sd.items()
            if k in own and own[k].shape == v.shape
            and not k.startswith(("deconv_layers", "final_layer"))}
    m.load_state_dict(keep, strict=False)
    _init_head(m.deconv_layers, m.final_layer)

    n_frozen = 0
    for name, p in m.named_parameters():
        if not name.startswith(("deconv_layers", "final_layer")):
            p.requires_grad_(False)
            n_frozen += p.numel()
    n_train = sum(p.numel() for p in m.parameters() if p.requires_grad)
    # Without this the override run would be called probe_tern_dc32 as well and would
    # overwrite the checkpoint directory of the model currently ON THE BOARD.
    exp_id = "probe_%s_dc%d" % (which, ch)
    if override:
        exp_id = "%s_head%d" % (os.path.basename(os.path.dirname(ckpt)), ch)
    assert not (override and os.path.abspath(os.path.join(EXP_DIR, exp_id))
                == os.path.abspath(os.path.dirname(ckpt))), \
        "refit would overwrite its own source checkpoint"
    print("[%s] backbone=%s from %s | frozen %d params, training %d (head only)"
          % (exp_id, which, os.path.basename(os.path.dirname(ckpt)), n_frozen, n_train))
    print("[%s] restored %d backbone tensors, head re-initialised" % (exp_id, len(keep)))

    best = train(m, exp_id, epochs=epochs, lr=1e-3, lr_steps=(int(epochs * 0.6),
                 int(epochs * 0.85)), gamma=0.1, batch=48, workers=4,
                 eval_every=1, eval_tail=epochs)
    print("[%s] best PCKh = %.3f" % (exp_id, best))


if __name__ == "__main__":
    main()
