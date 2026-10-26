# tools

Host-side generators, checkers and utilities. Run them from the repository root. Inputs come from
`golden/p1_golden/vec` (made by `golden/p1_golden/run_p1.sh`) and `models/<task>/`.

## Contents

| script | purpose | writes |
|---|---|---|
| `fetch_release.py`, `release_assets.json` | downloads the release assets, checks their SHA-256 and puts them where the scripts expect them (`--group`, `--from-dir`, `--check`) | `artifacts/`, `models/mbv2_pose/*.bin`, `train/mbv2_pose/checkpoints/` |
| `pack_fuse_weights.py` | packs the golden weights into the DDR weight image the engine reads | `golden/p1_golden/vec/fuse_weights.bin`, `fuse_weights_index.json` |
| `gen_desctab.py` | block descriptor table from the manifest and the weight index; stops if a network does not fit the memories | `tools/fuse_desctab.h`, `rtl/fuse/tb/*.vh` (ignored) |
| `gen_fuse_ddr.py` | DDR image and arena map for the whole-frame simulation, with a verify pass | `rtl/fuse/tb/*.hex` (ignored) |
| `gen_input_qlut.py` | int8 input quantiser table from `model_meta.c`; `--check` reports up to date or stale | `sw/app/input_qlut.h` |
| `hd_ref_export.py` | head reference vectors for the head testbenches | `rtl/fuse/tb/hd_vec/` (ignored) |
| `tailpack.py`, `gather_cost.json` | tail-packing rule and its cost data, used by the packer and the encoder tests | none |
| `codeprint.py` | proves that an edit changed only comments and whitespace (`check`, `selftest`) | none |
| `demo_montage.py` | puts finished demo videos of the same clip into one titled grid (runs no model) | the `--out` video |
| `score_old_ckpts.py` | re-scores checkpoints of the earlier, non-public research repository on the MPII ruler and counts weights, weight bytes and MACs per layer kind; kept as the measuring method of the `ch3_*` entries of `results/board_results.json` (it needs that repository, `--old-repo`) | the `--out` JSON |

## How to run

    python tools/fetch_release.py --group boot model
    python tools/pack_fuse_weights.py && python tools/gen_desctab.py && python tools/gen_fuse_ddr.py

## Rules

- A tool takes its paths from the repository root, never from a user name, drive letter or
  environment path.
- A tool that generates a file says in its header what it reads and what it writes; generated files
  are ignored by git.
- `pack_fuse_weights.py --verify` reports 6 false errors (it mis-splits the tail-packed stages); it is
  not a gate.
