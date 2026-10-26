# run_hd_int.ps1 -- integrated-path gate for the head: twn_fuse_top with HD_PROBE = 1 (testbench
# tb\tb_hd_int.v), with destructive arms.
#
# What it covers beyond run_hd_frame.ps1 (engine alone, vectors driven directly) and run_hd_seq.ps1
# (sequencer alone): the CSR head window, the descriptor commit, the sequencer, the three movers, the
# AXI ports and the DDR model (tb\tb_ddr_model.v). It compares every byte the head writes into DDR
# with the golden vectors of rtl\fuse\tb\hd_vec. The requantisation tables are programmed through
# the CSR window at 0x0400 and read back out of the engine at each operator's start.
#
# Arms (only arm 1 and arm 6 are gates; no arm uses `force`):
#   1 intact                              four operators bit-exact (bytes compared are printed)
#   2 + HD_SEQ_BREAK_DRAIN                skips the write drain. Required to fail only when arm 1
#                                         printed "DRAINRACE reachable=1"; otherwise reported only.
#   3 + HD_SEQ_BREAK_PASS                 drops the mode-A input re-issue; must fail
#   4 + HD_INT_SKIP_RQ                    requant window not written; must fail and not be 4/4
#   5 intact, one golden byte flipped     must fail with one wrong byte at max|diff| 1 (localised)
#   6 + HD_INT_BB2HD                      BB2HD: A_BB2HD = 1, op61 reads input slot 1 and op64
#                                         writes heatmap box B (+0x40000); must be bit-exact
#   7 + HD_INT_BB2HD + FUSE_NEG_BB2HD_HDSEL   head slot taken from bb_par instead of ~bb_par; must fail
#
# Usage: powershell -ExecutionPolicy Bypass -File rtl\fuse\sim\run_hd_int.ps1
#          [-Quick]                       skip arms 3, 4 and 5
#          [-Defines "BFM_RLAT=40,BFM_STALL=3"]   bus timing of the DDR model (comma separated).
#                                         Allowed valued defines: BFM_RLAT, BFM_STALL, HD_INT_IDLE,
#                                         HD_INT_CYCLES; they are passed to xvlog quoted, then
#                                         compared with what the DDR model reports it built.
#          [-Label name]                  part of the work directory name
# Prerequisites: Vivado xvlog.bat / xelab.bat / xsim.bat. Generated inputs: rtl\fuse\tb\hd_vec,
#   produced by `python tools\hd_ref_export.py`. The script checks beat counts and the
#   op N output == op N+1 input chain of the vectors and exits 1 on a mismatch.
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin).
# Work directories: %TEMP%\twn_hdint_<label>_<arm>_<pid> (not deleted).
# Result: summary table, then HD_INT_GATE_PASS (exit 0) or HD_INT_GATE_FAIL (exit 1). Diagnostics
#   are printed with Write-Host inside Run(), because Write-Output there joins the return value.
param([string]$Defines = "", [switch]$Quick, [string]$Label = "default")

$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
$tree = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path   # derived from this script's location
$root = "$tree"
$fuse = "$root\rtl\fuse"
$ip   = "$root\rtl\src"
$rsrc = "$root\rtl\src"
$vec  = "$fuse\tb\hd_vec"

# Every module of twn_fuse_top, the head engine, the tri-port RAM and this gate's DDR model
# and testbench.
$src = @(
    "$fuse\twn_fuse_select.v", "$fuse\twn_fuse_tree.v", "$fuse\twn_fuse_requant.v",
    "$ip\bram_sdp.v",          "$ip\bram_sdp_bw.v",     "$rsrc\bram_tdp.v",
    "$fuse\twn_fuse_array.v",  "$fuse\twn_dw_array.v",  "$fuse\twn_blockseq.v",
    "$fuse\twn_rowbuf.v",      "$fuse\twn_rowbuf_rot.v","$fuse\twn_wmem.v",
    "$rsrc\twn_axi_rd.v",      "$rsrc\twn_axi_wr.v",    "$fuse\twn_wfetch.v",
    "$fuse\twn_act_rd.v",      "$fuse\twn_act_wr.v",    "$fuse\twn_act_gather.v",
    "$fuse\twn_act_scatter.v", "$fuse\twn_res_add.v",   "$fuse\twn_frameseq.v",
    "$fuse\twn_csr.v",         "$fuse\twn_desctab.v",   "$fuse\twn_uop_enc.v",
    "$fuse\twn_uop_issue.v",   "$fuse\twn_dw_pack.v",   "$fuse\twn_ring_warb.v",
    "$fuse\twn_dwseq.v",       "$fuse\twn_res_buf.v",
    "$rsrc\twn_hd_compute.v",  "$fuse\twn_hd_seq.v",    "$fuse\twn_fuse_top.v",
    "$fuse\tb\tb_ddr_model.v", "$fuse\tb\tb_hd_int.v")

