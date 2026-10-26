"""Paths, classes and geometry of the indoor scene-segmentation task."""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))      # train/coco_seg
DATA = os.path.join(ROOT, "data")
COCO = os.environ.get("COCO_ROOT", os.path.join(DATA, "coco"))           # images
STUFF = os.environ.get("COCOSTUFF_ROOT", os.path.join(DATA, "stuff"))     # stuffthingmaps
IMAGES = {"train": os.path.join(COCO, "train2017"), "val": os.path.join(COCO, "val2017")}
MAPS = {"train": os.path.join(STUFF, "train2017"), "val": os.path.join(STUFF, "val2017")}
CACHE = os.path.join(ROOT, "runs", "cache")
EXP_DIR = os.environ.get("SEG_EXP_DIR", os.path.join(ROOT, "checkpoints"))
POSE_CKPT = os.path.join(ROOT, "..", "..", "artifacts", "mbv2_pose", "probe_tern_dc32_best.pth")

# 16 output classes. Each lists the COCO-Stuff label ids (labels.txt, 1..182) merged into it;
# a labelled pixel in none of them is class 0 "other"; unlabelled pixels are ignored (255).
CLASSES = [
    ("other", []),
    ("person", [1]),
    ("floor", [101, 114, 115, 116, 117, 118, 131, 152]),       # carpet, floor-*, mat, rug
    ("wall", [171, 172, 173, 174, 175, 176, 177]),
    ("ceiling", [102, 103]),
    ("window", [68, 109, 180, 181]),                            # window, curtain, blind
    ("door", [71, 112]),
    ("bed", [65, 93, 141]),                                     # bed, blanket, pillow
    ("chair", [62]),
    ("couch", [63]),
    ("table", [67, 69, 107, 110, 165]),                         # dining table, desk, counter, table
    ("cabinet", [98, 108, 123, 156]),                           # cabinet, cupboard, furniture-other, shelf
    ("appliance", [72, 73, 76, 78, 79, 80, 82]),                # tv, laptop, keyboard, microwave, oven, toaster, fridge
    ("toilet/sink", [70, 81]),
    ("plant", [64, 86, 119, 142]),                              # potted plant, vase, flower, plant-other
    ("stairs", [161]),
]
NUM_CLASSES = len(CLASSES)
IGNORE = 255
# An image counts as indoor when this many of its labelled pixels are floor, wall, ceiling,
# window, door, bed, couch, table, cabinet, appliance, toilet/sink or stairs.
INDOOR_CLASSES = (2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 15)
INDOOR_MIN_FRAC = 0.20

INPUT = 256
STRIDE = 4
OUT = INPUT // STRIDE
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)
PAD_RGB = (124, 116, 104)

# display colours (RGB) of the 16 classes
PALETTE = [
    (0, 0, 0), (220, 20, 60), (152, 120, 80), (180, 180, 170), (240, 240, 210), (90, 170, 230),
    (140, 80, 40), (120, 60, 200), (250, 170, 30), (230, 90, 160), (110, 200, 110),
    (60, 110, 160), (40, 40, 220), (0, 200, 200), (30, 140, 30), (255, 230, 0),
]
