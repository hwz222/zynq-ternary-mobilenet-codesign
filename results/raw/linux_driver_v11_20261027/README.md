# Evidence: the twn_fuse driver v1.1 (2026-10-27)

Raw output of the v1.1 checks. A line starting with `# ` is the command that was run; the first
line of each board log names the date (UTC), the kernel and the boot files (hashes: first 16 hex
digits of SHA-256). Summary of the numbers: `results/board_results.json`, entry
`linux_driver_twn_fuse_v11_20261027`. The study handout `docs/zh-TW/driver-handout-2/` quotes these
files line by line.

The first letter of a file name is where it was taken:

| letter | boot files / host | what it is |
|---|---|---|
| S | PC (Vivado 2023.2, WSL) | simulation gates, the binding check, the bitstream build |
| D | v1.0.0 boot files (BOOT.BIN `690d87cc5f4b6897`, system.dtb `18fff66fcfb7798b`): UIO and `/dev/mem` available, no interrupt line; the v1.1 driver loaded by hand (`twn_fuse.ko` `5f77eacd80e62272`), polling | the four-arm A/B, ioctl cost, debugfs, synthetic fixtures, the boot state before v1.1, pipeline stage times |
| E | the v1.1 release image (BOOT.BIN `5d226057efc8760b` with bitstream `11b4d88f583b8e23`, system.dtb `bc4255b1c54ae27e` with the SMMU on, Image `0110440877a3738d`, rootfs `8c54689ab21fe45c`), checked with the board kit `8440be649b2228b6` (E0-E8) and the release kit `97cc94ee729e5f78` (E9) | everything on the image users get |
| F | the final bitstream (BOOT.BIN `18a066f87cfbad8d`) with the first v1.1 kernel and root file system, the SMMU enabled in system.dtb, `arm_smmu.disable_bypass=1` on the command line | finding the SMMU stream IDs |
| G | boot E with `system_nosmmu.dtb` (`6ceadb90b64b6a98`) | the same checks with the SMMU off, for comparison |

| file | what it shows |
|---|---|
| `S1_csr_irq_gate.log` | the interrupt unit gate: intact PASS (18 checks), the two injected defects caught |
| `S2_hd_int_gate.log` | the head integration gate with the final RTL (Non-secure AXI masters): `HD_INT_GATE_PASS` |
| `S3_binding_check.log` | `test/binding_check.py` on the binding and on the node of the release system.dtb: PASS |
| `S4_build_timing.log`, `S4_timing_impl_fuse_v11.rpt`, `S4_util_impl_fuse_v11.rpt` | the final bitstream's build: WNS 0.000 ns, WHS +0.008 ns at 240 MHz after the post-route recovery; utilization (host and paths replaced by placeholders) |
| `D1_ab_measure.log` | fps of four arms, 6 runs each: UIO 228.94, UIO elsewhere 229.09, driver with a Device mapping 228.83, driver 231.53 |
| `D2_bench.log` | `twn_bench`: ioctl 1.63 us, backbone frame time split, CPU store/load bandwidth on the buffer in both mappings |
| `D3_debugfs.log` | debugfs files, short frame, refused value, `dma_fault` without the SMMU (unnoticed) |
| `D4_synthetic.log` | the four synthetic fixtures on both backends, both head placements |
| `D5_boot_state.log` | the v1.0.0 boot: STRICT_DEVMEM off, `devmem` reads DDR and the registers, MemTotal 1773764 kB |
| `D6_stage_times.log` | pipeline stage times (`PIPE_TIMING=1`) in both mappings: write-in 0.09-0.10 vs 0.14-0.15 ms |
| `board_hashes_D.txt` | the files on the board for boot D |
| `E0_kit_sha.log` | `sha256sum -c` of the board kit on the board: all OK |
| `E1_boot_state.log` | driver loaded at boot, interrupt, iommu group, `/dev/mem` refused, MemTotal 2035396 kB |
| `E2_board_check.log`, `E2m_board_check_mpii.log` | the board check with the synthetic and with the MPII fixtures: PASS |
| `E3_bench.log` | interrupt vs `use_irq=0`: CPU 10.7 vs 465.8 us per frame, wait 14.0 vs 39.3 us |
| `E4_debugfs.log` | debugfs; `dma_fault` stopped by an SMMU context fault |
| `E5_synthetic.log` | synthetic fixtures 8/8 runs bit-exact |
| `E6_irqcount.log` | 1000 frames = 1000 interrupts, none extra |
| `E7_first_login.log` | first interactive login on the serial console: Ctrl-C ignored, empty and mismatched passwords refused, then the forced change |
| `E8_smmu.log` | the SMMU check on the release image: fixtures, 233.40 fps, context fault on the out-of-buffer read |
| `board_hashes_E.txt` | the files on the board for boot E |
| `E9_release_kit.log` | the release board kit (`97cc94ee729e5f78`: the same files with the binaries stripped of debug information, which held build paths) on boot E: hashes OK, no debug information left, board check PASS, synthetic fixtures bit-exact |
| `F0_smmu_find_stream_ids.log` | with the guessed IDs: the SMMU reports the unlisted 0x12c0, 0x1300, 0x1740 |
| `F1_smmu_measured_ids.log` | with the measured IDs: no global fault, fixtures bit-exact |
| `G1_boot_state.log` ... `G4_debugfs.log` | the SMMU off: 232.67 / 232.35 / 231.49 fps, CPU 10.8 us per frame, `dma_fault` unnoticed |
| `first_bitstream/` | the first v1.1 bitstream (Secure AXI masters), superseded; its own README |

The MPII fixtures (`E2m`) and the weights are not in the repository; the synthetic fixtures are
(`models/mbv2_pose/fixtures_synthetic/`). The board kit is a release asset.
