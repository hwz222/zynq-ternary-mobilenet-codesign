"""M1: pack the ternary weights of mbv2_dc32_pwstem to 2-bit for the PL weight ROM.

Encoding (two's-complement 2-bit, 4 weights/byte, LSB-first -- same as twn-pose-c-hw):
    0 -> 0b00,  +1 -> 0b01,  -1 -> 0b11        decode = twn_unpack2()

Sections in data/model_mbv2_packed.bin:
    [0 .. W2LIN)          linear ternary section (row-major oc*ic), used by the stem path,
                          the C-side verification, and as the round-trip reference
    [W2_AL .. +W2HW)      HW-ORDERED pointwise section: each 64-weight chunk (o, icc) is
                          16 bytes, stored contiguously and 16-byte aligned, zero-padded
                          when IC % 64 != 0. This makes the PL datapath's 16 byte reads
                          per cycle STATICALLY bank-disjoint (chunk_base = chunk_idx*16),
                          which is what lets HLS schedule the 64-lane loop at II=1 -- with
                          the raw row-major layout the bank analysis fails (II up to 27).
    [W2_AL+W2HW .. +W8)   int8 section (depthwise + deconv + final, raw int8)

Per-op offsets -> hls/pack_meta_mbv2.h:
    W2_OFF[i]   : ELEMENT index into the linear ROM (stem + verification), -1 if not ternary
    W2HW_OFF[i] : BYTE offset into the HW-ordered section (pw ops only), -1 otherwise
    W8_OFF[i]   : BYTE offset into the int8 section, -1 if op i has no int8 weights

Gates (hard failures): linear round-trip == original; HW-ordered chunks decode back to
the exact per-op weight rows (padding zones all-zero).
Run from train/mbv2_pose/ via export/export_board_model.py
"""
import importlib.util
import os
import sys

import numpy as np

TOOLS = os.path.dirname(os.path.abspath(__file__))              # train/mbv2_pose/export
REPO = os.path.dirname(TOOLS)                                   # train/mbv2_pose
HERE = os.path.join(REPO, "runs", "export")                     # default output root (env overrides)
sys.path.insert(0, REPO)

spec = importlib.util.spec_from_file_location(
    "extract_mbv2", os.path.join(TOOLS, "extract_mbv2.py"))
EX = importlib.util.module_from_spec(spec)
spec.loader.exec_module(EX)


def pack2(vals):
    """int8 {-1,0,+1} -> uint8 packed 4/byte (LSB-first)."""
    v = np.asarray(vals, dtype=np.int8)
    assert set(np.unique(v)).issubset({-1, 0, 1}), "non-ternary value in ternary op"
    codes = (v.astype(np.uint8) & 0x3)              # -1 -> 0b11, 0 -> 0, 1 -> 1
    if codes.size % 4:
        codes = np.concatenate([codes, np.zeros(4 - codes.size % 4, np.uint8)])
    c = codes.reshape(-1, 4)
    return (c[:, 0] | (c[:, 1] << 2) | (c[:, 2] << 4) | (c[:, 3] << 6)).astype(np.uint8)


def unpack2(packed, n):
    out = np.zeros(n, dtype=np.int8)
    for i in range(n):
        code = (packed[i >> 2] >> ((i & 3) * 2)) & 0x3
        out[i] = code if code < 2 else code - 4     # sign-extend 2 bits
    return out


