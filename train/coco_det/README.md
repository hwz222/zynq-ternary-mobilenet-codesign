# train/coco_det

12-class object detection on the accelerator's network.

CenterNet-style detection with the board's fixed network: the same MobileNetV2 backbone (ternary
pointwise + stem), the same 32-channel deconvolution head and 16-channel 1x1 output as `mbv2_pose`.
Only the meaning of the 16 output channels and the weights differ.

| output channels | meaning |
|---|---|
| 0-11 | centre heatmaps (sigmoid on the processor) of person, bottle, cup, chair, couch, bed, dining table, toilet, tv, laptop, sink, refrigerator |
| 12, 13 | box width and height, in input pixels / 32 |
| 14, 15 | sub-pixel centre offset, output pixels |

Input: the image letterboxed to 256x256 (mean-pixel padding), RGB, ImageNet normalisation; output
64x64 (stride 4). Decoding on the processor: sigmoid, 3x3 peak picking, top-k, box = (cell + offset) x 4
+- size x 32 / 2, then undo the letterbox (`src/centernet.py`, `src/evaluate.py`).

## Layout

```
src/        qmodel.py (network, copied from mbv2_pose and trimmed), twn.py, config.py, data.py,
            centernet.py (targets, loss, decode), train.py, evaluate.py (the ruler), demo.py
configs/    one JSON per run
launch.ps1  detached launcher
data/       directory link to the COCO folder: train2017/, val2017/, annotations/   (ignored)
checkpoints/<exp_id>/  best.pth, last.pth, log.txt, metrics.jsonl            (ignored)
runs/       annotation cache, demo output                                     (ignored)
```

## Data

COCO 2017 (images: Flickr terms; annotations: CC BY 4.0): train2017 (118,287 images, 83,709 of them
contain at least one of the 12 classes and are used), val2017 (5,000 images, all used for the ruler).
Download `http://images.cocodataset.org/zips/train2017.zip`, `val2017.zip` and
`annotations_trainval2017.zip` from the COCO website. The delivered checkpoints are release assets
(`python tools/fetch_release.py --group checkpoints` from the repository root puts them in
`artifacts/coco_det/`).

## Commands (from this folder, training environment, see ../README.md)

    powershell -File launch.ps1 configs/det12_tern_pose.json          # train, detached
    python -m src.evaluate checkpoints/det12_tern_pose/best.pth        # the ruler
    python -m src.demo --ckpt checkpoints/det12_tern_pose/best.pth --video in.mp4 --out runs/demo.mp4

## Ruler

COCO box AP@[0.5:0.95] (pycocotools COCOeval) on all 5,000 val2017 images restricted to the 12 category
ids, boxes mapped back to original image coordinates. Results go to `results/`, not here.

## Earlier model: the head initialisation of the delivered one

1. `configs/det12_tern_pose.json`: pose backbone, 9 epochs (planned 24; shortened to 14 after epoch 6,
   stopped after epoch 9 when the demo showed almost no furniture detections).
2. `configs/diag/*.json` (`runs_diag.ps1`): four 2-epoch comparison arms on a fixed 30,000-image subset
   (pose vs ImageNet start, ternary vs INT8). They learned at the same slow rate, so the recipe was kept.
3. `configs/det12_tern_cont.json`: 16 more epochs from step 1, images with a non-person class sampled x3.
4. `python -m src.recal_bn checkpoints/det12_tern_cont/best.pth`: BatchNorm statistics re-estimated on
   200 batches of un-augmented training images (weights unchanged) -> `best_bn.pth`, used as
   `artifacts/coco_det/det12_tern_cont_best_bn.pth`. Numbers: `results/task_results.json`.

The original runs of these steps started from the backbone of an earlier deployed pose model
(superseded, not released), and their result `artifacts/coco_det/det12_tern_cont_best_bn.pth` is not released
either. `src/config.py` now points the pose backbone (`POSE_CKPT`) at the deployed
`probe_tern_dc32`, so re-running these steps (for the detector with `DET_CLASSSET=v1`) gives a comparable but not identical head
initialisation for the delivered model below; pass its path as `head_ckpt` in `configs/det12v2_tern_probe.json`.

The val AP swings between epochs even at a near-zero learning rate; that is BatchNorm running
statistics drifting with the augmented batches, and step 4 removes it. Re-estimate before evaluating
any checkpoint you intend to keep.

## Delivered model since 2026-10-13: class set v2 on the deployed pose backbone

The delivered detector starts from the
deployed pose model `probe_tern_dc32`, and replaces bottle and cup (AP 1.7 and 3.8, too small at a 256
input) by oven and potted plant (`DET_CLASSSET=v2`, the default; use `DET_CLASSSET=v1` for the older
checkpoint, which has its own annotation cache).

1. `configs/det12v2_tern_probe.json`: `init: rebase` - backbone from probe_tern_dc32, head from
   `artifacts/coco_det/det12_tern_cont_best_bn.pth` with the two changed classes' output rows
   re-initialised (`head_rows`), 8 epochs, images with furniture and images with a person lying down
   (`src/lying.py`) both sampled x3.
2. `configs/det12v2_tern_probe_cont.json`: 12 more epochs from step 1.
3. `python -m src.recal_bn ...` -> `artifacts/coco_det/det12v2_tern_probe_cont_best_bn.pth`.

`python -m src.lying_recall CKPT [--thr]` counts how many of the 108 lying people in COCO val2017 get a
person box (IoU >= 0.5). `src/demo.py --boxes-out` writes per-frame person boxes for
`train/pose_fallEnhancement`'s two-stage demo. `src/video_boxes.py` writes every person box >= 0.05 of
each frame of a video or a zip of frames, the input of that workspace's fall detection.
