/* ============================================================================
 *  main_cam.c -- live USB-webcam pose demo on the AXU2CGB.
 *
 *  V4L2 capture (YUYV, or MJPEG via libturbojpeg) -> crop box resized to 256x256
 *  -> int8 quantise (input_qlut.h) -> inference -> skeleton drawn on /dev/fb0
 *  (fbdev; keypoints go to stdout when there is no framebuffer).
 *  Default build: mbv2_ps (65-operator backbone + NEON head). -DFUSE_BACKEND:
 *  fused backbone + PL head (run with FUSE_HEAD_PL=1; sequential only).
 *
 *  Usage: mbv2_cam [/dev/video0] [/dev/fb0]
 *         mbv2_cam --selftest [golden/fix_0.bin]      replay a fixture bit-exactly
 *  Files, relative to the working directory: default build
 *    model_mbv2_packed.bin, model_mbv2.bin; fused build data/fuse_weights.bin,
 *    data/model_mbv2_packed.bin.
 *  Environment: CAM_FMT=mjpg, CAM_W / CAM_H (default 640x480), CAM_CROP_CX /
 *    CAM_CROP_CY / CAM_CROP_SIDE / CAM_CROP_SHIFT, CAM_STREAM=<port>,
 *    CAM_STREAM_Q, CAM_STREAM_NOJPEG, CAM_DUMP=<dir> with CAM_DUMP_EVERY /
 *    CAM_DUMP_N / CAM_DUMP_SKIP, CAM_QSTAT, CAM_SEQ=1, PIPE_PIN, PIPE_RT,
 *    FUSE_HEAD_PL.
 *  Needs the V4L2 uapi headers and libturbojpeg in the sysroot.
 * ========================================================================== */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE      /* CPU_SET / sched_setaffinity (before any header) */
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>
#include <linux/fb.h>
#include <turbojpeg.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#include "mbv2_ps.h"
#ifdef FUSE_BACKEND
#include "mbv2_fuse_ps.h"       /* the fused backbone + PL head */
#endif
#include "pl_hal.h"
#include "model_meta.h"
#include "pack_meta_mbv2.h"
#include "mbv2_pose.h"
#define W2ROM_BYTES (W2_AL + W2HW_BYTES)

/* CAM_MAX_PIX bounds every frame buffer; the buffers are static so the memory is
 * reserved up front. */
#define CAM_MAX_PIX (1920*1080)

extern const double INPUT_SCALE;                 /* from model_meta.c */

/* 14-joint skeleton edges, joint indices 0..13 */
static const int EDGES[][2] = {
    {0,1},{1,2},{2,6},{6,3},{3,4},{4,5},        /* legs -> pelvis */
    {6,7},{7,8},{8,9},                          /* spine/neck/head */
    {8,12},{12,11},{11,10},                     /* r arm */
    {8,13},                                     /* l shoulder link (approx) */
};
#define N_EDGES ((int)(sizeof(EDGES)/sizeof(EDGES[0])))

static double now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

/* Open a weight file and require it to be exactly `n` bytes, so a larger file
 * from another export is refused instead of being read short. Returns the open
 * stream positioned at 0, or NULL after printing why. */
static FILE *open_exact(const char *path, size_t n) {
    FILE *f = fopen(path, "rb");
    long sz;
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return NULL; }
    if (fseek(f, 0, SEEK_END) != 0 || (sz = ftell(f)) < 0) {
        fprintf(stderr, "cannot size %s\n", path); fclose(f); return NULL; }
    rewind(f);
    if ((size_t)sz != n) {
        fprintf(stderr, "%s is %ld bytes, this build wants %zu -- the app and the "
                        "file come from different exports\n", path, sz, n);
        fclose(f); return NULL; }
    return f;
}

/* ---- CAM_STREAM: one record per frame over TCP ----
 * The board listens and the host connects. One client at a time; a second
 * connection replaces the first. Streaming perturbs the frame rate (JPEG
 * encoding, and a slow reader back-pressures the loop), so numbers taken with
 * it on are not throughput results. */
static int g_lsock = -1, g_csock = -1;
static int g_jpeg_q = 75, g_send_jpeg = 1;

/* ---- a still pushed from the host ----
 * The viewer can send one JPEG to run instead of a camera frame. It goes
 * through the same crop, quantiser and engine as a live frame. The reply is an
 * ordinary frame record with flags bit 1 (FLAG_IS_STILL) set; bit 0 means a
 * JPEG is attached. */
static uint8_t *g_still_jpg = NULL;      /* owned; the newest push waiting to be run */
static uint32_t g_still_len = 0;
#define STILL_MAX_BYTES (16u * 1024u * 1024u)
#define STILL_RECV_MS   4000.0           /* deadline for a push's payload */
#define FLAG_HAS_JPEG   1u
#define FLAG_IS_STILL   2u

/* ---- the crop box ----
 * The network is single-person top-down, so the box should frame the person.
 * 0 means "the centre square". The box centre is shifted down by g_crop_shift
 * of the box side (default 0.06). */
static int   g_crop_cx = 0, g_crop_cy = 0, g_crop_side = 0;
static float g_crop_shift = 0.06f;      /* downward shift, as a fraction of the box */

static void crop_box(int jw, int jh, int *side, int *ox, int *oy)
{
    int sd = g_crop_side > 0 ? g_crop_side : (jw < jh ? jw : jh);
    int cx = g_crop_cx > 0 ? g_crop_cx : jw / 2;
    int cy = g_crop_cy > 0 ? g_crop_cy : jh / 2;
    cy += (int)(g_crop_shift * sd);
    if (sd < 32) sd = 32;
    *side = sd; *ox = cx - sd / 2; *oy = cy - sd / 2;
}

static int stream_listen(int port)
{
    struct sockaddr_in a;
    int on = 1;
    g_lsock = socket(AF_INET, SOCK_STREAM, 0);
    if (g_lsock < 0) { perror("socket"); return -1; }
    setsockopt(g_lsock, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_ANY); a.sin_port = htons(port);
    if (bind(g_lsock, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); return -1; }
    if (listen(g_lsock, 1) < 0) { perror("listen"); return -1; }
    /* non-blocking accept: the pipeline must keep running with nobody watching */
    fcntl(g_lsock, F_SETFL, fcntl(g_lsock, F_GETFL, 0) | O_NONBLOCK);
    printf("[stream] listening on port %d, %s\n", port,
           g_send_jpeg ? "JPEG frame + keypoints" : "keypoints only (no image leaves the board)");
    printf("[stream] 🔴 streaming perturbs the frame rate; this is a viewer, not a benchmark\n");
    fflush(stdout);
    return 0;
}

