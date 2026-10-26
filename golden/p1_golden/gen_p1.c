/* ============================================================================
 *  gen_p1.c -- emits per-block golden vectors (inputs, outputs, packed weights,
 *  requant tables) and a JSON manifest with a SHA-256 per file.
 *
 *  p0_fused.c is #included (its main() renamed away) so the vectors come from the
 *  same tiled_block()/fused_block() code that p0_fused checks, through the g_tap hook.
 *
 *  Per block bNN:
 *    bNN_in, _e (expand/stem out), _d (depthwise out), _p (project out before the
 *    residual), _out, _res (residual source, when present)   int8 CHW
 *    bNN_wte, _wtp   packed ternary weights                   128-lane 2-bit words
 *    bNN_wdw         depthwise weights                        int8, oc-major
 *    bNN_rqe/rqd/rqp requant tables                           M0 i32 | bias i64 | sh i8
 *
 *  Checks printed at the end (exit 1 if any fails):
 *   0. every unit-test case in the coverage table is supplied by some block
 *   1. every intermediate value fits in int8
 *   2. the packed weights decode back to the blob element for element
 *   3. the block outputs equal the fused path's, not just the tiled path's
 *
 *  build:  cc -O2 -I../../sw/net -I. -I../p0_fused gen_p1.c \
 *             ../../models/mbv2_pose/model_meta.c ../../sw/net/mbv2_pose.c -o gen_p1 -lm
 *  run  :  ./gen_p1 <blob.bin> <fixture.bin> <outdir>   (run_p1.sh does both)
 * ========================================================================== */
#define main p0_main_not_used
#include "p0_fused.c"
#undef main

/* ------------------------------------------------------------------ sha256 --
 * Vendored so the manifest does not depend on an external hashing tool. */