def main():
    m = EX.load_model()
    from src.dataset import MPIIDataset
    ds = MPIIDataset("valid")
    seams = EX.calibrate_seams(m, ds, EX.CAL_N)
    ops, blob, arrays, consts = EX.extract(m, seams)

    K = 128                                              # S1 datapath lanes / chunk size
                                                         # (MUST equal K_LANES in mbv2_layer.cpp)
    tern_stream, i8_stream, hw_stream = [], [], []
    w2_off, w2hw_off, w8_off = [], [], []
    t_elems = i8_bytes = hw_bytes = 0
    for op in ops:
        if op["type"] == EX.OP_CONV:                      # every backbone CONV is ternary
            n = op["oc"] * op["ic"] * op["kh"] * op["kw"]
            w = blob[op["w_off"]:op["w_off"] + n]
            assert t_elems % 4 == 0, "ternary op not 4-aligned"
            tern_stream.append(w)
            w2_off.append(t_elems); w8_off.append(-1)
            t_elems += n
            # HW-ordered chunked copy. The stem (kh==3) is ALSO emitted as a pw block:
            # on the PL it runs as a 1x1 conv over the im2col'd 27-channel input (row
            # order ic*9 + ky*3 + kx == the natural (oc, ic, ky, kx) flatten below),
            # which deleted the dedicated stem datapath (~14K LUT of crossbars).
            ic, oc = op["ic"] * op["kh"] * op["kw"], op["oc"]
            icc = (ic + K - 1) // K
            rows = w.reshape(oc, ic).astype(np.int8)
            if ic <= 32:
                # S2b pack4 (mirror of RTL PACKr==2 = descriptor_ic <= 32): one 128-lane chunk
                # carries FOUR oc's 32-lane sub-chunks -> 4 oc/cycle. Stem (eff-ic 27 ->
                # IMCOL_C 32), the early projections and the ic16/ic24/ic32 expands land here.
                assert oc % 4 == 0, f"pack4 needs OC%4==0 (op oc={oc})"
                padded = np.zeros((oc, 32), dtype=np.int8)
                padded[:, :ic] = rows
                quads = padded.reshape(oc // 4, 128)         # [A(32)|B(32)|C(32)|D(32)] per word
                hw_stream.append(pack2(quads.reshape(-1)))
                w2hw_off.append(hw_bytes)
                hw_bytes += (oc // 4) * (K // 4)
            elif ic <= 64:
                # S1 pack2 (mirror of RTL PACKr==1 = descriptor_ic in (32,64]): one 128-lane
                # chunk carries TWO oc's 64-lane sub-chunks -> 2 oc/cycle.
                assert oc % 2 == 0, f"pack2 needs even OC (op oc={oc})"
                padded = np.zeros((oc, 64), dtype=np.int8)
                padded[:, :ic] = rows
                pairs = padded.reshape(oc // 2, 128)         # [ocA(64) | ocB(64)] per word
                hw_stream.append(pack2(pairs.reshape(-1)))
                w2hw_off.append(hw_bytes)
                hw_bytes += (oc // 2) * (K // 4)
            else:
                padded = np.zeros((oc, icc * K), dtype=np.int8)
                padded[:, :ic] = rows
                hw_stream.append(pack2(padded.reshape(-1)))
                w2hw_off.append(hw_bytes)
                hw_bytes += oc * icc * (K // 4)
        elif op["type"] in (EX.OP_DW, EX.OP_DECONV, EX.OP_FINAL):
            n = (op["oc"] * op["kh"] * op["kw"] if op["type"] == EX.OP_DW
                 else op["ic"] * op["oc"] * op["kh"] * op["kw"])
            w = blob[op["w_off"]:op["w_off"] + n]
            i8_stream.append(w)
            w2_off.append(-1); w2hw_off.append(-1); w8_off.append(i8_bytes)
            i8_bytes += n
        else:                                             # ADD
            w2_off.append(-1); w2hw_off.append(-1); w8_off.append(-1)

    tern = np.concatenate(tern_stream)
    packed = pack2(tern)
    hw = np.concatenate(hw_stream)
    i8 = np.concatenate(i8_stream).astype(np.int8)
    w2_al = (packed.size + 15) // 16 * 16                # pad linear section to 16 B

    # ---- gate 1: linear round trip ----
    rt = unpack2(packed, tern.size)
    assert np.array_equal(rt, tern.astype(np.int8)), "LINEAR ROUND-TRIP MISMATCH"
    # ---- gate 2: HW-ordered chunks decode back to the exact weight rows ----
    for oi, op in enumerate(ops):
        if op["type"] == EX.OP_CONV:
            ic, oc = op["ic"] * op["kh"] * op["kw"], op["oc"]
            icc = (ic + K - 1) // K
            ref = blob[op["w_off"]:op["w_off"] + oc * ic].reshape(oc, ic).astype(np.int8)
            if ic <= 32:
                n = (oc // 4) * K
                got = unpack2(hw[w2hw_off[oi]:w2hw_off[oi] + n // 4], n).reshape(oc, 32)
                assert np.array_equal(got[:, :ic], ref), f"HW-ORDER(pack4) MISMATCH op {oi}"
                assert not got[:, ic:].any(), f"HW-ORDER(pack4) PAD NOT ZERO op {oi}"
            elif ic <= 64:
                n = (oc // 2) * K
                got = unpack2(hw[w2hw_off[oi]:w2hw_off[oi] + n // 4], n).reshape(oc, 64)
                assert np.array_equal(got[:, :ic], ref), f"HW-ORDER(pack) MISMATCH op {oi}"
                assert not got[:, ic:].any(), f"HW-ORDER(pack) PAD NOT ZERO op {oi}"
            else:
                n = oc * icc * K
                got = unpack2(hw[w2hw_off[oi]:w2hw_off[oi] + n // 4], n).reshape(oc, icc * K)
                assert np.array_equal(got[:, :ic], ref), f"HW-ORDER MISMATCH op {oi}"
                assert not got[:, ic:].any(), f"HW-ORDER PAD NOT ZERO op {oi}"

    zeros = float((tern == 0).mean())
    print(f"[pack] ternary {tern.size} weights ({zeros*100:.1f}% zeros) "
          f"-> linear {packed.size} B + hw-ordered {hw.size} B | int8 {i8.size} B")
    print(f"[gate] linear round-trip PASS | hw-ordered decode PASS ({sum(1 for o in w2hw_off if o >= 0)} pw ops)")

    # Output dirs default to in-place 256 paths; env TWN_OUT_DATA/TWN_OUT_HLS redirect them for
    # an ISOLATED 192 deploy (256 data/ + hls/pack_meta_mbv2.h are then never touched).
    out_data = os.environ.get("TWN_OUT_DATA", os.path.join(HERE, "data"))
    os.makedirs(out_data, exist_ok=True)
    out_bin = os.path.join(out_data, "model_mbv2_packed.bin")
    with open(out_bin, "wb") as f:
        packed.tofile(f)
        f.write(b"\x00" * (w2_al - packed.size))
        hw.tofile(f)
        i8.tofile(f)
    print(f"[emit] {out_bin} ({w2_al + hw.size + i8.size} B total)")

    hls_dir = os.environ.get("TWN_OUT_HLS", os.path.join(HERE, "hls"))
    os.makedirs(hls_dir, exist_ok=True)
    with open(os.path.join(hls_dir, "pack_meta_mbv2.h"), "w", newline="\n") as f:
        f.write("/* AUTO-GENERATED by tools/pack_ternary.py -- packed-weight offsets */\n")
        f.write("#ifndef PACK_META_MBV2_H\n#define PACK_META_MBV2_H\n")
        f.write(f"#define W2_BYTES {packed.size}\n")
        f.write(f"#define W2_AL {w2_al}\n")                 # linear section padded size
        f.write(f"#define W2HW_BYTES {hw.size}\n")
        f.write(f"#define W8_BYTES {i8.size}\n")
        f.write(f"#define W2_ELEMS {tern.size}\n")
        f.write("static const long W2_OFF[] = {" + ",".join(map(str, w2_off)) + "};\n")
        f.write("static const long W2HW_OFF[] = {" + ",".join(map(str, w2hw_off)) + "};\n")
        f.write("static const long W8_OFF[] = {" + ",".join(map(str, w8_off)) + "};\n")
        # S1: the pack criterion lives in TWO places (twn_top PACKr and this tool). This
        # table is the tool's sworn statement of the per-op layout class; the driver asserts
        # the RTL criterion against it at init, so a drift fails LOUD at startup instead of
        # producing silently wrong weights on exactly the ops in the disputed IC range.
        pk = [((2 if (op["ic"] * op["kh"] * op["kw"]) <= 32 else
                1 if (op["ic"] * op["kh"] * op["kw"]) <= 64 else 0)
               if op["type"] == EX.OP_CONV else -1) for op in ops]
        f.write("#define W2_LANES 128\n")
        f.write("#define W2_PACK_LAYOUT 3\n")   # 3 = pack4/pack2/linear tri-class (S2b)
        f.write("static const signed char W2_PACK[] = {" + ",".join(map(str, pk)) + "};\n")
        f.write("#endif\n")
    print(f"[emit] {hls_dir}\\pack_meta_mbv2.h")


if __name__ == "__main__":
    main()
