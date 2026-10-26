"""lint_multidrive.py -- fail on any signal with more than one driver: a reg assigned
from two clocked always blocks, or a wire driven by two continuous assignments.

Simulation resolves a multiply-driven reg as last-write-wins, which usually looks
correct; synthesis cannot build two drivers for one flip-flop (Vivado [Synth 8-6859] /
[Synth 8-6858]) and ties the net to a constant, deleting the logic it gates.

Reads:   by default every .v in rtl/src and rtl/fuse (relative to this file);
         with file arguments, those files. Writes nothing; exit 0 = clean.

    python rtl/sim/lint_multidrive.py            # the shipped engines
    python rtl/sim/lint_multidrive.py <files>    # anything else
    python rtl/sim/lint_multidrive.py --selftest

--selftest runs the inline filter tests (generate scopes, `ifdef arms, indexed
continuous assigns: each must stay quiet on an exclusive case and still flag a real
collision) and, when rtl/counterfactual holds the archived
twn_hd_compute_B2_inc2_still_good.v / _inc3_minimal_repro.v pair, requires inc3 to be
flagged and inc2 clean; that half is skipped when the files are absent.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")
FUSE = os.path.join(HERE, "..", "fuse")
CF = os.path.join(HERE, "..", "counterfactual")

def shipped():
    """Every .v in rtl/src and rtl/fuse, discovered rather than hand-listed, so a file
    cannot silently drop out of the check."""
    out = []
    for d in (SRC, FUSE):
        if os.path.isdir(d):
            out += [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".v")]
    return sorted(out)


# ---- generate-scope tracking ----
# Two assignments to the same name only conflict if they can coexist. Exclusive
# generate branches (`if ... begin : g_a ... end else begin : g_b ... end`) and
# instances of one generate loop each declare their own signal, so a named begin
# opens a scope and two drivers conflict only when their scope paths are identical.
# (`end` does not match endgenerate/endmodule/endcase.)
# `ifdef / `else arms are scopes too: exactly one arm compiles, e.g. a *_NEG_* arm
# holding a deliberately wrong assignment beside the right one.
SCOPE_TOK = re.compile(
    r"\bbegin\b(?:\s*:\s*(\w+))?"          # 1: named begin
    r"|\bend\b"
    r"|`(ifdef|ifndef)\s+(\w+)"            # 2,3: conditional open
    r"|`(elsif)\s+(\w+)"                   # 4,5
    r"|`(else|endif)\b"                    # 6
)


def scope_checkpoints(text):
    """[(offset, scope_tuple)] -- the enclosing scope path after each token.

    A scope is anything that makes two pieces of text unable to coexist: a named generate
    block, or one arm of a preprocessor conditional."""
    stack, depth, out = [], 0, []
    pp = []                       # preprocessor arm stack, parallel to `stack`
    for m in SCOPE_TOK.finditer(text):
        tok = m.group(0)
        if tok.startswith("begin"):
            depth += 1
            if m.group(1):
                stack.append((depth, m.group(1)))
        elif tok.startswith("`"):
            if m.group(2):                        # ifdef / ifndef
                pp.append(f"?{m.group(2)}:{m.group(3)}")
                stack.append((None, pp[-1]))
            elif m.group(4):                      # elsif
                if pp:
                    stack = [s for s in stack if s[1] != pp[-1]]
                    pp[-1] = f"?elsif:{m.group(5)}"
                    stack.append((None, pp[-1]))
            elif m.group(6) == "else":
                if pp:
                    stack = [s for s in stack if s[1] != pp[-1]]
                    pp[-1] = "?else:" + pp[-1]
                    stack.append((None, pp[-1]))
            else:                                 # endif
                if pp:
                    stack = [s for s in stack if s[1] != pp[-1]]
                    pp.pop()
        else:                                     # end
            if stack and stack[-1][0] == depth:
                stack.pop()
            depth -= 1
        out.append((m.end(), tuple(n for _, n in stack)))
    return out


def scope_at(checkpoints, pos):
    """The named-scope path in force at `pos`. Linear scan: these files are small and a
    bisect here would be optimising the wrong thing."""
    cur = ()
    for off, sc in checkpoints:
        if off > pos:
            break
        cur = sc
    return cur

# A non-blocking assignment's target, with any bit/part select stripped: `foo[3:0] <= x`
# and `foo <= x` both drive `foo`. The left context accepts line start, `;`, `begin`,
# `else` or `)` because several assignments are written per line.
ASSIGN = re.compile(r"(?:^|;|\bbegin\b|\belse\b|\))\s*([A-Za-z_]\w*)\s*(?:\[[^\]]*\])*\s*<=",
                    re.M)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


ALWAYS = re.compile(r"^[ \t]*always\b", re.M)


def blocks(text):
    """[(index, start_offset, end_offset)] for each clocked always block.

    Offsets rather than substrings, because the scope path of an assignment is now part of
    its identity and that needs a position in the original text. Splitting on an indented
    `always` is still exact -- the fused design writes them inside generate blocks, so
    anchoring at column 0 would have missed every one of them."""
    starts = [m.start() for m in ALWAYS.finditer(text)]
    out, i = [], 0
    for n, s in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(text)
        if re.match(r"[ \t]*always\b\s*@\s*\(\s*posedge", text[s:end]):
            out.append((i, s, end))
            i += 1
    return out


# The other half of the same class: one wire driven by two continuous assignments.
# The index is kept here and stripped in ASSIGN: different bit ranges of one vector may
# have different continuous drivers (e.g. in generate loops), while for a clocked
# block two always blocks writing `x[i]` are one flip-flop whatever `i` is.
# `assign w[3:0]=x; assign w[3:0]=y;` is still caught -- same index, same key.
CONT = re.compile(r"^\s*assign\s+([A-Za-z_]\w*)((?:\s*\[[^\]]*\])*)\s*=", re.M)


def check_text(text):
    """{(name, scope): [drivers]} for anything with more than one driver IN THE SAME
    generate scope. Keyed by (name, scope) because the same identifier in two exclusive
    generate branches -- or in two instances of one generate loop -- is two different
    signals, not one signal with two drivers."""
    text = strip_comments(text)
    cps = scope_checkpoints(text)
    owners = {}

    for i, s, e in blocks(text):
        # The scope of the ASSIGNMENT, not of the always block: precise enough for both,
        # and it costs nothing.
        for m in ASSIGN.finditer(text[s:e]):
            key = (m.group(1), scope_at(cps, s + m.start(1)))
            owners.setdefault(key, set()).add(f"always#{i}")

    seen = {}
    for m in CONT.finditer(text):
        idx = re.sub(r"\s+", "", m.group(2) or "")
        key = (m.group(1) + idx, scope_at(cps, m.start(1)))
        seen[key] = seen.get(key, 0) + 1
    for key, n in seen.items():
        if n > 1:
            owners.setdefault(key, set()).update(f"assign#{k}" for k in range(n))

    return {k: sorted(v) for k, v in owners.items() if len(v) > 1}


def check(path):
    return check_text(open(path, encoding="utf-8", errors="replace").read())


def run(paths, label):
    bad = 0
    for p in paths:
        hits = check(p)
        if hits:
            bad += 1
            print(f"FAIL {os.path.basename(p)}")
            for (nm, sc), bl in sorted(hits.items()):
                n = nm if not sc else f"{'.'.join(sc)}.{nm}"
                print(f"  '{n}' has {len(bl)} drivers ({', '.join(bl)}). Synthesis will "
                      f"keep one -- a constant, if one is reachable -- and drop the rest, "
                      f"deleting everything the tied signal gates. Simulation will not "
                      f"notice: it resolves multiple drivers as last-write-wins.")
    if bad:
        print(f"\n{label}: {bad} file(s) with a multiply-driven reg -- DO NOT BUILD")
    else:
        print(f"{label}: clean ({len(paths)} files)")
    return bad


# ---- the filters are tested in both directions, inline ----
# A filter that suppresses false positives can suppress true ones, so each has a case
# it must stay silent on and one it must still catch.
GEN_EXCLUSIVE = """
module m;
  generate
    if (P == 0) begin : g_a
      reg [7:0] mem;
      always @(posedge clk) begin mem <= a; end
    end else begin : g_b
      reg [7:0] mem;
      always @(posedge clk) begin mem <= b; end
    end
  endgenerate
  generate
    for (k = 0; k < 4; k = k + 1) begin : g_bank
      wire w;
      assign w = x[k];
    end
  endgenerate
