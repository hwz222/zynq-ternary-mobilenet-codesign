"""Parametrized (compressible) SimpleBaseline = ResNet-ish backbone + deconv head.

Two compression axes (charter request):
  * width   -- `width_mult` scales the base channels [64,128,256,512].
  * depth   -- `blocks` is the #residual-blocks per kept stage; its LENGTH is the
               number of stages kept (deep stages dropped first, charter deep->shallow).

The deconv head count is DERIVED so the output stays 64x64 (= input/4 = HEATMAP_SIZE):
the stem downsamples /4, each kept stage after the first has stride 2, so we need
(num_stages - 1) deconvs to upsample back. This keeps the PCKh ruler identical.

Both a float model (PoseResNetC) and a Brevitas quant model (PoseResNetCQuant) are
provided, with IDENTICAL parameter names, so weights relay float->quant via
load_state_dict(strict=False) (KD pipeline) and torchvision ImageNet weights load
partially when width_mult==1.0 (matching-shape names only).
"""
import brevitas.nn as qnn
import torch
import torch.nn as nn
from brevitas.quant.scaled_int import Int8WeightPerTensorFloat

from src.config import NUM_JOINTS
from src.quant_model import A_RELU, A_SIGNED, W_TERNARY, QuantConfig
from src.twn import TWNWeightPerChannel, TWNWeightPerTensor

W_INT8 = Int8WeightPerTensorFloat
W_TWN = TWNWeightPerTensor
W_TWN_PC = TWNWeightPerChannel

BASE_CH = [64, 128, 256, 512]


def round8(x):
    """Round channel count to a multiple of 8 (>=8) -- hardware/divisibility friendly."""
    return max(8, int(round(x / 8.0)) * 8)


def derive_arch(width_mult=1.0, blocks=(2, 2, 2, 2), deconv_ch=256, channels_override=None):
    """Return (channels, strides, deconv_num, deconv_ch) for the given knobs.

    channels[i] = round8(BASE_CH[i] * width_mult) for each KEPT stage (len == len(blocks)),
    unless channels_override (explicit per-stage list) is given -- used to shrink a single
    stage (e.g. stage4 512->256) without touching the rest.
    strides     = [1, 2, 2, ...] (first stage stride 1, rest stride 2).
    deconv_num  = len(blocks) - 1  (keeps output at 64x64).
    """
    n_stages = len(blocks)
    assert 1 <= n_stages <= 4, "keep between 1 and 4 stages"
    if channels_override is not None:
        assert len(channels_override) == n_stages, "channels_override must match #stages"
        channels = [round8(c) for c in channels_override]
    else:
        channels = [round8(BASE_CH[i] * width_mult) for i in range(n_stages)]
    strides = [1] + [2] * (n_stages - 1)
    deconv_num = n_stages - 1
    return channels, strides, deconv_num, round8(deconv_ch) if deconv_ch >= 8 else deconv_ch


