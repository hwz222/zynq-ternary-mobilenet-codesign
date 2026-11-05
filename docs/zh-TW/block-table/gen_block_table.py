# -*- coding: utf-8 -*-
"""gen_block_table.py -- decode the backbone block table for block_table.tex.

Reads tools/fuse_desctab.h (the 272 words the driver writes with TWN_IOC_SET_TABLE)
and takes every field's bit position from rtl/fuse/twn_desctab.v itself, so the
layout printed in the PDF is the RTL's, not a copy of it. Writes gen/*.tex.
tools/fuse_desctab.h and the two model files of check 2 are not tracked; step 1 of
docs/REBUILD.md generates them (run_p1.sh, pack_fuse_weights.py, gen_desctab.py).

Checks, all of which must pass before anything is written:
  1. re-encoding the decoded fields gives back every word (so every bit outside a
     field is 0 in every row);
  2. the fields equal the model's shape file and weight index (p1_manifest.json,
     fuse_weights_index.json in golden/p1_golden/vec/, or --model-dir); skipped,
     and left out of the PDF, when they are not there;
  3. in the weight file each region starts where the previous one ends, rounded up
     to ALIGN bytes, and no region runs past its on-chip memory's depth;
  4. neighbouring blocks (16 -> 0 included) never overlap in an on-chip memory.

usage:  python gen_block_table.py [--model-dir DIR]
then:   latexmk -xelatex block_table.tex
"""
import argparse, io, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
GEN = os.path.join(HERE, "gen")


def rd(rel):
    return io.open(os.path.join(ROOT, rel), encoding="utf-8").read()


ap = argparse.ArgumentParser()
ap.add_argument("--model-dir", default=os.path.join(ROOT, "golden", "p1_golden", "vec"),
                help="directory holding p1_manifest.json and fuse_weights_index.json "
                     "(default: golden/p1_golden/vec)")
args = ap.parse_args()
if not all(os.path.isfile(os.path.join(args.model_dir, n))
           for n in ("p1_manifest.json", "fuse_weights_index.json")):
    args.model_dir = None

# ---- the table ----
hdr = rd("tools/fuse_desctab.h")
NBLK = int(re.search(r"#define FUSE_NBLK (\d+)", hdr).group(1))
NW = int(re.search(r"#define FUSE_DESC_WORDS (\d+)", hdr).group(1))
T = []
for bi, body in re.findall(r"/\* block\s+(\d+) \*/(.*)", hdr):
    ws = [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]+)u", body)]
    assert int(bi) == len(T) and len(ws) == NW
    T.append(ws)
assert len(T) == NBLK

# ---- the field layout, from the RTL's assign statements ----
rtl = rd("rtl/fuse/twn_desctab.v")
FIELDS = []                       # (word, hi, lo, name, signed)
for name, sg, w, hi, lo in re.findall(
        r"assign\s+(\w+)\s*=\s*(\$signed\()?w(\d+)\[(\d+)(?::(\d+))?\]", rtl):
    FIELDS.append((int(w), int(hi), int(lo or hi), name, bool(sg)))
# the prefetched block's register file: curf[k] holds word k + 3
for name, k, hi, lo in re.findall(
        r"assign\s+(\w+)\s*=\s*curf\[(\d+)\](?:\[(\d+):(\d+)\])?\s*;", rtl):
    if name.startswith("fb_"):
        continue                  # the same bits as mb_*, already taken from w9 / w10
    FIELDS.append((int(k) + 3, int(hi) if hi else 31, int(lo) if lo else 0, name, False))
FIELDS.sort(key=lambda x: (x[0], x[2]))
names = [x[3] for x in FIELDS]
assert len(names) == len(set(names)), names
# no two fields share a bit
for wi in range(NW):
    used = 0
    for w, hi, lo, n, s in FIELDS:
        if w == wi:
            m = ((1 << (hi - lo + 1)) - 1) << lo
            assert not used & m, (wi, n)
            used |= m
print("RTL layout: %d fields in %d words" % (len(FIELDS), NW))


def f(w, hi, lo):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def decode(ws):
    d = {}
    for wi, hi, lo, n, sg in FIELDS:
        v = f(ws[wi], hi, lo)
        d[n] = v - (1 << (hi - lo + 1)) if sg and v >> (hi - lo) else v
    return d


D = [decode(ws) for ws in T]

