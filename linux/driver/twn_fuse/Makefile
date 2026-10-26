# Build twn_fuse.ko out of tree against the kernel of the PetaLinux project (run in WSL / Linux).
#
#   make prepare    once: copy the project's kernel build directory to $(KOUT) and run
#                   modules_prepare there (the PetaLinux project itself is never written)
#   make            build twn_fuse.ko
#   make test       build test/twn_errtest and test/twn_bench (run on the board)
#   make clean
#
# The module only loads on a kernel built by the same project: check with
#   modinfo twn_fuse.ko | grep vermagic      (on the board: uname -r)

PLNX_ROOT ?= $(HOME)/petalinux
PLNX_PROJ ?= $(PLNX_ROOT)/proj/ternpose
SDK_DIR   ?= $(PLNX_ROOT)/sdk
KWORK     ?= $(PLNX_PROJ)/build/tmp/work-shared/zynqmp-generic-xczu2cg
KSRC      ?= $(KWORK)/kernel-source
KOUT      ?= $(HOME)/twn_kbuild

ARCH          := arm64
CROSS_COMPILE ?= aarch64-xilinx-linux-
export PATH   := $(SDK_DIR)/sysroots/x86_64-petalinux-linux/usr/bin/aarch64-xilinx-linux:$(PATH)
# the SDK environment script sets user-space CFLAGS/LDFLAGS that break a kernel build
unexport CFLAGS LDFLAGS CPPFLAGS CC LD

SYSROOT   ?= $(SDK_DIR)/sysroots/cortexa72-cortexa53-xilinx-linux

KMAKE = $(MAKE) -C $(KSRC) O=$(KOUT) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE)

all:
	$(KMAKE) M=$(CURDIR) modules

prepare:
	@test -d $(KWORK)/kernel-build-artifacts || { echo "no kernel build in $(KWORK) (set PLNX_PROJ)"; exit 1; }
	rm -rf $(KOUT)
	cp -a $(KWORK)/kernel-build-artifacts $(KOUT)
	$(KMAKE) modules_prepare

TESTS = test/twn_errtest test/twn_bench

test: $(TESTS)

test/%: test/%.c twn_fuse_ioctl.h
	$(CROSS_COMPILE)gcc --sysroot=$(SYSROOT) -O2 -Wall -o $@ $<

clean:
	$(KMAKE) M=$(CURDIR) clean
	rm -f $(TESTS)

.PHONY: all prepare test clean
