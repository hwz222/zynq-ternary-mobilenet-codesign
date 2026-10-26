# vivado

IP packaging, block design, implementation and bitstream for Vivado 2023.2.

## Contents

| file | what it does |
|---|---|
| `build.cmd` | the whole chain: lint, elaboration, IP packaging, block design, synthesis, implementation, bitstream and XSA; sets the build recipe variables |
| `package_fuse_ip.tcl` | packages `rtl/` as the IP `twn:user:twn_fuse` |
| `build_bd_fuse.tcl` | block design (processing system, four HP ports, interconnects, `fuse_0`, `obs_gpio`), implementation, post-route recovery, bitstream and XSA |
| `alinx_ps/ps_config.tcl` | processing-system settings of the ALINX AXU2CGB board |
| `fuse_t1mem_pblock.xdc` | floorplan constraint for the weight memories |
| `fuse_dp_check.tcl` | after synthesis and implementation, checks that every datapath instance still has cells |
| `elab_fuse_layer.ps1` | elaboration check of the packaged top |

## How to run

    vivado\build.cmd          # Windows, about 1 hour

`VIVADO_SETTINGS` (default `C:\Xilinx\Vivado\2023.2\settings64.bat`), `PYTHON` and `FUSE_TAG`
(default `ternpose`) are optional.

## Outputs

In `build/`: `system_fuse_ternpose.bit`, `system_fuse_ternpose.xsa`, the utilisation, timing and
datapath-check reports (`util_*`, `timing_*`, `dpcheck_*`); Vivado logs in `vivado/*.log`.

## Rules

- Outputs never go into this folder (logs excepted, and they are ignored by git).
- The recipe is in `build.cmd`; a different strategy or a changed constraint is a change of the
  design: record its timing and resources in `results/`.
- The first routing ends about 30 ps below zero slack by design of the recipe; `build_bd_fuse.tcl`
  runs the post-route recovery in the same session. A build that does not end with WNS >= 0 is not a
  result.
