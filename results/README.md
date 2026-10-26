# results

Measured numbers with their provenance. A number quoted anywhere else in this repository is copied
from one of the two JSON files here.

## Contents

| file | content |
|---|---|
| `board_results.json` | the accelerator and the deployed pose model: throughput, correctness and accuracy on the board, host accuracy, resources, timing, and the earlier builds they replaced |
| `task_results.json` | host-side accuracy of the other models trained for the same hardware (detection, segmentation, depth, pose for people lying down, a fall-alarm prototype); none of them has run on the board |
| `raw/` | the logs, reports and per-item outputs the entries cite in their `source` field |

## Entry format

Each entry is keyed by a build or experiment id and carries:

| field | meaning |
|---|---|
| `current` | `true` for the entry that describes the present state; superseded entries stay with `false` |
| `date` | date of the measurement |
| `ruler` | what exactly was measured and how: app, frame count, fixtures, dataset split, metric, clock |
| `build` | what was measured: BOOT.BIN, bitstream, weight files, apps or checkpoint, each with the first 16 hex digits of its SHA-256 |
| `source` | the raw output behind the values (a path under `results/raw/` where it was archived) |
| `measured_by` | the command that repeats the measurement |

followed by the values.

## Reading the entries

- **Key names.** `thesis_model_*` entries describe the model chosen for the author's master's thesis,
  `probe_tern_dc32`, which is also the deployed model and the one in `models/mbv2_pose`. `ch3_*`
  entries hold the evidence for the choice of network (backbone, head width, which layers are
  ternary). `opt1_*`, `rebuilt_from_clone_*` and `linux_rebuilt_*` are earlier builds of the same
  design, kept for history.
- **Superseded models.** `mbv2_pose_room_mix_w3_head32_20261012` and the checkpoint names
  `room_mix_w3_head32`, `room_mix_w3`, `room_ctrl` and `room_ctrl_head32` are identifiers of an earlier
  deployed pose model and its sibling checkpoints (superseded, not released). The task entries marked
  `current: false` (`det12_tern_cont`, `seg16_tern_pose`, `depth_tern_distill`) are earlier task
  models built on that model's backbone, also not released. They are kept so that the provenance of
  the current entries stays complete.
- **Commits, branches and tags** named inside entries (for example `d21153c`, branch
  `thesis-model-probe-tern-dc32`, tag `v1-opt1-rebuilt`) belong to the private development history
  from which this repository was published; they are not part of this repository's history. The
  SHA-256 prefixes identify the files: the release assets and the files you build can be compared
  against them.
- **Placeholders.** Absolute paths of the build machine in the raw logs were replaced by `<repo>` (this
  repository's root), `<earlier-repo>` (the earlier, non-public research repository the `ch3_*` and
  candidate checkpoints come from), `<conda-env>`, `<temp>`, `<datasets>` and `<host>`. Apart from these
  placeholders and one comment line of `deploy_probe_tern_dc32_20261012/sd_sets_main_probe.txt`
  ("thesis model" now reads "deployed model"), the raw files are unchanged.
- **Earlier names.** In raw logs and older entries, `OPT-001` is the earlier name of the backbone-to-head
  direct write (BB2HD, register `A_BB2HD`), and `opt1` names the first build that contained it.
- **`artifacts/...` paths** name release assets after `tools/fetch_release.py` has put them in place;
  `artifacts/opt1/*` and `artifacts/*/MANIFEST.json` existed only in the private archive.
- **Known gaps.** `linux_rebuilt_20261012` cites `results/raw/speed_linux_rebuilt_20261012.log`,
  which was never archived; its values are superseded by `thesis_model_probe_tern_dc32_board_20261012`
  on the same boot. Power is not recorded in this file: the 7.66 W quoted in the README was measured on
  an earlier bitstream of the same design.

## Rules

- Append only: a superseded entry is marked `current: false`, never deleted or rewritten. (For this
  public release, paths, host names and wording that referred to private documents were neutralised
  as described above; `timing_bitstream_52b400785924efe0` was added from the timing report of the
  release build.)
- A value without ruler, build and date does not belong here. Negative and failed results are
  recorded too, with the reason.
- Raw outputs that back an entry are stored under `raw/` with a path in `source`; a console history
  is not evidence.
- Other documents keep pointers to entries, not copies of their numbers without the entry name.