/* Viewer -> board. Every control message opens with the same 16-byte header; a
 * partial header is kept across polls so the stream stays in step:
 *
 *     'TWNC'  cx  cy  side      -- move the crop box
 *     'TWNI'  jpeg_len  0  0    -- then jpeg_len bytes: run this still instead of a frame */
static uint8_t g_ctrl_buf[16];
static size_t  g_ctrl_have = 0;

/* The payload of a still push: blocking with a deadline rather than spread
 * across polls. */
static int ctrl_recv_payload(uint8_t *p, uint32_t n)
{
    double t0 = now_ms();
    uint32_t got = 0;
    while (got < n) {
        ssize_t r = recv(g_csock, p + got, n - got, MSG_DONTWAIT);
        if (r > 0) { got += (uint32_t)r; continue; }
        if (r == 0) return -1;                          /* viewer closed mid-push */
        if (errno != EAGAIN && errno != EWOULDBLOCK) return -1;
        if (now_ms() - t0 > STILL_RECV_MS) return -1;
        usleep(1000);
    }
    return 0;
}

static void stream_poll_control(void)
{
    if (g_csock < 0) return;
    ssize_t n = recv(g_csock, g_ctrl_buf + g_ctrl_have,
                     sizeof g_ctrl_buf - g_ctrl_have, MSG_DONTWAIT);
    if (n <= 0) return;
    g_ctrl_have += (size_t)n;
    if (g_ctrl_have < sizeof g_ctrl_buf) return;        /* the rest arrives on a later poll */
    g_ctrl_have = 0;

    uint32_t magic; int32_t v[3];
    memcpy(&magic, g_ctrl_buf, 4);
    memcpy(v, g_ctrl_buf + 4, 12);

    if (magic == 0x434E5754u) {                         /* 'T','W','N','C' */
        g_crop_cx = v[0]; g_crop_cy = v[1]; g_crop_side = v[2];
        printf("[stream] crop set to centre (%d,%d) side %d\n", v[0], v[1], v[2]);
        fflush(stdout);
        return;
    }

    if (magic == 0x494E5754u) {                         /* 'T','W','N','I' */
        uint32_t len = (uint32_t)v[0];
        /* a bad length cannot be skipped over, so the connection is dropped */
        if (v[0] <= 0 || len > STILL_MAX_BYTES) {
            printf("[stream] still push rejected: length %d\n", v[0]);
            fflush(stdout); close(g_csock); g_csock = -1; return;
        }
        uint8_t *buf = (uint8_t *)malloc(len);
        if (!buf) {
            printf("[stream] still push: out of memory (%u bytes)\n", len);
            fflush(stdout); close(g_csock); g_csock = -1; return;
        }
        if (ctrl_recv_payload(buf, len) < 0) {
            free(buf);
            printf("[stream] still push: payload did not arrive\n");
            fflush(stdout); close(g_csock); g_csock = -1; return;
        }
        free(g_still_jpg);                              /* a newer push replaces an unrun one */
        g_still_jpg = buf; g_still_len = len;
        printf("[stream] still pushed, %u bytes\n", len);
        fflush(stdout);
        return;
    }

    printf("[stream] unknown control magic %08x -- dropping the connection rather than "
           "guessing where the next message starts\n", magic);
    fflush(stdout); close(g_csock); g_csock = -1;
}

static void stream_poll_accept(void)
{
    if (g_lsock < 0) return;
    int c = accept(g_lsock, NULL, NULL);
    if (c < 0) return;
    int on = 1;
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
    if (g_csock >= 0) close(g_csock);
    g_csock = c;
    printf("[stream] viewer connected\n");
    fflush(stdout);
}

static int send_all(int fd, const void *buf, size_t n)
{
    const uint8_t *p = (const uint8_t *)buf;
    while (n) {
        ssize_t w = send(fd, p, n, 0);
        if (w <= 0) return -1;
        p += w; n -= (size_t)w;
    }
    return 0;
}

/* the header is packed by hand rather than by a struct, so it has no padding */
static void stream_frame(uint32_t idx, const uint8_t *rgb, int jw, int jh,
                         int side, int ox, int oy, const int *kp, const int32_t *conf,
                         uint32_t infer_us, uint32_t period_us, tjhandle enc,
                         uint16_t xflags)
{
    if (g_csock < 0) return;
    uint8_t *jpg = NULL; unsigned long jlen = 0;
    if (g_send_jpeg && enc) {
        if (tjCompress2(enc, rgb, jw, 0, jh, TJPF_RGB, &jpg, &jlen,
                        TJSAMP_420, g_jpeg_q, TJFLAG_FASTDCT) != 0) {
            jpg = NULL; jlen = 0;
        }
    }
    uint8_t h[4 + 2 + 2 + 4 + 4 * 5 + 2 * 28 + 4 * 14 + 4 + 4 + 4];
    size_t o = 0;
#define PUT32(v) do { uint32_t _t = (uint32_t)(v); memcpy(h + o, &_t, 4); o += 4; } while (0)
#define PUT16(v) do { uint16_t _t = (uint16_t)(v); memcpy(h + o, &_t, 2); o += 2; } while (0)
    PUT32(0x504E5754u); PUT16(2); PUT16((jlen ? FLAG_HAS_JPEG : 0u) | xflags); PUT32(idx);
    PUT32(jw); PUT32(jh); PUT32(side); PUT32(ox); PUT32(oy);
    for (int i = 0; i < 28; i++) PUT16((int16_t)kp[i]);
    /* per joint, the accumulator value at the arg-max position (a confidence) */
    for (int i = 0; i < 14; i++) PUT32(conf[i]);
    PUT32(infer_us); PUT32(period_us); PUT32((uint32_t)jlen);
#undef PUT32
#undef PUT16
    int bad = send_all(g_csock, h, o) < 0;
    if (!bad && jlen) bad = send_all(g_csock, jpg, jlen) < 0;
    if (jpg) tjFree(jpg);
    if (bad) {
        printf("[stream] viewer went away\n"); fflush(stdout);
        close(g_csock); g_csock = -1;
    }
}