# ---- check 1: round trip ----
for bi, ws in enumerate(T):
    back = [0] * NW
    for wi, hi, lo, n, sg in FIELDS:
        back[wi] |= (D[bi][n] & ((1 << (hi - lo + 1)) - 1)) << lo
    assert back == ws, bi
checks = [r"把解出的欄位依同一套位元位置重新編碼，%d 列 $\times$ %d 字全部和原字相同；"
          r"這也證明所有「未用」位元在每一列都是 0。" % (NBLK, NW)]

# ---- check 2: the model's own files, when available ----
LOG2 = {1: 0, 2: 1, 4: 2, 8: 3}
REG = ("tern", "dw", "rqa", "rqd")
if args.model_dir:
    man = json.load(io.open(os.path.join(args.model_dir, "p1_manifest.json"), encoding="utf-8"))["blocks"]
    idx = json.load(io.open(os.path.join(args.model_dir, "fuse_weights_index.json"), encoding="utf-8"))["blocks"]
    assert len(man) == len(idx) == NBLK
    for bi, (b, e) in enumerate(zip(man, idx)):
        d = D[bi]
        assert (d["c_in"], d["c_mid"], d["c_out"]) == (b["in"]["c"], b["mid"]["c"], b["out"]["c"]), bi
        assert (d["h_in"], d["w_in"]) == (b["in"]["h"], b["in"]["w"]), bi
        assert d["s_dw"] == (b["dw_stride"] == 2) and d["has_res"] == bool(b["has_residual"]), bi
        assert d["pack_e"] == LOG2[b["pack_e"]["pack"]] and d["pack_p"] == LOG2[b["pack_p"]["pack"]], bi
        assert d["stem"] == (1 if b.get("stem") else 0), bi
        for k in REG:
            assert (d["off_" + k], d["n_" + k], d["mb_" + k]) == \
                   (e[k]["off"], e[k]["words"], e[k]["mem_base"]), (bi, k)
    checks.append(r"解出的通道數、尺寸、stride、residual、pack、stem、4 種參數的 offset／字數／片上起點，"
                  r"和模型形狀檔 \f{p1\_manifest.json}、權重索引 \f{fuse\_weights\_index.json} 逐列相同"
                  r"（%d/%d）。這兩個檔和 \f{tools/fuse\_desctab.h} 一樣不進版控，"
                  r"由 \f{docs/REBUILD.md} 第 1 步產生。" % (NBLK, NBLK))
    print("model files: %d/%d blocks" % (NBLK, NBLK))
else:
    print("model files: not found (run docs/REBUILD.md step 1, or pass --model-dir); check 2 skipped")

# ---- check 3: weight-file offsets and on-chip depths ----
pk = rd("tools/pack_fuse_weights.py")
ALIGN = int(re.search(r"^ALIGN\s*=\s*(\d+)", pk, re.M).group(1))
BEAT = int(re.search(r"^BEAT\s*=\s*(\d+)", pk, re.M).group(1))
DEPTH = {k: int(re.search(r"%s_WORDS\s*=\s*(\d+)" % k.upper(), rtl).group(1)) for k in REG}
wm = rd("rtl/fuse/twn_wmem.v")
BITS = {"tern": int(re.search(r"TERN_WORDS\s*=\s*\d+,\s*//\s*(\d+) bit", wm).group(1)),
        "dw":   int(re.search(r"DW_WORDS\s*=\s*\d+,\s*//\s*(\d+) bit", wm).group(1)),
        "rqa":  int(re.search(r"RQ_W\s*=\s*(\d+)", wm).group(1)),
        "rqd":  int(re.search(r"RQD_WORDS\s*=\s*\d+\s*//\s*(\d+) bit", wm).group(1))}
