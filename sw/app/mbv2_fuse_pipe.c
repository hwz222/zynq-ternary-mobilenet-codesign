/* ============================================================================
 *  mbv2_fuse_pipe.c -- cross-frame PS/PL pipeline for the fused backbone.
 *
 *  Usage: mbv2_fuse_pipe <proj_root> [frames] [fixture]     (".", 120, 0)
 *    <proj_root>/data/fuse_weights.bin, data/model_mbv2.bin,
 *    data/model_mbv2_packed.bin (only with FUSE_HEAD_PL=1),
 *    golden/fix_<n>.bin
 *
 *  Two stages, synchronised by a condition variable:
 *    FUSE_HEAD_PL=0  PRODUCER = write input + PL backbone + read back -> bb[k&1]
 *                    HEAD     = mbv2_ps_head + DARK from bb[k&1]
 *    FUSE_HEAD_PL=1  PRODUCER = write input + start head(k-1) + backbone(k) +
 *                               wait head (no uncached readout)
 *                    CONSUMER = drain the heatmap + reshape + arg-max + DARK
 *  The heatmap drain is in the consumer so it is off the PL critical path; it
 *  is safe there because op64's output alternates between two buffers.
 *
 *  Correctness: the pipelined keypoints must match both a sequential run of the
 *  same mode and the fixture's golden keypoints. Exit status is non-zero if
 *  either differs.
 *
 *  Environment: FUSE_HEAD_PL, PIPE_ROTATE=n (rotate over fixtures 0..n-1),
 *  PIPE_TIMING, PIPE_PIN=0, PIPE_CPU_PROD / PIPE_CPU_HEAD (cpu index, -1 free),
 *  PIPE_RT=1 (SCHED_FIFO producer), HEAD_THREADS, and the diagnostics
 *  PIPE_PLSIM=<ms>, PIPE_PLSIM_IO=1, PIPE_PLSIM_CACHED=1 (see main()).
 *  PL_UIO / PL_ARENA_PA / PL_ARENA_SZ are read by pl_hal_fuse.c.
 * ========================================================================== */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#include <sched.h>
#include <unistd.h>

#include "mbv2_ps.h"
#include "mbv2_fuse_ps.h"
#include "model_meta.h"
#include "mbv2_pose.h"
#include "pack_meta_mbv2.h"

#define FUSE_BLOB_BYTES 740992          /* pack_fuse_weights.py's blob; must come from
                                         * the same packer run as
                                         * tools/fuse_desctab.h */
#define MAX_FRAMES      4000
/* model_mbv2_packed.bin's three sections (sizes from pack_meta_mbv2.h); the
 * head's weights are the hd_pl tail of the last one. */
#define PACKED_BYTES    ((size_t)W2_AL + (size_t)W2HW_BYTES + (size_t)W8_BYTES)

/* The PL clock the cycle counters are converted at, in MHz. */
#ifndef FUSE_CLK_MHZ
#define FUSE_CLK_MHZ 240.0
#endif

static double now_ms(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
                            return t.tv_sec*1e3 + t.tv_nsec/1e6; }

/* Read exactly n bytes from a file that is exactly n bytes long, so a larger
 * file from another export is refused. Returns 0 on success; prints the reason
 * and returns 1 otherwise. */
static int read_exact(const char *path, void *dst, size_t n) {
    FILE *f = fopen(path, "rb");
    long sz;
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    if (fseek(f, 0, SEEK_END) != 0 || (sz = ftell(f)) < 0) {
        fprintf(stderr, "cannot size %s\n", path); fclose(f); return 1; }
    rewind(f);
    if ((size_t)sz != n) {
        fprintf(stderr, "%s is %ld bytes, this build wants %zu -- rebuild the app and "
                        "the file from the same export\n", path, sz, n);
        fclose(f); return 1; }
    if (fread(dst, 1, n, f) != n) {
        fprintf(stderr, "short read on %s\n", path); fclose(f); return 1; }
    fclose(f);
    return 0;
}

static uint8_t  g_fuse[FUSE_BLOB_BYTES];
static int8_t   g_head[BLOB_BYTES];
/* The input is an array of fixtures; g_nfix is 1 unless PIPE_ROTATE says
 * otherwise. */
