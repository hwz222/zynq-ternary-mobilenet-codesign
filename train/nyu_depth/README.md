# train/nyu_depth

Monocular metric depth on the accelerator's network.

The board's fixed network with output channel 0 trained as log(depth in metres); channels 1-15 are
trained to zero. The processor computes exp() of channel 0 and scales the 64x64 map to the image.

## Layout

```
src/        qmodel.py, twn.py, config.py, data.py, train.py, evaluate.py (the ruler), demo.py
configs/    one JSON per run
launch.ps1  detached launcher
data/       directory link to the NYU folder: train/ (47,584 h5 frames), val/official/ (654) (ignored)
checkpoints/<exp_id>/, runs/                                                       (ignored)
```

## Data

NYU Depth V2 in the FastDepth h5 layout from `huggingface.co/datasets/sayakpaul/nyu_depth_v2`
(card: Apache-2.0; the underlying NYU data is for research use): 47,584 training frames from the raw
sequences and the 654 official test frames. Each h5 holds `rgb` (3x480x640 uint8) and `depth`
(480x640 float32, metres); the dataset page lists the 14 tar files. The delivered checkpoints are
release assets (`python tools/fetch_release.py --group checkpoints` from the repository root puts
them in `artifacts/nyu_depth/`).

## Commands (from this folder, training environment, see ../README.md)

    powershell -File launch.ps1 configs/depth_tern_pose.json
    python -m src.evaluate checkpoints/depth_tern_pose/best.pth
    python -m src.demo --ckpt checkpoints/depth_tern_pose/best.pth --video in.mp4 --out runs/demo.mp4

## Ruler

The standard NYU metrics on the 654 official test frames at 640x480 inside the Eigen crop
(rows 45-470, columns 41-600), ground truth in (0.001, 10] m, no scale alignment: delta < 1.25,
AbsRel, RMSE (and delta2, delta3, SqRel, RMSE-log, log10). Results go to `results/`.

## Earlier model: the head initialisation of the delivered one

1. `configs/depth_tern_pose.json`: pose backbone, 8 epochs on NYU only. Good on NYU's own test set,
   but blurred and wrong on scenes outside NYU (a person placed beyond 6 m in a dark clip).
2. Teacher labels: `src/pseudo_label.py` (run in a copy of the training environment with
   `transformers` added) writes metric depth from Depth Anything V2 metric indoor Small for 23,996 indoor COCO
   train images to `data/pseudo_coco/`. `data/coco` is a directory link to the COCO folder.
3. `configs/depth_tern_distill.json`: 6 epochs from step 1 (BatchNorm re-estimated) on NYU plus the
   teacher-labelled images.
4. `python -m src.recal_bn checkpoints/depth_tern_distill/best.pth --pseudo`: BatchNorm statistics
   re-estimated on the same mix -> `best_bn.pth`, used as
   `artifacts/nyu_depth/depth_tern_distill_best_bn.pth`. Numbers: `results/task_results.json`.

The original runs of these steps started from the backbone of an earlier deployed pose model
(superseded, not released), and their result `artifacts/nyu_depth/depth_tern_distill_best_bn.pth` is not released
either. `src/config.py` now points the pose backbone (`POSE_CKPT`) at the deployed
`probe_tern_dc32`, so re-running these steps gives a comparable but not identical head
initialisation for the delivered model below; pass its path as `head_ckpt` in `configs/depth_tern_probe.json`.

## Delivered model since 2026-10-13: on the deployed pose backbone

1. `configs/depth_tern_probe.json`: `init: rebase` - backbone from probe_tern_dc32, head from
   `artifacts/nyu_depth/depth_tern_distill_best_bn.pth`, 4 epochs on NYU + the teacher-labelled images.
2. `configs/depth_tern_probe_cont.json`: 4 more epochs from step 1 (BatchNorm re-estimated).
3. `python -m src.recal_bn checkpoints/depth_tern_probe_cont/last.pth --pseudo` ->
   `artifacts/nyu_depth/depth_tern_probe_cont_last_bn.pth`.
