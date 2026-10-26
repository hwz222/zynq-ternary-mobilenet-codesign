"""Brevitas quantized SimpleBaseline (ResNet-18 + deconv head).

ONE class serves the full-INT8 baseline and every TWN config: a QuantConfig marks
which backbone regions use ternary (TWN) weights; everything else uses INT8 weights.
All activations are int8/uint8 (genuine int8 numerics, fake-quant; host-only -> no FINN
export constraints). Parameter names mirror src/model.PoseResNet18 exactly so weights
relay FP32 -> INT8 -> TWN via load_state_dict(strict=False).

Region keys (for QuantConfig.twn_keys): "stem", "layer1".."layer4" (whole stage) or
"layer4.1" (single block), "deconv", "final". By the charter, stem/deconv/final stay INT8
by default; only backbone stages go TWN.
"""
import brevitas.nn as qnn
import torch
import torch.nn as nn
from brevitas.quant.scaled_int import (Int8ActPerTensorFloat,
                                       Int8WeightPerTensorFloat,
                                       Uint8ActPerTensorFloat)

from src.config import NUM_JOINTS
from src.twn import TWNWeightPerChannel, TWNWeightPerTensor, verify_ternary

W_INT8 = Int8WeightPerTensorFloat
W_TWN = TWNWeightPerTensor
W_TWN_PC = TWNWeightPerChannel      # ternary, one alpha per output channel

# Every ternary quantizer, per-tensor or per-channel. The `_twn` flag set from this is the
# SINGLE source of truth for twn_modules() (Discipline-B), scripts/measure_sep.py (ternary
# vs INT8 MAC split) and src/model_size.py (2-bit vs 8-bit weight accounting). Forgetting a
# quantizer here does not raise -- it silently reports a ternary layer as INT8.
W_TERNARY = (W_TWN, W_TWN_PC)


# Activation quantizers with a short stats-collection warmup. The default 300 steps only
# *initialize* the (then-learned) scale but cost ~12 min of percentile collection per run and
# don't transfer across the relay; 50 steps initializes just as well and is ~6x cheaper.
class _Uint8ActFast(Uint8ActPerTensorFloat):
    collect_stats_steps = 50


class _Int8ActFast(Int8ActPerTensorFloat):
    collect_stats_steps = 50


A_RELU = _Uint8ActFast      # post-ReLU activations (>=0)  -> uint8
A_SIGNED = _Int8ActFast     # input + residual pre-add branch -> int8


class QuantConfig:
    """Routes each conv path to one of three weight quantizers.

    twn_pc_keys wins over twn_keys, so a region may be listed as ternary while a subset of
    it (typically the depthwise convs) is upgraded to a per-output-channel alpha.
    """

    def __init__(self, twn_keys=(), twn_pc_keys=(), name="int8"):
        self.twn_keys = set(twn_keys)
        self.twn_pc_keys = set(twn_pc_keys)
        self.name = name

    @staticmethod
    def _match(path, keys):
        return any(path == k or path.startswith(k + ".") for k in keys)

    def is_twn(self, path):
        return self._match(path, self.twn_keys)

    def is_twn_pc(self, path):
        return self._match(path, self.twn_pc_keys)

    def weight_quant(self, path):
        if self.is_twn_pc(path):
            return W_TWN_PC
        if self.is_twn(path):
            return W_TWN
        return W_INT8


def _qconv(inp, outp, k, stride, padding, weight_quant, bias=False, transpose=False):
    cls = qnn.QuantConvTranspose2d if transpose else qnn.QuantConv2d
    m = cls(inp, outp, k, stride=stride, padding=padding, bias=bias, weight_quant=weight_quant)
    m._twn = weight_quant in W_TERNARY
    return m