class ArchSpec:
    """Bundles the compression knobs and the derived geometry."""
    def __init__(self, width_mult=1.0, blocks=(2, 2, 2, 2), deconv_ch=256, name="r18",
                 channels_override=None, separable=False):
        self.width_mult = float(width_mult)
        self.blocks = tuple(int(b) for b in blocks)
        self.deconv_ch_req = int(deconv_ch)
        self.name = name
        self.separable = bool(separable)   # backbone 3x3 -> depthwise-separable
        self.channels, self.strides, self.deconv_num, self.deconv_ch = derive_arch(
            width_mult, self.blocks, deconv_ch, channels_override)
        self.stem_ch = self.channels[0]

    def twn_no_final_keys(self):
        """TWN region = everything ternary EXCEPT the final 1x1 (the known wall-hit layer).
        = stem + all kept stages + deconv head."""
        keys = ["stem", "deconv"] + [f"layer{i+1}" for i in range(len(self.blocks))]
        return set(keys)

    def twn_all_keys(self):
        """TWN region = EVERYTHING ternary, including the final 1x1 (the twn_all config).
        Makes the whole net multiplier-free (final conv no longer needs an INT8 MAC)."""
        return self.twn_no_final_keys() | {"final"}

    def twn_backbone_keys(self):
        """TWN region = stem + kept stages ONLY; deconv AND final stay INT8.
        The HW-aware split: ternary backbone on PL fabric (no multipliers), INT8 head
        on DSP/NEON. Anchor: twn_s1234 (backbone-only TWN on full R18) = 87.57."""
        return {"stem"} | {f"layer{i+1}" for i in range(len(self.blocks))}

    # --- separable-only leaf keys (pointwise vs depthwise granularity) ---
    def _stage_iter(self, stages):
        return range(len(self.blocks)) if stages is None else stages

    def twn_pointwise_keys(self, stages=None):
        """Every backbone 1x1 pointwise conv ternary (both convs' .pw + downsample 1x1).
        Depthwise, stem, deconv, final stay INT8. `stages` restricts to a stage subset
        for the deep->shallow chain (e.g. (3,) = layer4 only)."""
        keys = set()
        for i in self._stage_iter(stages):
            for b in range(self.blocks[i]):
                keys |= {f"layer{i+1}.{b}.conv1.pw", f"layer{i+1}.{b}.conv2.pw",
                         f"layer{i+1}.{b}.downsample.0"}
        return keys

    def twn_depthwise_keys(self, stages=None):
        """Every backbone 3x3 depthwise conv ternary."""
        keys = set()
        for i in self._stage_iter(stages):
            for b in range(self.blocks[i]):
                keys |= {f"layer{i+1}.{b}.conv1.dw", f"layer{i+1}.{b}.conv2.dw"}
        return keys

    def twn_pw_dw_keys(self, stages=None):
        return self.twn_pointwise_keys(stages) | self.twn_depthwise_keys(stages)

    def __repr__(self):
        return (f"ArchSpec({self.name}: w={self.width_mult} blocks={self.blocks} "
                f"ch={self.channels} deconv={self.deconv_num}x{self.deconv_ch})")


# ----------------------------- float model -----------------------------
def _conv3x3(i, o, s=1):
    return nn.Conv2d(i, o, 3, stride=s, padding=1, bias=False)


def _conv1x1(i, o, s=1):
    return nn.Conv2d(i, o, 1, stride=s, bias=False)


def _dwconv3x3(c, s=1):
    """Depthwise 3x3 (groups=C)."""
    return nn.Conv2d(c, c, 3, stride=s, padding=1, groups=c, bias=False)


class SepConv(nn.Module):
    """Depthwise-separable replacement for one 3x3 conv: dw3x3(groups=C) -> BN -> ReLU
    -> pw1x1 -> BN. Returns the pre-activation (BN output), matching BasicBlock's
    conv->BN convention so the block wraps it identically. Every conv is followed by a
    LIVE BatchNorm (the point of this study: BN renormalizes after ternarization)."""

    def __init__(self, cin, cout, stride=1):
        super().__init__()
        self.dw = _dwconv3x3(cin, stride)
        self.bn_dw = nn.BatchNorm2d(cin)
        self.act = nn.ReLU(inplace=True)
        self.pw = _conv1x1(cin, cout)
        self.bn_pw = nn.BatchNorm2d(cout)

    def forward(self, x):
        return self.bn_pw(self.pw(self.act(self.bn_dw(self.dw(x)))))


class SepBasicBlock(nn.Module):
    """ResNet BasicBlock with each 3x3 replaced by SepConv; residual/ReLU identical."""
    expansion = 1

    def __init__(self, inplanes, planes, stride=1, downsample=None):
        super().__init__()
        self.conv1 = SepConv(inplanes, planes, stride)
        self.relu = nn.ReLU(inplace=True)
        self.conv2 = SepConv(planes, planes, 1)
        self.downsample = downsample
        self.stride = stride

    def forward(self, x):
        identity = x
        out = self.relu(self.conv1(x))
        out = self.conv2(out)
        if self.downsample is not None:
            identity = self.downsample(x)
        out += identity
        return self.relu(out)


