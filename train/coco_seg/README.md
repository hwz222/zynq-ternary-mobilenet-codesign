# train/coco_seg

16-class indoor scene segmentation on the accelerator's network.

The board's fixed network (ternary MobileNetV2 backbone, 32-channel deconvolution head, 16-channel
1x1 output) with each output channel the logit of one class; the processor takes the per-pixel arg-max
of the 64x64 map and scales it to the image.

Classes (merged from COCO-Stuff's 182 labels, `src/config.py`): other, person, floor (incl. carpet,
rug, mat), wall, ceiling, window (incl. curtain, blind), door, bed (incl. pillow, blanket), chair,
couch, table (incl. desk, counter), cabinet (incl. cupboard, shelf, other furniture), appliance (tv,
laptop, keyboard, microwave, oven, toaster, fridge), toilet/sink, plant, stairs.

## Layout

```
src/        qmodel.py, twn.py, config.py (classes, palette, indoor rule), data.py, train.py,
            evaluate.py (the ruler), demo.py
configs/    one JSON per run
launch.ps1  detached launcher
data/coco   directory link to the COCO folder (images)          (ignored)
data/stuff  directory link to the COCO-Stuff folder (label maps) (ignored)
checkpoints/<exp_id>/, runs/                               (ignored)
```

## Data

COCO-Stuff 164K pixel maps (`stuffthingmaps_trainval2017.zip`, CC BY 4.0) on the COCO 2017 images.
Only indoor images are used: at least 20 % of the labelled pixels are floor, wall, ceiling, window,
door, bed, couch, table, cabinet, appliance, toilet/sink or stairs. That keeps 47,305 of 118,287 train
images and 2,011 of 5,000 val images. The delivered checkpoints are release assets
(`python tools/fetch_release.py --group checkpoints` from the repository root puts them in
`artifacts/coco_seg/`).

## Commands (from this folder, training environment, see ../README.md)

    powershell -File launch.ps1 configs/seg16_tern_pose.json
    python -m src.evaluate checkpoints/seg16_tern_pose/best.pth
    python -m src.demo --ckpt checkpoints/seg16_tern_pose/best.pth --video in.mp4 --out runs/demo.mp4

## Ruler

Mean IoU over the 16 classes on the 2,011 indoor val2017 images at each image's original resolution
(logits upsampled bilinearly, letterbox removed), unlabelled pixels ignored. Results go to `results/`.

## Earlier model: the head initialisation of the delivered one

1. `configs/seg16_tern_pose.json`: pose backbone, 12 epochs.
2. `python -m src.recal_bn checkpoints/seg16_tern_pose/last.pth`: BatchNorm statistics re-estimated on
   200 batches of un-augmented indoor training images (weights unchanged) -> `last_bn.pth`, used as
   `artifacts/coco_seg/seg16_tern_pose_last_bn.pth`. Numbers: `results/task_results.json`.

The original runs of these steps started from the backbone of an earlier deployed pose model
(superseded, not released), and their result `artifacts/coco_seg/seg16_tern_pose_last_bn.pth` is not released
either. `src/config.py` now points the pose backbone (`POSE_CKPT`) at the deployed
`probe_tern_dc32`, so re-running these steps gives a comparable but not identical head
initialisation for the delivered model below; pass its path as `head_ckpt` in `configs/seg16_tern_probe.json`.

In `src/demo.py` class 0 "other" is left uncoloured so unlabelled regions keep the image's colours.

## Delivered model since 2026-10-13: on the deployed pose backbone

1. `configs/seg16_tern_probe.json`: `init: rebase` - backbone from probe_tern_dc32, head from
   `artifacts/coco_seg/seg16_tern_pose_last_bn.pth`, 6 epochs, indoor images with a person lying down
   (`src/lying.py`) sampled x3.
2. `configs/seg16_tern_probe_cont.json`: 6 more epochs from step 1 (BatchNorm re-estimated).
3. `python -m src.recal_bn checkpoints/seg16_tern_probe_cont/last.pth` ->
   `artifacts/coco_seg/seg16_tern_probe_cont_last_bn.pth`.
