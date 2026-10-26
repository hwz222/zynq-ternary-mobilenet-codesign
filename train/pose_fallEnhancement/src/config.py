"""Central config: paths, joint set, input/heatmap geometry. One ruler (Discipline C)."""
import os

# ROOT is train/mbv2_pose/. Every path below derives from it or from an environment variable.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# TWN_DATA_ROOT: directory holding mpii/{annot,images} and sports/{annot,images}
DATA_ROOT = os.environ.get("TWN_DATA_ROOT", os.path.join(ROOT, "data"))
DATA_DIR = os.path.join(DATA_ROOT, "mpii")
# image roots can be overridden one by one (the images are large and live outside the repo)
IMAGE_DIR = os.environ.get("TWN_MPII_IMAGES", os.path.join(DATA_DIR, "images"))
ANNOT_DIR = os.path.join(DATA_DIR, "annot")
SPORTS_ANNOT = os.path.join(DATA_ROOT, "sports", "annot")
SPORTS_IMAGES = os.environ.get("TWN_SPORTS_IMAGES", os.path.join(DATA_ROOT, "sports", "images"))
# training output and checkpoint store: <exp_id>/{best,last}.pth, metrics.jsonl. TWN_EXP_DIR redirects
# it (smoke tests write to a scratch directory so checkpoints/ is never touched).
CKPT_DIR = os.path.join(ROOT, "checkpoints")
EXP_DIR = os.environ.get("TWN_EXP_DIR", CKPT_DIR)

# --- Geometry ---
# Default 256 (the original, reproducible setup). Set env var TWN_INPUT_SIZE (e.g. 192)
# to run the IDENTICAL pipeline at another resolution; HEATMAP_SIZE always follows as
# input/4 (MBV2/R18 backbone /32 + 3x deconv x8 = net stride 4). When the env var is
# unset the 256 setup is byte-for-byte unchanged, so 256 stays fully reproducible.
_RES = int(os.environ.get("TWN_INPUT_SIZE", "256"))
assert _RES % 32 == 0, f"TWN_INPUT_SIZE must be a multiple of 32, got {_RES}"
INPUT_SIZE = (_RES, _RES)              # (w, h) fed to the network
HEATMAP_SIZE = (_RES // 4, _RES // 4)  # (w, h) output heatmaps
SIGMA = 2                   # gaussian sigma for target heatmaps
SC_BIAS = 0.6               # MPII head-size bias for PCKh normalization
PIXEL_STD = 200.0           # MPII scale unit: person box pixels = scale * 200

IMAGE_MEAN = [0.485, 0.456, 0.406]
IMAGE_STD = [0.229, 0.224, 0.225]

# --- Joint selection ---
# We keep 14 of MPII's 16 joints, dropping pelvis(6) and thorax(7) -- the two
# redundant torso-centre joints -- per the project charter's explicit list
# (shoulders, elbows, wrists, hips, knees, ankles, head-top, neck).
# Each entry: (our_name, mpii_id).
JOINTS = [
    ("head_top",   9),
    ("neck",       8),   # MPII "upper_neck"
    ("r_shoulder", 12),
    ("l_shoulder", 13),
    ("r_elbow",    11),
    ("l_elbow",    14),
    ("r_wrist",    10),
    ("l_wrist",    15),
    ("r_hip",       2),
    ("l_hip",       3),
    ("r_knee",      1),
    ("l_knee",      4),
    ("r_ankle",     0),
    ("l_ankle",     5),
]
JOINT_NAMES = [n for n, _ in JOINTS]
KEEP_MPII_IDS = [i for _, i in JOINTS]
NUM_JOINTS = len(JOINTS)  # 14

# Left/right pairs in OUR indexing, for horizontal-flip augmentation.
FLIP_PAIRS = [(2, 3), (4, 5), (6, 7), (8, 9), (10, 11), (12, 13)]

# Grouping for PCKh reporting (our indices).
PCKH_GROUPS = {
    "Head":     [0, 1],
    "Shoulder": [2, 3],
    "Elbow":    [4, 5],
    "Wrist":    [6, 7],
    "Hip":      [8, 9],
    "Knee":     [10, 11],
    "Ankle":    [12, 13],
}
