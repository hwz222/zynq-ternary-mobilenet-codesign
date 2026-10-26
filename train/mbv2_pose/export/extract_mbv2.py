"""Extract mbv2_dc32_pwstem into an integer-only inference plan + C golden artifacts.

Same folding math as twn-pose-c/tools/extract_params.py (proven bit-exact twice):
    a_out = clamp( rshift( M0_c * acc + bias_c , shift_c ), lo, hi )
    A_c = gamma_c/sqrt(var_c+eps) * (s_w * s_in) / s_out
    B_c = (beta_c - gamma_c*mu_c/sqrt(var_c+eps)) / s_out
    M0_c = round(A_c * 2^shift_c), bias_c = round(B_c * 2^shift_c)   (MULT_BITS=16 -> 1 DSP48)

New vs the ResNet ports:
  * depthwise conv (INT8 weights, groups=C)
  * INT16 SEAMS: MobileNetV2's linear bottlenecks are deliberately un-activated, so the
    trained graph has NO quantizer on 7 non-residual block outputs / 10 residual sums.
    The integer pipeline represents those tensors as int16 with a per-tensor scale
    calibrated from val-set maxabs (headroom x1.05). Residual add:
        seam_out = clamp16( rshift( Mp*proj_int8 + Mq*seam_in_int16, sh ) )

Emits:
  build/params.npz               (for debugging)
  ../data/model_mbv2.bin         weight blob (ternary as int8 {-1,0,+1}; int8 raw)
  ../src/model_meta.c/.h         op program + requant tables (auto-generated C)
  ../golden/fix_<i>.bin          fixtures: input int8 + final acc int32 + kpts + per-op checksums

Run from train/mbv2_pose/ via export/export_board_model.py (or directly: python export/extract_mbv2.py --strict-int8 --ckpt ...)
"""
import argparse
import os
import sys

import numpy as np
import torch

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # train/mbv2_pose/
sys.path.insert(0, REPO)
from src.build_model import region_keys, build_quant                 # noqa: E402
from src.dataset import MPIIDataset                                  # noqa: E402
from src.config import INPUT_SIZE, HEATMAP_SIZE                      # noqa: E402
# INPUT_SIZE/HEATMAP_SIZE follow env TWN_INPUT_SIZE (default 256). Set TWN_INPUT_SIZE=192
# and --ckpt .../mbv2_dc32_192/best.pth to extract the 192 deployment. The op program itself
# is resolution-independent (no spatial dims stored); only NET_IN/OUT + maxact + calibration change.
IN_W, IN_H = int(INPUT_SIZE[0]), int(INPUT_SIZE[1])
OUT_W, OUT_H = int(HEATMAP_SIZE[0]), int(HEATMAP_SIZE[1])

# Default output root when TWN_OUT_SRC / TWN_OUT_DATA / TWN_OUT_GOLD are not set. Under runs/ so a bare
# call never writes into a tracked directory; export/export_board_model.py always sets all three.
HERE = os.path.join(REPO, "runs", "export")
CKPT = os.environ.get("TWN_CKPT", os.path.join(REPO, "checkpoints", "probe_tern_dc32", "best.pth"))
EPS = 1e-5
MULT_BITS = 16
CAL_N = 32            # images for seam-scale calibration
SEAM_MARGIN = 1.05

OP_CONV, OP_DW, OP_DECONV, OP_ADD, OP_FINAL = 0, 1, 2, 3, 4
I8, U8, I16 = (-128, 127), (0, 255), (-32768, 32767)
SEAM_DEN = 32767.0     # seam-scale denominator (= "the seams are 16-bit" decision)
IN_LO = -128           # input-image clamp floor


# ----------------------------- model + brevitas readers -----------------------------
HEAD_PROJ = int(os.environ.get("TWN_HEAD_PROJ", "0"))   # 0 = the deployed tree, unchanged


