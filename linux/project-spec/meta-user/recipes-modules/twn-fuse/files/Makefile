# Makefile for the Yocto module class (twn-fuse.bb). For a build outside PetaLinux, use
# linux/driver/twn_fuse/Makefile instead.
obj-m := twn_fuse.o

SRC := $(shell pwd)

all:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC)

modules_install:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC) modules_install

clean:
	rm -f *.o *~ core .depend .*.cmd *.ko *.mod.c *.mod
	rm -f Module.markers Module.symvers modules.order
	rm -rf .tmp_versions Modules.symvers