/* ---- CAM_DUMP: keep frames and keypoints as files ----
 * With CAM_DUMP=<dir>, every CAM_DUMP_EVERY-th frame is written as a binary PPM
 * together with the crop geometry used (cam_kp.txt: idx jw jh side ox oy, then
 * 14 (x,y) pairs in heatmap coordinates); drawing is left to the host. */
static int   g_dump_n = 0;                 /* how many frames written so far */
static FILE *g_dump_kp = NULL;

static void dump_frame(const char *dir, const uint8_t *rgb, int jw, int jh,
                       int side, int ox, int oy, const int *kp)
{
    char path[512];
    snprintf(path, sizeof path, "%s/cam_%02d.ppm", dir, g_dump_n);
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "[dump] cannot write %s\n", path); return; }
    fprintf(f, "P6\n%d %d\n255\n", jw, jh);
    fwrite(rgb, 1, (size_t)jw * jh * 3, f);
    fclose(f);
    if (!g_dump_kp) {
        snprintf(path, sizeof path, "%s/cam_kp.txt", dir);
        g_dump_kp = fopen(path, "w");
        if (!g_dump_kp) { fprintf(stderr, "[dump] cannot write %s\n", path); return; }
        fprintf(g_dump_kp, "# idx jw jh side ox oy then 14 (x,y) pairs in 64x64 heatmap coords\n");
    }
    fprintf(g_dump_kp, "%d %d %d %d %d %d", g_dump_n, jw, jh, side, ox, oy);
    for (int k = 0; k < 28; k++) fprintf(g_dump_kp, " %d", kp[k]);
    fprintf(g_dump_kp, "\n");
    fflush(g_dump_kp);
    printf("[dump] wrote %s/cam_%02d.ppm (%dx%d)\n", dir, g_dump_n, jw, jh);
    fflush(stdout);
    g_dump_n++;
}

/* ---- int8 quantise ----
 * INPUT_QLUT is generated by tools/gen_input_qlut.py from the deployed model's
 * INPUT_SCALE: per channel, the quantised value of the ImageNet-normalised
 * pixel. The golden fixtures store the already-quantised tensor, so no fixture
 * exercises this step; CAM_QSTAT=1 prints the statistics of the live tensor. */
#include "input_qlut.h"

/* Crop box -> the 256x256 int8 tensor. One definition for live frames and
 * pushed stills. Sampling is clamped because the box may hang off the frame. */
static void prep_input(const uint8_t *rgb, int jw, int jh,
                       int side, int ox, int oy, int8_t *inp)
{
    for (int y = 0; y < 256; y++) {
        int sy = oy + y * side / 256;
        if (sy < 0) sy = 0; else if (sy >= jh) sy = jh - 1;
        const uint8_t *row = rgb + (size_t)sy * jw * 3;
        int8_t *d0 = inp + y * 256, *d1 = d0 + 256 * 256, *d2 = d1 + 256 * 256;
        for (int x = 0; x < 256; x++) {
            int sx = ox + x * side / 256;
            if (sx < 0) sx = 0; else if (sx >= jw) sx = jw - 1;
            const uint8_t *s = row + (size_t)sx * 3;
            d0[x] = INPUT_QLUT[0][s[0]];      /* plane c uses channel c's table */
            d1[x] = INPUT_QLUT[1][s[1]];
            d2[x] = INPUT_QLUT[2][s[2]];
        }
    }
}

/* ---- YUYV 4:2:2 -> RGB ----
 * JFIF full-range coefficients, 16.16 fixed point. */
static inline uint8_t clamp8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : (uint8_t)v); }
static void yuyv_to_rgb(const uint8_t *src, uint8_t *dst, int w, int h) {
    int n = w * h / 2;                                     /* two pixels per YUYV quad */
    for (int i = 0; i < n; i++) {
        int y0 = src[4*i], cb = src[4*i+1] - 128, y1 = src[4*i+2], cr = src[4*i+3] - 128;
        int r = ( 91881 * cr) >> 16;
        int g = (-22554 * cb - 46802 * cr) >> 16;
        int b = (116130 * cb) >> 16;
        dst[6*i+0] = clamp8(y0 + r); dst[6*i+1] = clamp8(y0 + g); dst[6*i+2] = clamp8(y0 + b);
        dst[6*i+3] = clamp8(y1 + r); dst[6*i+4] = clamp8(y1 + g); dst[6*i+5] = clamp8(y1 + b);
    }
}