def load_model(ckpt=CKPT):
    tk, pk = region_keys("mbv2", 1.0, None, 32, "pw_stem")
    if HEAD_PROJ:
        # The projection variant: one ternary 1x1 between the backbone and the head. Built
        # here rather than through build_quant because build_quant has no way to pass the
        # kwarg, and the default path must stay byte-identical -- the regression that proves
        # it is in the projection experiment's report.
        from src.mbv2_model import PoseMBV2Quant
        from src.quant_model import QuantConfig
        m = PoseMBV2Quant(QuantConfig(twn_keys=set(tk) | {"head_proj"}, twn_pc_keys=pk),
                          width_mult=1.0, deconv_ch=32, head_proj_ch=HEAD_PROJ)
    else:
        m = build_quant("mbv2", 1.0, None, 32, tk, pk)
    m.eval()
    with torch.no_grad():
        m(torch.zeros(1, 3, IN_H, IN_W))          # lazy-init brevitas quant modules at target res
    m.load_state_dict(torch.load(ckpt, map_location="cpu")["model"])
    m.eval()
    return m


def w_int_scale(conv):
    qw = conv.quant_weight()
    scale = float(qw.scale.reshape(-1)[0])
    ints = torch.round(qw.value / qw.scale).to(torch.int32).numpy()
    return ints, scale


def act_scale(mod):
    old = mod.return_quant_tensor
    mod.return_quant_tensor = True
    with torch.no_grad():
        qt = mod(torch.randn(1, 4, 4, 4))
    mod.return_quant_tensor = old
    return float(qt.scale.reshape(-1)[0])


def apply_strict_int8(m):
    """Strict-INT8 scheme -- adder-tree terms all in [-127,127].

    DEFAULT OFF; main() calls this only under --strict-int8. Three parameter groups change
    and nothing else -- weights, architecture and the input quantizer are untouched, so both
    weight blobs (model_mbv2.bin, model_mbv2_packed.bin) stay byte-identical to the deployed
    ones and the model runs on the current 16-bit bitstream unchanged:
      seams (17)     : scale maxabs*1.05/127 (was /32767), clamp +/-127 (was +/-32767)
      ReLU acts (37) : scale x(255/127), clamp 0..127 -- same real range, half resolution
      int8 class (10) + input image : clamp -127..127 (-128 banned: its negation overflows)
    add_quant / input_quant scales are excluded from the x(255/127), mirroring the
    gate-0-verified reference implementation (tools/int8tree_ab.py build_plan, scheme "D").
    Accuracy pre-measured on full val: 84.217 -> 84.177 (-0.04, McNemar not significant).
    """
    global I8, U8, I16, SEAM_DEN, IN_LO, act_scale
    I8, U8, I16 = (-127, 127), (0, 127), (-127, 127)
    SEAM_DEN, IN_LO = 127.0, -127
    keep = {id(mod) for name, mod in m.named_modules()
            if name.endswith("add_quant") or name == "input_quant"}
    base = act_scale

    def scaled_act(mod):
        s = base(mod)
        return s if id(mod) in keep else s * (255.0 / 127.0)
    act_scale = scaled_act


def bn_params(bn):
    return (bn.weight.detach().numpy().astype(np.float64),
            bn.bias.detach().numpy().astype(np.float64),
            bn.running_mean.detach().numpy().astype(np.float64),
            bn.running_var.detach().numpy().astype(np.float64))


