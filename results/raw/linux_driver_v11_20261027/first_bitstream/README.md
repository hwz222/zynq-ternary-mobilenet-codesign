# First v1.1 bitstream (superseded)

These logs come from the first interrupt bitstream of v1.1, built 2026-10-27 with `FUSE_TAG=v11irq`
(bitstream `8168c91ab4205501`, XSA `853b2d89767d5163`, BOOT.BIN `7da00842c7c104e1`, system.dtb
`b1e2fda6e333dbc7`; hashes are the first 16 hex digits of SHA-256). Everything in them passed except
the SMMU, and that failure is why the bitstream was replaced:

- `E1`-`E7`, `board_hashes_E.txt`: the v1.1 image on that bitstream. Driver loaded at boot with the
  interrupt, `/dev/mem` refused, the 256 MB reservation returned, board check PASS (232.98 / 233.23 /
  232.16 fps), CPU time per backbone frame 11.9 us with the interrupt and 477.3 us with polling,
  1000 frames = 1000 interrupts, forced password change at the first login.
- `F1_smmu_guessed_ids.log`: the same image with the SMMU enabled in the device tree and the
  accelerator given stream IDs 0x0e80, 0x1280, 0x1680. Every fixture failed and `dma_fault` caused
  no SMMU fault. A second boot with `arm_smmu.disable_bypass=1` (not kept as a log) still showed no
  fault of any kind.

Cause: the AXI masters (`rtl/src/twn_axi_rd.v`, `twn_axi_wr.v`) drove AxPROT = 3'b000, i.e. Secure
transactions. The Linux SMMU driver programs only the Non-secure stream mapping, so Secure traffic
from the PL was neither translated nor checked; with the buffer at an I/O virtual address the PL
read and wrote the wrong place. The masters now drive 3'b010 (Non-secure), the bitstream was
rebuilt, and the logs one directory up (same file names) were taken again on the new image.
