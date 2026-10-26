"""FP32 SimpleBaseline: ResNet-18 backbone (torchvision-named) + deconv head.

Backbone parameter names mirror torchvision.resnet18 exactly so ImageNet-pretrained
weights load directly. The Brevitas quant model (src/quant_model.py) mirrors these
names so weights relay across FP32 -> INT8 -> TWN via load_state_dict(strict=False).
"""
import torch
import torch.nn as nn

from src.config import NUM_JOINTS


def conv3x3(inp, outp, stride=1):
    return nn.Conv2d(inp, outp, 3, stride=stride, padding=1, bias=False)


def conv1x1(inp, outp, stride=1):
    return nn.Conv2d(inp, outp, 1, stride=stride, bias=False)


class BasicBlock(nn.Module):
    expansion = 1

    def __init__(self, inplanes, planes, stride=1, downsample=None):
        super().__init__()
        self.conv1 = conv3x3(inplanes, planes, stride)
        self.bn1 = nn.BatchNorm2d(planes)
        self.relu = nn.ReLU(inplace=True)
        self.conv2 = conv3x3(planes, planes)
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


class PoseResNet18(nn.Module):
    def __init__(self, num_joints=NUM_JOINTS, deconv_ch=256):
        super().__init__()
        self.inplanes = 64
        # --- stem ---
        self.conv1 = nn.Conv2d(3, 64, 7, stride=2, padding=3, bias=False)
        self.bn1 = nn.BatchNorm2d(64)
        self.relu = nn.ReLU(inplace=True)
        self.maxpool = nn.MaxPool2d(3, stride=2, padding=1)
        # --- stages ---
        self.layer1 = self._make_layer(64, 2, stride=1)
        self.layer2 = self._make_layer(128, 2, stride=2)
        self.layer3 = self._make_layer(256, 2, stride=2)
        self.layer4 = self._make_layer(512, 2, stride=2)
        # --- deconv head (3x upsample: 8->16->32->64) ---
        self.deconv_layers = self._make_deconv(512, deconv_ch, num=3)
        self.final_layer = nn.Conv2d(deconv_ch, num_joints, 1)
        self._init_head()

    def _make_layer(self, planes, blocks, stride):
        downsample = None
        if stride != 1 or self.inplanes != planes * BasicBlock.expansion:
            downsample = nn.Sequential(
                conv1x1(self.inplanes, planes * BasicBlock.expansion, stride),
                nn.BatchNorm2d(planes * BasicBlock.expansion),
            )
        layers = [BasicBlock(self.inplanes, planes, stride, downsample)]
        self.inplanes = planes * BasicBlock.expansion
        for _ in range(1, blocks):
            layers.append(BasicBlock(self.inplanes, planes))
        return nn.Sequential(*layers)

    def _make_deconv(self, inp, outp, num=3):
        layers = []
        for _ in range(num):
            layers += [
                nn.ConvTranspose2d(inp, outp, 4, stride=2, padding=1, output_padding=0, bias=False),
                nn.BatchNorm2d(outp),
                nn.ReLU(inplace=True),
            ]
            inp = outp
        return nn.Sequential(*layers)

    def _init_head(self):
        for m in list(self.deconv_layers.modules()):
            if isinstance(m, nn.ConvTranspose2d):
                nn.init.normal_(m.weight, std=0.001)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.constant_(m.weight, 1)
                nn.init.constant_(m.bias, 0)
        nn.init.normal_(self.final_layer.weight, std=0.001)
        nn.init.constant_(self.final_layer.bias, 0)

    def forward(self, x):
        x = self.maxpool(self.relu(self.bn1(self.conv1(x))))
        x = self.layer1(x)
        x = self.layer2(x)
        x = self.layer3(x)
        x = self.layer4(x)
        x = self.deconv_layers(x)
        return self.final_layer(x)


def load_imagenet_backbone(model):
    """Load torchvision ImageNet-pretrained ResNet-18 weights into the backbone."""
    from torchvision.models import ResNet18_Weights, resnet18
    sd = resnet18(weights=ResNet18_Weights.IMAGENET1K_V1).state_dict()
    # keep only backbone keys present in our model (conv1/bn1/layer1..4)
    own = model.state_dict()
    transfer = {k: v for k, v in sd.items() if k in own and own[k].shape == v.shape}
    missing = model.load_state_dict(transfer, strict=False)
    return len(transfer), missing
