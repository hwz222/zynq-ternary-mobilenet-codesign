FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# bsp.cfg is the empty fragment petalinux-create writes; twn-v11.cfg is ours (see that file)
SRC_URI:append = " file://bsp.cfg file://twn-v11.cfg"
KERNEL_FEATURES:append = " bsp.cfg twn-v11.cfg"
