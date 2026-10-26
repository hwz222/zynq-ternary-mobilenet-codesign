"""The network the accelerator runs, as a Brevitas quantised model with a 16-channel output.

Copied from train/mbv2_pose/src (mbv2_model.py, quant_model.py, compress_model._qconv,
build_model.region_keys) and trimmed to what this workspace needs. The module tree and every
parameter name are the same as the pose model's, so the pose backbone loads by name:

  input_quant                        int8 activation quantiser on the normalised image
  features.0 .. features.17          MobileNetV2 stem + 17 inverted residuals (stride 32, 320 ch)
  deconv_layers.{0,3,6}              three 4x4 stride-2 transposed convs, 32 channels each
  final_layer                        1x1 conv, 32 -> OUT_CH (16, the hardware's op64 width)

Quantisation ("pw_stem" region, the one the board runs): the 34 pointwise 1x1 convs of the
backbone and the 3x3 stem are ternary {-1,0,+1} with one scale per tensor (src/twn.py); depthwise
convs, the deconvolutions and the final 1x1 are INT8. Activations are uint8 after ReLU and int8 on
the input and before every residual add. The final 1x1 output is not quantised: on the board it is
the int32 accumulator.
"""
import brevitas.nn as qnn
import torch
import torch.nn as nn
from brevitas.quant.scaled_int import (Int8ActPerTensorFloat, Int8WeightPerTensorFloat,
                                       Uint8ActPerTensorFloat)
from torchvision.models import mobilenet_v2
from torchvision.models.mobilenetv2 import InvertedResidual

from src.twn import TWNWeightPerTensor, verify_ternary

N_BACKBONE = 18          # features[:18]: stem + 17 inverted residuals
DECONV_CH = 32           # head width fixed by the accelerator
OUT_CH = 16              # final 1x1 width fixed by the accelerator


class _Uint8ActFast(Uint8ActPerTensorFloat):
    collect_stats_steps = 50


class _Int8ActFast(Int8ActPerTensorFloat):
    collect_stats_steps = 50


A_RELU = _Uint8ActFast
A_SIGNED = _Int8ActFast
W_INT8 = Int8WeightPerTensorFloat
W_TWN = TWNWeightPerTensor


def ternary_paths():
    """Paths of the 34 pointwise convs and the stem: the 'pw_stem' region."""
    ref = mobilenet_v2(weights=None).features
    keys = set()
    for i in range(N_BACKBONE):
        for name, sub in ref[i].named_modules():
            if isinstance(sub, nn.Conv2d) and (sub.groups == 1):
                keys.add(f"features.{i}" + (f".{name}" if name else ""))
    return keys


class QuantConfig:
    def __init__(self, twn_keys=()):
        self.twn_keys = set(twn_keys)

    def weight_quant(self, path):
        if any(path == k or path.startswith(k + ".") for k in self.twn_keys):
            return W_TWN
        return W_INT8


def _qconv(i, o, k, stride, padding, weight_quant, bias=False, transpose=False, groups=1):
    cls = qnn.QuantConvTranspose2d if transpose else qnn.QuantConv2d
    m = cls(i, o, k, stride=stride, padding=padding, groups=groups, bias=bias,
            weight_quant=weight_quant)
    m._twn = weight_quant is W_TWN
    return m


def _mirror_cna(cna, wq):
    conv, bn = cna[0], cna[1]
    return nn.Sequential(
        _qconv(conv.in_channels, conv.out_channels, conv.kernel_size[0], conv.stride[0],
               conv.padding[0], wq, groups=conv.groups),
        nn.BatchNorm2d(bn.num_features),
        qnn.QuantReLU(act_quant=A_RELU),
    )


class QInvertedResidual(nn.Module):
    def __init__(self, ref_block, wq_fn, prefix):
        super().__init__()
        self.use_res = ref_block.use_res_connect
        subs = []
        for j, sub in enumerate(ref_block.conv):
            path = f"{prefix}.conv.{j}"
            if isinstance(sub, nn.Sequential):
                subs.append(_mirror_cna(sub, wq_fn(path + ".0")))
            elif isinstance(sub, nn.Conv2d):
                subs.append(_qconv(sub.in_channels, sub.out_channels, sub.kernel_size[0],
                                   sub.stride[0], sub.padding[0], wq_fn(path), groups=sub.groups))
            elif isinstance(sub, nn.BatchNorm2d):
                subs.append(nn.BatchNorm2d(sub.num_features))
        self.conv = nn.Sequential(*subs)
        self.add_quant = qnn.QuantIdentity(act_quant=A_SIGNED) if self.use_res else None

    def forward(self, x):
        out = self.conv(x)
        if self.use_res:
            return x + self.add_quant(out)
        return out