def quantize_multiplier(A):
    """A -> (M0, shift) with A ~ M0 * 2^-shift and |M0| < 2^MULT_BITS whenever shift > 0
    (17 bits signed; see the carry note below).

    The cap belongs on M0's WIDTH (single-DSP 17-bit operand), not on the shift value:
    a barrel shift is free in hardware and rshift_round handles s<=62 in int64. The old
    ResNet port clamped s<=31, which never fired there (activation scales ~1e-2) but
    saturates here -- seam scales ~1e-4 push A_c down to ~1e-6, and an s=31 clamp would
    leave M0 with only ~11 significant bits (32x precision loss). s<=47 keeps the full
    MULT_BITS precision for every A_c that occurs in this network.

    ROUNDING CAN CARRY INTO BIT 16 (review item C2, fixed 2026-10-05). s is chosen so
    that |a|*2^s lies in [2^15, 2^16), but when it lies in [65535.5, 2^16) the round()
    gives exactly 65,536 = 2^16, which needs 18 bits signed, not the 17 the docstring
    promised. That value is renormalised to 32,768 with s-1 -- the SAME multiplier
    (65536 * 2^-s == 32768 * 2^-(s-1)) -- so |M0| <= 65,535 whenever s > 0. Every
    other input produces exactly the output it did before. (s == 0 means |a| >= 2^16,
    already outside the 17-bit range; that case is left as it was.) Neither model hits
    it -- largest |M0| 65,534 (checkpoint mbv2_dc32_pwstem_ftI30) and 65,529
    (an earlier deployed pose model) -- and re-running --strict-int8 for both on 2026-10-05
    reproduced export_strict_int8/src/model_meta.c byte for byte.
    """
    A = np.asarray(A, dtype=np.float64)
    M0 = np.zeros(A.shape, dtype=np.int64)
    shift = np.zeros(A.shape, dtype=np.int64)
    for c, a in enumerate(A):
        if a == 0:
            continue
        s = int(np.floor(MULT_BITS - np.log2(abs(a))))
        s = max(0, min(s, 47))
        mm = min(int(round(abs(a) * 2.0 ** s)), 2 ** 31 - 1)
        if mm == 2 ** MULT_BITS and s > 0:      # C2: carry out of the rounding
            mm, s = 2 ** (MULT_BITS - 1), s - 1
        M0[c] = mm if a > 0 else -mm
        shift[c] = s
    return M0, shift


def fold_requant(s_w, s_in, bn, s_out, relu, lohi):
    g, b, mu, var = bn
    inv = g / np.sqrt(var + EPS)
    A = inv * (s_w * s_in) / s_out
    B = (b - inv * mu) / s_out
    M0, shift = quantize_multiplier(A)
    bias = np.round(B * 2.0 ** shift).astype(np.int64)
    return dict(M0=M0, shift=shift, bias=bias, lo=lohi[0], hi=lohi[1], relu=int(relu))


def add_combine(s_p, s_x, s_out, lohi):
    P, Q = s_p / s_out, s_x / s_out
    s = int(np.floor(MULT_BITS - np.log2(max(P, Q))))
    s = max(0, min(s, 47))
    mp = min(int(round(P * 2 ** s)), 2 ** 31 - 1)
    mq = min(int(round(Q * 2 ** s)), 2 ** 31 - 1)
    # The same carry as quantize_multiplier's (C2, 2026-10-05): the larger of the two
    # can round to exactly 2^16. mp and mq share one shift, so both are re-rounded at
    # s-1 rather than one of them halved. Unchanged for every other input.
    if max(mp, mq) == 2 ** MULT_BITS and s > 0:
        s -= 1
        mp = min(int(round(P * 2 ** s)), 2 ** 31 - 1)
        mq = min(int(round(Q * 2 ** s)), 2 ** 31 - 1)
    return dict(mp=mp, mq=mq, sh=s, lo=lohi[0], hi=lohi[1])


# ----------------------------- seam calibration -----------------------------
def calibrate_seams(m, ds, n):
    """maxabs of every features[i] block OUTPUT (i>=1) over n val images."""
    maxabs = {}
    hooks = []

    def mk(i):
        def h(_m, _in, out):
            v = float(out.abs().max())
            maxabs[i] = max(maxabs.get(i, 0.0), v)
        return h

    for i in range(1, len(m.features)):
        hooks.append(m.features[i].register_forward_hook(mk(i)))
    with torch.no_grad():
        for k in range(n):
            inp, _, _, _ = ds[(k * 211) % len(ds)]
            m(inp.unsqueeze(0))
    for h in hooks:
        h.remove()
    return {i: maxabs[i] * SEAM_MARGIN / SEAM_DEN for i in maxabs}