/* ---- V4L2 ---- */
struct vbuf { void *start; size_t len; };
static int v4l2_open(const char *dev, int *w, int *h, struct vbuf **bufs, int *nbuf, int fd_out[1],
                     int *is_yuyv) {
    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open video"); return -1; }
    /* prefer YUYV (no decode); CAM_FMT=mjpg selects MJPEG */
    const char *fsel = getenv("CAM_FMT");
    int want_mjpg = (fsel && (fsel[0] == 'm' || fsel[0] == 'M'));
    struct v4l2_format fmt; memset(&fmt, 0, sizeof fmt);
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    /* CAM_W / CAM_H choose the capture mode (default 640x480) */
    int req_w = getenv("CAM_W") ? atoi(getenv("CAM_W")) : 640;
    int req_h = getenv("CAM_H") ? atoi(getenv("CAM_H")) : 480;
    if (req_w * req_h > CAM_MAX_PIX) {
        fprintf(stderr, "CAM_W x CAM_H = %d exceeds the %d this build reserves\n",
                req_w * req_h, CAM_MAX_PIX);
        return -1;
    }
    fmt.fmt.pix.width = req_w; fmt.fmt.pix.height = req_h;
    fmt.fmt.pix.pixelformat = want_mjpg ? V4L2_PIX_FMT_MJPEG : V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_ANY;
    if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0 || fmt.fmt.pix.pixelformat !=
        (want_mjpg ? V4L2_PIX_FMT_MJPEG : V4L2_PIX_FMT_YUYV)) {
        memset(&fmt, 0, sizeof fmt);                       /* fall back to the other format */
        fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        fmt.fmt.pix.width = req_w; fmt.fmt.pix.height = req_h;
        fmt.fmt.pix.pixelformat = want_mjpg ? V4L2_PIX_FMT_YUYV : V4L2_PIX_FMT_MJPEG;
        fmt.fmt.pix.field = V4L2_FIELD_ANY;
        if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) { perror("S_FMT"); close(fd); return -1; }
    }
    *is_yuyv = (fmt.fmt.pix.pixelformat == V4L2_PIX_FMT_YUYV);
    printf("[cam] format = %s %dx%d\n", *is_yuyv ? "YUYV (no decode)" : "MJPEG (libjpeg-turbo)",
           fmt.fmt.pix.width, fmt.fmt.pix.height);
    *w = fmt.fmt.pix.width; *h = fmt.fmt.pix.height;

    struct v4l2_requestbuffers req; memset(&req, 0, sizeof req);
    req.count = 4; req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; req.memory = V4L2_MEMORY_MMAP;
    if (ioctl(fd, VIDIOC_REQBUFS, &req) < 0) { perror("REQBUFS"); close(fd); return -1; }
    *nbuf = req.count;
    *bufs = calloc(req.count, sizeof(struct vbuf));
    for (unsigned i = 0; i < req.count; i++) {
        struct v4l2_buffer b; memset(&b, 0, sizeof b);
        b.type = req.type; b.memory = V4L2_MEMORY_MMAP; b.index = i;
        if (ioctl(fd, VIDIOC_QUERYBUF, &b) < 0) { perror("QUERYBUF"); return -1; }
        (*bufs)[i].len = b.length;
        (*bufs)[i].start = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
        ioctl(fd, VIDIOC_QBUF, &b);
    }
    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (ioctl(fd, VIDIOC_STREAMON, &type) < 0) { perror("STREAMON"); return -1; }
    fd_out[0] = fd;
    return 0;
}

/* ---- framebuffer ---- */
struct fbdev { int fd; uint8_t *mem; int w, h, bpp, stride; };
static int fb_open(const char *dev, struct fbdev *fb) {
    fb->fd = open(dev, O_RDWR);
    if (fb->fd < 0) return -1;
    struct fb_var_screeninfo v; struct fb_fix_screeninfo f;
    ioctl(fb->fd, FBIOGET_VSCREENINFO, &v); ioctl(fb->fd, FBIOGET_FSCREENINFO, &f);
    fb->w = v.xres; fb->h = v.yres; fb->bpp = v.bits_per_pixel; fb->stride = f.line_length;
    fb->mem = mmap(NULL, f.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb->fd, 0);
    return fb->mem == MAP_FAILED ? -1 : 0;
}
static void fb_putpx(struct fbdev *fb, int x, int y, uint8_t r, uint8_t g, uint8_t b) {
    if (x < 0 || y < 0 || x >= fb->w || y >= fb->h) return;
    uint8_t *p = fb->mem + y * fb->stride + x * (fb->bpp / 8);
    if (fb->bpp == 32) { p[0] = b; p[1] = g; p[2] = r; p[3] = 0xff; }
    else if (fb->bpp == 16) { uint16_t c = ((r>>3)<<11)|((g>>2)<<5)|(b>>3); *(uint16_t*)p = c; }
}
static void fb_blit_rgb(struct fbdev *fb, const uint8_t *rgb, int rw, int rh) {
    for (int y = 0; y < rh && y < fb->h; y++)
        for (int x = 0; x < rw && x < fb->w; x++) {
            const uint8_t *s = rgb + (y * rw + x) * 3;
            fb_putpx(fb, x, y, s[0], s[1], s[2]);
        }
}
static void draw_disc(struct fbdev *fb, int cx, int cy, int rad, uint8_t r, uint8_t g, uint8_t b) {
    for (int dy = -rad; dy <= rad; dy++) for (int dx = -rad; dx <= rad; dx++)
        if (dx*dx + dy*dy <= rad*rad) fb_putpx(fb, cx+dx, cy+dy, r, g, b);
}

/* ===================== 3-stage camera pipeline ============================
 * PREP(frame k+1) || PL backbone(frame k) || HEAD+draw(frame k-1). PREP owns
 * the v4l2 fd so all ioctls stay on one thread. Default build only. */
struct cam_ctx {
    int vfd, vw, vh, is_yuyv; struct vbuf *bufs; tjhandle tj; struct fbdev *fb;
    const uint8_t *w2rom; const int8_t *w8rom, *head_blob;
};
static struct cam_ctx g_ctx;
static uint8_t  g_rgb[2][CAM_MAX_PIX*3];    /* decoded frame per slot (HEAD draws it) */
static int8_t   g_inp[2][3*256*256];
static int16_t  g_bb[2][MBV2_BB_LEN];       /* backbone -> head boundary, double buffered */
static int32_t  g_acc[14*64*64];            /* head scratch (HEAD is single-threaded) */
/* HEAD_PL mode only: the accumulator is per slot; it is read out in the PL
 * thread, while DARK and drawing run in the display thread. */
static int32_t  g_accs[2][14*64*64];
static int      g_head_pl = 0;
static int      g_kp[2][14*2];
static pthread_mutex_t cm = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cc = PTHREAD_COND_INITIALIZER;
static int col_ready[2] = {0,0};             /* PREP -> PL   : im2col slot filled */
static int bb_ready[2]  = {0,0};             /* PL   -> HEAD : boundary tensor ready */
static volatile int cam_stop = 0;
static double g_t_dec = 0, g_t_prep = 0;     /* last PREP timings (display only) */

static void cam_pin(int cpu) {
    if (getenv("PIPE_PIN") && atoi(getenv("PIPE_PIN")) == 0) return;
    cpu_set_t s; CPU_ZERO(&s); CPU_SET(cpu, &s); sched_setaffinity(0, sizeof(s), &s);
}