class Mbv2Quant(nn.Module):
    def __init__(self, ternary=True, out_ch=OUT_CH):
        super().__init__()
        self.cfg = QuantConfig(ternary_paths() if ternary else ())
        ref = mobilenet_v2(weights=None).features
        self.input_quant = qnn.QuantIdentity(act_quant=A_SIGNED)
        feats = []
        for i in range(N_BACKBONE):
            m = ref[i]
            if isinstance(m, InvertedResidual):
                feats.append(QInvertedResidual(m, self.cfg.weight_quant, f"features.{i}"))
            else:
                feats.append(_mirror_cna(m, self.cfg.weight_quant(f"features.{i}.0")))
        self.features = nn.Sequential(*feats)
        layers, inp = [], 320
        for i in range(3):
            layers += [_qconv(inp, DECONV_CH, 4, 2, 1, self.cfg.weight_quant(f"deconv.{i}"),
                              transpose=True),
                       nn.BatchNorm2d(DECONV_CH), qnn.QuantReLU(act_quant=A_RELU)]
            inp = DECONV_CH
        self.deconv_layers = nn.Sequential(*layers)
        self.final_layer = _qconv(DECONV_CH, out_ch, 1, 1, 0, self.cfg.weight_quant("final"),
                                  bias=True)
        for m in self.deconv_layers.modules():
            if isinstance(m, qnn.QuantConvTranspose2d):
                nn.init.normal_(m.weight, std=0.001)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.constant_(m.weight, 1); nn.init.constant_(m.bias, 0)
        nn.init.normal_(self.final_layer.weight, std=0.001)
        nn.init.constant_(self.final_layer.bias, 0)

    def forward(self, x):
        return self.final_layer(self.deconv_layers(self.features(self.input_quant(x))))

    def twn_modules(self):
        return {n: m for n, m in self.named_modules() if getattr(m, "_twn", False)}

    def verify_all_ternary(self):
        return [verify_ternary(m, name=n) for n, m in self.twn_modules().items()]


def materialize(model, size=256):
    """Brevitas builds its quantiser buffers on the first forward; do it on the CPU, before
    any move to the GPU (a later load_state_dict puts them back on the CPU)."""
    model.eval()
    with torch.no_grad():
        model(torch.zeros(1, 3, size, size))
    return model


def relay_backbone(model, ckpt_path, prefixes=("input_quant.", "features.")):
    """Load the tensors under `prefixes` from a checkpoint whose names and shapes match.
    Call on the CPU, before materialize()/to(device)."""
    sd = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    sd = sd.get("model", sd)
    own = model.state_dict()
    take = {k: v for k, v in sd.items()
            if k.startswith(prefixes) and k in own and own[k].shape == v.shape}
    model.load_state_dict(take, strict=False)
    n_own = sum(1 for k in own if k.startswith(prefixes))
    return len(take), n_own


def rebase(model, backbone_ckpt, head_ckpt, head_rows=None):
    """Backbone (input_quant.*, features.*) from one checkpoint, head (deconv_layers.*,
    final_layer.*) from another, so a task model moves onto a new backbone without training from
    scratch. head_rows maps each final_layer output row to a row of the head checkpoint, or -1 to
    keep this model's fresh initialisation (a class that changed). Call on the CPU, before
    materialize()/to(device). Returns (n backbone tensors, n head tensors)."""
    own = model.state_dict()
    bb = torch.load(backbone_ckpt, map_location="cpu", weights_only=False)
    bb = bb.get("model", bb)
    hd = torch.load(head_ckpt, map_location="cpu", weights_only=False)
    hd = hd.get("model", hd)
    take = {k: v for k, v in bb.items() if k.startswith(("input_quant.", "features.")) and k in own
            and own[k].shape == v.shape}
    nb = len(take)
    for k, v in hd.items():
        if not k.startswith(("deconv_layers.", "final_layer.")) or k not in own:
            continue
        if k in ("final_layer.weight", "final_layer.bias") and head_rows is not None:
            t = own[k].clone()
            for i, j in enumerate(head_rows):
                if j >= 0:
                    t[i] = v[j]
            take[k] = t
        elif own[k].shape == v.shape:
            take[k] = v
    model.load_state_dict(take, strict=False)
    return nb, len(take) - nb