# ----------------------------- extraction: walk -> op program -----------------------------
def extract(m, seam_scales):
    md = dict(m.named_modules())
    ops, wparts, arrays = [], [], dict(M0=[], bias=[], sh=[])
    woff = [0]

    def push_w(w):
        w8 = w.astype(np.int8)
        off = woff[0]
        wparts.append(w8.reshape(-1))
        woff[0] += w8.size
        return off

    def push_rq(rq):
        off = len(arrays["M0"])
        arrays["M0"].extend(int(v) for v in rq["M0"])
        arrays["bias"].extend(int(v) for v in rq["bias"])
        arrays["sh"].extend(int(v) for v in rq["shift"])
        return off

    def conv_op(typ, conv, rq, in_buf, out_buf):
        w, _ = w_int_scale(conv)
        ops.append(dict(
            type=typ, in_buf=in_buf, in2_buf=-1, out_buf=out_buf,
            ic=conv.in_channels, oc=conv.out_channels,
            kh=conv.kernel_size[0], kw=conv.kernel_size[1],
            stride=conv.stride[0], pad=conv.padding[0],
            w_off=push_w(w), rq_off=push_rq(rq),
            relu=rq["relu"], lo=rq["lo"], hi=rq["hi"], mp=0, mq=0, sh=0))

    s_in0 = act_scale(md["input_quant"])

    # stem: features.0 = [tern conv 3x3 s2, BN, QuantReLU]
    _, sw = w_int_scale(md["features.0.0"])
    s0 = act_scale(md["features.0.2"])
    conv_op(OP_CONV, md["features.0.0"],
            fold_requant(sw, s_in0, bn_params(md["features.0.1"]), s0, True, U8),
            in_buf=0, out_buf=1)
    cur_scale, cur_buf = s0, 1

    # inverted residual blocks
    for i in range(1, len(m.features)):
        blk = m.features[i]
        conv_seq = blk.conv
        t6 = len(conv_seq) == 4
        out_buf = 1 - cur_buf if cur_buf in (0, 1) else 0
        s_seam_out = seam_scales[i]

        if t6:
            exp, dwc, proj, pbn = conv_seq[0], conv_seq[1], conv_seq[2], conv_seq[3]
        else:
            dwc, proj, pbn = conv_seq[0], conv_seq[1], conv_seq[2]

        s_in_blk = cur_scale
        if t6:
            _, sw_e = w_int_scale(exp[0])
            s_e = act_scale(exp[2])
            conv_op(OP_CONV, exp[0],
                    fold_requant(sw_e, s_in_blk, bn_params(exp[1]), s_e, True, U8),
                    in_buf=cur_buf, out_buf=2)
            dw_in_buf, s_dw_in = 2, s_e
        else:
            dw_in_buf, s_dw_in = cur_buf, s_in_blk

        _, sw_d = w_int_scale(dwc[0])
        s_d = act_scale(dwc[2])
        conv_op(OP_DW, dwc[0],
                fold_requant(sw_d, s_dw_in, bn_params(dwc[1]), s_d, True, U8),
                in_buf=dw_in_buf, out_buf=3)

        _, sw_p = w_int_scale(proj)
        if blk.use_res:
            s_add = act_scale(md[f"features.{i}.add_quant"])
            conv_op(OP_CONV, proj,
                    fold_requant(sw_p, s_d, bn_params(pbn), s_add, False, I8),
                    in_buf=3, out_buf=2)
            ac = add_combine(s_add, s_in_blk, s_seam_out, I16)
            ops.append(dict(type=OP_ADD, in_buf=2, in2_buf=cur_buf, out_buf=out_buf,
                            ic=proj.out_channels, oc=proj.out_channels, kh=0, kw=0,
                            stride=1, pad=0, w_off=0, rq_off=0, relu=0,
                            lo=ac["lo"], hi=ac["hi"], mp=ac["mp"], mq=ac["mq"], sh=ac["sh"]))
        else:
            conv_op(OP_CONV, proj,
                    fold_requant(sw_p, s_d, bn_params(pbn), s_seam_out, False, I16),
                    in_buf=3, out_buf=out_buf)
        cur_scale, cur_buf = s_seam_out, out_buf

    # optional ternary 1x1 projection between the backbone and the head. Its whole purpose is
    # hardware: the first deconv's input channel count decides the head engine's mode, and at
    # 320 it forces the expensive weight-slice path. It also hands the deconv a uint8 tensor
    # instead of the int16 seam.
    if HEAD_PROJ:
        pc, pb, pr = md["head_proj.0"], md["head_proj.1"], md["head_proj.2"]
        _, sw_hp = w_int_scale(pc)
        s_hp = act_scale(pr)
        out_buf = 1 - cur_buf
        conv_op(OP_CONV, pc,
                fold_requant(sw_hp, cur_scale, bn_params(pb), s_hp, True, U8),
                in_buf=cur_buf, out_buf=out_buf)
        cur_scale, cur_buf = s_hp, out_buf

    # deconv head x3: [QuantConvTranspose INT8, BN, QuantReLU]
    for di in range(3):
        c, b, r = md[f"deconv_layers.{3*di}"], md[f"deconv_layers.{3*di+1}"], md[f"deconv_layers.{3*di+2}"]
        _, sw_d = w_int_scale(c)
        s_d = act_scale(r)
        out_buf = 1 - cur_buf
        conv_op(OP_DECONV, c,
                fold_requant(sw_d, cur_scale, bn_params(b), s_d, True, U8),
                in_buf=cur_buf, out_buf=out_buf)
        cur_scale, cur_buf = s_d, out_buf

    # final 1x1 INT8 (+bias)
    fl = md["final_layer"]
    qw = fl.quant_weight()
    sw_f = float(qw.scale.reshape(-1)[0])
    wf = torch.round(qw.value / qw.scale).to(torch.int32).numpy()
    ops.append(dict(type=OP_FINAL, in_buf=cur_buf, in2_buf=-1, out_buf=-1,
                    ic=fl.in_channels, oc=fl.out_channels, kh=1, kw=1, stride=1, pad=0,
                    w_off=push_w(wf), rq_off=0, relu=0, lo=0, hi=0, mp=0, mq=0, sh=0))
    consts = dict(input_scale=s_in0, final_out_mult=sw_f * cur_scale,
                  final_bias=fl.bias.detach().numpy().astype(np.float64))
    return ops, np.concatenate(wparts), arrays, consts


