# run_units.ps1 -- run every per-module testbench under rtl\fuse\tb, plus its break tests.
#
# Usage:
#   .\run_units.ps1                   every gate and every break test
#   .\run_units.ps1 -Only tb_uop_enc  one target (name prefix match)
#   .\run_units.ps1 -NoBreak          skip the break tests
#   .\run_units.ps1 -Quiet            suppress passing detail (failing logs are always printed)
# Prerequisites: Vivado xvlog.bat / xelab.bat / xsim.bat; Python for the generators.
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin);
#   PYTHON = interpreter for the generators (default `python`).
# Generated inputs: a row with `gen` runs that script from rtl\fuse\tb once per invocation before its
#   gate (gen_uop_cases.py, gen_gather_cases.py, gen_scatter_cases.py, gen_res_add.py,
#   gen_wfetch_tb.py). They rewrite the case files in rtl\fuse\tb from the weights of this tree.
# Work directory: %TEMP%\twn_sim\units_<pid>.
# Result: one line per gate (PASS / FAIL / MEAS) and per break test ("bites" is good; "STILL PASSES"
#   or "GATE BROKEN" counts as a failure), then a summary line. Exit 1 if any gate or break test failed.
#
# Adding a testbench means adding a row to $targets; a module with no row has no gate here.
# Break tests: where a row names `define`, the testbench is run again with that define and must FAIL.
#   A define is either in the RTL (`<MODULE>_NEG_*`, never defined for a build) or in the testbench
#   (`*_TB_NEG_*`, BAD_*), where it changes only how the DUT is instantiated or what the check is fed.
#   The row's `why` text says which and what the defect is.
# Unit gates only: they test modules in isolation and say nothing about the wiring. The other gates:
#   run_p5.ps1 (17-block bit-exact), run_p3.ps1 (depthwise array against golden),
#   run_fuse_axi_boost.ps1 (top-level AXI), elab_top.ps1 (elaboration of twn_fuse_top).
param([switch]$Quiet, [switch]$NoBreak, [string]$Only = "")

$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
# The tree root is derived from this script's location.
$tree = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$fuse = Join-Path $tree "rtl\fuse"
$ip   = Join-Path $tree "rtl\src"   # the packaged IP dir is gitignored; rtl\src holds the same sources
$rsrc = Join-Path $tree "rtl\src"
# Per process, so that concurrent runs do not delete each other's libraries and snapshots.
$work = Join-Path $env:TEMP ("twn_sim\units_" + $PID)
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
$py   = if ($env:PYTHON) { $env:PYTHON } else { "python" }

# Every module is compiled for every target, so a new dependency needs no per-target list.
$src = @(
    "$fuse\twn_fuse_select.v", "$fuse\twn_fuse_tree.v", "$fuse\twn_fuse_requant.v",
    "$ip\bram_sdp.v",          "$ip\bram_sdp_bw.v",     "$fuse\twn_fuse_array.v",
    "$fuse\twn_dw_array.v",    "$fuse\twn_blockseq.v",  "$fuse\twn_rowbuf.v",
    "$fuse\twn_rowbuf_rot.v",  "$fuse\twn_wmem.v",      "$rsrc\twn_axi_rd.v",
    "$rsrc\twn_axi_wr.v",      "$fuse\twn_wfetch.v",    "$fuse\twn_act_rd.v",
    "$fuse\twn_act_wr.v",      "$fuse\twn_act_gather.v","$fuse\twn_act_scatter.v",
    "$fuse\twn_res_add.v",     "$fuse\twn_frameseq.v",  "$fuse\twn_csr.v",
    "$fuse\twn_desctab.v",     "$fuse\twn_uop_enc.v",   "$fuse\twn_uop_issue.v",
    "$fuse\twn_dw_pack.v",     "$fuse\twn_ring_warb.v", "$fuse\twn_dwseq.v",
    "$fuse\twn_res_buf.v")

