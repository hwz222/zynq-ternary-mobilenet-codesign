"""MobileNetV2-backbone SimpleBaseline (float + Brevitas quant twin) for the DSC study.

Backbone = torchvision `mobilenet_v2().features[:18]` (stem + 17 inverted residuals, /32);
head = the same SimpleBaseline 3x ConvTranspose deconv (8->16->32->64) + final 1x1 -> 14 joints.

The quant twin is built by MIRRORING the torchvision modules (same dims + same nested names
`features.N.conv.M...`), so ImageNet weights load into the float model and KD relay (strict=False)
carries the trained float student into the quant twin.

TWN region map (as first defined for the ONNX export of the earlier code base): backbone POINTWISE 1x1 (expand +
project) -> ternary; backbone DEPTHWISE 3x3, the 3x3 stem, deconv head, and final 1x1 -> INT8.
(Correction: that map is the plain `pw` region only. The deployed model uses the
`pw_stem` region (src/build_model.py region_keys: `pw | stem`, the default of
src/score_ckpt.py --region), in which the 3x3 stem is TERNARY too; depthwise, deconv head and
final 1x1 stay INT8.)
"""
import brevitas.nn as qnn
import torch
import torch.nn as nn
from torchvision.models import MobileNet_V2_Weights, mobilenet_v2
from torchvision.models.mobilenetv2 import InvertedResidual

from src.compress_model import _qconv
from src.config import NUM_JOINTS
from src.quant_model import A_RELU, A_SIGNED

N_BACKBONE = 18   # features[:18] -> drop the final 320->1280 expansion


def _backbone_out_ch(width_mult):
    with torch.no_grad():
        feats = mobilenet_v2(weights=None, width_mult=width_mult).features[:N_BACKBONE]
        return feats(torch.zeros(1, 3, 64, 64)).shape[1]


def mbv2_region_keys(width_mult=1.0):
    """Classify every backbone conv by role -> (pointwise, depthwise, stem) path sets.
    Paths match the mirrored quant twin's module names exactly."""
    ref = mobilenet_v2(weights=None, width_mult=width_mult).features
    pw, dw, stem = set(), set(), set()
    for i in range(N_BACKBONE):
        for name, sub in ref[i].named_modules():
            if not isinstance(sub, nn.Conv2d):
                continue
            path = f"features.{i}" + (f".{name}" if name else "")
            if sub.groups > 1:
                dw.add(path)                              # depthwise 3x3
            elif sub.kernel_size == (1, 1):
                pw.add(path)                              # pointwise 1x1 (expand/project)
            else:
                stem.add(path)                            # 3x3 groups=1 (stem only)
    return pw, dw, stem


# --------------------------- shared head builders ---------------------------
def _deconv_float(inp, outp, num=3):
    layers = []
    for _ in range(num):
        layers += [nn.ConvTranspose2d(inp, outp, 4, 2, 1, bias=False),
                   nn.BatchNorm2d(outp), nn.ReLU(inplace=True)]
        inp = outp
    return nn.Sequential(*layers)


def _deconv_quant(inp, outp, num, wq):
    layers = []
    for i in range(num):
        layers += [_qconv(inp, outp, 4, 2, 1, wq(f"deconv.{i}"), transpose=True),
                   nn.BatchNorm2d(outp), qnn.QuantReLU(act_quant=A_RELU)]
        inp = outp
    return nn.Sequential(*layers)


def _init_head(deconv_layers, final_layer):
    for m in deconv_layers.modules():
        if isinstance(m, (nn.ConvTranspose2d, qnn.QuantConvTranspose2d)):
            nn.init.normal_(m.weight, std=0.001)
        elif isinstance(m, nn.BatchNorm2d):
            nn.init.constant_(m.weight, 1); nn.init.constant_(m.bias, 0)
    nn.init.normal_(final_layer.weight, std=0.001)
    nn.init.constant_(final_layer.bias, 0)


# --------------------------- float model ---------------------------
class PoseMBV2(nn.Module):
    def __init__(self, num_joints=NUM_JOINTS, width_mult=1.0, deconv_ch=256, pretrained=True):
        super().__init__()
        w = MobileNet_V2_Weights.IMAGENET1K_V1 if (pretrained and width_mult == 1.0) else None
        self.features = mobilenet_v2(weights=w, width_mult=width_mult).features[:N_BACKBONE]
        bo = _backbone_out_ch(width_mult)
        self.deconv_layers = _deconv_float(bo, deconv_ch, 3)
        self.final_layer = nn.Conv2d(deconv_ch, num_joints, 1)
        _init_head(self.deconv_layers, self.final_layer)

    def forward(self, x):
        return self.final_layer(self.deconv_layers(self.features(x)))


