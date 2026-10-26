"""Paths, classes and geometry of the detection task."""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))      # train/coco_det
DATA = os.environ.get("COCO_ROOT", os.path.join(ROOT, "data"))           # data/ -> the COCO folder
TRAIN_IMAGES = os.path.join(DATA, "train2017")
VAL_IMAGES = os.path.join(DATA, "val2017")
TRAIN_JSON = os.path.join(DATA, "annotations", "instances_train2017.json")
VAL_JSON = os.path.join(DATA, "annotations", "instances_val2017.json")
CACHE = os.path.join(ROOT, "runs", "cache")                               # compact annotation arrays
EXP_DIR = os.environ.get("DET_EXP_DIR", os.path.join(ROOT, "checkpoints"))
POSE_CKPT = os.path.join(ROOT, "..", "..", "artifacts", "mbv2_pose", "probe_tern_dc32_best.pth")

# 12 COCO categories that matter indoors: (name, COCO category id). Order = output channel.
# v1: the first detector (det12_tern_cont). v2: bottle and cup, too small at a 256 input to be found,
# replaced by oven and potted plant in the same channels. DET_CLASSSET selects one (default v2);
# evaluate or render a v1 checkpoint with DET_CLASSSET=v1.
CLASS_SETS = {
    "v1": [("person", 1), ("bottle", 44), ("cup", 47), ("chair", 62), ("couch", 63), ("bed", 65),
           ("dining table", 67), ("toilet", 70), ("tv", 72), ("laptop", 73), ("sink", 81),
           ("refrigerator", 82)],
    "v2": [("person", 1), ("oven", 79), ("potted plant", 64), ("chair", 62), ("couch", 63), ("bed", 65),
           ("dining table", 67), ("toilet", 70), ("tv", 72), ("laptop", 73), ("sink", 81),
           ("refrigerator", 82)],
}
CLASSSET = os.environ.get("DET_CLASSSET", "v2")
CLASSES = CLASS_SETS[CLASSSET]
NUM_CLASSES = len(CLASSES)                 # 12 heatmap channels
CAT_IDS = [c for _, c in CLASSES]
CH_WH = (12, 13)                           # box width, height in input pixels / WH_UNIT
CH_OFF = (14, 15)                          # sub-pixel centre offset in output pixels, [0, 1)
WH_UNIT = 32.0                             # keeps the size channels near the heatmap logits' range

INPUT = 256                                # network input, square
STRIDE = 4                                 # output 64 x 64
OUT = INPUT // STRIDE
MAX_OBJ = 96
MEAN = (0.485, 0.456, 0.406)               # RGB, the pose model's normalisation
STD = (0.229, 0.224, 0.225)
PAD_RGB = (124, 116, 104)                  # letterbox fill = the mean pixel
