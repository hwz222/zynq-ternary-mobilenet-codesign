# Board evidence: the twn_fuse kernel driver (2026-10-26/27)

Raw output of `linux/driver/twn_fuse/test/board_check.sh` and of the state captures around it,
on the ALINX AXU2CGB: BOOT.BIN `690d87cc5f4b6897` (bitstream `52b400785924efe0`), kernel
`6.1.30-xilinx-v2023.2`, `twn_fuse.ko` `8b3649080da3254d` (hashes: first 16 hex digits of SHA-256).
In the state captures, a line starting with `# ` is the command that was run.

Three boots, in this order:

| file | boot | what it shows |
|---|---|---|
| `host_hashes.txt`, `board_hashes_{A,B,C}.txt` | | the driver, the four apps and the test program on the host, and every staged file on the board after each boot |
| `A1_fresh_boot_uio_dtb.txt` | A: original `system.dtb` (`18fff66fcfb7798b`, node says `generic-uio`) | state right after boot: kernel command line, CMA, STATUS = 0, the device on UIO |
| `A2_board_check_uio_dtb.log` | A | the full board check: fixtures on both paths, 14 refusal/success checks with the 3 s timeout and the driver's dmesg, rmmod while open and while only mapped, five unload/reload cycles, throughput |
| `A3_driver_state.txt` | A | the driver bound: modinfo, /proc/iomem, /dev node, sysfs after a frame, the maps of a running app, ten reloads with a 64 MB buffer |
| `A4_uio_state.txt` | A | back on UIO: the maps of a running v1.0.0-style app (`/dev/mem` and `/dev/uio4`) |
| `B1_patched_dtb_boot.txt` | B: patched `system.dtb` (`564da1539647de7c`, node says `wjhuang,twn-fuse-1.0`) | no driver bound after boot; `insmod` binds by compatible with no `driver_override`; fixtures |
| `B2_board_check_patched_dtb.log` | B | the same board check under the patched device tree |
| `C1_rollback_to_uio_dtb.txt` | C: original `system.dtb` copied back | the rollback: device on UIO, driver not loaded, STATUS 0 before and 0x00010043 after a UIO-only run, fixtures |
| `dtb_diff.txt` | host | `dtc -I dtb -O dts` of both device trees, diffed: one line differs |

The board hash lists cover the module, the apps, the test program, the data and the fixtures;
`board_check.sh` and `bind.sh` were copied from this commit's `linux/driver/twn_fuse/` and are not in
those lists.

In `B1_patched_dtb_boot.txt` line 4 is the stderr of the `ls -l .../driver` on line 8 (no such
file: no driver bound yet); stderr reached the log before stdout.

Summary of the numbers: `results/board_results.json`, entry `linux_driver_twn_fuse_20261026`.