# name        = the FILE, without .v
# top         = the module inside it, when that differs from the file name
# what        = one line, printed with the result, so a green line says what it covers
# hex         = files it $readmemh's, copied into the work dir (empty for most)
# breaks      = @{ define = "..."; why = "what the defect is" }
# gen         = a generator in rtl\fuse\tb to run first (once per invocation)
$targets = @(
    @{ name="tb_uop_enc";       gen="gen_uop_cases.py"
       what="micro-op encoder: 17 blocks x 2 stages, every field + the three bases, with the descriptor's real pack0/msg (tail-pack appendix in the project base)"
       breaks=@(@{define="UOP_NEG_PROJBASE";   why="project's weight base ignores the expand's run"},
                @{define="UOP_NEG_RQBASE_OCG"; why="requant base per output-channel group, not dense (only where pack_e != 4)"},
                @{define="UOPENC_TB_NEG_TIED_OFF"; why="[testbench] pack0/msg tied to zero, as this bench had them until 2026-10-05: [90:88] and the tail-packed expands' project base go wrong"}) },
    @{ name="tb_uop_issue";     what="one micro-op per request: no double-issue, no missed request, none during a flush"
       breaks=@(@{define="UOP_NEG_NO_SCAT_HOLD"; why="the next row is issued while the scatter still owes the previous row its flush"}) },
    @{ name="tb_dwseq";         gen="gen_uop_cases.py"
       what="depthwise walk: order, coverage, tap hold, the REQUANT ADDRESS WINDOW {3,4}, row-buffer address, re-arm; block 0 at the hardware's 128 columns"
       breaks=@(@{define="DWSEQ_TB_NEG_RQ_LAG5"; why="[testbench] one register in front of the window check == twn_dwseq with RQ_LAG 5: the next group's first column gets the previous group's constants (the old check passed this)"},
                @{define="DWSEQ_NEG_NO_SPENT";   why="a held request restarts the walk -- the row is issued twice"},
                @{define="DWSEQ_NEG_RQ_NOLAG";   why="the requant address comes straight off the walk, so every lane group's last 3 columns are requantised with the NEXT group's constants"},
                @{define="DWSEQ_NEG_BOFF_SHIFT16"; why="the lane group is scaled by RB_T1's 16-byte word instead of DW_LANES=8, so every group after the first reads twice its own offset -- this gate's ADDRESS check was DOCUMENTED AND ABSENT (addr_err declared, cleared, never incremented), so this defect once passed the whole unit suite 21/0 and only tb_fuse_frame saw it, at 0 of 17"}) },
    @{ name="tb_dw_pack";       gen="gen_uop_cases.py"
       what="where a depthwise output lands in RingC (word/lane/replication); block 0 at 128 columns"
       breaks=@(@{define="DWP_TB_NEG_WORD6"; why="[testbench] the word index instantiated 6 bits wide: rows over 64 words (blocks 2, 11, 12) wrap onto their own head"}) },
    @{ name="tb_ring_warb";     what="RingA/RingC write arbiter: conservation over what was PRESENTED, B never stalled, a_can is a PROMISE, a_dropped can fire"
       breaks=@(@{define="WARB_NEG_LOSSY"; why="the arbiter promises unconditionally and throws away what it cannot take -- the shipped design, which lost 93 of block 0's 7,216 loader writes every frame"}) },
    @{ name="tb_rowbuf_lanewr"; what="lane-at-a-time writes == word-at-a-time, in the depthwise's scrambled order"
       breaks=@(@{define="RBLW_TB_NEG_NO_LANEWR"; why="[testbench] the buffer instantiated without LANE_WR: its own word counter, whole words, wr_word_i/wr_lane ignored"}) },
    @{ name="tb_rowbuf_extmem"; what="EXT_MEM row buffer == internal storage, bit for bit" },
    @{ name="tb_rowbuf_mod3";   top="tb_mod3"; what="twn_rowbuf's OWN mod3 / q3_2 (called on an instance), every 11-bit row"
       breaks=@(@{define="MOD3_TB_NEG_NO_S3"; why="[testbench] the function under test swapped for a copy without the last fold's >= 3 correction"}) },
    @{ name="tb_rowbuf_ring";   what="ring pointers, credit, and the top/bottom padding rows" },
    @{ name="tb_rowbuf_slice";  what="MEM_SLICE storage == one flat array, bit for bit, at RB_T1's geometry"
       breaks=@(@{define="RB_NEG_SLICE_COMB"; why="the slice multiplexer selects on the current address rather than the one the registered data came from -- one wrong word every time a read walk crosses a 512-word boundary"}) },
    @{ name="tb_rowptr_rule";   what="the pointer rule itself, against an independent model"
       breaks=@(@{define="BAD_NAIVE_RPTR"; why="[testbench] the rule's naive rptr += s form"},
                @{define="BAD_NO_CAP";     why="[testbench] the fire threshold without its min(.., h_in) cap"}) },
    @{ name="tb_desctab";       what="descriptor table: 32-byte load, per-block fields, prefetch index" },
    @{ name="tb_csr_axil_b2b";  what="twn_csr AXI4-Lite: back-to-back writes and reads each land and each get a response; the descriptor window does not alias at a[12]"
       breaks=@(@{define="CSR_NEG_READY_LATE"; why="ready computed from the registered flags, still 1 one cycle after its handshake -- the second back-to-back write overwrites the first and gets no response (the code before 2026-10-06)"}) },
    @{ name="tb_frameseq";      what="frame sequencer: 17 blocks, compute of b overlapped with prefetch of b+1" },
    @{ name="tb_act_gather";    what="activation gather: [x][c] addressing across every block geometry, plus block 0's 3x3 stride-2 stem"
       hex=@("tb_act_gather_stem_row.hex", "tb_act_gather_stem_act.hex"); gen="gen_gather_cases.py"
       breaks=@(@{define="GATH_NEG_NO_TRANSPOSE"; why="the stem's nine taps reach the array in the row's order, not the weights'"},
                @{define="GATH_NEG_NO_LPAD";      why="the stem's left column is clamped but the lane mapping is not slid with it"},
                @{define="GATH_NEG_NO_PADROW";    why="the stem's top pad pass gathers a real row instead of zeros"},
                @{define="GATH_NEG_NO_SRC_TAG";   why="the two-word cache is tagged by word index alone, so a stem pass is served the PREVIOUS kernel row's bytes"}) },
    @{ name="tb_act_scatter";   what="activation scatter: pack masking, write-enable pattern, a ONE-CYCLE row-end request, and BACK-TO-BACK beats"; gen="gen_scatter_cases.py"
       breaks=@(@{define="SCAT_NEG_FLUSH_PULSE"; why="the row end is served only if the drain is idle on that exact cycle"},
                @{define="SCAT_NEG_DRAIN_WINS";  why="the drain's terminal d_run<=0 overwrites the next group's restart -- clean at half rate, a whole pixel group lost back to back"}) },
    @{ name="tb_act_rt";        what="activation read/write masters against an AXI model, INCLUDING a sink that refuses -- the loader must stall the R channel, not drop the word"
       breaks=@(@{define="ACTRD_NEG_NO_BP"; why="twn_act_rd passes s_ready(1'b1) and emits a word every 8 beats whatever the ring says -- the shipped loader"}) },
    @{ name="tb_res_add";       what="residual add: saturation and the int8 range"; hex=@("tb_res_add_vec.hex"); gen="gen_res_add.py"
       breaks=@(@{define="RES_NEG_UPPER_LANES"; why="the round bit dropped on lanes 4 and up -- invisible to a four-lane-only gate"}) },
    @{ name="tb_res_buf";       what="residual row store: 32 rows through a 10-row ring at the deployed size, against a flat model, plus the too-shallow detector"
       breaks=@(@{define="RESBUF_NEG_NO_WRAP";  why="the ring slot wraps on its own bit width, not on DEPTH -- invisible at a power-of-two depth"},
                @{define="RESBUF_NEG_NO_STALE"; why="a ring one row too shallow returns the wrong row and nothing says so"}) },
    @{ name="tb_wfetch";        what="weight fetch: every word, address and count for 17 blocks, plus the AXI AR rules (INCR, <= 256 beats, no 4 KB crossing). Not twn_wmem, not double buffering"
       hex=@("tb_wfetch_ddr.hex"); gen="gen_wfetch_tb.py"
       breaks=@(@{define="AXIRD_NEG_NO_4K";      why="twn_axi_rd without its 4 KB split: the data is still right, only the AR check sees it (it passed before 2026-10-05)"},
                @{define="WFETCH_TB_NEG_BASE16"; why="[testbench] the DDR base one beat off: every word from the wrong bytes, every address right"}) },
    @{ name="tb_fuse_rq_round"; what="requant rounding at the 11-bit window's edges (the 2.5e-6 overflow) and at the clamp's edges"
       breaks=@(@{define="RQ_NEG_WINDOW11"; why="the round added inside 11 bits, as before 2026-08-12: 1023 + 1 wraps, 127 becomes 0 / -127"},
                @{define="RQ_NO_ROUND";     why="truncation instead of rounding -- invisible at the saturating edges alone, so the in-range values are what catch it"}) },
    # kind="measure": prints a number, not a verdict, so ALL PASS is not required of it.
    # It still fails if it prints no "===" line.
    @{ name="tb_p4_schedule"; kind="measure"
       what="block schedule: stage overlap, array utilisation, where the idle cycles go" }
)