# ----------------------------- integer numpy forward -----------------------------
def conv2d_int(x, W, stride, pad):
    IC, H, Wd = x.shape
    OC, _, KH, KW = W.shape
    xp = np.zeros((IC, H + 2 * pad, Wd + 2 * pad), dtype=np.int64)
    xp[:, pad:pad + H, pad:pad + Wd] = x
    OH = (H + 2 * pad - KH) // stride + 1
    OW = (Wd + 2 * pad - KW) // stride + 1
    acc = np.zeros((OC, OH, OW), dtype=np.int64)
    for ky in range(KH):
        for kx in range(KW):
            sl = xp[:, ky:ky + OH * stride:stride, kx:kx + OW * stride:stride]
            acc += np.tensordot(W[:, :, ky, kx].astype(np.int64), sl, axes=([1], [0]))
    return acc


def dwconv2d_int(x, W, stride, pad):
    """x[C,H,W], W[C,1,KH,KW] -> acc[C,OH,OW]."""
    C, H, Wd = x.shape
    _, _, KH, KW = W.shape
    xp = np.zeros((C, H + 2 * pad, Wd + 2 * pad), dtype=np.int64)
    xp[:, pad:pad + H, pad:pad + Wd] = x
    OH = (H + 2 * pad - KH) // stride + 1
    OW = (Wd + 2 * pad - KW) // stride + 1
    acc = np.zeros((C, OH, OW), dtype=np.int64)
    for ky in range(KH):
        for kx in range(KW):
            sl = xp[:, ky:ky + OH * stride:stride, kx:kx + OW * stride:stride]
            acc += W[:, 0, ky, kx].astype(np.int64)[:, None, None] * sl
    return acc