class QBasicBlock(nn.Module):
    expansion = 1

    def __init__(self, inplanes, planes, stride, wq1, wq2, downsample=None):
        super().__init__()
        self.conv1 = _qconv(inplanes, planes, 3, stride, 1, wq1)
        self.bn1 = nn.BatchNorm2d(planes)
        self.relu1 = qnn.QuantReLU(act_quant=A_RELU)
        self.conv2 = _qconv(planes, planes, 3, 1, 1, wq2)
        self.bn2 = nn.BatchNorm2d(planes)
        self.add_quant = qnn.QuantIdentity(act_quant=A_SIGNED)
        self.relu2 = qnn.QuantReLU(act_quant=A_RELU)
        self.downsample = downsample

    def forward(self, x):
        identity = x
        out = self.relu1(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        out = self.add_quant(out)
        if self.downsample is not None:
            identity = self.downsample(x)
        out = out + identity
        return self.relu2(out)


class PoseResNet18Quant(nn.Module):
    def __init__(self, cfg: QuantConfig, num_joints=NUM_JOINTS, deconv_ch=256):
        super().__init__()
        self.cfg = cfg
        self.inplanes = 64
        # --- stem ---
        self.input_quant = qnn.QuantIdentity(act_quant=A_SIGNED)
        self.conv1 = _qconv(3, 64, 7, 2, 3, self._wq("stem"))
        self.bn1 = nn.BatchNorm2d(64)
        self.relu = qnn.QuantReLU(act_quant=A_RELU)
        self.maxpool = nn.MaxPool2d(3, stride=2, padding=1)
        # --- stages ---
        self.layer1 = self._make_layer(64, 2, 1, "layer1")
        self.layer2 = self._make_layer(128, 2, 2, "layer2")
        self.layer3 = self._make_layer(256, 2, 2, "layer3")
        self.layer4 = self._make_layer(512, 2, 2, "layer4")
        # --- deconv head ---
        self.deconv_layers = self._make_deconv(512, deconv_ch, 3)
        self.final_layer = _qconv(deconv_ch, num_joints, 1, 1, 0, self._wq("final"), bias=True)
        self._init_head()

    def _wq(self, path):
        return self.cfg.weight_quant(path)

    def _make_layer(self, planes, blocks, stride, stage):
        layers = []
        for b in range(blocks):
            bstride = stride if b == 0 else 1
            prefix = f"{stage}.{b}"
            ds = None
            if b == 0 and (bstride != 1 or self.inplanes != planes):
                ds_conv = _qconv(self.inplanes, planes, 1, bstride, 0,
                                 self._wq(f"{prefix}.downsample.0"))
                ds = nn.Sequential(ds_conv, nn.BatchNorm2d(planes),
                                   qnn.QuantIdentity(act_quant=A_SIGNED))
            block = QBasicBlock(self.inplanes, planes, bstride,
                                self._wq(f"{prefix}.conv1"), self._wq(f"{prefix}.conv2"), ds)
            self.inplanes = planes
            layers.append(block)
        return nn.Sequential(*layers)

    def _make_deconv(self, inp, outp, num=3):
        layers = []
        for i in range(num):
            layers += [
                _qconv(inp, outp, 4, 2, 1, self._wq(f"deconv.{i}"), transpose=True),
                nn.BatchNorm2d(outp),
                qnn.QuantReLU(act_quant=A_RELU),
            ]
            inp = outp
        return nn.Sequential(*layers)

    def _init_head(self):
        for m in self.deconv_layers.modules():
            if isinstance(m, qnn.QuantConvTranspose2d):
                nn.init.normal_(m.weight, std=0.001)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.constant_(m.weight, 1)
                nn.init.constant_(m.bias, 0)
        nn.init.normal_(self.final_layer.weight, std=0.001)
        nn.init.constant_(self.final_layer.bias, 0)

    def forward(self, x):
        x = self.input_quant(x)
        x = self.maxpool(self.relu(self.bn1(self.conv1(x))))
        x = self.layer1(x)
        x = self.layer2(x)
        x = self.layer3(x)
        x = self.layer4(x)
        x = self.deconv_layers(x)
        return self.final_layer(x)

    # --- Discipline B helpers ---
    def twn_modules(self):
        """{name: module} for every conv whose weight_quant is TWN."""
        return {n: m for n, m in self.named_modules() if getattr(m, "_twn", False)}

    def verify_all_ternary(self):
        """Run Discipline-B verification on all TWN layers; list of result dicts."""
        return [verify_ternary(m, name=n) for n, m in self.twn_modules().items()]


def materialize_and_move(model, device, input_size=(1, 3, 256, 256)):
    """Brevitas builds its quant submodules lazily on the first forward, on the default
    (CPU) device. Calling .to(device) before that leaves those buffers on CPU. So run one
    eval-mode CPU forward (no runtime-stat pollution) to materialize them, then move."""
    was_training = model.training
    model.eval()
    with torch.no_grad():
        model(torch.zeros(*input_size))
    model.to(device)
    model.train(was_training)
    return model
