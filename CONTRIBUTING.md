# Contributing

Thank you for your interest. Issues and pull requests are welcome: bug reports, ports to other Zynq
UltraScale+ boards, new task models for the same hardware, and documentation fixes.

## Before you start

- Read the [`README.md`](README.md) and the `README.md` of the directory you are changing; each one
  says what belongs there and how its files are produced.
- Get the release assets (`python tools/fetch_release.py`) and regenerate the fixtures from your own
  MPII copy ([`docs/QUICKSTART.md`](docs/QUICKSTART.md), "Fixtures and dataset files"); every gate below
  needs them.

## Building and testing

The full sequence is in [`docs/REBUILD.md`](docs/REBUILD.md); the gates are described in
[`docs/VERIFICATION.md`](docs/VERIFICATION.md). What a change must pass depends on what it touches:

| change | must pass |
|---|---|
| RTL (`rtl/`) | `python rtl/sim/lint_multidrive.py --selftest`, `powershell -File vivado\elab_fuse_layer.ps1`, `powershell -File rtl\fuse\sim\run_engine_tests.ps1 -Integration` (all 35 ok), a bitstream build with WNS >= 0, and `bash board/deploy.sh verify` on a board if you have one |
| C reference or generators (`golden/`, `tools/`) | `( cd golden/p1_golden && bash run_p1.sh )` (P1 GATE: PASS), `python tools/gen_fuse_ddr.py` (ALL PASS), then the engine suite |
| board software (`sw/`) | `bash board/build_apps.sh`, then `deploy.sh data` and `verify` on a board |
| training or export (`train/`) | the workspace's ruler (`src/score_ckpt.py` or the task's `src/evaluate.py`); for the pose exporter, the nine files of `models/mbv2_pose` reproduced byte for byte |
| scripts | `bash -n` for shell scripts, `python -m py_compile` for Python files |

Say in the pull request which gates you ran and what they printed. A gate that was not run is
reported as not run.

## The bit-exact rule

The accelerator's output must equal the integer C reference (`sw/net/mbv2_pose.c`, in the fused
order of `golden/p0_fused`) on every byte. A change that alters any output byte is a change of the
reference first: change and re-verify P0/P1, regenerate the vectors, then make the RTL match. Never
edit generated vectors, testbench case files or exported model files by hand; change their generator.

## Tests must be able to fail

A new RTL module gets a unit test in `rtl/fuse/tb/` and a row in `rtl/fuse/sim/run_units.ps1`, with at
least one deliberate defect (a `<MODULE>_NEG_*` define in the RTL or a testbench define) that the test
must catch. A test that cannot fail proves nothing.

## Results

A new measurement is a new entry in `results/board_results.json` or `results/task_results.json`, with
date, ruler, build hashes, the raw output under `results/raw/` and the command that repeats it (see
[`results/README.md`](results/README.md)). Do not edit existing entries; mark a superseded one
`current: false`. Do not quote a number in documentation without the entry it comes from.

## Style

- Verilog: one module per file, file name = module name; comments describe what the code does now,
  without history or dates. Prove a comment-only edit with `python tools/codeprint.py check`.
- Python: standard library plus numpy for the tools; paths derive from the repository root or from
  environment variables, never from a user name or drive letter.
- Shell scripts keep LF line endings, `.cmd` and `.ps1` keep CRLF (`.gitattributes` enforces both).
- Generated files go to `build/` or are listed in `.gitignore`; they are never committed.
- Documentation is in English and lives in the root `README.md`, `docs/` and the directory READMEs.

## Datasets and privacy

Do not commit dataset images, video frames, label files or anything derived from them that shows a
person (fixtures included), and no root file system image: it contains the board's password hash.

## License

By contributing you agree that your contribution is licensed under the Apache License 2.0
([`LICENSE`](LICENSE)).
