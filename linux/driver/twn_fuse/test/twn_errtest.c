/*
 * twn_errtest.c -- the driver's refusals, one check per line (run on the board, as root).
 *
 *   ./twn_errtest          every check except the timeout
 *   ./twn_errtest timeout  also load a table the PL refuses and run a frame: -ETIMEDOUT after 3 s
 *                          (afterwards, any app reloads the right table)
 *   ./twn_errtest hold     map the buffer, close the device, keep only the mapping for 3 s
 *                          (board_check.sh tries rmmod meanwhile; it must be refused)
 *
 * Exit status 0 only if every check passed. Build: see linux/driver/twn_fuse/README.md.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include "../twn_fuse_ioctl.h"

static int fails;

/* r is the return value of the call, e the errno it left; want 0 = success expected */
static void check(const char *what, int r, int e, int want)
{
	int ok = want ? (r < 0 && e == want) : (r >= 0);

	printf("%-4s %-52s -> %s\n", ok ? "PASS" : "FAIL", what,
	       r < 0 ? strerror(e) : "ok");
	fails += !ok;
}

#define CALL(what, expr, want) do { errno = 0; int r_ = (expr); check(what, r_, errno, want); } while (0)

int main(int argc, char **argv)
{
	int fd = open(TWN_DEV_PATH, O_RDWR);
	struct twn_status s;
	struct twn_bases b;
	struct twn_bb_run run;
	struct twn_hd_desc hd;
	struct twn_table t;
	uint32_t words[16];
	void *v;

	if (fd < 0) { perror("open " TWN_DEV_PATH); return 1; }
	if (argc > 1 && !strcmp(argv[1], "hold")) {
		if (ioctl(fd, TWN_IOC_STATUS, &s) ||
		    (v = mmap(NULL, s.arena_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)) == MAP_FAILED) {
			perror("hold");
			return 1;
		}
		close(fd);              /* from here on, only the mapping refers to the device */
		sleep(3);
		return 0;
	}
	CALL("second open of the device (one owner at a time)", open(TWN_DEV_PATH, O_RDWR), EBUSY);
	CALL("STATUS", ioctl(fd, TWN_IOC_STATUS, &s), 0);
	printf("     arena %llu bytes, CTRL %08x STATUS %08x\n",
	       (unsigned long long)s.arena_size, s.ctrl, s.status);

	/* mmap: only the buffer, from its start */
	/* (the mmap() call is inside CALL so that errno is read right after it) */
	CALL("mmap the whole buffer",
	     (v = mmap(NULL, s.arena_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)) == MAP_FAILED ? -1 : 0, 0);
	CALL("mmap one page more than the buffer",
	     (v = mmap(NULL, s.arena_size + 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)) == MAP_FAILED ? -1 : 0, EINVAL);
	CALL("mmap at a non-zero offset",
	     (v = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 4096)) == MAP_FAILED ? -1 : 0, EINVAL);

	/* offsets are checked against the buffer */
	b = (struct twn_bases){ .w_off = s.arena_size, .act_off = 0 };
	CALL("SET_BASES, weights at the end of the buffer", ioctl(fd, TWN_IOC_SET_BASES, &b), EINVAL);
	b = (struct twn_bases){ .w_off = 8, .act_off = 0 };
	CALL("SET_BASES, offset not 16-byte aligned", ioctl(fd, TWN_IOC_SET_BASES, &b), EINVAL);
	run = (struct twn_bb_run){ .in_off = 1ull << 40, .out_off = 0 };
	CALL("BB_RUN, input offset 1 TB", ioctl(fd, TWN_IOC_BB_RUN, &run), EINVAL);
	memset(&hd, 0, sizeof hd);
	hd.out_off = s.arena_size - 4096;
	hd.out_beats = 4096 / 16 + 1;  /* one beat past the end */
	CALL("HD_COMMIT, output runs one beat past the end", ioctl(fd, TWN_IOC_HD_COMMIT, &hd), EINVAL);

	/* user pointers go through copy_from_user */
	CALL("STATUS into an unmapped pointer", ioctl(fd, TWN_IOC_STATUS, (void *)16), EFAULT);
	t = (struct twn_table){ .words = 16, .nwords = 16, .nblk = 1 };
	CALL("SET_TABLE whose words pointer is unmapped", ioctl(fd, TWN_IOC_SET_TABLE, &t), EFAULT);
	CALL("an ioctl number the driver does not know", ioctl(fd, _IO(TWN_IOC_MAGIC, 99)), ENOTTY);

	if (argc > 1 && !strcmp(argv[1], "timeout")) {
		struct timespec a, c;

		/* a table the PL's check refuses: every field all ones */
		memset(words, 0xff, sizeof words);
		t = (struct twn_table){ .words = (uintptr_t)words, .nwords = 16, .nblk = 1 };
		CALL("SET_TABLE that the PL's check refuses", ioctl(fd, TWN_IOC_SET_TABLE, &t), EINVAL);
		/* the PL ignores START until a table passes, so done never comes */
		run = (struct twn_bb_run){ .in_off = 0, .out_off = 0 };
		clock_gettime(CLOCK_MONOTONIC, &a);
		CALL("BB_RUN with no valid table", ioctl(fd, TWN_IOC_BB_RUN, &run), ETIMEDOUT);
		clock_gettime(CLOCK_MONOTONIC, &c);
		printf("     returned after %.2f s\n", (c.tv_sec - a.tv_sec) + 1e-9 * (c.tv_nsec - a.tv_nsec));
	}

	printf("%s: %d check(s) failed\n", fails ? "FAIL" : "PASS", fails);
	return fails ? 1 : 0;
}
