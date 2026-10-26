/*
 * twn_bench.c -- what the driver itself costs (run on the board, as root).
 *
 *   ./twn_bench [frames]     default 1000 frames
 *
 * 1. ioctl round trip: TWN_IOC_STATUS (six register reads, no lock), 100000 times.
 * 2. one backbone frame, many times: the time the app sees around TWN_IOC_BB_RUN, the time
 *    the driver measured inside it (START -> done), and the PL's own cycle count; plus the
 *    CPU time the process used per frame. The difference between the three numbers is
 *    the driver's overhead: syscall and copy (app - driver) and wake-up latency (driver - PL).
 *
 * Part 2 needs a frame that can run: run any app first (it loads the descriptor table, the
 * bases and the weights; the DMA buffer keeps them while the module stays loaded). The input
 * and output offsets are those of sw/app/mbv2_fuse_ps.c (OFF_IN, OFF_OUT).
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include "../twn_fuse_ioctl.h"

#define OFF_IN   0x00180000u    /* OFF_ACT + 2 slots of 256 KB, as mbv2_fuse_ps.c */
#define OFF_OUT  0x00280000u
#define PL_MHZ   240.0

static double now_ns(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e9 + t.tv_nsec;
}

static double cpu_ns(void)
{
	struct rusage u;

	getrusage(RUSAGE_SELF, &u);
	return (u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1e9 +
	       (u.ru_utime.tv_usec + u.ru_stime.tv_usec) * 1e3;
}

int main(int argc, char **argv)
{
	int frames = argc > 1 ? atoi(argv[1]) : 1000;
	int fd = open(TWN_DEV_PATH, O_RDWR);
	struct twn_status s;
	struct twn_bb_run r;
	double t0, t1, c0, c1, app = 0, drv = 0, pl = 0;
	int i, n = 100000;

	if (fd < 0) { perror("open " TWN_DEV_PATH); return 1; }

	t0 = now_ns();
	for (i = 0; i < n; i++)
		if (ioctl(fd, TWN_IOC_STATUS, &s)) { perror("STATUS"); return 1; }
	t1 = now_ns();
	printf("ioctl STATUS: %d calls, %.2f us per call\n", n, (t1 - t0) / n / 1e3);

	c0 = cpu_ns();
	for (i = 0; i < frames; i++) {
		memset(&r, 0, sizeof r);
		r.in_off = OFF_IN;
		r.out_off = OFF_OUT;
		t0 = now_ns();
		if (ioctl(fd, TWN_IOC_BB_RUN, &r)) {
			printf("BB_RUN: %s (run an app first, see the header)\n", strerror(errno));
			return 1;
		}
		t1 = now_ns();
		app += t1 - t0;
		drv += r.ns;
		pl  += r.cycles[0] / PL_MHZ * 1e3;
	}
	c1 = cpu_ns();
	printf("BB_RUN: %d frames, per frame: app %.1f us, driver %.1f us, PL cycles %.1f us\n",
	       frames, app / frames / 1e3, drv / frames / 1e3, pl / frames / 1e3);
	printf("        overhead: syscall+copy %.1f us, wait (driver - PL cycles) %.1f us\n",
	       (app - drv) / frames / 1e3, (drv - pl) / frames / 1e3);
	printf("        CPU time of this process: %.1f us per frame (%.1f %% of the frame time)\n",
	       (c1 - c0) / frames / 1e3, 100.0 * (c1 - c0) / app);
	return 0;
}