# The beat counts tb_hd_int.v hard-codes (the same table as run_hd_frame.ps1), checked before a
# simulator starts.
$expect = [ordered]@{
    "hd_op61_in.hex"  =  1280; "hd_op61_w.hex" = 10240; "hd_op61_out.hex" =   512
    "hd_op62_in.hex"  =   512; "hd_op62_w.hex" =  1024; "hd_op62_out.hex" =  2048
    "hd_op63_in.hex"  =  2048; "hd_op63_w.hex" =  1024; "hd_op63_out.hex" =  8192
    "hd_op64_in.hex"  =  8192; "hd_op64_w.hex" =    32; "hd_op64_out.hex" = 16384
    "hd_rq.hex"       =   128
}

# --- provenance -------------------------------------------------------------
# Print what is being compared (hash and time of each source, the vector manifest).
Write-Output "=== inputs ==="
foreach ($f in @("$fuse\twn_fuse_top.v", "$fuse\twn_hd_seq.v", "$fuse\twn_csr.v",
                 "$rsrc\twn_hd_compute.v", "$rsrc\twn_axi_rd.v", "$rsrc\twn_axi_wr.v",
                 "$fuse\tb\tb_hd_int.v", "$fuse\tb\tb_ddr_model.v")) {
    if (-not (Test-Path $f)) { Write-Output "MISSING $f"; exit 1 }
    $h = (Get-FileHash $f -Algorithm SHA256).Hash.Substring(0,16).ToLower()
    $t = (Get-Item $f).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
    Write-Output ("  {0}  {1}  {2}" -f $h, $t, (Split-Path $f -Leaf))
}
if (-not (Test-Path $vec)) {
    Write-Output "MISSING $vec -- run: python tools\hd_ref_export.py"
    exit 1
}
$manp = Join-Path $vec "hd_vec_manifest.json"
if (Test-Path $manp) {
    $man = Get-Content $manp -Raw | ConvertFrom-Json
    Write-Output ("  vectors generated {0}  fixture {1}  git {2}" -f `
                  $man.generated_utc, $man.fixture, $man.git)
}
$bad = 0
foreach ($k in $expect.Keys) {
    $p = Join-Path $vec $k
    if (-not (Test-Path $p)) { Write-Output "  MISSING vector $k"; $bad++; continue }
    $n = (Get-Content $p | Measure-Object -Line).Lines
    if ($n -ne $expect[$k]) {
        Write-Output ("  STALE  {0}: {1} beats, tb_hd_int.v assumes {2}" -f $k, $n, $expect[$k])
        $bad++
    }
}
if ($bad -gt 0) {
    Write-Output "vector set does not match the testbench -- rerun tools\hd_ref_export.py"
    exit 1
}
Write-Output ("  {0} vector files, all beat counts as expected" -f $expect.Count)

# Operator N's golden output must be operator N+1's input file: this gate feeds op62 from what op61
# actually wrote to DDR, so a broken chain would score the design against unrelated references.
foreach ($pair in @(@("hd_op61_out.hex","hd_op62_in.hex"),
                    @("hd_op62_out.hex","hd_op63_in.hex"),
                    @("hd_op63_out.hex","hd_op64_in.hex"))) {
    $a = (Get-FileHash (Join-Path $vec $pair[0]) -Algorithm SHA256).Hash
    $b = (Get-FileHash (Join-Path $vec $pair[1]) -Algorithm SHA256).Hash
    if ($a -ne $b) { Write-Output ("  CHAIN BROKEN: {0} != {1}" -f $pair[0], $pair[1]); exit 1 }
    Write-Output ("  chain {0} == {1}  sha {2}" -f $pair[0], $pair[1], $a.Substring(0,16).ToLower())
}

# The embedded quotes are needed: xvlog is a .bat wrapper and cmd splits an argument on '='
# unless it is quoted, so a plain `-d BFM_RLAT=40` arrives as `-d BFM_RLAT` plus a file named `40`.
$defWant = @{}
$defArgs = @()
foreach ($d in ($Defines -split '[,\s]+' | Where-Object { $_ -ne "" })) {
    if ($d -match '^(BFM_RLAT|BFM_STALL|HD_INT_IDLE|HD_INT_CYCLES)=(\d+)$') {
        $defArgs += @("-d", "`"$d`"")
        $defWant[$Matches[1]] = [int]$Matches[2]
    } elseif ($d -match '=') {
        Write-Output "valued define '$d' is not in the allow-list; it cannot survive xvlog on Windows"
        exit 1
    } else {
        $defArgs += @("-d", $d)
    }
}
# What the bus model is asked for, and what it will actually be if nothing is.
$wantRlat  = if ($defWant.ContainsKey("BFM_RLAT"))  { $defWant["BFM_RLAT"] }  else { 0 }
$wantStall = if ($defWant.ContainsKey("BFM_STALL")) { $defWant["BFM_STALL"] } else { 0 }
Write-Output ("  bus model requested: RLAT={0} STALL={1}" -f $wantRlat, $wantStall)

