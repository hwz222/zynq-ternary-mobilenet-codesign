SUMMARY = "Linux platform driver for the ternary MobileNetV2 accelerator (twn_fuse)"
DESCRIPTION = "linux/driver/twn_fuse of the repository, built as a kernel module and loaded at boot"
LICENSE = "GPL-2.0-only | MIT"
LIC_FILES_CHKSUM = "file://twn_fuse.c;beginline=1;endline=1;md5=107a173833ee0b60d07de595965ecd52"

inherit module

# twn_fuse.c and twn_fuse_ioctl.h are copied from linux/driver/twn_fuse/ by linux/build_linux.sh,
# so the repository keeps one copy of the source; Makefile is the module-class one in files/.
SRC_URI = "file://Makefile \
           file://twn_fuse.c \
           file://twn_fuse_ioctl.h \
          "
S = "${WORKDIR}"

RPROVIDES:${PN} += "kernel-module-twn-fuse"
# loaded at boot; with the v1.1 device tree it binds the node by its compatible string
KERNEL_MODULE_AUTOLOAD += "twn_fuse"
