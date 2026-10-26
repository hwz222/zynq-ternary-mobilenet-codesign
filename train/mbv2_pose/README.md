# train/mbv2_pose

Training, scoring and export code for the pose network that runs on the board, `models/mbv2_pose/`.
It holds only what the deployed model's training, its scoring and its export execute; the code was
extracted from an earlier, non-public research code base (see "Provenance of the code" below).

Since 2026-10-12 the deployed model is **`probe_tern_dc32`** (lineage step 3 below). Before that the
board ran `room_mix_w3_head32`, an earlier deployed pose model (superseded, not released); its
recipe is not part of this repository.

## The model

MobileNetV2 (width 1.0, `features[:18]`, stride 32), a head of three 4x4 stride-2 transposed
convolutions with 32 channels, and a final 1x1 convolution; 14 MPII joints, 256 x 256 input,
64 x 64 heatmaps. Quantisation-aware training with Brevitas: the 33 pointwise 1x1 convolutions and the
3x3 stem, 34 layers in all, are ternary {-1, 0, +1} with one scale per tensor (TWN, `src/twn.py`,
region `pw_stem`); the depthwise convolutions, the transposed-convolution head and the final 1x1 are
INT8. The exported network has 65 operators and 1,715,936 ternary weights.

Recipe of `probe_tern_dc32`: the backbone of `sports_r2_w3` (step 2: an earlier ternary model
fine-tuned on MPII plus Penn Action with knowledge distillation) is frozen, the head is
re-initialised and trained alone with the ground-truth loss on MPII plus Penn Action.

Its accuracy and the zero fraction of its ternary weights are recorded in
`results/board_results.json`: `thesis_model_probe_tern_dc32_host_20261012` (host ruler,
`src/score_ckpt.py`, with the same-recipe INT8 counterpart) and
`thesis_model_probe_tern_dc32_board_20261012` (the integer network on the board over the whole MPII
validation split, `src/score_board.py`). The training loop's own PCKh differs from the standalone
one by up to 0.1; quote only the standalone one.

Exported files (SHA-256, first 16 hex digits), identical to `models/mbv2_pose/`:

| file | sha256-16 |
|---|---|
| `model_mbv2.bin` | `accd59743da29a6e` |
| `model_mbv2_packed.bin` | `67728c886e2a4618` |
| `fixtures/fix_0..3.bin` | `00ba35795fa6dcc8`, `cce0dc613522cd92`, `56c627da6f831221`, `2ef37ef2fc46b274` |

## Lineage (initialisation chain)

| step | checkpoint | sha256-16 | started from | recipe | released |
|---|---|---|---|---|---|
| 1 | `mbv2_dc32_pwstem_ftI30` | `bd48a9e78d0c8316` | an earlier float and ternary chain | not part of this repository | no |
| 2 | `sports_r2_w3` | `cfd666b058b96a1d` | step 1 | MPII + Penn Action (x3.0), 30 epochs, batch 32, lr 2.5e-4 cosine, knowledge distillation from a ResNet-18 float teacher | yes, `sports_r2_w3_best.pth` (input of step 3) |
| 3 | **`probe_tern_dc32`** (deployed) | `c731da80a73704c9` | step 2 backbone (frozen), head re-initialised | head only (197,265 parameters), plain ground-truth loss, no teacher, 18 epochs, batch 48, lr 1e-3 (x0.1 at epochs 10 and 15), MPII + Penn Action uniform over records, seed 42 | yes, `probe_tern_dc32_best.pth` |
| - | `room_mix_w3_head32` (deployed until 2026-10-12) | `789dd3b3bfb71cfe` | step 3 | an earlier deployed pose model, superseded; recipe not included | no |

Step 1 cannot be reproduced from this repository, and step 2 only as its checkpoint (its training
entry was not carried over). Step 3 needs only `checkpoints/sports_r2_w3/best.pth`, which
`python tools/fetch_release.py --group checkpoints` (from the repository root) puts in place; this
is why `sports_r2_w3_best.pth` is a release asset. Training is not
bit-reproducible (cuDNN autotuning, data-loader order): a retrain gives a nearby PCKh, not the same
checkpoint.

## Layout

```
src/        config, dataset, heatmaps, transforms; mbv2_model, quant_model, compress_model, twn (model and
            quantisation); model (ResNet-18, the distillation teacher of step 2; not used by step 3); build_model (ternary region keys and builder);
            train (loop, loss); probe_head_capacity (the head-only stage of step 3); run_recipe (launcher); evaluate (PCKh); score_ckpt (the standalone ruler);
            score_board (the same ruler on the integer network's outputs from the board or the C
            reference); build_mpii_annot (MPII .mat -> train/valid JSON); demo
configs/    probe_tern_dc32.json (the deployed model, step 3)
export/     export_board_model.py (driver) + extract_mbv2.py, pack_ternary.py, append_hd_pl.py
checkpoints/  ignored by git: <name>/best.pth
data/         ignored by git: mpii|sports/annot/{train,valid}.json
runs/         ignored by git: training work directories and export scratch
```

## Data

