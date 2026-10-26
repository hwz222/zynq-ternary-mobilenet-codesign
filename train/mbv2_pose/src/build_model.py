"""Model construction for the board model: region keys (which convs are ternary) and the
Brevitas quantised MobileNetV2 builder.

Extracted VERBATIM from the experiment orchestrator (sep_orchestrate.py) of the earlier, non-public
research code base (functions set_seed,
region_keys, build_quant, constant TEACHER). The rest of that file (the DSC-ResNet branch of
region_keys/build_quant, the experiment matrix, finalize, write_table, main) is not used by the
board model's training or export and was left out. In region_keys/build_quant only the
`if model == "dsc"` branches were removed; the MobileNetV2 code is unchanged.
"""
import os
import random

import numpy as np
import torch

from src.config import EXP_DIR
from src.mbv2_model import PoseMBV2Quant, mbv2_region_keys
from src.quant_model import QuantConfig

TEACHER = os.path.join(EXP_DIR, "fp32_baseline", "best.pth")


def set_seed(s=42):
    random.seed(s); np.random.seed(s); torch.manual_seed(s); torch.cuda.manual_seed_all(s)


def region_keys(model, width, blocks, deconv_ch, region):
    """-> (twn_keys, pc_keys): per-TENSOR ternary paths, per-CHANNEL ternary paths.

    Anything in neither set stays INT8. pc_keys wins over twn_keys (QuantConfig routes it
    first), so `backbone_pcdw` can name the whole backbone as ternary while upgrading only
    the depthwise convs to a per-output-channel alpha.
    """
    if region in ("float", "int8"):
        return set(), set()
    pw, dw, stem = mbv2_region_keys(width)
    if region == "pw_stem":
        return pw | stem, set()
    if region == "pw_stem_pc":
        return pw | stem, pw | stem      # pw+stem ternary, per-output-channel alpha (HW-free)
    if region == "pw_deep":              # deep->shallow limit: ternarize only pointwise in the
        return {p for p in pw if int(p.split(".")[1]) >= 7}, set()   # deeper blocks (features>=7)
    if region == "pw_mid":               # a shallower cut: pointwise from features>=4
        return {p for p in pw if int(p.split(".")[1]) >= 4}, set()
    if region == "pw_sh3":               # shallower still: pointwise from features>=3
        return {p for p in pw if int(p.split(".")[1]) >= 3}, set()
    if region == "pw_sh2":               # shallower still: pointwise from features>=2
        return {p for p in pw if int(p.split(".")[1]) >= 2}, set()
    if region == "backbone_pcdw":
        return pw | stem, dw
    return {"pw": pw, "pw_dw": pw | dw, "backbone": pw | dw | stem,
            "no_final": pw | dw | stem | {"deconv"},
            "all": pw | dw | stem | {"deconv", "final"}}[region], set()


def build_quant(model, width, blocks, deconv_ch, twn_keys, pc_keys=()):
    cfg = QuantConfig(twn_keys=twn_keys, twn_pc_keys=pc_keys)
    return PoseMBV2Quant(cfg, width_mult=width, deconv_ch=deconv_ch)