# Diagnostics inside a function are Write-Host, not Write-Output: Write-Output joins the return
# value and would hide the reason behind an "ERR" verdict.
function Run([string]$tag, [string[]]$extra, [bool]$perturb) {
    $work = Join-Path $env:TEMP ("twn_hdint_" + $Label + "_" + $tag + "_" + $PID)
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    Copy-Item (Join-Path $vec "*.hex") $work
    if ($perturb) {
        # One nibble of one golden byte, as in run_hd_frame.ps1: beat 4096 of op63's output,
        # byte 0's low nibble. XOR 1 moves that int8 by exactly +-1, so op63 must report
        # "bytes wrong 1 ... max|diff| 1". Only op63's score can move: op64 is fed from what op63
        # wrote to DDR, not from this file.
        $p = Join-Path $work "hd_op63_out.hex"
        $lines = Get-Content $p
        $old = $lines[4096]
        $nib = [Convert]::ToInt32($old.Substring(31,1), 16)
        $lines[4096] = $old.Substring(0,31) + ("{0:x}" -f ($nib -bxor 1))
        Set-Content -Path $p -Value $lines -Encoding ascii
        Write-Host ("  perturbed hd_op63_out.hex beat 4096: {0} -> {1}" -f $old, $lines[4096])
    }
    Set-Location $work
    $a = @("--nolog","-sv") + $defArgs + $extra + @("-i","$fuse\tb") + $src
    $r = & xvlog.bat @a 2>&1 | Out-String
    if ($r -match "ERROR") { return @{v="ERR"; out=("COMPILE ERROR`n" + $r); exact=0} }
    $r = & xelab.bat --nolog -debug typical -s s tb_hd_int 2>&1 | Out-String
    if ($r -match "ERROR") { return @{v="ERR"; out=("ELAB ERROR`n" + $r); exact=0} }
    $o = & xsim.bat s -runall --nolog 2>&1 | Out-String
    $verdict = "UNKNOWN"
    if ($o -match "tb_hd_int: PASS")               { $verdict = "PASS" }
    elseif ($o -match "tb_hd_int: (\d+) FAILURES") { $verdict = "FAIL($($Matches[1]))" }
    # How many operators were bit-exact.
    $exact = ([regex]::Matches($o, "BIT-EXACT")).Count
    # Did the bus timing arrive? Read from the DDR model's own parameters, because a dropped define
    # would silently turn a back-pressure run into a zero-latency run.
    $rlat = -1; $stall = -1
    if ($o -match "BUS MODEL RLAT=(\d+) STALL=(\d+)") {
        $rlat = [int]$Matches[1]; $stall = [int]$Matches[2]
    }
    # Is the write-drain race reachable in this environment? Measured by the testbench.
    $reach = -1; $mdrain = -1; $mgap = -1
    if ($o -match "DRAINRACE reachable=(\d+) maxdrain=(-?\d+) maxgap=(-?\d+)") {
        $reach = [int]$Matches[1]; $mdrain = [int]$Matches[2]; $mgap = [int]$Matches[3]
    }
    return @{ v = $verdict; out = $o; exact = $exact; rlat = $rlat; stall = $stall;
              reach = $reach; mdrain = $mdrain; mgap = $mgap }
}

# Print the per-operator report, not only the verdict line. A compile or elaboration failure is
# printed whole, because the filter below would drop the error lines.
function Show($r) {
    if ($r.v -eq "ERR") { Write-Output $r.out; return }
    # [twn_csr] is in the filter so the window-disjointness check's verdict is visible when it
    # passes.
    ($r.out -split "`r?`n" | Where-Object {
        $_ -match "^(op6|      |  |---|===|FAIL|\[tb_hd_int\]|\[twn_csr\])" }) |
        ForEach-Object { Write-Output $_ }
}