class BasicBlock(nn.Module):
    expansion = 1

    def __init__(self, inplanes, planes, stride=1, downsample=None):
        super().__init__()
        self.conv1 = _conv3x3(inplanes, planes, stride)
        self.bn1 = nn.BatchNorm2d(planes)
        self.relu = nn.ReLU(inplace=True)
        self.conv2 = _conv3x3(planes, planes)
        self.bn2 = nn.BatchNorm2d(planes)
        self.downsample = downsample
        self.stride = stride

    def forward(self, x):
        identity = x
        out = self.relu(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        if self.downsample is not None:
            identity = self.downsample(x)
        out += identity
        return self.relu(out)


class PoseResNetC(nn.Module):
    """Float compressible SimpleBaseline. Names mirror src.model.PoseResNet18."""
    def __init__(self, arch: ArchSpec, num_joints=NUM_JOINTS):
        super().__init__()
        self.arch = arch
        ch, strides = arch.channels, arch.strides
        self.inplanes = arch.stem_ch
        # stem
        self.conv1 = nn.Conv2d(3, arch.stem_ch, 7, stride=2, padding=3, bias=False)
        self.bn1 = nn.BatchNorm2d(arch.stem_ch)
        self.relu = nn.ReLU(inplace=True)
        self.maxpool = nn.MaxPool2d(3, stride=2, padding=1)
        # stages
        self.stages = nn.ModuleList()
        for i, (planes, nblk, st) in enumerate(zip(ch, arch.blocks, strides)):
            setattr(self, f"layer{i+1}", self._make_layer(planes, nblk, st))
        # deconv head
        self.deconv_layers = self._make_deconv(self.inplanes, arch.deconv_ch, arch.deconv_num)
        self.final_layer = nn.Conv2d(arch.deconv_ch if arch.deconv_num > 0 else self.inplanes,
                                     num_joints, 1)
        self._init_head()

    def _make_layer(self, planes, blocks, stride):
        Block = SepBasicBlock if self.arch.separable else BasicBlock
        downsample = None
        if stride != 1 or self.inplanes != planes:
            downsample = nn.Sequential(_conv1x1(self.inplanes, planes, stride),
                                       nn.BatchNorm2d(planes))
        layers = [Block(self.inplanes, planes, stride, downsample)]
        self.inplanes = planes
        for _ in range(1, blocks):
            layers.append(Block(self.inplanes, planes))
        return nn.Sequential(*layers)

    def _make_deconv(self, inp, outp, num):
        layers = []
        for _ in range(num):
            layers += [nn.ConvTranspose2d(inp, outp, 4, stride=2, padding=1, bias=False),
                       nn.BatchNorm2d(outp), nn.ReLU(inplace=True)]
            inp = outp
        return nn.Sequential(*layers)

    def _init_head(self):
        for m in self.deconv_layers.modules():
            if isinstance(m, nn.ConvTranspose2d):
                nn.init.normal_(m.weight, std=0.001)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.constant_(m.weight, 1); nn.init.constant_(m.bias, 0)
        nn.init.normal_(self.final_layer.weight, std=0.001)
        nn.init.constant_(self.final_layer.bias, 0)

    def forward(self, x):
        x = self.maxpool(self.relu(self.bn1(self.conv1(x))))
        for i in range(len(self.arch.blocks)):
            x = getattr(self, f"layer{i+1}")(x)
        x = self.deconv_layers(x)
        return self.final_layer(x)


# ----------------------------- quant model -----------------------------
def _qconv(i, o, k, stride, padding, weight_quant, bias=False, transpose=False, groups=1):
    cls = qnn.QuantConvTranspose2d if transpose else qnn.QuantConv2d
    m = cls(i, o, k, stride=stride, padding=padding, groups=groups, bias=bias,
            weight_quant=weight_quant)
    m._twn = weight_quant in W_TERNARY      # per-tensor OR per-channel ternary
    return m


class QSepConv(nn.Module):
    """Brevitas twin of SepConv: quant dw3x3(groups=C) -> BN -> QuantReLU -> quant pw1x1 -> BN.
    Names line up with SepConv (dw/bn_dw/act/pw/bn_pw) for float<->quant relay."""

    def __init__(self, cin, cout, stride, wq_dw, wq_pw):
        super().__init__()
        self.dw = _qconv(cin, cin, 3, stride, 1, wq_dw, groups=cin)
        self.bn_dw = nn.BatchNorm2d(cin)
        self.act = qnn.QuantReLU(act_quant=A_RELU)
        self.pw = _qconv(cin, cout, 1, 1, 0, wq_pw)
        self.bn_pw = nn.BatchNorm2d(cout)

    def forward(self, x):
        return self.bn_pw(self.pw(self.act(self.bn_dw(self.dw(x)))))


class QSepBasicBlock(nn.Module):
    """Brevitas twin of SepBasicBlock. `wq` is path->weight_quant, prefixed for this block."""
    expansion = 1

    def __init__(self, inplanes, planes, stride, wq, downsample=None):
        super().__init__()
        self.conv1 = QSepConv(inplanes, planes, stride, wq("conv1.dw"), wq("conv1.pw"))
        self.relu1 = qnn.QuantReLU(act_quant=A_RELU)
        self.conv2 = QSepConv(planes, planes, 1, wq("conv2.dw"), wq("conv2.pw"))
        self.add_quant = qnn.QuantIdentity(act_quant=A_SIGNED)
        self.relu2 = qnn.QuantReLU(act_quant=A_RELU)
        self.downsample = downsample

    def forward(self, x):
        identity = x
        out = self.relu1(self.conv1(x))
        out = self.conv2(out)
        out = self.add_quant(out)
        if self.downsample is not None:
            identity = self.downsample(x)
        out = out + identity
        return self.relu2(out)


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


class PoseResNetCQuant(nn.Module):
    """Brevitas quant compressible SimpleBaseline. Names mirror PoseResNetC exactly."""
    def __init__(self, arch: ArchSpec, cfg: QuantConfig, num_joints=NUM_JOINTS):
        super().__init__()
        self.arch = arch
        self.cfg = cfg
        ch, strides = arch.channels, arch.strides
        self.inplanes = arch.stem_ch
        self.input_quant = qnn.QuantIdentity(act_quant=A_SIGNED)
        self.conv1 = _qconv(3, arch.stem_ch, 7, 2, 3, self._wq("stem"))
        self.bn1 = nn.BatchNorm2d(arch.stem_ch)
        self.relu = qnn.QuantReLU(act_quant=A_RELU)
        self.maxpool = nn.MaxPool2d(3, stride=2, padding=1)
        for i, (planes, nblk, st) in enumerate(zip(ch, arch.blocks, strides)):
            setattr(self, f"layer{i+1}", self._make_layer(planes, nblk, st, f"layer{i+1}"))
        self.deconv_layers = self._make_deconv(self.inplanes, arch.deconv_ch, arch.deconv_num)
        final_in = arch.deconv_ch if arch.deconv_num > 0 else self.inplanes
        self.final_layer = _qconv(final_in, num_joints, 1, 1, 0, self._wq("final"), bias=True)
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
            if self.arch.separable:
                block = QSepBasicBlock(self.inplanes, planes, bstride,
                                       lambda sub, p=prefix: self._wq(f"{p}.{sub}"), ds)
            else:
                block = QBasicBlock(self.inplanes, planes, bstride,
                                    self._wq(f"{prefix}.conv1"), self._wq(f"{prefix}.conv2"), ds)
            self.inplanes = planes
            layers.append(block)
        return nn.Sequential(*layers)

    def _make_deconv(self, inp, outp, num):
        layers = []
        for i in range(num):
            layers += [_qconv(inp, outp, 4, 2, 1, self._wq(f"deconv.{i}"), transpose=True),
                       nn.BatchNorm2d(outp), qnn.QuantReLU(act_quant=A_RELU)]
            inp = outp
        return nn.Sequential(*layers)

    def _init_head(self):
        for m in self.deconv_layers.modules():
            if isinstance(m, qnn.QuantConvTranspose2d):
                nn.init.normal_(m.weight, std=0.001)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.constant_(m.weight, 1); nn.init.constant_(m.bias, 0)
        nn.init.normal_(self.final_layer.weight, std=0.001)
        nn.init.constant_(self.final_layer.bias, 0)

    def forward(self, x):
        x = self.input_quant(x)
        x = self.maxpool(self.relu(self.bn1(self.conv1(x))))
        for i in range(len(self.arch.blocks)):
            x = getattr(self, f"layer{i+1}")(x)
        x = self.deconv_layers(x)
        return self.final_layer(x)

    # Discipline B helpers (same API as src.quant_model.PoseResNet18Quant)
    def twn_modules(self):
        return {n: m for n, m in self.named_modules() if getattr(m, "_twn", False)}

    def verify_all_ternary(self):
        from src.twn import verify_ternary
        return [verify_ternary(m, name=n) for n, m in self.twn_modules().items()]


def load_imagenet_partial(model):
    """Best-effort: load torchvision ResNet-18 ImageNet weights into matching-name,
    matching-shape params (only helps when width_mult==1.0 and the block exists)."""
    from torchvision.models import ResNet18_Weights, resnet18
    sd = resnet18(weights=ResNet18_Weights.IMAGENET1K_V1).state_dict()
    own = model.state_dict()
    transfer = {k: v for k, v in sd.items() if k in own and own[k].shape == v.shape}
    model.load_state_dict(transfer, strict=False)
    return len(transfer)