#define NFIX_MAX 4
static int      g_nfix = 1;
static int8_t   g_inp[NFIX_MAX][NET_IN_C * NET_IN_H * NET_IN_W];
#define INP(k)  (g_inp[(k) % g_nfix])
static int16_t  g_bb[2][MBV2_BB_LEN];          /* double-buffered boundary */
static int32_t  g_acc[NET_OUT_C * NET_OUT_H * NET_OUT_W];
static int32_t  g_kp_gold[NFIX_MAX][NET_OUT_C * 2];  /* each fixture's golden keypoints */
static int    (*g_kp)[NET_OUT_C * 2];
static volatile float g_dark_sink;
static int      g_head_pl = 0;                 /* the head runs in the fabric   */
static int32_t *g_ro[2];                       /* per-slot cached copy of the
                                                * PL's accumulator             */
static uint8_t  g_packed[PACKED_BYTES];        /* source of the head's weights  */

static pthread_mutex_t m  = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cv = PTHREAD_COND_INITIALIZER;
static int bb_full[2]  = {0,0};
static int bb_frame[2] = {0,0};
static int stop = 0, g_frames = 0;

enum { ROLE_PROD = 0, ROLE_HEAD = 1 };
/* Which cpu a role is pinned to, -1 = left free. The banner and the pinning
 * both call this so the log matches what the run did. */
static int pin_target(int role) {
    if (getenv("PIPE_PIN") && atoi(getenv("PIPE_PIN")) == 0) return -1;
    static const char *evt[2] = { "PIPE_CPU_PROD", "PIPE_CPU_HEAD" };
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    const char *e = getenv(evt[role]);
    int cpu;
    if (e) cpu = atoi(e);
    else if (n >= 2) cpu = (role == ROLE_PROD) ? 0 : -1;
    else return -1;
    return (cpu < 0 || cpu >= n) ? -1 : cpu;
}
/* The head is unpinned by default: mbv2_pose splits the head across a
 * 2-worker pool, which pinning the head thread to one core would serialise. */
static void pin_role(int role) {
    int cpu = pin_target(role);
    if (cpu < 0) return;
    cpu_set_t s; CPU_ZERO(&s); CPU_SET(cpu, &s);
    if (sched_setaffinity(0, sizeof(s), &s) != 0)
        fprintf(stderr, "[pipe] pin role %d -> cpu %d FAILED (%s)\n", role, cpu, strerror(errno));
    else if (getenv("PIPE_TIMING"))
        fprintf(stderr, "[pipe] role %d pinned to cpu %d\n", role, cpu);
}

/* Consumer stage: frame k from slot k&1.
 *   FUSE_HEAD_PL=0: the NEON head (deconv + final + arg-max) from the boundary
 *                   tensor the producer widened into g_bb[s].
 *   FUSE_HEAD_PL=1: the head already ran in the fabric; drain its accumulator
 *                   out of the arena, reshape to CHW, arg-max.
 * DARK is included either way, so the stage time covers the whole head. */