# --------------------------- quant twin ---------------------------
def _mirror_cna(cna, wq):
    """torchvision Conv2dNormActivation (Sequential[Conv, BN, ReLU6]) -> quant Sequential
    [QuantConv, BN, QuantReLU] with matching .0/.1/.2 indices."""
    conv, bn = cna[0], cna[1]
    return nn.Sequential(
        _qconv(conv.in_channels, conv.out_channels, conv.kernel_size[0], conv.stride[0],
               conv.padding[0], wq, groups=conv.groups),
        nn.BatchNorm2d(bn.num_features),
        qnn.QuantReLU(act_quant=A_RELU),
    )


class QInvertedResidual(nn.Module):
    """Quant twin of torchvision InvertedResidual, mirroring `.conv` submodule indices."""
    def __init__(self, ref_block, wq_fn, prefix):
        super().__init__()
        self.use_res = ref_block.use_res_connect
        subs = []
        for j, sub in enumerate(ref_block.conv):
            path = f"{prefix}.conv.{j}"
            if isinstance(sub, nn.Sequential):                 # Conv2dNormActivation (expand / dw)
                subs.append(_mirror_cna(sub, wq_fn(path + ".0")))
            elif isinstance(sub, nn.Conv2d):                   # project 1x1 (bare, linear)
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


class PoseMBV2Quant(nn.Module):
    """`head_proj_ch=None` (the default) builds the DEPLOYED module tree, byte for byte.

    Setting it inserts a 1x1 projection between the backbone and the deconv head, so the
    first deconv reads `head_proj_ch` channels instead of the backbone's 320. That is a
    hardware lever, not an accuracy one: on the FPGA the first deconv's 320 input channels
    are what force the head engine's weight-streaming mode (160 KB of weights, 16 passes
    over the input, 1.43 ms of the 5.99 ms head). At <=64 input channels the weights stay
    resident and the op costs ~0.3 ms. The projection itself is ternary, so it is nearly
    free on the multiplier-free tree.

    It is a SEPARATE module, deliberately not spliced into `deconv_layers`: inserting it
    there would shift every later layer's name and break weight relay for the whole head.
    As its own attribute, all 34 ternary backbone convs, deconv.1/2 and final relay by name;
    only `deconv_layers.0.weight` legitimately changes shape and is re-initialised.
    """

    def __init__(self, cfg, num_joints=NUM_JOINTS, width_mult=1.0, deconv_ch=256,
                 head_proj_ch=None):
        super().__init__()
        self.cfg = cfg
        ref = mobilenet_v2(weights=None, width_mult=width_mult).features
        self.input_quant = qnn.QuantIdentity(act_quant=A_SIGNED)
        feats = []
        for i in range(N_BACKBONE):
            m = ref[i]
            if isinstance(m, InvertedResidual):
                feats.append(QInvertedResidual(m, self._wq, f"features.{i}"))
            else:                                              # stem Conv2dNormActivation
                feats.append(_mirror_cna(m, self._wq(f"features.{i}.0")))
        self.features = nn.Sequential(*feats)
        bo = _backbone_out_ch(width_mult)
        self.head_proj = None
        if head_proj_ch:
            self.head_proj = nn.Sequential(
                _qconv(bo, head_proj_ch, 1, 1, 0, self._wq("head_proj")),
                nn.BatchNorm2d(head_proj_ch),
                qnn.QuantReLU(act_quant=A_RELU),
            )
            nn.init.constant_(self.head_proj[1].weight, 1)
            nn.init.constant_(self.head_proj[1].bias, 0)
            bo = head_proj_ch
        self.deconv_layers = _deconv_quant(bo, deconv_ch, 3, self._wq)
        self.final_layer = _qconv(deconv_ch, num_joints, 1, 1, 0, self._wq("final"), bias=True)
        _init_head(self.deconv_layers, self.final_layer)

    def _wq(self, path):
        return self.cfg.weight_quant(path)

    def forward(self, x):
        x = self.input_quant(x)
        x = self.features(x)
        if self.head_proj is not None:
            x = self.head_proj(x)
        x = self.deconv_layers(x)
        return self.final_layer(x)

    # Discipline-B helpers (same API as PoseResNetCQuant)
    def twn_modules(self):
        return {n: m for n, m in self.named_modules() if getattr(m, "_twn", False)}

    def verify_all_ternary(self):
        from src.twn import verify_ternary
        return [verify_ternary(m, name=n) for n, m in self.twn_modules().items()]
