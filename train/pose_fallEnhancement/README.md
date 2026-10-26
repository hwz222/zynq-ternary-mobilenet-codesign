# train/pose_fallEnhancement

The pose model, fine-tuned to also handle people lying down, and a fall-alarm prototype.

The deployed pose model `probe_tern_dc32` (`artifacts/mbv2_pose/probe_tern_dc32_best.pth`, a release
asset) fine-tuned so
that it also finds the joints of people lying on the floor, the case that matters for falls. Same
network and quantisation as `train/mbv2_pose` (ternary pointwise + stem, INT8 depthwise and head,
14 joint heatmaps), so it can replace the pose weights on the board without any hardware change.

## Layout

```
src/        copy of train/mbv2_pose/src (model, quantisation, MPII dataset, ruler, demo) plus:
            build_coco_lying.py  COCO people lying down -> MPII-schema records
            train_fall.py        the fine-tune (two rulers each epoch)
            recal_bn.py          BatchNorm re-estimation + both rulers
            dataset.py           + ROT90_AUG: turn a share of the crops by +-90 degrees
            demo.py              + --boxes: run on a crop around a detected person (two-stage)
            fall_features.py     person tracks + joints per frame of a video (fall detection, below)
            fall_rules.py        the fall rule and its score on the URFD labels
            fall_tune.py         rule parameters chosen on half of URFD, reported on the other half
            fall_demo.py         fall-detection demo video
configs/    one JSON per run
launch.ps1  detached launcher (runs src.train_fall)
data/mpii/annot, data/sports/annot   label files copied from train/mbv2_pose      (ignored)
data/coco_lying/annot                built by src.build_coco_lying              (ignored)
data/coco                            directory link to the COCO folder                (ignored)
data/urfd                            directory link to the URFD folder: *-cam0-rgb.zip, label CSVs (ignored)
checkpoints/<exp_id>/, runs/                                                  (ignored)
```

Images: MPII from `TWN_MPII_IMAGES`, Penn Action frames from `TWN_SPORTS_IMAGES` (defaults
`data/mpii/images` and `data/sports/images`), COCO through `data/coco`. The label files of MPII and
Penn Action are those of `train/mbv2_pose` (see its README).

## Data

A COCO person counts as lying when it has >= 8 labelled keypoints, a shoulder and a hip, and the torso
is more than 60 degrees from upright: 2,346 people in train2017, 108 in val2017. COCO has no head top
and no upper neck, so those two joints carry no loss on these records.

## Commands (from this folder, training environment, see ../README.md)

    python -m src.build_coco_lying
    powershell -File launch.ps1 configs/pose_fallEnhancement.json
    python -m src.score_ckpt pose_fallEnhancement                      # MPII ruler, standalone
    python -m src.demo --ckpt checkpoints/pose_fallEnhancement/best.pth --video in.mp4 --out out.mp4 \
        [--boxes person_boxes.json]                                    # boxes from train/coco_det's demo

## Rulers

- MPII val, 2,289 people, PCKh@0.5, 14 joints, `src.score_ckpt` (the project ruler; must stay close
  to probe_tern_dc32's 85.992).
- COCO-lying val, 108 people, a joint is correct within 0.1 x the longer side of the person box,
  12 joints (`src/build_coco_lying.py` encodes this through the record's head box).

Numbers: `results/task_results.json`.

## How the delivered model was made

`configs/pose_fallEnhancement.json`: every tensor of probe_tern_dc32, then 8 epochs of full fine-tuning
on MPII + sports + the COCO lying people sampled x4, 15 % of crops turned by +-90 degrees, colour
jitter on 30 %. The last epoch is the delivered one. BatchNorm re-estimation is NOT applied here: it
lowered both rulers for this model (MPII 85.04 -> 84.40), unlike the task models.

A comparison arm with BatchNorm frozen and a 3x lower learning rate
(`configs/pose_fallEnhancement_gentle.json`) still lost 2.7 MPII points in its first epoch and was
stopped; the loss of MPII accuracy comes from the weight updates, and it recovers as the learning rate
decays.

## Two-stage use

On a whole camera frame a fallen person is small and off-centre, and the single-person model fails.
Run `train/coco_det`'s demo with `--boxes-out` to get person boxes per frame, then this demo with
`--boxes`: the pose model then sees a crop around the person, as in training. Both stages run on the
same accelerator (two weight sets).

## Fall detection (host prototype)

Goal: an alarm within about a second of a person falling. The fall is detected as a change, not from
one frame: the person is tracked while upright, where both networks are reliable, and the alarm fires
when the track turns from upright to lying fast.

1. In `train/coco_det`: `python -m src.video_boxes --ckpt ../../artifacts/coco_det/det12v2_tern_probe_cont_best_bn.pth
   --inputs <urfd>/*-cam0-rgb.zip --out-dir runs/urfd_boxes` writes every person box >= 0.05 per frame.
2. `python -m src.fall_features --boxes ../coco_det/runs/urfd_boxes --frames data/urfd --mode track --rot
   --out runs/fall/track_rot`: up to 4 person tracks (a fixed camera also sees person-like things, such
   as a chair with a coat, that score as high as the person), box size change per frame limited to
   0.5-2x, joint-following for 1.5 s when the detector loses the person, pose crops turned by +-90
   degrees when the person is wide or tilted.
3. `python -m src.fall_rules runs/fall/track_rot [--split odd|even|all]`: the rule (module docstring);
   its defaults are the parameters chosen by `python -m src.fall_tune runs/fall/track_rot --json <out>`.
4. `python -m src.fall_demo runs/fall/track_rot/<seq>.json --out <mp4>`: video with the state, the alarm
   banner and a time strip of the box shape.

Data: UR Fall Detection Dataset, cam0 RGB, 30 falls and 40 daily activities with per-frame labels
(https://fenix.ur.edu.pl/~mkepski/ds/uf.html), kept outside the repository with the other datasets
and not redistributed.
Parameters are chosen on the odd-numbered sequences and reported on the even-numbered ones. Numbers:
`results/task_results.json`, entry `fall_detect_urfd_20261013`.
