/* Generated network tables (op program, requant parameters). Do not edit by hand. */
#ifndef MODEL_META_H
#define MODEL_META_H
#include <stdint.h>

typedef struct { int type,in_buf,in2_buf,out_buf,ic,oc,kh,kw,stride,pad;
  int w_off,rq_off,relu,lo,hi,mp,mq,sh; } Op;

#define N_OPS 65
#define BLOB_BYTES 1977216
#define MAXACT 1572864
#define NET_IN_C 3
#define NET_IN_H 256
#define NET_IN_W 256
#define NET_OUT_C 14
#define NET_OUT_H 64
#define NET_OUT_W 64

extern const Op OPS[N_OPS];
extern const int32_t RQ_M0[];
extern const int64_t RQ_BIAS[];
extern const int8_t RQ_SH[];
extern const double INPUT_SCALE, FINAL_OUT_MULT;
extern const double FINAL_BIAS[14];
#endif