typedef struct { uint32_t s[8]; uint64_t n; uint8_t b[64]; size_t bl; } sha_t;
static const uint32_t SK[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define RR(x,n) (((x)>>(n))|((x)<<(32-(n))))
static void sha_blk(sha_t *c, const uint8_t *p) {
    uint32_t w[64], a,b_,d,e,f,g,h,i,t1,t2, cc;
    for (i=0;i<16;i++) w[i]=(p[i*4]<<24)|(p[i*4+1]<<16)|(p[i*4+2]<<8)|p[i*4+3];
    for (i=16;i<64;i++) {
        uint32_t s0=RR(w[i-15],7)^RR(w[i-15],18)^(w[i-15]>>3);
        uint32_t s1=RR(w[i-2],17)^RR(w[i-2],19)^(w[i-2]>>10);
        w[i]=w[i-16]+s0+w[i-7]+s1;
    }
    a=c->s[0];b_=c->s[1];cc=c->s[2];d=c->s[3];e=c->s[4];f=c->s[5];g=c->s[6];h=c->s[7];
    for (i=0;i<64;i++) {
        t1=h+(RR(e,6)^RR(e,11)^RR(e,25))+((e&f)^(~e&g))+SK[i]+w[i];
        t2=(RR(a,2)^RR(a,13)^RR(a,22))+((a&b_)^(a&cc)^(b_&cc));
        h=g;g=f;f=e;e=d+t1;d=cc;cc=b_;b_=a;a=t1+t2;
    }
    c->s[0]+=a;c->s[1]+=b_;c->s[2]+=cc;c->s[3]+=d;c->s[4]+=e;c->s[5]+=f;c->s[6]+=g;c->s[7]+=h;
}
static void sha_init(sha_t *c){ static const uint32_t I[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,
    0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    memcpy(c->s,I,sizeof I); c->n=0; c->bl=0; }
static void sha_up(sha_t *c, const void *dp, size_t n) {
    const uint8_t *p=dp; c->n+=n;
    while (n) { size_t k=64-c->bl; if(k>n)k=n; memcpy(c->b+c->bl,p,k); c->bl+=k; p+=k; n-=k;
                if (c->bl==64){ sha_blk(c,c->b); c->bl=0; } }
}
static void sha_hex(sha_t *c, char *out) {
    uint64_t bits=c->n*8; uint8_t pad[72]; size_t i, pl;
    pad[0]=0x80; pl=1; while ((c->bl+pl)%64!=56) pad[pl++]=0;
    for (i=0;i<8;i++) pad[pl++]=(uint8_t)(bits>>(56-8*i));
    sha_up(c,pad,pl);
    for (i=0;i<8;i++) sprintf(out+i*8,"%08x",c->s[i]);
    out[64]=0;
}

/* ------------------------------------------------------------------ output --
 * Everything is written int8. wr_i8() counts every element outside [-128,127]
 * (g_range_fail, check 1) instead of silently truncating. */
static char  g_dir[512];
static FILE *g_man;
static int   g_range_fail = 0;

static void wr_i8(const char *name, const int16_t *v, size_t n, const char *note) {
    char path[600], hex[65]; sha_t c; sha_init(&c);
    int8_t *buf = malloc(n);
    for (size_t i = 0; i < n; i++) {
        if (v[i] < -128 || v[i] > 127) {
            fprintf(stderr, "RANGE VIOLATION in %s: element %zu = %d does not fit in int8\n",
                    name, i, v[i]);
            g_range_fail++;
        }
        buf[i] = (int8_t)v[i];
    }
    sprintf(path, "%s/%s.bin", g_dir, name);
    FILE *f = fopen(path, "wb"); fwrite(buf, 1, n, f); fclose(f);
    sha_up(&c, buf, n); sha_hex(&c, hex);
    fprintf(g_man, "   {\"file\": \"%s.bin\", \"bytes\": %zu, \"sha256\": \"%s\", \"what\": \"%s\"}",
            name, n, hex, note);
    free(buf);
}
static void wr_raw(const char *name, const void *v, size_t n, const char *note) {
    char path[600], hex[65]; sha_t c; sha_init(&c);
    sprintf(path, "%s/%s.bin", g_dir, name);
    FILE *f = fopen(path, "wb"); fwrite(v, 1, n, f); fclose(f);
    sha_up(&c, v, n); sha_hex(&c, hex);
    fprintf(g_man, "   {\"file\": \"%s.bin\", \"bytes\": %zu, \"sha256\": \"%s\", \"what\": \"%s\"}",
            name, n, hex, note);
}

/* ---- ternary weight packing ------------------------------------------------
 * One 128-lane word = 32 bytes, two bits per lane, code 00 = 0, 01 = +1, 11 = -1.
 * `pack` output channels share a word, channel j owning lanes [j*L, j*L + n_eff)
 * where L = 128 / pack; the remaining lanes are zero.
 *
 * L is 128/pack, not n_eff: lane k then needs activation x[k mod L], a bit mask for
 * power-of-two L (rtl/fuse/twn_fuse_select.v selects k&31, k&63 or k&127 when
 * OCMAX = 4) instead of a modulo by a runtime value. tools/pack_ternary.py pads the
 * same way.
 *
 * The 3x3 stem needs several passes: each pass reduces one kernel row, so its 27 taps
 * are cut into 3 groups of 9 (tap order ic*3 + kx within a group), each with its own
 * word stream. A 1x1 has one pass, n_eff = ic, tap order = ic.
 *
 * Image layout: [output-channel group][pass or segment][word]; the pass is the inner
 * index, laid out like a segment. */
/* ---- the mixed-segment rotation schedule (msg) ----------------------------
 * A stage qualifies when it is a 1x1 whose n_eff leaves a whole 32-lane group idle at
 * pack 1 (64 < n_eff <= 96) and whose output channel count C satisfies the tests below
 * (C%16 == 0, 4*ceil(C/16) <= C/4, C/4 <= 256).
 * The decision is made only here; the result goes into p1_manifest.json (msg_e,
 * msg_p) and tools/gen_desctab.py reads it from there. */
static int msg_of(const Op *o) {
    int n_eff = o->ic * o->kh * o->kw;
    if (o->kh != 1) return 0;
    if (!(n_eff > 64 && n_eff <= 96)) return 0;
    if (o->oc % 16) return 0;
    if (4 * ((o->oc + 15) / 16) > o->oc / 4) return 0;
    if (o->oc / 4 > 256) return 0;
    return 1;
}
/* where weight (jj, k) lives: *bt = beat, *lg = lane group. The twelve (jj, chunk)
 * pairs map one-to-one onto twelve of the sixteen (beat, group) slots. */
static void msg_slot(int jj, int k, int *bt, int *lg) {
    int c = k / 32;
    if (((jj - c) & 3) == 3) { *lg = 3; *bt = c; }
    else                     { *lg = c; *bt = (jj - c) & 3; }
}
static size_t pack_stage(const int8_t *blob, const Op *o, uint8_t **img_out,
                         int *n_eff_out, int *npass_out, int *pack_out, int *words_out)
{
    int is_stem = (o->kh == 3);
    int npass   = is_stem ? o->kh : 1;
    int n_eff   = is_stem ? o->ic * o->kw : o->ic;
    int msg     = msg_of(o);
    int pk      = msg ? 4 : pack_of(n_eff);
    int L       = msg ? 32 : ((pk > 1) ? 128 / pk : ((n_eff + 127) / 128) * 128);
    int words   = msg ? ((n_eff + 31) / 32) : ((L * pk + 127) / 128);
    int ngrp    = (o->oc + pk - 1) / pk;
    size_t nb   = (size_t)npass * ngrp * words * 32;
    uint8_t *img = calloc(nb, 1);
    for (int ps = 0; ps < npass; ps++)
        for (int g = 0; g < ngrp; g++)
            for (int j = 0; j < pk; j++) {
                int oc = g * pk + j;
                if (oc >= o->oc) continue;
                for (int k = 0; k < n_eff; k++) {
                    /* k -> the blob's tap index for this pass */
                    int src = is_stem ? (k / o->kw) * o->kh * o->kw + ps * o->kw + (k % o->kw)
                                      : k;
                    int w = blob[o->w_off + (size_t)oc * o->ic * o->kh * o->kw + src];
                    int code = (w == 0) ? 0 : (w > 0 ? 1 : 3);
                    size_t bit;
                    if (msg) {
                        int bt, lg; msg_slot(j, k, &bt, &lg);
                        bit = (((size_t)g * npass + ps) * words * 128
                               + (size_t)bt * 128 + (size_t)lg * 32 + (k % 32)) * 2;
                    } else {
                        bit = (((size_t)g * npass + ps) * words * 128 + (size_t)j * L + k) * 2;
                    }
                    img[bit >> 3] |= (uint8_t)(code << (bit & 7));
                }
            }
    *img_out = img; *n_eff_out = n_eff; *npass_out = npass;
    *pack_out = pk;  *words_out = words;
    return nb;
}
/* the inverse, so the packing is a checked bijection and not a hope */
static int unpack_check(const int8_t *blob, const Op *o, const uint8_t *img,
                        int n_eff, int npass, int pk, int words)
{
    int is_stem = (o->kh == 3), ngrp = (o->oc + pk - 1) / pk, bad = 0;
    int msg = msg_of(o);
    int L = msg ? 32 : ((pk > 1) ? 128 / pk : ((n_eff + 127) / 128) * 128);
    for (int ps = 0; ps < npass; ps++)
        for (int g = 0; g < ngrp; g++)
            for (int j = 0; j < pk; j++) {
                int oc = g * pk + j;
                if (oc >= o->oc) continue;
                for (int k = 0; k < n_eff; k++) {
                    size_t bit;
                    if (msg) {
                        int bt, lg; msg_slot(j, k, &bt, &lg);
                        bit = (((size_t)g * npass + ps) * words * 128
                               + (size_t)bt * 128 + (size_t)lg * 32 + (k % 32)) * 2;
                    } else {
                        bit = (((size_t)g * npass + ps) * words * 128 + (size_t)j * L + k) * 2;
                    }
                    int code = (img[bit >> 3] >> (bit & 7)) & 3;
                    int back = (code == 0) ? 0 : (code == 1 ? 1 : -1);
                    int src = is_stem ? (k / o->kw) * o->kh * o->kw + ps * o->kw + (k % o->kw)
                                      : k;
                    if (back != blob[o->w_off + (size_t)oc * o->ic * o->kh * o->kw + src]) bad++;
                }
            }
    return bad;
}

/* ---- requant tables --------------------------------------------------------
 * Emitted with the same narrowing (nar_m0/nar_bias/nar_sh) that p0_fused.c applies. */
static void wr_rq(const char *name, int rq_off, int oc, const char *note) {
    size_t n = (size_t)oc * (4 + 8 + 1);
    uint8_t *buf = malloc(n), *q = buf;
    for (int c = 0; c < oc; c++) { int32_t m = nar_m0(RQ_M0[rq_off + c]); memcpy(q, &m, 4); q += 4; }
    for (int c = 0; c < oc; c++) { int64_t b = nar_bias(RQ_BIAS[rq_off + c]); memcpy(q, &b, 8); q += 8; }
    for (int c = 0; c < oc; c++) { *q++ = (uint8_t)nar_sh(RQ_SH[rq_off + c]); }
    wr_raw(name, buf, n, note);
    free(buf);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <blob.bin> <fixture.bin> <outdir>\n", argv[0]); return 2; }
    snprintf(g_dir, sizeof g_dir, "%s", argv[3]);
    int8_t *blob = NULL;
    if (mbv2_load_weights(argv[1], &blob) != 0) { fprintf(stderr, "blob load failed\n"); return 2; }
    FILE *f = fopen(argv[2], "rb");
    if (!f) { fprintf(stderr, "fixture open failed\n"); return 2; }
    int8_t *inp = malloc(NET_IN_C * NET_IN_H * NET_IN_W);
    if (fread(inp, 1, NET_IN_C * NET_IN_H * NET_IN_W, f) !=
        (size_t)(NET_IN_C * NET_IN_H * NET_IN_W)) { fprintf(stderr, "fixture short\n"); return 2; }
    fclose(f);
    build_blocks();

    char mpath[600]; snprintf(mpath, sizeof mpath, "%s/p1_manifest.json", g_dir);
    g_man = fopen(mpath, "w");
    if (!g_man) { fprintf(stderr, "cannot write %s\n", mpath); return 2; }
    fprintf(g_man, "{\n \"_README\": \"P1 golden vectors for doc/FUSE_SPEC.html. Produced by "
        "golden/p1_golden/gen_p1.c, which includes the P0-verified kernels rather than re-implementing "
        "them. Regenerate with golden/p1_golden/run_p1.sh; the sha256 of every file is here so a "
        "regeneration is checkable, which is why the .bin files themselves are not committed.\",\n");
    fprintf(g_man, " \"fixture\": \"%s\",\n", argv[2]);
    fprintf(g_man, " \"model\": \"export_strict_int8\",\n");
    fprintf(g_man, " \"tensor_dtype\": \"int8, CHW\",\n");
    fprintf(g_man, " \"requant_table_layout\": \"oc x int32 M0, then oc x int64 bias, then oc x uint8 shift; NARROWED to the hardware widths 18/40/6\",\n");
    fprintf(g_man, " \"ternary_word\": \"128 lanes x 2 bits = 32 bytes; 00=0 01=+1 11=-1; `pack` output channels share a word, channel j owns lanes [j*n_eff, j*n_eff+n_eff)\",\n");
    fprintf(g_man, " \"blocks\": [\n");

    size_t maxel = MAXACT;
    int16_t *cur = malloc(sizeof(int16_t) * maxel);
    int16_t *nxt = malloc(sizeof(int16_t) * maxel);
    int16_t *fus = malloc(sizeof(int16_t) * maxel);
    /* residual sources: a block's residual is its own input, so keep the input around */
    for (int i = 0; i < NET_IN_C * NET_IN_H * NET_IN_W; i++) cur[i] = (int16_t)inp[i];
    int H = NET_IN_H, W = NET_IN_W;
    int wt_bad = 0, fuse_bad = 0;
    size_t total_bytes = 0;

    printf(" blk  ops         in            e             d             out         "
           " n_eff pass pack seg   weight bytes\n");
    printf(" ---  ----------  ------------  ------------  ------------  ------------"
           "  ----- ---- ---- ---   ------------\n");

    for (int bi = 0; bi < N_BLK; bi++) {
        Block *b = &BLK[bi];
        const Op *e = &OPS[b->e], *d = &OPS[b->dw], *p = &OPS[b->p];
        int He = outdim(H, e->kh, e->stride, e->pad), We = outdim(W, e->kw, e->stride, e->pad);
        int OH, OW, OH2, OW2;

        g_tap = 1; g_tapE = g_tapD = g_tapP = NULL;
        tiled_block(blob, b, cur, H, W, nxt, &OH, &OW);
        g_tap = 0;
        fused_block(blob, b, cur, H, W, fus, &OH2, &OW2);
        size_t nout = (size_t)p->oc * OH * OW;
        for (size_t i = 0; i < nout; i++) if (nxt[i] != fus[i]) fuse_bad++;

        char nm[64]; int first = 1;
        #define ENTRY(...) do { if (!first) fprintf(g_man, ",\n"); first = 0; __VA_ARGS__; } while (0)

        fprintf(g_man, "  {\"block\": %d, \"ops\": [%d,%d,%d,%d],\n", bi, b->e, b->dw, b->p, b->add);
        fprintf(g_man, "   \"in\":  {\"c\": %d, \"h\": %d, \"w\": %d},\n", e->ic, H, W);
        fprintf(g_man, "   \"mid\": {\"c\": %d, \"h\": %d, \"w\": %d},\n", e->oc, He, We);
        fprintf(g_man, "   \"out\": {\"c\": %d, \"h\": %d, \"w\": %d},\n", p->oc, OH, OW);
        fprintf(g_man, "   \"stem\": %s, \"expand_stride\": %d, \"dw_stride\": %d, \"has_residual\": %s,\n",
                e->kh == 3 ? "true" : "false", e->stride, d->stride, b->add >= 0 ? "true" : "false");
        fprintf(g_man, "   \"clamp\": {\"e\": [%d,%d], \"d\": [%d,%d], \"p\": [%d,%d]},\n",
                e->lo, e->hi, d->lo, d->hi, p->lo, p->hi);
        fprintf(g_man, "   \"relu\":  {\"e\": %d, \"d\": %d, \"p\": %d},\n", e->relu, d->relu, p->relu);
        fprintf(g_man, "   \"rq_off\":{\"e\": %d, \"d\": %d, \"p\": %d},\n", e->rq_off, d->rq_off, p->rq_off);
        if (b->add >= 0)
            fprintf(g_man, "   \"residual\": {\"mp\": %d, \"mq\": %d, \"sh\": %d, \"clamp\": [%d,%d]},\n",
                    nar_mq(OPS[b->add].mp), nar_mq(OPS[b->add].mq), OPS[b->add].sh,
                    OPS[b->add].lo, OPS[b->add].hi);

        /* --- weights, packed --- */
        uint8_t *ie, *ip; int ne, npe, pke, wde, np_, npp, pkp, wdp;
        size_t nbe = pack_stage(blob, e, &ie, &ne, &npe, &pke, &wde);
        size_t nbp = pack_stage(blob, p, &ip, &np_, &npp, &pkp, &wdp);
        wt_bad += unpack_check(blob, e, ie, ne, npe, pke, wde);
        wt_bad += unpack_check(blob, p, ip, np_, npp, pkp, wdp);
        fprintf(g_man, "   \"pack_e\": {\"n_eff\": %d, \"passes\": %d, \"pack\": %d, \"words_per_group\": %d, \"lane_use_pct\": %.1f},\n",
                ne, npe, pke, wde, 100.0 * ne * pke / 128.0);
        fprintf(g_man, "   \"pack_p\": {\"n_eff\": %d, \"passes\": %d, \"pack\": %d, \"words_per_group\": %d, \"lane_use_pct\": %.1f},\n",
                np_, npp, pkp, wdp, np_ > 128 ? 100.0 * np_ / (((np_ + 127) / 128) * 128.0)
                                              : 100.0 * np_ * pkp / 128.0);
        /* n_seg is the word count per group, not ceil(n_eff/128); they differ for an msg
         * stage, whose words are 32-channel chunks of one activation word. */
        fprintf(g_man, "   \"n_seg_e\": %d, \"n_seg_p\": %d,\n",
                msg_of(e) ? wde : (ne + 127) / 128,
                msg_of(p) ? wdp : (np_ + 127) / 128);
        fprintf(g_man, "   \"msg_e\": %d, \"msg_p\": %d,\n", msg_of(e), msg_of(p));
        fprintf(g_man, "   \"files\": [\n");

        sprintf(nm, "b%02d_in",  bi); ENTRY(wr_i8(nm, cur, (size_t)e->ic * H * W, "block input"));
        sprintf(nm, "b%02d_e",   bi); ENTRY(wr_i8(nm, g_tapE, (size_t)e->oc * He * We,
                                        e->kh == 3 ? "stem output" : "expand output"));
        sprintf(nm, "b%02d_d",   bi); ENTRY(wr_i8(nm, g_tapD, (size_t)d->oc * OH * OW, "depthwise output"));
        if (g_tapP) { sprintf(nm, "b%02d_p", bi);
            ENTRY(wr_i8(nm, g_tapP, nout, "project output, BEFORE the residual add")); }
        sprintf(nm, "b%02d_out", bi); ENTRY(wr_i8(nm, nxt, nout,
                                        b->add >= 0 ? "block output, after the residual"
                                                    : "block output (= project output, no residual)"));
        if (b->add >= 0) { sprintf(nm, "b%02d_res", bi);
            ENTRY(wr_i8(nm, cur, nout, "residual source (this block's own input)")); }
        sprintf(nm, "b%02d_wte", bi); ENTRY(wr_raw(nm, ie, nbe, "expand/stem ternary weights, packed"));
        sprintf(nm, "b%02d_wtp", bi); ENTRY(wr_raw(nm, ip, nbp, "project ternary weights, packed"));
        sprintf(nm, "b%02d_wdw", bi);
        ENTRY(wr_raw(nm, blob + d->w_off, (size_t)d->oc * d->kh * d->kw, "depthwise int8 weights"));
        sprintf(nm, "b%02d_rqe", bi); ENTRY(wr_rq(nm, e->rq_off, e->oc, "requant table, expand/stem"));
        sprintf(nm, "b%02d_rqd", bi); ENTRY(wr_rq(nm, d->rq_off, d->oc, "requant table, depthwise"));
        sprintf(nm, "b%02d_rqp", bi); ENTRY(wr_rq(nm, p->rq_off, p->oc, "requant table, project"));
        fprintf(g_man, "\n   ]}%s\n", bi == N_BLK - 1 ? "" : ",");

        total_bytes += (size_t)e->ic*H*W + (size_t)e->oc*He*We + (size_t)d->oc*OH*OW
                     + nout * (b->add >= 0 ? 3 : 1) + nbe + nbp;
        printf(" %3d  %2d-%2d-%2d%-3s %4dx%3dx%-4d %4dx%3dx%-4d %4dx%3dx%-4d %4dx%3dx%-4d "
               " %5d %4d %4d %3d   %8zu\n",
               bi, b->e, b->dw, b->p, b->add >= 0 ? "+a" : "",
               e->ic, H, W, e->oc, He, We, d->oc, OH, OW, p->oc, OH, OW,
               ne, npe, pke, (ne + 127) / 128, nbe + nbp);

        free(ie); free(ip);
        free(g_tapE); free(g_tapD); if (g_tapP) free(g_tapP);
        memcpy(cur, nxt, sizeof(int16_t) * nout);
        H = OH; W = OW;
    }
    fprintf(g_man, " ]\n}\n");
    fclose(g_man);

    /* ---- coverage of the unit-test cases ---------------------------------------
     * Enumerates the cases and names the block that supplies each; an UNCOVERED line
     * means a testbench would have to invent stimulus. */
    struct { const char *what; char who[160]; } cov[] = {
        /* The list is what the design can issue: the packing-factor-8 case applies
         * only if PACK_MAX >= 8. */
        {"ternary array: packing factor 8 (only if PACK_MAX >= 8)", ""},
        {"ternary array: packing factor 4",              ""},
        {"ternary array: packing factor 2",              ""},
        {"ternary array: packing factor 1",              ""},
        {"ternary array: n_eff > 128 (cross-segment accumulation)", ""},
        {"ternary array: 3x3 stem mode (multi-pass)",    ""},
        {"ternary array: the two convs use DIFFERENT weights and tables", ""},
        {"depthwise: stride 1",                          ""},
        {"depthwise: stride 2",                          ""},
        {"depthwise: widest row (largest Cmid x W)",     ""},
        {"residual: block with a residual add",          ""},
        {"residual: block without one",                  ""},
        {"clamp: unsigned 0..127 (with ReLU)",           ""},
        {"clamp: signed -127..127 (linear bottleneck)",  ""},
    };
    int widest = -1; long widest_v = -1;
    {
        int hh = NET_IN_H, ww = NET_IN_W;
        for (int bi = 0; bi < N_BLK; bi++) {
            Block *b = &BLK[bi];
            const Op *e = &OPS[b->e], *d = &OPS[b->dw], *p = &OPS[b->p];
            int He = outdim(hh, e->kh, e->stride, e->pad), We = outdim(ww, e->kw, e->stride, e->pad);
            int Hd = outdim(He, d->kh, d->stride, d->pad), Wd = outdim(We, d->kw, d->stride, d->pad);
            int ne2 = (e->kh == 3) ? e->ic * e->kw : e->ic;
            int pke2 = pack_of(ne2), pkp2 = pack_of(p->ic);
            char t[8];
            #define MARK(i) do { sprintf(t, "%s%d", cov[i].who[0] ? " " : "", bi); \
                if (strlen(cov[i].who) < 150) strcat(cov[i].who, t); } while (0)
            if (pke2 == 8 || pkp2 == 8) MARK(0);
            if (pke2 == 4 || pkp2 == 4) MARK(1);
            if (pke2 == 2 || pkp2 == 2) MARK(2);
            if (pke2 == 1 || pkp2 == 1) MARK(3);
            if (ne2 > 128 || p->ic > 128) MARK(4);
            if (e->kh == 3)              MARK(5);
            if (e->rq_off != p->rq_off)  MARK(6);
            if (d->stride == 1)          MARK(7);
            if (d->stride == 2)          MARK(8);
            if ((long)d->oc * Wd > widest_v) { widest_v = (long)d->oc * Wd; widest = bi; }
            if (b->add >= 0)             MARK(10); else MARK(11);
            if (e->lo == 0)              MARK(12);
            if (p->lo < 0)               MARK(13);
            hh = Hd; ww = Wd;
        }
        sprintf(cov[9].who, "%d (%ld channel-pixels per output row)", widest, widest_v);
    }
    printf("\n--- coverage of §10.3's unit-test matrix (which block supplies each case) ---\n");
    printf("  (PACK_MAX = %d)\n", PACK_MAX);
    int uncovered = 0;
    for (size_t i = 0; i < sizeof cov / sizeof cov[0]; i++) {
        /* A packing factor above PACK_MAX is not part of the design, so an empty row
         * there is not a hole. */
        int applies = 1;
        if (i == 0 && PACK_MAX < 8) applies = 0;
        if (i == 2 && PACK_MAX < 2) applies = 0;
        if (applies && !cov[i].who[0]) uncovered++;
        printf("  %-56s %s\n", cov[i].what,
               cov[i].who[0] ? cov[i].who
                             : (applies ? "*** UNCOVERED ***"
                                        : "not in the design at this PACK_MAX"));
    }

    printf("\ntotal vector bytes: %.2f MB\n", total_bytes / 1048576.0);
    printf("check 0  every §10.3 unit-test case has a block     : %s (%d uncovered)\n",
           uncovered ? "FAIL" : "PASS", uncovered);
    printf("check 1  every intermediate fits in int8            : %s (%d violations)\n",
           g_range_fail ? "FAIL" : "PASS", g_range_fail);
    printf("check 2  packed weights decode back to the blob     : %s (%d mismatches)\n",
           wt_bad ? "FAIL" : "PASS", wt_bad);
    printf("check 3  block outputs equal the FUSED path's       : %s (%d elements)\n",
           fuse_bad ? "FAIL" : "PASS", fuse_bad);
    int bad = g_range_fail || wt_bad || fuse_bad || uncovered;
    printf("\nP1 VECTORS %s -- manifest at %s\n", bad ? "INVALID" : "written", mpath);
    return bad ? 1 : 0;
}