| set | records train / valid | where the label files come from | images |
|---|---|---|---|
| `mpii` | 16,896 / 2,289 (the validation split is the ruler) | `python -m src.build_mpii_annot --mat <mpii>/mpii_human_pose_v1_u12_1.mat` | `TWN_MPII_IMAGES` |
| `sports` (Penn Action) | 5,470 / 903 | made with a tool of the earlier code base (Penn Action labels, head top and neck from a teacher network, quality gates); not included | `TWN_SPORTS_IMAGES` (the Penn Action `frames` folder) |

`build_mpii_annot` uses only the `single_person` instances of the `img_train == 1` images and splits
by image with seed 42 (12 % of the images for validation). On the official
`mpii_human_pose_v1_u12_1.mat` it writes these files (SHA-256, also in `tools/release_assets.json`):

| file | sha256 |
|---|---|
| `data/mpii/annot/train.json` | `5d28476312bdc6b075359dd9ce6552f413e20d3b6ecb6a216d7193087d74d16b` |
| `data/mpii/annot/valid.json` | `20de57f70ea91ffc46814d243145df56c8e0012f4e65a7cb74709952da4fa83b` |
| `data/mpii/annot/meta.json` | `0f49522d706001a1e71eabcfb4472268f91c23c868e029099d8bcff955bbf562` |

Label files are expected in `data/<set>/annot/`; `TWN_DATA_ROOT` moves the whole `data/` directory,
and the image variables above override the default `data/<set>/images`. The MPII validation split is
never mixed into training (`TWN_EXTRA_SPLITS=train`). Without the Penn Action labels you can still
score, export and regenerate the fixtures; only training step 3 needs them.

## Commands

All from `train/mbv2_pose/`, in the training environment ([`../README.md`](../README.md)).

1. Environment variables (PowerShell shown; use `export` in bash):

       $env:PYTHONUTF8 = 1
       $env:TWN_MPII_IMAGES   = "<mpii>\images"
       $env:TWN_SPORTS_IMAGES = "<penn_action>\frames"

2. Train (never inside `checkpoints/`: training resumes from `last.pth` and overwrites `best.pth`;
   the launcher refuses, and copies the checkpoints it needs from `checkpoints/` into the work
   directory):

       python -m src.run_recipe configs/probe_tern_dc32.json --stage B --workdir runs/probe_tern_dc32

3. Score with the single ruler (`--expect` takes the value of the results entry, tolerance 0.005):

       python -m src.score_ckpt ../../artifacts/mbv2_pose/probe_tern_dc32_best.pth --expect 85.992

   The integer network on the board over the whole validation split: `src/score_board.py`
   (`inputs`, then `sw/app/mbv2_fuse_eval` on the board, then `score`; `compare` against
   `golden/ref_batch`), see [`docs/REBUILD.md`](../../docs/REBUILD.md).

4. Export. The driver first runs the ternary check (34 layers, values in {-1, 0, +1}, zeros present;
   a failing model is not exported), then `extract_mbv2.py --strict-int8`, `pack_ternary.py` and
   `append_hd_pl.py`. It needs the MPII validation images (32 for calibration, 4 for the fixtures):

       python export/export_board_model.py --ckpt ../../artifacts/mbv2_pose/probe_tern_dc32_best.pth --out runs/export/final
       # result in runs/export/final/models_layout/; --install writes into ../../models/mbv2_pose instead

5. Verify: all nine files must equal the shipped set (`model_mbv2.bin`, `model_mbv2_packed.bin`,
   `model_meta.c`, `model_meta.h`, `pack_meta_mbv2.h`, `fixtures/fix_0..3.bin`): compare the binaries
   with the SHA-256 values above or in `tools/release_assets.json`, and the text files with
   `git diff --no-index` (a checkout with `core.autocrlf=true` may give `model_meta.c` CRLF line
   endings, which a byte comparison reports as different).

   Smoke test of the training entry points on a tiny label subset: point `TWN_DATA_ROOT` at a
   directory with truncated `annot/{train,valid}.json` per set and use `--epochs 1 --workdir <scratch>`.

During `--strict-int8` extraction the printed "argmax agreement vs Brevitas" is low (a few of 16
images with all 14 joints at the same position). The integer network really differs from the
quantisation-aware model; its PCKh over the whole validation split, measured on the board and equal to
the C reference, is in `thesis_model_probe_tern_dc32_board_20261012`.

## Provenance of the code

- `src/build_model.py` is the used part of the earlier code base's experiment orchestrator
  (`set_seed`, `region_keys`, `build_quant`, `TEACHER`); branches for other backbone families were
  removed, the MobileNetV2 code is unchanged.
- `export/*.py`: the header comments that the exporter writes into `model_meta.c/.h` and
  `pack_meta_mbv2.h` match the files in `models/mbv2_pose` (comment-only change).
- `export/export_board_model.py` replaces the earlier PowerShell export chain and adds the ternary
  gate and the file mapping into the `models/` layout.
- `src/run_recipe.py`, `src/build_mpii_annot.py` (unchanged split logic, with command-line paths) and
  the two configs are new in this repository.
- Default data and output directories derive from this folder (`TWN_DATA_ROOT`, `TWN_EXP_DIR` and the
  image variables override them).