static void *cam_prep(void *arg) {
    (void)arg;
    for (int k = 0; !cam_stop; k++) {
        int s = k & 1;
        pthread_mutex_lock(&cm);
        while (col_ready[s] && !cam_stop) pthread_cond_wait(&cc, &cm);
        pthread_mutex_unlock(&cm);
        if (cam_stop) break;

        struct v4l2_buffer b; memset(&b, 0, sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP;
        if (ioctl(g_ctx.vfd, VIDIOC_DQBUF, &b) < 0) { if (errno == EAGAIN) { k--; continue; }
            perror("DQBUF"); cam_stop = 1; break; }
        double t0 = now_ms();
        int ok;
        if (g_ctx.is_yuyv) { yuyv_to_rgb(g_ctx.bufs[b.index].start, g_rgb[s], g_ctx.vw, g_ctx.vh); ok = 1; }
        else ok = (tjDecompress2(g_ctx.tj, g_ctx.bufs[b.index].start, b.bytesused, g_rgb[s],
                                 g_ctx.vw, 0, g_ctx.vh, TJPF_RGB, 0) == 0);
        double t1 = now_ms();
        ioctl(g_ctx.vfd, VIDIOC_QBUF, &b);           /* release the capture buffer early */
        if (!ok) { k--; continue; }

        int jw = g_ctx.vw, jh = g_ctx.vh;
        int side = jw < jh ? jw : jh, ox = (jw-side)/2, oy = (jh-side)/2;
        for (int y = 0; y < 256; y++) {
            int sy = oy + y*side/256;
            const uint8_t *row = g_rgb[s] + (size_t)sy*jw*3;
            int8_t *d0 = g_inp[s] + y*256, *d1 = d0 + 256*256, *d2 = d1 + 256*256;
            for (int x = 0; x < 256; x++) {
                const uint8_t *p = row + (size_t)(ox + x*side/256)*3;
                d0[x] = INPUT_QLUT[0][p[0]];   /* plane c uses channel c's table */
                d1[x] = INPUT_QLUT[1][p[1]];
                d2[x] = INPUT_QLUT[2][p[2]];
            }
        }
        mbv2_ps_prep(g_ctx.w2rom, g_ctx.w8rom, g_ctx.head_blob, g_inp[s], s);   /* im2col */
        g_t_dec = t1 - t0; g_t_prep = now_ms() - t1;

        pthread_mutex_lock(&cm);
        col_ready[s] = 1; pthread_cond_broadcast(&cc);
        pthread_mutex_unlock(&cm);
    }
    pthread_mutex_lock(&cm); pthread_cond_broadcast(&cc); pthread_mutex_unlock(&cm);
    return NULL;
}

static void *cam_head(void *arg) {
    (void)arg;
    cam_pin(0);
    for (int k = 0; !cam_stop; k++) {
        int s = k & 1;
        pthread_mutex_lock(&cm);
        while (!bb_ready[s] && !cam_stop) pthread_cond_wait(&cc, &cm);
        pthread_mutex_unlock(&cm);
        if (cam_stop) break;

        int32_t *acc = g_head_pl ? g_accs[s] : g_acc;
        if (!g_head_pl)                      /* HEAD_PL: acc and keypoints already exist */
            mbv2_ps_head(g_ctx.head_blob, g_bb[s], acc, g_kp[s]);
        { static float dc[14][2]; mbv2_dark_refine(acc, dc); (void)dc; }
        if (g_ctx.fb) {
            struct fbdev *fb = g_ctx.fb;
            fb_blit_rgb(fb, g_rgb[s], g_ctx.vw, g_ctx.vh);
            int side2 = g_ctx.vw < g_ctx.vh ? g_ctx.vw : g_ctx.vh;
            int ox2 = (g_ctx.vw-side2)/2, oy2 = (g_ctx.vh-side2)/2;
            int px[14], py[14];
            for (int j = 0; j < 14; j++) { px[j] = ox2 + g_kp[s][j*2]*side2/64;
                                           py[j] = oy2 + g_kp[s][j*2+1]*side2/64; }
            for (int e = 0; e < N_EDGES; e++) { int a = EDGES[e][0], c = EDGES[e][1];
                for (int t = 0; t <= 32; t++) draw_disc(fb, px[a]+(px[c]-px[a])*t/32,
                                                            py[a]+(py[c]-py[a])*t/32, 1, 0,255,0); }
            for (int j = 0; j < 14; j++) draw_disc(fb, px[j], py[j], 4, 255, 32, 32);
        } else if ((k & 31) == 0) {
            printf("kpts:"); for (int j = 0; j < 14; j++) printf(" (%d,%d)", g_kp[s][j*2], g_kp[s][j*2+1]);
            printf("\n");
        }
        pthread_mutex_lock(&cm);
        bb_ready[s] = 0; pthread_cond_broadcast(&cc);
        pthread_mutex_unlock(&cm);
    }
    return NULL;
}

static int cam_pipeline(void) {
    pthread_t pw, hw;
    g_head_pl = mbv2_ps_head_in_pl();            /* decides the stage contents, see cam_head */
    pl_set_wait_yield(1);                        /* per-op PL wait sleep-polls -> core freed */
    pthread_create(&pw, NULL, cam_prep, NULL);
    pthread_create(&hw, NULL, cam_head, NULL);
    cam_pin(1);
    if (!(getenv("PIPE_RT") && atoi(getenv("PIPE_RT")) == 0)) {
        struct sched_param sp = { .sched_priority = 10 };
        if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0)
            fprintf(stderr, "[cam] SCHED_FIFO unavailable (%s) -- staying CFS\n", strerror(errno));
    }
    printf("[cam] 3-stage pipeline: PREP || PL%s || %s (CAM_SEQ=1 for the old path)\n",
           g_head_pl ? "+head+readout" : "", g_head_pl ? "DARK+draw" : "HEAD");
    double t_last = now_ms(); int frames = 0;
    for (int k = 0; !cam_stop; k++) {
        int s = k & 1;
        pthread_mutex_lock(&cm);
        while (!col_ready[s] && !cam_stop) pthread_cond_wait(&cc, &cm);      /* PREP filled s */
        while (bb_ready[s] && !cam_stop)  pthread_cond_wait(&cc, &cm);       /* HEAD drained s */
        pthread_mutex_unlock(&cm);
        if (cam_stop) break;
        double t0 = now_ms();
        mbv2_ps_plrun(s, g_head_pl ? NULL : g_bb[s]);
        /* HEAD_PL: read the accumulator out here, before the next frame's PL
         * overwrites it in the arena */
        if (g_head_pl) mbv2_ps_finish_pl(g_accs[s], g_kp[s]);
        double pl = now_ms() - t0;
        pthread_mutex_lock(&cm);
        col_ready[s] = 0; bb_ready[s] = 1; pthread_cond_broadcast(&cc);
        pthread_mutex_unlock(&cm);
        if (++frames % 15 == 0) {
            double t = now_ms();
            printf("\r%.1f fps | decode %.1f + prep %.1f | PL %.1f ms   ",
                   15000.0/(t-t_last), g_t_dec, g_t_prep, pl); fflush(stdout);
            t_last = t;
        }
    }
    cam_stop = 1;
    pthread_mutex_lock(&cm); pthread_cond_broadcast(&cc); pthread_mutex_unlock(&cm);
    pthread_join(pw, NULL); pthread_join(hw, NULL);
    return 0;
}