FILEB = {k: -(-BITS[k] // 8 // BEAT) * BEAT for k in REG}     # bytes per word in the file


def up(v):
    return -(-v // ALIGN) * ALIGN


for bi, d in enumerate(D):
    for a, b in zip(REG, REG[1:]):
        assert up(d["off_" + a] + d["n_" + a] * FILEB[a]) == d["off_" + b], (bi, a)
    if bi + 1 < NBLK:
        assert up(d["off_rqd"] + d["n_rqd"] * FILEB["rqd"]) == D[bi + 1]["off_tern"], bi
    for k in REG:
        assert d["mb_" + k] + d["n_" + k] <= DEPTH[k], (bi, k)
checks.append(r"權重檔 offset 前後相接：每個區域的 offset 加上「字數 $\times$ 檔案中每字的位元組數」，"
              r"補到 %d bytes 的倍數，等於下一個區域的 offset；每個區域的片上起點加字數不超過記憶體深度"
              r"（%d/%d）。" % (ALIGN, NBLK, NBLK))

# ---- check 4: neighbours do not overlap on chip ----
for bi in range(NBLK):
    a, b = D[bi], D[(bi + 1) % NBLK]
    for k in REG:
        a0, a1 = a["mb_" + k], a["mb_" + k] + a["n_" + k]
        b0, b1 = b["mb_" + k], b["mb_" + k] + b["n_" + k]
        assert a1 <= b0 or b1 <= a0, (bi, k)
checks.append(r"相鄰兩個 block（含 block %d 接回 block 0）在 4 個片上記憶體裡的區域都不重疊"
              r"（%d/%d 對）。" % (NBLK - 1, NBLK, NBLK))
print("offsets, depths, neighbour overlap: pass")

# ---- the numbers block_table.tex quotes in its prose (sections 4 and 5) ----
# If the table changes, this fails and the prose has to be re-read, not left stale.
PROSE = [
    (T[1][0], 0x41818010),
    ((D[1]["c_in"], D[1]["c_mid"], D[1]["c_out"], D[1]["s_dw"], D[1]["has_res"]), (16, 96, 24, 1, 0)),
    ((D[1]["mb_tern"], D[1]["n_tern"], D[1]["mb_dw"], D[1]["n_dw"]), (8112, 48, 228, 12)),
    ((D[1]["mb_rqa"], D[1]["n_rqa"], D[1]["mb_rqd"], D[1]["n_rqd"]), (570, 30, 228, 12)),
    ((D[1]["off_tern"], D[1]["off_dw"], D[1]["off_rqa"], D[1]["off_rqd"], D[2]["off_tern"]),
     (1856, 3392, 4352, 5312, 6080)),
    ((T[2][9], T[2][10]), (0, 0)),
    ((D[0]["mb_tern"], D[16]["mb_tern"], D[16]["n_tern"]), (4720, 0, 4720)),
    ((D[2]["mp_res"], D[2]["mq_res"], D[2]["sh_res"], D[2]["lo_res"], D[2]["hi_res"]),
     (45374, 46742, 16, -127, 127)),
    ((FILEB["tern"], FILEB["dw"], FILEB["rqa"], FILEB["rqd"]), (32, 80, 32, 64)),
]
for got, want in PROSE:
    assert got == want, (got, want)
print("numbers quoted in the prose: %d groups match" % len(PROSE))

# ================= LaTeX fragments =================
os.makedirs(GEN, exist_ok=True)
X = r"$\times$"
NAMES = {"tern": "三值權重", "dw": "depthwise 權重",
         "rqa": "expand/project requant", "rqd": "depthwise requant"}


def put(fn, lines):
    io.open(os.path.join(GEN, fn), "w", encoding="utf-8", newline="\n").write(
        "\n".join(lines) + "\n\\bottomrule\n")


def tt(s):
    return r"\texttt{" + s.replace("_", r"\_") + "}"


io.open(os.path.join(GEN, "checks.tex"), "w", encoding="utf-8", newline="\n").write(
    "\\begin{enumerate}\n" + "".join("\\item %s\n" % c for c in checks) + "\\end{enumerate}\n")
io.open(os.path.join(GEN, "consts.tex"), "w", encoding="utf-8", newline="\n").write(
    "".join("\\newcommand{\\%s}{%s}\n" % (n, v) for n, v in (
        ("FileBdw", FILEB["dw"]), ("FileBrqd", FILEB["rqd"]), ("FileBtern", FILEB["tern"]),
        ("FileBrqa", FILEB["rqa"]), ("AlignB", ALIGN))))


def meaning(n, d):
    v = d[n]
    if n == "c_in":
        return "輸入 %d 通道" % v
    if n == "c_mid":
        if d["stem"]:
            return "stem 3%s3 conv 的輸出 %d 通道" % (X, v)
        return "expand 後 %d 通道（倍率 %g）" % (v, v / d["c_in"])
    if n == "c_out":
        return "輸出 %d 通道" % v
    if n == "s_dw":
        if v:
            return "stride 2，輸出 %d%s%d" % (d["h_in"] // 2, X, d["w_in"] // 2)
        return "stride 1，尺寸不變"
    if n == "has_res":
        return "有 residual 加法" if v else "無 residual"
    if n == "h_in":
        return "輸入高 %d" % v
    if n == "w_in":
        return "輸入寬 %d" % v
    if n in ("pack_e", "pack_p"):
        return "log2 編碼，pack = %d" % (1 << v)
    if n == "in_slot":
        return "0xF：不讀 slot，從 IN 讀影像" if v == 15 else "讀 activation slot %d" % v
    if n == "out_slot":
        return "寫 activation slot %d" % v
    if n in ("row_bytes_in", "row_bytes_out"):
        c = d["c_in"] if n.endswith("in") else d["c_out"]
        w = d["w_in"] if n.endswith("in") else d["w_in"] // (2 if d["s_dw"] else 1)
        return "%d 通道 %s %d 像素 = %d B%s" % (c, X, w, c * w, "" if c * w == v else "，補到 128 倍數")
    for pre in ("off_", "n_", "mb_"):
        if n.startswith(pre) and n[len(pre):] in REG:
            k = n[len(pre):]
            if pre == "off_":
                return "%s在權重檔的位置（byte）" % NAMES[k]
            if pre == "n_":
                return "%d 字（片上 %d bit/字），檔案中佔 %d B" % (v, BITS[k], v * FILEB[k])
            return "%d + %d = %d，深度 %d" % (v, d["n_" + k], v + d["n_" + k], DEPTH[k])
    if n == "res_slot":
        return "等於本 block 的 in\\_slot；資料路徑不讀"
    if n in ("nseg_e", "nseg_p"):
        return "分 %d 段（從 1 起算）" % v
    if n == "stem":
        return "是第一層 stem" if v else "不是 stem"
    if n in ("pack0_e", "pack0_p"):
        return "0 = 與 pack 相同" if v == 0 else "log2 編碼，第 0 段 pack = %d" % (1 << v)
    if n in ("msg_e", "msg_p"):
        return "混合分段旋轉：" + ("開" if v else "關")
    if n in ("mp_res", "mq_res"):
        if not d["has_res"]:
            return "單位值 %d" % v
        return r"$%d / 2^{%d} \approx %.4f$" % (v, d["sh_res"], v / 2 ** d["sh_res"])
    if n == "sh_res":
        return "右移 %d 位" % v if v else "不移位"
    if n == "lo_res":
        return "輸出下限"
    if n == "hi_res":
        return "輸出上限"
    raise KeyError(n)            # a field the RTL has and this page does not explain


def example(bi):
    ws, d = T[bi], D[bi]
    L = []
    for wi in range(NW):
        flds = [x for x in FIELDS if x[0] == wi]
        for j, (w_, hi, lo, n, sg) in enumerate(flds):
            raw = f(ws[wi], hi, lo)
            width = hi - lo + 1
            rng = ("%d" % hi) if hi == lo else ("%d:%d" % (hi, lo))
            rawtxt = (r"\texttt{0x%X}" % raw) if width > 18 else (r"\texttt{%s}" % format(raw, "0%db" % width))
            L.append(" & ".join([str(wi) if j == 0 else "",
                                 (r"\texttt{%08X}" % ws[wi]) if j == 0 else "",
                                 rng, tt(n), rawtxt, str(d[n]), meaning(n, d)]) + r" \\")
        if wi < NW - 1:
            L.append(r"\midrule")
    put("ex%d.tex" % bi, L)
    b = []
    for wi in range(NW):
        s = format(ws[wi], "032b")
        b.append(r"%d & \texttt{%08X} & \texttt{%s} \\" % (wi, ws[wi], " ".join(s[i:i + 4] for i in range(0, 32, 4))))
    put("bits%d.tex" % bi, b)


example(1)
example(2)

L = []
for bi, d in enumerate(D):
    L.append(" & ".join([
        str(bi), str(d["c_in"]), str(d["c_mid"]), str(d["c_out"]),
        "%d%s%d" % (d["h_in"], X, d["w_in"]), "2" if d["s_dw"] else "1",
        "有" if d["has_res"] else "無", str(1 << d["pack_e"]), str(1 << d["pack_p"]),
        "F" if d["in_slot"] == 0xF else str(d["in_slot"]), str(d["out_slot"]),
        str(d["mb_tern"]), "是" if d["stem"] else ""]) + r" \\")
put("summary.tex", L)
for part, sl in (("a", slice(0, NW // 2)), ("b", slice(NW // 2, NW))):
    put("raw_%s.tex" % part, [str(bi) + " & " + " & ".join(r"\texttt{%08X}" % w for w in ws[sl]) + r" \\"
                              for bi, ws in enumerate(T)])
print("wrote", GEN)