Write-Output ""
Write-Output "############ arm 1: INTACT -- this one is the gate ############"
$a1 = Run "intact" @() $false
Show $a1

Write-Output ""
Write-Output "############ arm 2: intact + HD_SEQ_BREAK_DRAIN (destructive) ############"
Write-Output "#  Skips the write drain only. The mode-A re-issue is left alone, so this"
Write-Output "#  arm fails on the DRAIN or not at all -- it can no longer die of"
Write-Output "#  starvation and be scored as a catch."
Write-Output "#"
Write-Output "#  🔴 WHETHER IT CAN FAIL AT ALL IS A MEASUREMENT, NOT AN ASSUMPTION."
Write-Output "#  The race needs the residual write drain (e_done -> m_out_done) to"
Write-Output "#  outlast the gap to the next e_start. Arm 1 prints both numbers as"
Write-Output "#  DRAINRACE reachable=/maxdrain=/maxgap=, and the verdict below REQUIRES"
Write-Output "#  this arm to fail only when reachable=1. Measured 2026-08-15: it is 0 --"
Write-Output "#  twn_axi_wr has no write FIFO and tb_ddr_model answers B on wlast, so"
Write-Output "#  the drain is a couple of cycles while the requant reload alone is ~68."
Write-Output "#  That is a fact about this bench, and the rule turns itself back on if a"
Write-Output "#  FIFO or a real interconnect ever changes it. The directed test for the"
Write-Output "#  race is tb_hd_seq.v check 3, which holds the drain off for 200 cycles."
$a2 = Run "brk" @("-d","HD_SEQ_BREAK_DRAIN") $false
Show $a2

if (-not $Quick) {
    Write-Output ""
    Write-Output "############ arm 3: intact + HD_SEQ_BREAK_PASS (destructive) ############"
    Write-Output "#  Drops the mode-A input re-issue only. op61 is fed a sixteenth of its"
    Write-Output "#  input; the drain wait is left alone."
    $a3 = Run "brk_pass" @("-d","HD_SEQ_BREAK_PASS") $false
    Show $a3

    Write-Output ""
    Write-Output "############ arm 4: intact + HD_INT_SKIP_RQ (destructive) ############"
    Write-Output "#  The requantisation window is not written at all. If this still reports"
    Write-Output "#  4/4 bit-exact, the tables are not load-bearing and arm 1 proves nothing"
    Write-Output "#  about them."
    $a4 = Run "no_rq" @("-d","HD_INT_SKIP_RQ") $false
    Show $a4

    Write-Output ""
    Write-Output "############ arm 5: intact, ONE golden byte flipped ############"
    Write-Output "#  Proves the comparison walks real data and localises."
    $a5 = Run "pert" @() $true
    Show $a5
    $loc5 = ($a5.out -match "bytes compared 131072   bytes wrong 1   max\|diff\| 1")
}

# BB2HD: the head with A_BB2HD[0] = 1. Out of reset bb_par = 0, so the head latches hd_sel = 1:
# op61 must read input slot 1 (slot 0 is left X) and op64 must write heatmap box B, +0x40000 past the
# base it was committed with. Arm 7 swaps the latch (hd_sel = bb_par) and must fail.
Write-Output ""
Write-Output "############ arm 6: BB2HD, A_BB2HD = 1 -- a gate ############"
$a6 = Run "bb2hd" @("-d","HD_INT_BB2HD") $false
Show $a6
Write-Output ""
Write-Output "############ arm 7: BB2HD + FUSE_NEG_BB2HD_HDSEL (destructive) ############"
$a7 = Run "bb2hd_brk" @("-d","HD_INT_BB2HD","-d","FUSE_NEG_BB2HD_HDSEL") $false
Show $a7

