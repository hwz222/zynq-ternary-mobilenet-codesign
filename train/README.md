# train

Training, quantisation and export code for the networks that run on the accelerator, one
self-contained workspace per task. Models are exported into `models/<task>/`.

## Workspaces

| folder | task | the 16 output channels | on the board |
|---|---|---|---|
| [`mbv2_pose/`](mbv2_pose/README.md) | single-person pose, 14 joints: the deployed model | 14 joint heatmaps | yes |
| [`coco_det/`](coco_det/README.md) | object detection, 12 indoor COCO classes, CenterNet style | 12 centre heatmaps, box size, centre offset | not yet |
| [`coco_seg/`](coco_seg/README.md) | indoor scene segmentation, 16 classes merged from COCO-Stuff | 16 class logits per pixel | not yet |
| [`nyu_depth/`](nyu_depth/README.md) | monocular metric depth, NYU Depth V2 | log-depth on channel 0 | not yet |
| [`pose_fallEnhancement/`](pose_fallEnhancement/README.md) | the deployed pose model fine-tuned to also handle people lying down, plus a fall-alarm prototype | 14 joint heatmaps | not yet |

Every workspace uses the board's fixed network: the MobileNetV2 backbone with ternary pointwise and
stem convolutions, INT8 depthwise convolutions, a 32-channel INT8 transposed-convolution head and a
16-channel 1x1 output. Only the meaning of the output channels and the weights differ. The task
models are measured on the host (`results/task_results.json`); exporting them to the board's integer
format is future work.

## Layout of a workspace

```
train/<task>/
  src/           model, quantisation, data, training and evaluation code
  configs/       one JSON file per experiment (hyper-parameters, seed, data, initialisation)
  export/        exporter: checkpoint -> models/<task>/ (pose only, so far)
  launch.ps1     starts a training run detached from the terminal
  data/          datasets or links to them          (ignored by git)
  checkpoints/   weights during and after training  (ignored by git)
  runs/          logs, demo output, scratch          (ignored by git)
```

## Environment

Python 3.11, PyTorch 2.11.0 with CUDA 12.8, torchvision 0.26.0, Brevitas 0.12.1, numpy 1.26.4,
opencv-python 4.10.0.84 (and pycocotools for the COCO workspaces). Use a dedicated environment
(conda or venv), not the system Python. Check that the GPU is really used before a long run:

    python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.zeros(1).cuda() + 1)"

The `launch.ps1` scripts take the interpreter from `PYTHON`, else `python` from the PATH.

## How to run

Each workspace's README gives its data, commands and accuracy ruler. Commands run from the
workspace folder, for example:

    cd train/mbv2_pose
    python -m src.score_ckpt ../../artifacts/mbv2_pose/probe_tern_dc32_best.pth --expect 85.992

Checkpoints of the delivered models are release assets (`python tools/fetch_release.py --group
checkpoints`, from the repository root).

## Rules

- A workspace never imports from another one. Shared inputs (for example the pose checkpoint a task
  starts from) come from `artifacts/`, where the release fetcher puts them.
- Datasets live outside the repository; each workspace reaches them through its `data/` folder (a
  directory link) or the environment variables named in its README.
- One accuracy ruler per task: the same validation set, evaluation script and metric for every number,
  recorded next to the number in `results/`.
- Every ternarised layer is checked after quantisation: weights in {-1, 0, +1} before the scale, and
  zeros present. A model that fails the check is not exported.
- The accelerator fixes the network shape (see [`docs/REBUILD.md`](../docs/REBUILD.md), "Using the
  accelerator for another network"); check a new network against `tools/gen_desctab.py` before
  training for long.
- When only one more block changes, training starts from the previous converged configuration, not
  from scratch.