endmodule
"""

GEN_REAL = """
module m;
  generate
    for (k = 0; k < 4; k = k + 1) begin : g_bank
      reg [7:0] acc;
      always @(posedge clk) begin acc <= a; end
      always @(posedge clk) begin acc <= b; end
    end
  endgenerate
endmodule
"""

# Every filter gets a pair: one case it must stay silent on and one it must catch.
PP_EXCLUSIVE = """
module m;
`ifdef NEG_MODE
  assign a_can = 1'b1;
`else
  assign a_can = !a_full && !a_we;
`endif
endmodule
"""

PP_REAL = """
module m;
`ifdef NEG_MODE
  assign a_can = 1'b1;
  assign a_can = other;
`endif
endmodule
"""

IDX_DISTINCT = """
module m;
  assign fstg[0] = pair;
  assign fstg[1] = other;
  assign w[3:0] = x;
  assign w[7:4] = y;
endmodule
"""

IDX_SAME = """
module m;
  assign w[3:0] = x;
  assign w[3:0] = y;
endmodule
"""


def selftest():
    rc = 0

    # 1. the original defect, from the archived bisect points
    good = os.path.join(CF, "twn_hd_compute_B2_inc2_still_good.v")
    bad = os.path.join(CF, "twn_hd_compute_B2_inc3_minimal_repro.v")
    if os.path.exists(good) and os.path.exists(bad):
        ok = not check(good)
        caught = any(n == "q_i" for n, _ in check(bad))
        print(f"selftest: inc2 (last good) clean = {ok};  inc3 (minimal repro) flags q_i = {caught}")
        if not (ok and caught):
            print("selftest FAIL -- this lint no longer catches the bug that motivated it")
            rc = 1
    else:
        print(f"SELFTEST: archived bisect points missing -- that half SKIPPED")

    # 2. generate awareness, both directions
    fp = check_text(GEN_EXCLUSIVE)
    fn = check_text(GEN_REAL)
    quiet = not fp
    loud = any(n == "acc" for n, _ in fn)
    print(f"selftest: exclusive generate branches clean = {quiet};  "
          f"real multi-drive inside one generate scope still flagged = {loud}")
    if not quiet:
        print(f"selftest FAIL -- scope tracking is too weak, false positives: "
              f"{sorted(n for n, _ in fp)}")
        rc = 1
    if not loud:
        print("selftest FAIL -- scope tracking is TOO STRONG: it hides a real "
              "multiply-driven reg, which disables the entire check")
        rc = 1
    # 3. every other filter, both directions
    for label, quiet_src, loud_src, sig in (
            ("preprocessor arms", PP_EXCLUSIVE, PP_REAL, "a_can"),
            ("indexed continuous assigns", IDX_DISTINCT, IDX_SAME, "w[3:0]")):
        fp = check_text(quiet_src)
        fn = check_text(loud_src)
        quiet = not fp
        loud = any(n == sig for n, _ in fn)
        print(f"selftest: {label} -- exclusive/distinct clean = {quiet};  "
              f"genuine collision still flagged = {loud}")
        if not quiet:
            print(f"selftest FAIL -- {label}: false positives {sorted(n for n, _ in fp)}")
            rc = 1
        if not loud:
            print(f"selftest FAIL -- {label}: the filter is TOO STRONG and hides a real "
                  f"collision, which disables the check for everything it covers")
            rc = 1

    if rc == 0:
        print("selftest PASS -- catches the original defect, and every quietening filter "
              "(generate, preprocessor, bit-range) neither cries wolf nor goes silent")
    return rc


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--selftest"]
    rc = selftest() if "--selftest" in sys.argv else 0
    files = args or shipped()
    sys.exit(rc or run(files, "shipped RTL" if not args else "requested files"))