static void *head_worker(void *arg) {
    (void)arg;
    pin_role(ROLE_HEAD);
    int htim = getenv("PIPE_TIMING") != NULL;
    double h_wait = 0, h_comp = 0; int h_n = 0;
    for (int k = 0; k < g_frames; k++) {
        int s = k & 1;
        double ta = htim ? now_ms() : 0;
        pthread_mutex_lock(&m);
        while (!bb_full[s] && !stop) pthread_cond_wait(&cv, &m);
        if (!bb_full[s] && stop) { pthread_mutex_unlock(&m); break; }
        int fr = bb_frame[s];
        pthread_mutex_unlock(&m);
        double tb = htim ? now_ms() : 0;

        if (g_head_pl) {
            /* frame `fr`'s accumulator is in slot fr & 1, which the next
             * frame's head does not write (op64's output alternates) */
            mbv2_fuse_head_readout(fr, g_ro[s]);
            mbv2_fuse_head_finish(g_ro[s], g_acc, g_kp[fr]);
        } else {
            mbv2_ps_head(g_head, g_bb[s], g_acc, g_kp[fr]);
        }
        { static float dc[NET_OUT_C][2]; mbv2_dark_refine(g_acc, dc);
          g_dark_sink += dc[2][0]; }

        pthread_mutex_lock(&m);
        bb_full[s] = 0; pthread_cond_broadcast(&cv);
        pthread_mutex_unlock(&m);
        if (htim && k >= 2) { h_wait += tb - ta; h_comp += now_ms() - tb; h_n++; }
    }
    if (htim && h_n > 0)
        fprintf(stderr, "[pipe_timing] head stage: wait-bb=%.2f  head+dark=%.2f ms\n",
                h_wait / h_n, h_comp / h_n);
    return NULL;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *root = argc > 1 ? argv[1] : ".";
    int frames = argc > 2 ? atoi(argv[2]) : 120;
    int fx     = argc > 3 ? atoi(argv[3]) : 0;
    if (frames < 2) frames = 2;
    if (frames > MAX_FRAMES) frames = MAX_FRAMES;
    g_frames = frames;
    g_kp = malloc(sizeof(int) * NET_OUT_C * 2 * frames);
    if (!g_kp) { fprintf(stderr, "kp alloc failed\n"); return 1; }

    char p[512];
    FILE *f;
    snprintf(p, sizeof p, "%s/data/fuse_weights.bin", root);
    f = fopen(p, "rb");
    if (!f) { fprintf(stderr, "read %s\n", p); return 1; }
    /* exact-size check: a larger file would load a truncated blob whose
     * regions have moved */
    { long _sz; fseek(f, 0, SEEK_END); _sz = ftell(f); rewind(f);
      if (_sz != (long)FUSE_BLOB_BYTES) {
          fprintf(stderr, "%s is %ld bytes, this build wants %ld -- rebuild the app "
                          "and the blob from the same packer run\n",
                  p, _sz, (long)FUSE_BLOB_BYTES); fclose(f); return 1; } }
    if (fread(g_fuse, 1, FUSE_BLOB_BYTES, f) != FUSE_BLOB_BYTES) {
        fprintf(stderr, "read %s\n", p); fclose(f); return 1; }
    fclose(f);
    snprintf(p, sizeof p, "%s/data/model_mbv2.bin", root);
    if (read_exact(p, g_head, BLOB_BYTES)) return 1;

    /* The input is a fixture: deterministic, with its own golden keypoints.
     * PIPE_ROTATE=n loads fixtures 0..n-1 and feeds frame k from fixture
     * k mod n, to check that the frame time does not depend on pixel values;
     * unset or 1 uses the single fixture named by the argument. */
    { const char *r = getenv("PIPE_ROTATE");
      if (r && atoi(r) > 1) {
          g_nfix = atoi(r);
          if (g_nfix > NFIX_MAX) g_nfix = NFIX_MAX;
          if (fx != 0) {
              fprintf(stderr, "PIPE_ROTATE covers fixtures 0..%d; the fixture argument %d "
                              "would be ignored, so refusing rather than measuring something "
                              "other than what was asked.\n", g_nfix - 1, fx);
              return 1;
          }
      } }
    for (int q = 0; q < g_nfix; q++) {
        int fq = (g_nfix > 1) ? q : fx;
        snprintf(p, sizeof p, "%s/golden/fix_%d.bin", root, fq);
        f = fopen(p, "rb");
        if (!f) { fprintf(stderr, "open %s\n", p); return 1; }
        size_t ok = 1;
        ok &= fread(g_inp[q], 1, sizeof g_inp[q], f) == sizeof g_inp[q];
        if (fseek(f, (long)(NET_OUT_C * NET_OUT_H * NET_OUT_W) * 4, SEEK_CUR) != 0) ok = 0;
        ok &= fread(g_kp_gold[q], 1, sizeof g_kp_gold[q], f) == sizeof g_kp_gold[q];
        fclose(f);
        if (!ok) { fprintf(stderr, "fixture %d truncated\n", fq); return 1; }
    }
    /* rotated fixtures must differ, or the rotation measures nothing */
    for (int q = 1; q < g_nfix; q++)
        if (memcmp(g_inp[q], g_inp[0], sizeof g_inp[0]) == 0) {
            fprintf(stderr, "fixture %d is byte-identical to fixture 0 -- rotation would "
                            "measure nothing\n", q);
            return 1;
        }
    if (g_nfix > 1)
        printf("[pipe] ROTATING over %d fixtures: frame k uses fixture k mod %d\n",
               g_nfix, g_nfix);

    mbv2_fuse_init(g_fuse, FUSE_BLOB_BYTES);

    /* ---- the head in the fabric: weights are the hd_pl tail of
     * model_mbv2_packed.bin; descriptors and requantisation words are derived
     * and verified inside mbv2_fuse_head_init() ---- */
    g_head_pl = mbv2_fuse_head_in_pl();
    if (g_head_pl) {
        snprintf(p, sizeof p, "%s/data/model_mbv2_packed.bin", root);
        if (read_exact(p, g_packed, PACKED_BYTES)) return 1;
        mbv2_fuse_head_init(g_packed, PACKED_BYTES);
        for (int i = 0; i < 2; i++) {
            g_ro[i] = (int32_t *)malloc(mbv2_fuse_head_readout_bytes());
            if (!g_ro[i]) { fprintf(stderr, "readout buffer alloc failed\n"); return 1; }
        }
    }

    /* Sequential reference, run twice (the second result counts). It uses the
     * same FUSE_HEAD_PL mode as the stages below and is itself checked against
     * the fixture's golden keypoints. */
    int kp_ref[NFIX_MAX][NET_OUT_C * 2];
    fuse_counters_t ctr;
    for (int i = 0; i < 2; i++) {
        for (int q = 0; q < g_nfix; q++) {
            if (g_head_pl) {
                mbv2_fuse_infer(g_inp[q], g_head, g_acc, kp_ref[q], &ctr);
            } else {
                mbv2_fuse_backbone(g_inp[q], g_bb[0], &ctr);
                mbv2_ps_head(g_head, g_bb[0], g_acc, kp_ref[q]);
            }
        }
    }

    /* the sequential reference must match the fixture before it is used */
    int seq_bad = 0;
    for (int q = 0; q < g_nfix; q++)
        for (int i = 0; i < NET_OUT_C * 2; i++)
            if (kp_ref[q][i] != (int)g_kp_gold[q][i]) seq_bad++;
    if (seq_bad) {
        fprintf(stderr, "SEQUENTIAL REFERENCE DISAGREES WITH THE FIXTURE in %d of %d "
                        "keypoints -- refusing to measure throughput against it.\n",
                seq_bad, NET_OUT_C * 2 * g_nfix);
        return 1;
    }
    if (g_nfix > 1)
        printf("[pipe] sequential reference matches all %d fixtures: %d/%d keypoints each\n",
               g_nfix, NET_OUT_C, NET_OUT_C);
    else
        printf("[pipe] sequential reference matches fixture %d: %d/%d keypoints\n",
               fx, NET_OUT_C, NET_OUT_C);

    /* PIPE_PLSIM=<ms> is a diagnostic: it does not run the programmable logic,
     * so the fps it prints is not a throughput result. It replaces the backbone
     * call with a sleep of the same length, keeping the producer thread's shape
     * and removing the PL's DDR traffic, to separate that traffic from the
     * producer's CPU use. The reference loop above leaves a real boundary tensor
     * in slot 0, which is copied to slot 1 so the head sees realistic data. */
    double plsim = getenv("PIPE_PLSIM") ? atof(getenv("PIPE_PLSIM")) : 0.0;
    /* PIPE_PLSIM_IO=1 additionally keeps the processor's uncached arena traffic,
     * so PLSIM vs PLSIM_IO separates the arena's cost from the accelerator's. */
    int plsim_io = getenv("PIPE_PLSIM_IO") && atoi(getenv("PIPE_PLSIM_IO"));
    /* PIPE_PLSIM_CACHED=1 runs the same two phases against cacheable memory plus
     * the `dc civac` maintenance a cacheable arena would owe. */
    int plsim_cached = getenv("PIPE_PLSIM_CACHED") && atoi(getenv("PIPE_PLSIM_CACHED"));
    if (plsim > 0) {
        memcpy(g_bb[1], g_bb[0], sizeof g_bb[0]);
        /* likewise leave a real heatmap in slot 1 for the consumer; with the head
         * faked the producer publishes frame k rather than k-1 and needs no
         * drain */
        if (g_head_pl) mbv2_fuse_head_run(1);
        printf("🔴 [pipe] PIPE_PLSIM=%.2f ms io=%d cached=%d -- DIAGNOSTIC, the PL is "
               "NOT run. The fps below is NOT a throughput result.\n",
               plsim, plsim_io, plsim_cached);
        if (g_head_pl && plsim_cached)
            printf("🔴 [pipe] PIPE_PLSIM_CACHED has no effect with the head in the "
                   "fabric: the cacheable-arena experiment is written against the "
                   "boundary read-back, and this mode does not perform one.\n");
    } else if (plsim_io) {
        printf("🔴 [pipe] PIPE_PLSIM_IO without PIPE_PLSIM does nothing.\n");
    }

    pthread_t hw;
    if (pthread_create(&hw, NULL, head_worker, NULL) != 0) {
        fprintf(stderr, "head thread\n"); return 1; }

    pin_role(ROLE_PROD);
    /* SCHED_FIFO for the producer is off by default (PIPE_RT=1 enables it): in
     * this app the producer is the shorter stage, so real-time priority for it
     * preempts the longer one. */
    int want_rt = getenv("PIPE_RT") ? atoi(getenv("PIPE_RT")) : 0;
    if (want_rt) {
        struct sched_param sp = { .sched_priority = 10 };
        if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0)
            fprintf(stderr, "[pipe] SCHED_FIFO unavailable (%s) -- staying CFS\n",
                    strerror(errno));
    }
    /* print the stage contents: the cut moves with the mode */
    if (g_head_pl)
        printf("[pipe] stages: PRODUCER(write+stage+head(k-1)||backbone(k)) || "
               "CONSUMER(readout %zu B + reshape + argmax + DARK)\n",
               mbv2_fuse_head_readout_bytes());
    else
        printf("[pipe] stages: PRODUCER(write+PL+readback) || HEAD(NEON head + DARK)\n");
    /* the whole schedule on one line, so a log states what it ran under */
    {
        char a[16], b[16];
        int ca = pin_target(ROLE_PROD), cb = pin_target(ROLE_HEAD);
        if (ca < 0) snprintf(a, sizeof a, "free"); else snprintf(a, sizeof a, "cpu%d", ca);
        if (cb < 0) snprintf(b, sizeof b, "free"); else snprintf(b, sizeof b, "cpu%d", cb);
        printf("[pipe] schedule: producer=%s/%s  head=CFS/%s  workers=%s  head=%s\n",
               want_rt ? "SCHED_FIFO" : "CFS", a, b,
               getenv("HEAD_THREADS") ? getenv("HEAD_THREADS") : "default",
               g_head_pl ? "PL (FUSE_HEAD_PL=1)" : "PS/NEON");
    }

    int ptim = getenv("PIPE_TIMING") != NULL;
    if (plsim > 0 && !ptim)
        printf("🔴 [pipe] PLSIM without PIPE_TIMING measures nothing. Set PIPE_TIMING=1.\n");
    double w_bb = 0, w_run = 0, w_hand = 0;
    double t0 = now_ms();
    for (int k = 0; k < frames; k++) {
        /* Which frame is published: with the head in the fabric the producer
         * runs backbone(k) and head(k-1) together, so it publishes frame k-1
         * into slot (k-1)&1; otherwise frame k. */
        int hf = (g_head_pl && plsim <= 0) ? k - 1 : k;
        int s  = hf & 1;
        double ta = ptim ? now_ms() : 0;
        if (hf >= 0) {
            pthread_mutex_lock(&m);
            while (bb_full[s]) pthread_cond_wait(&cv, &m);  /* wait CONSUMER drained s */
            pthread_mutex_unlock(&m);
        }
        double tb = ptim ? now_ms() : 0;

        if (plsim > 0) {
            /* same duration and thread, no PL traffic; the slot already holds
             * the real boundary. With the head in the fabric the arena traffic
             * to keep is the input image plus the boundary staging, so PLSIM_IO
             * calls that mode's own io-only path. */
            struct timespec ts = { (time_t)(plsim / 1000.0),
                                   (long)((plsim - 1000.0 * (long)(plsim / 1000.0)) * 1e6) };
            if (plsim_io) {
                if (g_head_pl) mbv2_fuse_frame_pl_io_only(INP(k));
                else           mbv2_fuse_backbone_io_only(INP(k), g_bb[s], plsim_cached);
            }
            nanosleep(&ts, NULL);
        } else if (g_head_pl) {
            /* start head(k-1), run backbone(k), wait for the head */
            mbv2_fuse_frame_pl(INP(k), hf, &ctr);
        } else {
            mbv2_fuse_backbone(INP(k), g_bb[s], &ctr);      /* sleep-polls the PL */
        }

        double tc = ptim ? now_ms() : 0;
        if (hf >= 0) {
            pthread_mutex_lock(&m);
            bb_full[s] = 1; bb_frame[s] = hf;
            pthread_cond_broadcast(&cv);
            pthread_mutex_unlock(&m);
        }
        if (ptim && k >= 2) { w_bb += tb - ta; w_run += tc - tb; w_hand += now_ms() - tc; }
    }
    /* ---- drain: the head is one frame behind, so the last frame's head runs
     * here, inside the timed region ---- */
    if (g_head_pl && plsim <= 0) {
        int hf = frames - 1, s = hf & 1;
        pthread_mutex_lock(&m);
        while (bb_full[s]) pthread_cond_wait(&cv, &m);
        pthread_mutex_unlock(&m);
        mbv2_fuse_head_run(hf);
        pthread_mutex_lock(&m);
        bb_full[s] = 1; bb_frame[s] = hf;
        pthread_cond_broadcast(&cv);
        pthread_mutex_unlock(&m);
    }
    if (ptim && frames > 2) {
        double n = frames - 2;
        fprintf(stderr, "[pipe_timing] producer loop: wait-head=%.2f  backbone=%.2f"
                        "  handoff=%.2f  (sum=%.2f) ms\n",
                w_bb/n, w_run/n, w_hand/n, (w_bb + w_run + w_hand)/n);
        if (g_head_pl) {
            fuse_pl_split_t sp; mbv2_fuse_last_pl_split(&sp);
            fprintf(stderr, "[pipe_timing] producer split (last frame): write-in=%.2f"
                            "  stage-boundary=%.2f  backbone PL=%.2f  head PL=%.2f ms"
                            "  (the head overlaps the backbone; it is not additive)\n",
                    sp.t_in_ms, sp.t_stage_ms, sp.t_pl_ms, sp.t_hd_ms);
        }
    }
    pthread_mutex_lock(&m); stop = 1; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&m);
    pthread_join(hw, NULL);
    double t1 = now_ms();

    /* ---- two independent correctness checks, both must hold ---- */
    /* frame k came from fixture k mod g_nfix; both referees use the same index */
    int bad_seq = 0, bad_gold = 0;
    for (int k = 0; k < frames; k++) {
        int q = k % g_nfix;
        for (int i = 0; i < NET_OUT_C * 2; i++) {
            if (g_kp[k][i] != kp_ref[q][i]) {
                if (++bad_seq <= 5)
                    fprintf(stderr, "  frame %d (fixture %d) kp[%d]=%d != sequential %d\n",
                            k, q, i, g_kp[k][i], kp_ref[q][i]);
            }
            if (g_kp[k][i] != (int)g_kp_gold[q][i]) bad_gold++;
        }
    }

    double ms = t1 - t0;
    printf("\n=== fused cross-frame pipeline: %d frames in %.1f ms = %.2f ms/frame = %.2f fps ===\n",
           frames, ms, ms / frames, frames * 1000.0 / ms);
    printf("correctness vs sequential: %s (%d keypoint mismatches)\n",
           bad_seq ? "FAIL" : "PASS", bad_seq);
    if (g_nfix > 1)
        printf("correctness vs the %d fixtures' goldens: %s (%d keypoint mismatches)\n",
               g_nfix, bad_gold ? "FAIL" : "PASS", bad_gold);
    else
        printf("correctness vs fixture %d golden: %s (%d keypoint mismatches)\n",
               fx, bad_gold ? "FAIL" : "PASS", bad_gold);

    /* the counters of the last frame, with both engines running (mbv2_fuse_test
     * is sequential, so its counters are the array alone) */
    if (g_head_pl) {
        printf("\n  acceptance counters, LAST frame, BOTH ENGINES RUNNING:\n");
        fuse_print_counters(&ctr, FUSE_CLK_MHZ);
        printf("  (mbv2_fuse_test's copies are the array running ALONE -- it is\n"
               "   sequential. Compare against those, not against each other.)\n");
    }
    /* fixture 0's keypoints, as a sample; all fixtures were checked above */
    printf("keypoints (fixture %d):", (g_nfix > 1) ? 0 : fx);
    for (int k = 0; k < NET_OUT_C; k++)
        printf(" (%d,%d)", kp_ref[0][k*2], kp_ref[0][k*2+1]);
    printf("\n");
    return (bad_seq || bad_gold) ? 1 : 0;
}