def conv_transpose2d_int(x, W, stride, pad):
    IC, H, Wd = x.shape
    _, OC, KH, KW = W.shape
    OH = (H - 1) * stride - 2 * pad + KH
    OW = (Wd - 1) * stride - 2 * pad + KW
    acc = np.zeros((OC, OH, OW), dtype=np.int64)
    for ky in range(KH):
        iy = np.arange(H); oy = iy * stride - pad + ky
        my = (oy >= 0) & (oy < OH); iy, oy = iy[my], oy[my]
        if iy.size == 0:
            continue
        for kx in range(KW):
            ix = np.arange(Wd); ox = ix * stride - pad + kx
            mx = (ox >= 0) & (ox < OW); ix, ox = ix[mx], ox[mx]
            if ix.size == 0:
                continue
            sl = x[:, iy[:, None], ix[None, :]]
            acc[:, oy[:, None], ox[None, :]] += np.tensordot(
                W[:, :, ky, kx].astype(np.int64), sl, axes=([0], [0]))
    return acc


def rshift_round(t, s):
    t = np.asarray(t, dtype=np.int64)
    half = np.where(s > 0, np.int64(1) << np.maximum(np.asarray(s) - 1, 0), 0)
    return (t + half) >> s


def requant_arrays(acc, M0, bias, sh, relu, lo, hi):
    t = acc * M0[:, None, None] + bias[:, None, None]
    r = rshift_round(t, sh[:, None, None])
    if relu:
        r = np.maximum(r, 0)
    return np.clip(r, lo, hi)


def forward_int(ops, blob, arrays, consts, x_int8, checksums=None, sizes=None):
    if sizes is not None:
        sizes.append(int(x_int8.size))
    M0a = np.asarray(arrays["M0"], dtype=np.int64)
    Ba = np.asarray(arrays["bias"], dtype=np.int64)
    Sa = np.asarray(arrays["sh"], dtype=np.int64)
    bufs = {0: x_int8.astype(np.int64)}
    final_acc = None
    for oi, op in enumerate(ops):
        x = bufs[op["in_buf"]]
        if op["type"] == OP_CONV:
            W = blob[op["w_off"]:op["w_off"] + op["oc"] * op["ic"] * op["kh"] * op["kw"]] \
                .reshape(op["oc"], op["ic"], op["kh"], op["kw"]).astype(np.int64)
            acc = conv2d_int(x, W, op["stride"], op["pad"])
        elif op["type"] == OP_DW:
            W = blob[op["w_off"]:op["w_off"] + op["oc"] * op["kh"] * op["kw"]] \
                .reshape(op["oc"], 1, op["kh"], op["kw"]).astype(np.int64)
            acc = dwconv2d_int(x, W, op["stride"], op["pad"])
        elif op["type"] == OP_DECONV:
            W = blob[op["w_off"]:op["w_off"] + op["ic"] * op["oc"] * op["kh"] * op["kw"]] \
                .reshape(op["ic"], op["oc"], op["kh"], op["kw"]).astype(np.int64)
            acc = conv_transpose2d_int(x, W, op["stride"], op["pad"])
        elif op["type"] == OP_FINAL:
            W = blob[op["w_off"]:op["w_off"] + op["oc"] * op["ic"]] \
                .reshape(op["oc"], op["ic"], 1, 1).astype(np.int64)
            final_acc = conv2d_int(x, W, 1, 0)
            if checksums is not None:
                checksums.append(int(final_acc.sum()))
            break
        elif op["type"] == OP_ADD:
            p, xi = bufs[op["in_buf"]], bufs[op["in2_buf"]]
            t = p * op["mp"] + xi * op["mq"]
            out = np.clip(rshift_round(t, op["sh"]), op["lo"], op["hi"])
            bufs[op["out_buf"]] = out
            if checksums is not None:
                checksums.append(int(out.sum()))
            continue
        o = op["rq_off"]
        out = requant_arrays(acc, M0a[o:o + op["oc"]], Ba[o:o + op["oc"]], Sa[o:o + op["oc"]],
                             op["relu"], op["lo"], op["hi"])
        bufs[op["out_buf"]] = out
        if sizes is not None:
            sizes.append(int(out.size))
        if checksums is not None:
            checksums.append(int(out.sum()))
    return final_acc


