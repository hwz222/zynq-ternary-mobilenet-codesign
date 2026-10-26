#!/bin/sh
# Separate the causes of the throughput difference between the UIO path and the driver path
# (run on the board, as root, in the directory board_check.sh uses).
#
# The driver path changes three things at once; each arm below changes one of them:
#   uio        UIO + /dev/mem: buffer at 0x6000_0000 (reserved), Device-nGnRnE, polling in the app
#   uio_68     the same at 0x6800_0000 (another place in the reserved region): is the location
#              in DDR visible at all?
#   drv_dev    driver, buffer from CMA, mapped Device-nGnRnE (map_device=1), polling in the kernel
#   drv_nc     driver, buffer from CMA, mapped Normal non-cacheable (the default)
# uio -> drv_dev changes where the poll runs and where the buffer is; drv_dev -> drv_nc changes
# only the CPU-side memory attribute.
#
# Each arm runs mbv2_fuse_pipe (120 frames, FUSE_BB2HD=1) three times per round, two rounds in
# opposite order, so a slow drift of the board does not favour one arm.
#   sh ab_measure.sh            prints one line per run and a mean per arm
cd "$(dirname "$0")" || exit 1
run() {   # <arm> -> three fps values
    case "$1" in
    uio)     sh bind.sh uio >/dev/null; app=./mbv2_fuse_pipe_uio; env= ;;
    uio_68)  sh bind.sh uio >/dev/null; app=./mbv2_fuse_pipe_uio; env="PL_ARENA_PA=68000000 PL_ARENA_SZ=01000000" ;;
    drv_dev) sh bind.sh uio >/dev/null; sh bind.sh drv ./twn_fuse.ko map_device=1 >/dev/null; app=./mbv2_fuse_pipe_drv; env= ;;
    drv_nc)  sh bind.sh uio >/dev/null; sh bind.sh drv ./twn_fuse.ko >/dev/null; app=./mbv2_fuse_pipe_drv; env= ;;
    esac
    for i in 1 2 3; do
        f=$(env $env FUSE_BB2HD=1 FUSE_HEAD_PL=1 $app . 120 0 2>&1 | grep -a 'fps ===' | sed 's/.*= \([0-9.]*\) fps.*/\1/')
        echo "$1 $f"
    done
}
{
    for a in uio uio_68 drv_dev drv_nc; do run $a; done
    for a in drv_nc drv_dev uio_68 uio; do run $a; done
} | tee /tmp/ab.txt
echo "== mean of 6 runs per arm"
for a in uio uio_68 drv_dev drv_nc; do
    awk -v a=$a '$1 == a { s += $2; n++ } END { printf "%-8s %.2f fps (n=%d)\n", a, s / n, n }' /tmp/ab.txt
done
