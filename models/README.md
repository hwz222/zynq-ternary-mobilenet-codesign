# models

Exported networks, one folder per task: what the hardware flow (golden vectors, simulation, board
apps) consumes. Training code lives in `train/<task>/`; nothing here is edited by hand.

## Contents of `models/mbv2_pose/` (the deployed pose model, `probe_tern_dc32`)

| file | in git | content |
|---|---|---|
| `model_meta.c`, `model_meta.h` | yes | layer table, scales and requantisation parameters, written by the exporter |
| `pack_meta_mbv2.h` | yes | description of the packed weight file |
| `model_mbv2.bin` | no, release asset | the whole network: ternary backbone weights, requantisation, INT8 head |
| `model_mbv2_packed.bin` | no, release asset | the same with the head weights appended in the head engine's stream order |
| `fixtures/fix_0..3.bin` | no, regenerated | input image plus expected output of four MPII validation images, used by every bit-exact gate |

## How to fill it

    python tools/fetch_release.py --group model          # the two weight files, hash-checked

and the fixtures with the exporter, from your own MPII copy (root [`README.md`](../README.md),
"Fixtures and dataset files"). The exporter writes all nine files at once
(`train/mbv2_pose/export/export_board_model.py --install`); the two weight files it writes are
byte-identical to the release assets, and the expected hashes of the fixtures are in
`tools/release_assets.json`.

## Rules

- A folder is complete or absent: weights, metadata and fixtures from the same export, never mixed.
- Every export is checked at the exporter: each ternary layer holds only {-1, 0, +1} with zeros
  present, or nothing is written.
- After replacing a model, regenerate `golden/p1_golden/vec` and the `tools/` outputs, then run the
  engine suite.
- Checkpoints and datasets do not belong here; see [`train/README.md`](../train/README.md).
