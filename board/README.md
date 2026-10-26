# board

Scripts that assemble the boot image, cross-build the board apps, put files on the board and check
them there.

## Contents

| script | runs in | what it does |
|---|---|---|
| `make_boot.sh` | Git Bash or WSL | assembles `build/BOOT.BIN` with `bootgen` from the boot components in `build/linux/boot` (or `LINUX_DIR`), `system.dtb` and a bitstream |
| `build_apps.sh` | WSL | cross-builds the apps of `sw/app` with the PetaLinux SDK (`$PLNX_ROOT/sdk`): on the kernel driver into `build/arm-drv/` (default), with `HAL=uio` into `build/arm/` |
| `make_kit.sh` | WSL or Git Bash | packs `build/twn_board_kit.tar.gz`: the driver-backend apps, `twn_bench`, `twn_errtest`, the board scripts, the weights and the synthetic fixtures, with `SHA256SUMS` |
| `deploy.sh` | Git Bash | over the network: `pin`, `push`, `pushlinux`, `data`, `verify`, `speed`, `rollback` |
| `flash_sd.sh` | Git Bash, card in the host | copies a boot set onto the card's FAT partition, keeps the replaced files in `previous_<date>/`, compares hashes |

## How to run

    bash board/make_boot.sh [bitstream.bit] [output.BIN]
    bash board/build_apps.sh
    bash board/make_kit.sh
    export BOARD_PW=<root password of the board>
    bash board/deploy.sh pin | push <BOOT.BIN> | pushlinux [BOOT.BIN] [sd-dir] | data | verify | speed | rollback
    bash board/flash_sd.sh <drive> [BOOT.BIN] [sd-dir]          # <drive> e.g. E:

Each script's header lists its arguments and environment variables: `BOARD_IP` (default
192.168.10.2), `BOARD_PW` (required by `deploy.sh`), `PLINK` and `PSCP`, `BOOTGEN`, `LINUX_DIR`,
`PLNX_ROOT`, `FUSE_CLK_MHZ`. The full sequence is in [`docs/REBUILD.md`](../docs/REBUILD.md), step 7.

## Outputs

`build/BOOT.BIN`, `build/arm-drv/*` and `build/twn_board_kit.tar.gz`; on the board, the apps in `/home/root/`, the weights in
`/home/root/data/` and the fixtures in `/home/root/golden/`; on the card, `BOOT_rollback.BIN` and
`previous_linux/`.

## Rules

- The board is reached from Windows (`plink`/`pscp`), not from WSL. Its ssh host key changes at every
  boot and is read again each time; a reboot is confirmed by a new `boot_id`.
- After a new BOOT.BIN or Linux set: reboot, then `data`, then `verify`. A measurement counts only when
  `verify` printed max abs diff 0 on the same boot.
- Keep a way back before changing the card: `deploy.sh pin` once (rollback BOOT.BIN); `pushlinux`
  keeps the files it replaces in `previous_linux/`; `flash_sd.sh` keeps them in `previous_<date>/`.
- Do not poll the board with repeated ssh commands while it measures: it lowers the frame rate.
- Record a measurement in `results/board_results.json` with its build, ruler and date.