def argmax_coords(hm):
    K = hm.shape[0]
    idx = hm.reshape(K, -1).argmax(1)
    return np.stack([idx % hm.shape[2], idx // hm.shape[2]], 1)


# ----------------------------- C emission -----------------------------
def emit_c(ops, blob, arrays, consts, maxact, out_src, out_data):
    os.makedirs(out_src, exist_ok=True)
    os.makedirs(out_data, exist_ok=True)
    blob.astype(np.int8).tofile(os.path.join(out_data, "model_mbv2.bin"))

    n = len(ops)
    with open(os.path.join(out_src, "model_meta.h"), "w", newline="\n") as f:
        f.write("/* Generated network tables (op program, requant parameters). Do not edit by hand. */\n")
        f.write("#ifndef MODEL_META_H\n#define MODEL_META_H\n#include <stdint.h>\n\n")
        f.write("typedef struct { int type,in_buf,in2_buf,out_buf,ic,oc,kh,kw,stride,pad;\n")
        f.write("  int w_off,rq_off,relu,lo,hi,mp,mq,sh; } Op;\n\n")
        f.write(f"#define N_OPS {n}\n")
        f.write(f"#define BLOB_BYTES {blob.size}\n")
        f.write(f"#define MAXACT {maxact}\n")
        f.write(f"#define NET_IN_C 3\n#define NET_IN_H {IN_H}\n#define NET_IN_W {IN_W}\n")
        f.write(f"#define NET_OUT_C 14\n#define NET_OUT_H {OUT_H}\n#define NET_OUT_W {OUT_W}\n\n")
        f.write("extern const Op OPS[N_OPS];\n")
        f.write("extern const int32_t RQ_M0[];\nextern const int64_t RQ_BIAS[];\n")
        f.write("extern const int8_t RQ_SH[];\n")
        f.write("extern const double INPUT_SCALE, FINAL_OUT_MULT;\n")
        f.write("extern const double FINAL_BIAS[14];\n#endif\n")

    with open(os.path.join(out_src, "model_meta.c"), "w", newline="\n") as f:
        f.write('/* Generated network tables (op program, requant parameters). Do not edit by hand. */\n')
        f.write('#include "model_meta.h"\n\n')
        f.write("const Op OPS[N_OPS] = {\n")
        for op in ops:
            f.write("  {%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d},\n" % (
                op["type"], op["in_buf"], op["in2_buf"], op["out_buf"], op["ic"], op["oc"],
                op["kh"], op["kw"], op["stride"], op["pad"], op["w_off"], op["rq_off"],
                op["relu"], op["lo"], op["hi"], op["mp"], op["mq"], op["sh"]))
        f.write("};\n\n")

        def arr(name, ctype, vals, suffix=""):
            f.write(f"const {ctype} {name}[] = {{\n")
            for i in range(0, len(vals), 12):
                f.write("  " + ",".join(f"{v}{suffix}" for v in vals[i:i + 12]) + ",\n")
            f.write("};\n\n")
        arr("RQ_M0", "int32_t", arrays["M0"])
        arr("RQ_BIAS", "int64_t", arrays["bias"], "LL")
        arr("RQ_SH", "int8_t", arrays["sh"])
        f.write(f"const double INPUT_SCALE = {consts['input_scale']!r};\n")
        f.write(f"const double FINAL_OUT_MULT = {consts['final_out_mult']!r};\n")
        f.write("const double FINAL_BIAS[14] = {\n  " +
                ",".join(repr(float(v)) for v in consts["final_bias"]) + "};\n")


# ----------------------------- main -----------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--val", type=int, default=16, help="images for argmax validation")
    ap.add_argument("--fixtures", type=int, default=4)
    ap.add_argument("--ckpt", default=CKPT, help="checkpoint to extract (default: 256 pwstem)")
    ap.add_argument("--strict-int8", action="store_true",
                    help="strict-INT8 scheme: export with every adder-tree term in [-127,127] "
                         "(seams /127, ReLU x255/127 clamp 0..127, no -128). Default OFF; "
                         "weights and both weight blobs are unchanged either way.")
    args = ap.parse_args()

    print(f"[load] model + checkpoint: {args.ckpt}  (input {IN_W}x{IN_H})")
    m = load_model(args.ckpt)
    if args.strict_int8:
        apply_strict_int8(m)
        print("[STRICT-INT8] strict-INT8 export: seams /127, ReLU x(255/127) 0..127, no -128")
    ds = MPIIDataset("valid")
    print(f"[calibrate] seam scales over {CAL_N} images")
    seams = calibrate_seams(m, ds, CAL_N)
    print("  " + " ".join(f"f{i}:{s:.2e}" for i, s in sorted(seams.items())))

    ops, blob, arrays, consts = extract(m, seams)
    n_add = sum(1 for o in ops if o["type"] == OP_ADD)
    print(f"[extract] {len(ops)} ops ({n_add} residual adds), blob {blob.size/1024:.1f} KB, "
          f"rq entries {len(arrays['M0'])}")

    # buffer size: run the int forward once on zeros at the target resolution and take the
    # largest buffer written (the C runtime sizes every activation slot to MAXACT). Also cover
    # the stem im2col buffer (27ch at IN/2) which forward_int (plain 3x3 conv) never materializes.
    x0 = np.zeros((3, IN_H, IN_W), dtype=np.int64)
    szs = []
    _ = forward_int(ops, blob, arrays, consts, x0, sizes=szs)
    imcol_sz = 27 * (IN_H // 2) * (IN_W // 2)
    maxact = max(max(szs), imcol_sz)
    print(f"[emit] input {IN_W}x{IN_H} -> heatmap {OUT_W}x{OUT_H}, MAXACT={maxact}")
    # Output dirs default to the in-place 256 paths; env TWN_OUT_SRC/TWN_OUT_DATA redirect them
    # (used for an ISOLATED 192 deploy so the 256 src/data are never touched).
    out_src  = os.environ.get("TWN_OUT_SRC",  os.path.join(HERE, "src"))
    out_data = os.environ.get("TWN_OUT_DATA", os.path.join(HERE, "data"))
    emit_c(ops, blob, arrays, consts, maxact, out_src, out_data)

    # ---------------- validation vs Brevitas ----------------
    print(f"[validate] argmax agreement vs Brevitas on {args.val} images")
    s0 = consts["input_scale"]
    agree = tot = 0
    mx = 0
    for k in range(args.val):
        inp, _, _, _ = ds[(k * 137) % len(ds)]
        with torch.no_grad():
            hb = m(inp.unsqueeze(0)).squeeze(0).numpy()
        xi = np.clip(np.round(inp.numpy() / s0), IN_LO, 127).astype(np.int64)
        acc = forward_int(ops, blob, arrays, consts, xi)
        hm = acc.astype(np.float64) * consts["final_out_mult"] + consts["final_bias"][:, None, None]
        cb, ci = argmax_coords(hb), argmax_coords(hm)
        agree += int((cb == ci).all().item() if hasattr((cb == ci).all(), "item") else (cb == ci).all())
        tot += 1
        mx = max(mx, int(np.abs(cb - ci).max()))
    print(f"  images all-14-joints exact: {agree}/{tot} | max coord diff: {mx} px @64")

    # ---------------- golden fixtures (from the INT reference) ----------------
    gold = os.environ.get("TWN_OUT_GOLD", os.path.join(HERE, "golden"))
    os.makedirs(gold, exist_ok=True)
    for k in range(args.fixtures):
        inp, _, _, _ = ds[(k * 137) % len(ds)]
        xi = np.clip(np.round(inp.numpy() / s0), IN_LO, 127).astype(np.int8)
        cks = []
        acc = forward_int(ops, blob, arrays, consts, xi.astype(np.int64), cks)
        kp = argmax_coords(acc.astype(np.float64)).astype(np.int32)
        with open(os.path.join(gold, f"fix_{k}.bin"), "wb") as f:
            xi.tofile(f)                                        # int8 [3*256*256]
            acc.astype(np.int32).tofile(f)                      # int32 [14*64*64]
            kp.tofile(f)                                        # int32 [14*2]
            np.asarray(cks, dtype=np.int64).tofile(f)           # int64 [n_checksum_ops]
        print(f"  fixture {k}: {len(cks)} checksums, acc sum {int(acc.sum())}")
    print(f"[done] artifacts under {HERE}")


if __name__ == "__main__":
    main()
