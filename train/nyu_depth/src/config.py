"""Paths and geometry of the monocular depth task (NYU Depth V2, indoor, metric)."""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))      # train/nyu_depth
DATA = os.environ.get("NYU_ROOT", os.path.join(ROOT, "data"))            # data/ -> the NYU folder
TRAIN_DIR = os.path.join(DATA, "train")                                   # FastDepth h5: 47,584 frames
VAL_DIR = os.path.join(DATA, "val", "official")                           # the 654 official test frames
CACHE = os.path.join(ROOT, "runs", "cache")
EXP_DIR = os.environ.get("DEPTH_EXP_DIR", os.path.join(ROOT, "checkpoints"))
POSE_CKPT = os.path.join(ROOT, "..", "..", "artifacts", "mbv2_pose", "probe_tern_dc32_best.pth")

# Output channel 0 is log(depth in metres); channels 1..15 are trained to zero. The processor
# turns channel 0 into metres with exp().
CH_DEPTH = 0
MIN_DEPTH, MAX_DEPTH = 1e-3, 10.0
EIGEN_CROP = (45, 471, 41, 601)            # y0, y1, x0, x1 on 480x640: the standard NYU test crop

INPUT = 256
STRIDE = 4
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)
PAD_RGB = (124, 116, 104)