Write-Output ""
Write-Output "=================== summary ==================="
Write-Output ("bus model                        RLAT={0} STALL={1}   (requested {2}/{3})" -f `
              $a1.rlat, $a1.stall, $wantRlat, $wantStall)
Write-Output ("arm 1  intact                    = {0}   bit-exact operators {1}/4   (the gate)" -f $a1.v, $a1.exact)
# Whether arm 2 may pass is the testbench's measurement: reachable=1 means the race can occur and
# the arm must catch it.
$drainRule = if ($a1.reach -eq 1) { "must NOT be PASS" }
             else { "race unreachable here (maxdrain=$($a1.mdrain) < maxgap=$($a1.mgap)); reported, not required" }
Write-Output ("arm 2  + HD_SEQ_BREAK_DRAIN      = {0}   bit-exact operators {1}/4   ({2})" -f $a2.v, $a2.exact, $drainRule)
if (-not $Quick) {
    Write-Output ("arm 3  + HD_SEQ_BREAK_PASS       = {0}   bit-exact operators {1}/4   (must NOT be PASS)" -f $a3.v, $a3.exact)
    Write-Output ("arm 4  + HD_INT_SKIP_RQ          = {0}   bit-exact operators {1}/4   (must NOT be 4/4)" -f $a4.v, $a4.exact)
    Write-Output ("arm 5  one golden byte flipped   = {0}   bit-exact operators {1}/4   localised {2}" -f $a5.v, $a5.exact, $loc5)
}
Write-Output ("arm 6  BB2HD A_BB2HD = 1       = {0}   bit-exact operators {1}/4   (a gate)" -f $a6.v, $a6.exact)
Write-Output ("arm 7  BB2HD + NEG_BB2HD_HDSEL = {0}   bit-exact operators {1}/4   (must be FAIL(n))" -f $a7.v, $a7.exact)
Write-Output ""

# The verdict: arm 1 and arm 6 must be bit-exact, and every destructive arm must fail as listed in
# the header. Arm 2 is required to fail only when the testbench measured the drain race as reachable.
# The bus timing that arrived must equal the one requested.
$ok = ($a1.v -eq "PASS" -and $a1.exact -eq 4)
if (-not ($a6.v -eq "PASS" -and $a6.exact -eq 4)) { Write-Output ("arm 6 (BB2HD) is {0} with {1}/4 bit-exact." -f $a6.v, $a6.exact); $ok = $false }
if ($a7.v -notlike "FAIL(*") { Write-Output ("arm 7 is {0}, not FAIL(n): the gate has not been shown to see a wrong head slot." -f $a7.v); $ok = $false }
if ($a1.rlat -ne $wantRlat -or $a1.stall -ne $wantStall) {
    Write-Output ("BUS TIMING DID NOT ARRIVE: requested RLAT={0} STALL={1}, the model built RLAT={2} STALL={3}" -f `
                  $wantRlat, $wantStall, $a1.rlat, $a1.stall)
    $ok = $false
}
# A destructive arm counts only if it built, ran and reported failures ("FAIL(n)"). ERR (compile or
# elaboration error) and UNKNOWN (no verdict line) are not catches, and an arm that did not build is
# an error in its own right.
$armList = @(,@("arm 2", $a2))     # the leading comma keeps it a list of PAIRS
if (-not $Quick) { $armList += ,@("arm 3", $a3); $armList += ,@("arm 4", $a4); $armList += ,@("arm 5", $a5) }
foreach ($p in $armList) {
    if ($p[1].v -eq "ERR") { Write-Output ("{0} did not BUILD (compile/elab error, printed above) -- it tested nothing." -f $p[0]); $ok = $false }
}
if ($a1.reach -eq 1 -and $a2.v -notlike "FAIL(*") {
    Write-Output ("arm 2 is {0} while the drain race is REACHABLE -- the gate has not been shown to see a skipped write drain." -f $a2.v)
    $ok = $false
}
if ($a1.reach -lt 0) {
    Write-Output "arm 1 printed no DRAINRACE line -- the reachability measurement is missing."
    $ok = $false
}
if (-not $Quick) {
    if ($a3.v -notlike "FAIL(*") { Write-Output ("arm 3 is {0}, not FAIL(n): the gate has not been shown to see a starved mode-A input." -f $a3.v); $ok = $false }
    if ($a4.v -notlike "FAIL(*" -or $a4.exact -eq 4) { Write-Output ("arm 4 is {0} with {1}/4 bit-exact WITHOUT the requant tables programmed: not shown to be load-bearing." -f $a4.v, $a4.exact); $ok = $false }
    if ($a5.v -notlike "FAIL(*") { Write-Output ("arm 5 is {0} with a golden byte flipped: the comparison has not been shown to walk real data." -f $a5.v); $ok = $false }
}
if ($ok) {
    Write-Output "HD_INT_GATE_PASS -- the integrated head path is bit-exact"
    exit 0
}
Write-Output "HD_INT_GATE_FAIL -- the integrated head path is NOT bit-exact,"
Write-Output "  or a destructive arm the gate should catch went past it."
exit 1