if ($Only -ne "") { $targets = $targets | Where-Object { $_.name -like "$Only*" } }
if ($targets.Count -eq 0) { Write-Output "no target matches -Only '$Only'"; exit 1 }

# Runs one testbench, optionally with a define. Returns a hashtable:
#   ok      did it print ALL PASS
#   verdict the line it printed, or why there wasn't one
function Invoke-Gate([string]$n, [string]$top, [string[]]$hex, [string]$define, [string]$kind) {
    if (-not $top) { $top = $n }
    foreach ($p in $hex) { Copy-Item "$fuse\tb\$p" . -Force -ErrorAction SilentlyContinue }
    $lib = if ($define) { "${n}_neg" } else { $n }
    foreach ($d in @($lib, "s_$lib")) {
        if (Test-Path $d) { Remove-Item -Recurse -Force -LiteralPath $d -ErrorAction SilentlyContinue }
    }

    # The quotes around a -d argument are needed: xvlog is a .bat wrapper and cmd splits on '='
    # unless quoted. Defines here are bare names.
    $a = @("--nolog", "-sv", "-work", $lib, "-i", "$fuse\tb")
    if ($define) { $a += @("-d", "`"$define`"") }
    $a += $src + @("$fuse\tb\$n.v")

    $r = & xvlog.bat @a 2>&1 | Out-String
    if ($r -match "ERROR") { return @{ ok=$false; verdict="COMPILE ERROR"; log=$r } }
    $r = & xelab.bat --nolog -debug off -L $lib -s "s_$lib" "$lib.$top" 2>&1 | Out-String
    if ($r -match "ERROR") { return @{ ok=$false; verdict="ELABORATE ERROR"; log=$r } }
    $r = & xsim.bat "s_$lib" --nolog --runall 2>&1 | Out-String

    # A testbench whose image failed to load prints "0 errors" and looks like success,
    # so the verdict line is required.
    $v = ($r -split "`r?`n" | Where-Object { $_ -match "^===" } | Select-Object -Last 1)
    if (-not $v) { return @{ ok=$false; verdict="NO VERDICT LINE -- nothing was checked"; log=$r } }
    # A measurement has no verdict to give; anything else must say ALL PASS.
    $good = if ($kind -eq "measure") { $true } else { $v -match "ALL PASS" }
    return @{ ok = $good; verdict = $v.Trim(); log = $r }
}

$pass = 0; $fail = 0; $bpass = 0; $bfail = 0; $bad = @()
$genDone = @{}

foreach ($t in $targets) {
    $n = $t.name
    if ($t.gen) {
        if (-not $genDone.ContainsKey($t.gen)) {
            $go = & $py (Join-Path "$fuse\tb" $t.gen) 2>&1 | Out-String
            $genDone[$t.gen] = @{ ok = ($LASTEXITCODE -eq 0); log = $go }
            if (-not $Quiet) { Write-Output ("  (generated: {0})" -f $t.gen) }
        }
        if (-not $genDone[$t.gen].ok) {
            Write-Output $genDone[$t.gen].log
            $fail++; $bad += $n
            Write-Output ("  {0,-20} FAIL   generator {1} failed -- the case file would describe other weights" -f $n, $t.gen)
            continue
        }
    }
    $g = Invoke-Gate $n $t.top $t.hex $null $t.kind
    # -Quiet suppresses the passing detail, never the failing log.
    if (-not $g.ok) { Write-Output $g.log }
    if ($g.ok) {
        $pass++
        Write-Output ("  {0,-20} {1}   {2}" -f $n,
                      $(if ($t.kind -eq "measure") { "MEAS" } else { "PASS" }), $t.what)
        if (-not $Quiet -or $t.kind -eq "measure") { Write-Output ("  {0,-20}        {1}" -f "", $g.verdict) }
    } else {
        $fail++; $bad += $n
        Write-Output ("  {0,-20} FAIL   {1}" -f $n, $g.verdict)
    }

    if ($NoBreak -or -not $t.breaks) { continue }
    foreach ($b in $t.breaks) {
        $g = Invoke-Gate $n $t.top $t.hex $b.define $t.kind
        # Inverted on purpose: the defect is injected, so FAIL is the pass.
        if ($g.verdict -match "COMPILE ERROR|ELABORATE ERROR|NO VERDICT") {
            $bfail++; $bad += "$n/$($b.define)(broken run)"
            Write-Output ("    break {0,-24} GATE BROKEN  {1}" -f $b.define, $g.verdict)
        } elseif ($g.ok) {
            $bfail++; $bad += "$n/$($b.define)"
            Write-Output ("    break {0,-24} 🔴 STILL PASSES -- the gate cannot see {1}" -f $b.define, $b.why)
        } else {
            $bpass++
            Write-Output ("    break {0,-24} bites    {1}" -f $b.define, $b.why)
        }
    }
}

Write-Output ""
Write-Output ("=== fuse unit gates: {0} pass, {1} fail; break tests {2} bite, {3} did not ===" -f
              $pass, $fail, $bpass, $bfail)
Write-Output "    Unit gates only. The bit-exact, datapath, AXI and elaboration gates are separate scripts (see the header)."
if ($bad.Count -gt 0) { Write-Output ("    failing: " + ($bad -join ", ")) }
if ($fail -gt 0 -or $bfail -gt 0) { exit 1 }