int main(int argc, char **argv) {
    const char *vdev = argc > 1 ? argv[1] : "/dev/video0";
    const char *fdev = argc > 2 ? argv[2] : "/dev/fb0";

    /* weights */
#ifdef FUSE_BACKEND
    /* the fused build reads the accelerator's blob and the packed weights the PL
     * head is programmed from; sizes come from the generators' headers */
    #define FUSE_BLOB_BYTES 740992                    /* pack_fuse_weights.py, 64-B aligned */
    #define FUSE_PACKED_BYTES ((size_t)W2_AL + (size_t)W2HW_BYTES + (size_t)W8_BYTES)
    static uint8_t fuse_blob[FUSE_BLOB_BYTES];
    static uint8_t fuse_packed[FUSE_PACKED_BYTES];
    /* exact sizes, see open_exact() */
    FILE *f = open_exact("data/fuse_weights.bin", FUSE_BLOB_BYTES);
    if (!f || fread(fuse_blob,1,FUSE_BLOB_BYTES,f)!=FUSE_BLOB_BYTES) {
        fprintf(stderr, "cannot read data/fuse_weights.bin (want %d bytes)\n", FUSE_BLOB_BYTES);
        if (f) fclose(f);
        return 1; }
    fclose(f);
    f = open_exact("data/model_mbv2_packed.bin", FUSE_PACKED_BYTES);
    if (!f || fread(fuse_packed,1,FUSE_PACKED_BYTES,f)!=FUSE_PACKED_BYTES) {
        fprintf(stderr, "cannot read data/model_mbv2_packed.bin (want %zu bytes)\n",
                (size_t)FUSE_PACKED_BYTES);
        if (f) fclose(f);
        return 1; }
    fclose(f);
    mbv2_fuse_init(fuse_blob, FUSE_BLOB_BYTES);
    if (!mbv2_fuse_head_in_pl()) {
        fprintf(stderr, "FUSE_HEAD_PL is not set -- this app has no software head. "
                        "Run it as FUSE_HEAD_PL=1 ./mbv2_cam_fuse\n"); return 1; }
    mbv2_fuse_head_init(fuse_packed, FUSE_PACKED_BYTES);
    static int32_t fuse_bounce[262144/4];             /* mbv2_fuse_head_readout_bytes()/4 */
    if (mbv2_fuse_head_readout_bytes() != sizeof fuse_bounce) {
        fprintf(stderr, "head readout is %zu bytes, this buffer is %zu -- refusing to run\n",
                mbv2_fuse_head_readout_bytes(), sizeof fuse_bounce); return 1; }
    fuse_counters_t fuse_ctr;
#else
    static uint8_t w2rom[W2ROM_BYTES]; static int8_t w8rom[W8_BYTES]; static int8_t head_blob[BLOB_BYTES];
    /* exact sizes: the packed file is the two ROM images back to back */
    FILE *f = open_exact("model_mbv2_packed.bin", (size_t)W2ROM_BYTES + (size_t)W8_BYTES);
    if (!f || fread(w2rom,1,W2ROM_BYTES,f)!=W2ROM_BYTES || fread(w8rom,1,W8_BYTES,f)!=W8_BYTES) {
        fprintf(stderr, "cannot read model_mbv2_packed.bin\n"); if (f) fclose(f); return 1; }
    fclose(f);
    f = open_exact("model_mbv2.bin", BLOB_BYTES);
    if (!f || fread(head_blob,1,BLOB_BYTES,f)!=BLOB_BYTES) {
        fprintf(stderr,"cannot read model_mbv2.bin\n"); if (f) fclose(f); return 1; }
    fclose(f);
#endif

    /* --selftest: run a fixture through the real PL and check it bit-exactly
     * against the golden */
    if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
        const char *fx = argc > 2 ? argv[2] : "golden/fix_0.bin";
        static int8_t s_in[3*256*256]; static int32_t s_acc_ref[14*64*64], s_kp_ref[14*2];
        static int32_t s_acc[14*64*64]; int s_kp[14*2];
        FILE *g = fopen(fx, "rb");
        if (!g) { fprintf(stderr, "cannot open %s\n", fx); return 1; }
        size_t ok = 1;
        ok &= fread(s_in, 1, sizeof s_in, g) == sizeof s_in;
        ok &= fread(s_acc_ref, 1, sizeof s_acc_ref, g) == sizeof s_acc_ref;
        ok &= fread(s_kp_ref, 1, sizeof s_kp_ref, g) == sizeof s_kp_ref;
        fclose(g);
        if (!ok) { fprintf(stderr, "%s truncated\n", fx); return 1; }
#ifdef FUSE_BACKEND
        /* the same replay through the fused backbone and the PL head; use a
         * fixture from models/mbv2_pose/fixtures */
        mbv2_fuse_frame_pl(s_in, -1, &fuse_ctr);
        mbv2_fuse_head_run(0);
        mbv2_fuse_head_readout(0, fuse_bounce);
        mbv2_fuse_head_finish(fuse_bounce, s_acc, s_kp);
#else
        mbv2_ps_infer(w2rom, w8rom, head_blob, s_in, s_acc, s_kp);
#endif
        long maxd = 0;
        for (int i = 0; i < 14*64*64; i++) { long d = (long)s_acc[i]-(long)s_acc_ref[i]; if(d<0)d=-d; if(d>maxd)maxd=d; }
        int kbad = 0; for (int i = 0; i < 28; i++) if (s_kp[i] != s_kp_ref[i]) kbad++;
        printf("[selftest %s] final max|diff|=%ld | kpts %s -> %s\n", fx, maxd,
               kbad?"MISMATCH":"14/14", (maxd==0&&!kbad)?"BOARD BIT-EXACT vs golden":"FAIL");
        return (maxd==0 && !kbad) ? 0 : 1;
    }

    { int e = input_qlut_selfcheck();                /* a stale or truncated table fails here */
      if (e) { fprintf(stderr, "input_qlut selfcheck failed (%d) -- regenerate with "
                               "tools/gen_input_qlut.py\n", e); return 1; } }
    int vw, vh, nbuf, vfd, is_yuyv; struct vbuf *bufs;
    if (v4l2_open(vdev, &vw, &vh, &bufs, &nbuf, &vfd, &is_yuyv)) return 1;
    struct fbdev fb; int have_fb = (fb_open(fdev, &fb) == 0);
    if (have_fb) printf("[fb] %dx%d %dbpp\n", fb.w, fb.h, fb.bpp);
    else printf("[fb] %s unavailable -> headless (keypoints to stdout)\n", fdev);

    tjhandle tj = tjInitDecompress();
    /* a separate handle: tj above is a decompressor */
    static tjhandle g_tj_enc = NULL;
    if (getenv("CAM_CROP_CX")) g_crop_cx = atoi(getenv("CAM_CROP_CX"));
    if (getenv("CAM_CROP_CY")) g_crop_cy = atoi(getenv("CAM_CROP_CY"));
    if (getenv("CAM_CROP_SIDE")) g_crop_side = atoi(getenv("CAM_CROP_SIDE"));
    if (getenv("CAM_CROP_SHIFT")) g_crop_shift = (float)atof(getenv("CAM_CROP_SHIFT"));
    printf("[crop] centre (%s,%s) side %s, training down-shift %.3f of the box\n",
           g_crop_cx ? "set" : "auto", g_crop_cy ? "set" : "auto",
           g_crop_side ? "set" : "auto", g_crop_shift);
    { const char *sp = getenv("CAM_STREAM");
      if (sp && atoi(sp) > 0) {
          signal(SIGPIPE, SIG_IGN);          /* a viewer that dies must not kill the board app */
          if (getenv("CAM_STREAM_Q")) g_jpeg_q = atoi(getenv("CAM_STREAM_Q"));
          if (getenv("CAM_STREAM_NOJPEG") && atoi(getenv("CAM_STREAM_NOJPEG")) == 1)
              g_send_jpeg = 0;
          if (g_send_jpeg) g_tj_enc = tjInitCompress();
          stream_listen(atoi(sp));
      } }
    static uint8_t rgb[CAM_MAX_PIX*3];
    static int8_t inp[3*256*256];
    static int32_t acc[14*64*64]; int kp[14*2];

    /* the 3-stage pipeline is the default; CAM_SEQ=1 selects the sequential path */
    if (!(getenv("CAM_SEQ") && atoi(getenv("CAM_SEQ")) == 1)) {
        g_ctx.vfd = vfd; g_ctx.bufs = bufs; g_ctx.vw = vw; g_ctx.vh = vh;
        g_ctx.is_yuyv = is_yuyv; g_ctx.tj = tj; g_ctx.fb = have_fb ? &fb : NULL;
#ifdef FUSE_BACKEND
        /* the 3-stage pipeline drives the 65-operator backbone; the fused
         * build refuses it rather than silently running sequentially. The
         * fused cross-frame pipeline is mbv2_fuse_pipe.c. */
        fprintf(stderr,
            "the 3-stage camera pipeline is not implemented for the fused backbone.\n"
            "  run sequentially:  CAM_SEQ=1 FUSE_HEAD_PL=1 ./mbv2_cam_fuse\n"
            "  the fused cross-frame pipeline lives in mbv2_fuse_pipe_strict\n");
        return 1;
#else
        g_ctx.w2rom = w2rom; g_ctx.w8rom = w8rom; g_ctx.head_blob = head_blob;
        return cam_pipeline();
#endif
    }

    double t_last = now_ms(); int frames = 0; double fps = 0;
    for (;;) {
        struct v4l2_buffer b; memset(&b,0,sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; b.memory = V4L2_MEMORY_MMAP;
        if (ioctl(vfd, VIDIOC_DQBUF, &b) < 0) { if (errno==EAGAIN) continue; perror("DQBUF"); break; }

        int jw=vw, jh=vh;
        double tf = now_ms();
        int have_frame;
        if (is_yuyv) { yuyv_to_rgb(bufs[b.index].start, rgb, vw, vh); have_frame = 1; }
        else have_frame = (tjDecompress2(tj, bufs[b.index].start, b.bytesused, rgb,
                                         vw, 0, vh, TJPF_RGB, 0) == 0);
        double t_dec = now_ms() - tf;
        if (have_frame) {
            jw = vw; jh = vh;
            /* crop box -> 256x256 (nearest) -> int8 quantise */
            int side, ox, oy;
            crop_box(jw, jh, &side, &ox, &oy);
            prep_input(rgb, jw, jh, side, ox, oy, inp);
            double t_prep = now_ms() - tf;
            /* CAM_QSTAT=1 prints the live quantised tensor's statistics (no
             * golden fixture covers the quantiser). Expected: range about
             * [-102, +127], roughly half negative, and different per channel. */
            if (getenv("CAM_QSTAT") && (frames % 30) == 0) {
                for (int c = 0; c < 3; c++) {
                    const int8_t *q = inp + c*256*256;
                    int lo = 127, hi = -128; long neg = 0, sum = 0;
                    for (int i = 0; i < 256*256; i++) {
                        int v = q[i];
                        if (v < lo) lo = v;
                        if (v > hi) hi = v;
                        if (v < 0) neg++;
                        sum += v;
                    }
                    printf("[qstat] frame %d ch%c  [%4d,%4d]  neg %5.1f%%  mean %6.1f\n",
                           frames, "RGB"[c], lo, hi, 100.0*neg/(256.0*256.0),
                           (double)sum/(256.0*256.0));
                }
                fflush(stdout);
            }
            double ti = now_ms();
#ifdef FUSE_BACKEND
            /* sequential: head_frame = -1 runs the backbone alone, then the head
             * is run, drained and finished for this frame, so the skeleton is
             * drawn on the frame it came from */
            mbv2_fuse_frame_pl(inp, -1, &fuse_ctr);
            mbv2_fuse_head_run(0);
            mbv2_fuse_head_readout(0, fuse_bounce);
            mbv2_fuse_head_finish(fuse_bounce, acc, kp);
#else
            mbv2_ps_infer(w2rom, w8rom, head_blob, inp, acc, kp);   /* PL backbone + NEON head */
#endif
            double infer_ms = now_ms() - ti;

            if (have_fb) {
                fb_blit_rgb(&fb, rgb, jw, jh);
                int side2 = jw<jh?jw:jh, ox2=(jw-side2)/2, oy2=(jh-side2)/2;
                /* keypoints on 64x64 -> crop-square (256) -> camera px */
                int px[14], py[14];
                for (int k=0;k<14;k++){ px[k]=ox2 + kp[k*2]*side2/64; py[k]=oy2 + kp[k*2+1]*side2/64; }
                for (int e=0;e<N_EDGES;e++){ int a=EDGES[e][0], c=EDGES[e][1];
                    int steps=32; for(int s=0;s<=steps;s++){ int x=px[a]+(px[c]-px[a])*s/steps, y=py[a]+(py[c]-py[a])*s/steps; draw_disc(&fb,x,y,1,0,255,0);} }
                for (int k=0;k<14;k++) draw_disc(&fb, px[k], py[k], 4, 255, 32, 32);
            } else if ((frames&31)==0) {
                printf("kpts:"); for(int k=0;k<14;k++) printf(" (%d,%d)", kp[k*2], kp[k*2+1]); printf("\n");
            }

            /* the stream is independent of the framebuffer and the dump */
            if (g_lsock >= 0) {
                static double t_prev_send = 0;
                double t_now = now_ms();
                stream_poll_accept();
                stream_poll_control();
                /* the same box the pixels came from, not a recomputed one */
                int32_t conf[14];
                for (int c = 0; c < 14; c++)
                    conf[c] = acc[(size_t)c * 64 * 64 + (size_t)kp[c*2+1] * 64 + kp[c*2]];
                stream_frame((uint32_t)frames, rgb, jw, jh, side, ox, oy,
                             kp, conf, (uint32_t)(infer_ms * 1000.0),
                             (uint32_t)(t_prev_send > 0 ? (t_now - t_prev_send) * 1000.0 : 0),
                             g_tj_enc, 0);
                t_prev_send = t_now;

                /* A still handed over by the viewer: same crop_box, prep_input
                 * and engine calls as the live frame, with its own buffers. The
                 * fused counters are shared with live frames. */
                if (g_still_jpg) {
                    static int8_t  st_in[3*256*256];
                    static int32_t st_acc[14*64*64];
                    static int     st_kp[14*2];
                    int sw = 0, sh = 0, ssub = 0, scs = 0;
                    uint8_t *srgb = NULL;
                    if (tjDecompressHeader3(tj, g_still_jpg, g_still_len,
                                            &sw, &sh, &ssub, &scs) == 0
                        && sw > 0 && sh > 0 && (long)sw * (long)sh <= 40000000L)
                        srgb = (uint8_t *)malloc((size_t)sw * (size_t)sh * 3);
                    if (srgb && tjDecompress2(tj, g_still_jpg, g_still_len, srgb,
                                              sw, 0, sh, TJPF_RGB, 0) == 0) {
                        int sside, sox, soy;
                        crop_box(sw, sh, &sside, &sox, &soy);
                        prep_input(srgb, sw, sh, sside, sox, soy, st_in);
                        double tsi = now_ms();
#ifdef FUSE_BACKEND
                        mbv2_fuse_frame_pl(st_in, -1, &fuse_ctr);
                        mbv2_fuse_head_run(0);
                        mbv2_fuse_head_readout(0, fuse_bounce);
                        mbv2_fuse_head_finish(fuse_bounce, st_acc, st_kp);
#else
                        mbv2_ps_infer(w2rom, w8rom, head_blob, st_in, st_acc, st_kp);
#endif
                        double st_ms = now_ms() - tsi;
                        int32_t sconf[14];
                        for (int c = 0; c < 14; c++)
                            sconf[c] = st_acc[(size_t)c * 64 * 64
                                              + (size_t)st_kp[c*2+1] * 64 + st_kp[c*2]];
                        printf("[stream] still %dx%d inferred in %.2f ms\n", sw, sh, st_ms);
                        fflush(stdout);
                        stream_frame((uint32_t)frames, srgb, sw, sh, sside, sox, soy,
                                     st_kp, sconf, (uint32_t)(st_ms * 1000.0), 0,
                                     g_tj_enc, FLAG_IS_STILL);
                    } else {
                        printf("[stream] still push: not a JPEG this decoder can read\n");
                        fflush(stdout);
                    }
                    free(srgb);
                    free(g_still_jpg); g_still_jpg = NULL; g_still_len = 0;
                }
            }

            /* the dump is independent of the framebuffer */
            { const char *dd = getenv("CAM_DUMP");
              if (dd) {
                  int every = getenv("CAM_DUMP_EVERY") ? atoi(getenv("CAM_DUMP_EVERY")) : 15;
                  int want  = getenv("CAM_DUMP_N")     ? atoi(getenv("CAM_DUMP_N"))     : 8;
                  /* skip the first frames so auto-exposure and auto-gain converge */
                  int skip  = getenv("CAM_DUMP_SKIP") ? atoi(getenv("CAM_DUMP_SKIP"))  : 60;
                  if (every < 1) every = 1;
                  if (g_dump_n < want && frames >= skip && frames % every == 0) {
                      dump_frame(dd, rgb, jw, jh, side, ox, oy, kp);
                      if (g_dump_n >= want) {
                          printf("[dump] %d frames written, stopping\n", g_dump_n);
                          fflush(stdout);
                          break;
                      }
                  }
              } }

            if (++frames % 15 == 0) { double t=now_ms(); fps = 15000.0/(t-t_last); t_last=t;
                printf("\r%.1f fps | decode %.1f + prep %.1f + infer %.1f ms   ",
                       fps, t_dec, t_prep - t_dec, infer_ms); fflush(stdout); }
        }
        ioctl(vfd, VIDIOC_QBUF, &b);
    }
    tjDestroy(tj);
    return 0;
}
