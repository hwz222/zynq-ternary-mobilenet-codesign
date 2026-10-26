# run_fuse_axi_boost.ps1 -- top-level AXI gate for twn_fuse_top (HD_PROBE_ON, the head engine
# included): the whole-frame bit-exact testbench tb_fuse_frame.
#
# REAL: twn_fuse_top entire (twn_csr, twn_desctab, twn_frameseq, twn_wfetch, the AXI masters, the head).
# MODEL: the DDR, rtl\fuse\tb\tb_ddr_model.v, with RLAT (read latency) and STALL (back-pressure) knobs.
# tb_fuse_frame: every byte the design writes to DDR over a whole frame, against the C reference
# output tensors (gold_out.hex); prints FRAME PASS and the issue-beat count.
# A run that checked nothing (no "N checks, M errors" line, or zero checks) is a failure.
#
# Usage: powershell -ExecutionPolicy Bypass -File rtl\fuse\sim\run_fuse_axi_boost.ps1 [options]
#   -Only tb_fuse_frame      run one stage (the only one)
#   -Cycles N                simulation budget (FUSE_FRAME_CYCLES)
#   -Defines "A,B=1"         extra xvlog defines, comma separated, passed quoted; e.g.
#                            "BFM_RLAT=40,BFM_STALL=3" for bus latency and back-pressure,
#                            FUSE_FRAME_ISOLATE (alias FUSE_FRAME_INJECT): each block is fed the
#                            reference's own input tensor instead of the design's chain,
#                            FRAME_ZERO_ACMEM, FUSE_STEM_ACT, FUSE_BLK_CYC, FUSE_CC_ROWS3,
#                            FUSE_FRAME_STAGE / FUSE_STAGE_BNN (see tb\tb_fuse_frame.v)
#   -Break DEFINE            run with one injected defect; FAIL is the pass. Defects:
#                            FUSE_NEG_INJECT_ZERO, FUSE_NEG_INJECT_SLOT, FUSE_NEG_RESPROBE
#                            (testbench, with FUSE_FRAME_ISOLATE), FUSE_NEG_RINGA_STRIDE,
#                            FUSE_NEG_DW_UNCOUNTED, FUSE_NEG_STEM_HASIN, FUSE_NEG_STEM_PADLAG (RTL)
#   -Label name              part of the work directory name and of the summary line
#   -NoHead                  compile without HD_PROBE_ON (no head engine; label gets _nohead)
#   -Quiet                   do not echo the simulator output
# Prerequisites: Vivado xvlog.bat / xelab.bat / xsim.bat. Generated inputs in rtl\fuse\tb:
#   ddr_w.hex, ddr_in_b*.hex, gold_out.hex and gold_index.vh, from tools\gen_fuse_ddr.py (after
#   tools\pack_fuse_weights.py and tools\gen_desctab.py). Only gold_out.hex is checked here.
#   Hex files are copied into the work directory; gold_b*_e/_d.hex, tb_p4_block_b*_goldp/_goldd.hex
#   are copied only if present (they are read under FUSE_FRAME_STAGE / FUSE_FRAME_ISOLATE).
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin).
# Work directory: %TEMP%\twn_sim\axitb_<label>_<pid> (per process and per label; not deleted).
# Result: one line per stage, then "=== fuse AXI gate [label]: N pass, M fail, K checks ===".
#   Exit 1 if any stage failed or nothing was checked. With -Break a stage that still passes is
#   reported as "STILL PASSES" and counts as a failure.
param([switch]$Quiet, [string]$Defines = "", [string]$Label = "default",
      [string]$Only = "", [string]$Cycles = "", [string]$Break = "",
      [switch]$NoHead)

$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
# The tree root is derived from this script's location (three levels up from rtl\fuse\sim).
$tree = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$fuse = Join-Path $tree "rtl\fuse"
$ip   = Join-Path $tree "rtl\src"   # the packaged IP dir is gitignored; rtl\src holds the same sources
$rsrc = Join-Path $tree "rtl\src"
# Per process and per label, so that concurrent runs do not delete each other's libraries.
$work = Join-Path "$env:TEMP\twn_sim" ("axitb_" + $Label + "_" + $PID)
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

# Every module of twn_fuse_top (the list of elab_top.ps1) plus this gate's DDR model.
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
    "$fuse\twn_res_buf.v",
    # The head engine (built with HD_PROBE_ON, see $defArgs below).
    "$fuse\twn_hd_seq.v",     "$rsrc\twn_hd_compute.v",
    # bram_tdp: true dual-port RAM used by twn_hd_compute.
    "$rsrc\bram_tdp.v",
    "$fuse\twn_fuse_top.v",
    "$fuse\tb\tb_ddr_model.v")

# Each stage: the testbench, the images it reads, the verdict string, and one line saying what it
# gates (printed with the result).
$targets = @(
    @{ name = "tb_fuse_frame"
       # gold_b*_e.hex / gold_b*_d.hex: read under -d FUSE_FRAME_STAGE (block chosen with
       # -d FUSE_STAGE_BNN). tb_p4_block_b*_goldp.hex / _goldd.hex: read under
       # -d FUSE_FRAME_ISOLATE (per-operand residual split and depthwise checks).
       hex  = @("ddr_w.hex", "ddr_in_b*.hex", "gold_out.hex",
                "gold_b*_e.hex", "gold_b*_d.hex", "tb_p4_block_b*_goldp.hex",
                "tb_p4_block_b*_goldd.hex")
       verdict = "FRAME PASS"
       what = "EVERY BYTE WRITTEN TO DDR, against the C reference, at write time" }
)

# gold_out.hex is generated; without it the frame gate's golden array is all X.
if (-not (Test-Path (Join-Path $fuse "tb\gold_out.hex"))) {
    Write-Output "gold_out.hex is missing. Run:  python tools/gen_fuse_ddr.py"
    exit 1
}

if ($Only -ne "") { $targets = $targets | Where-Object { $_.name -eq $Only } }
if ($targets.Count -eq 0) { Write-Output "no target matches -Only '$Only'"; exit 1 }

# The embedded quotes are needed: xvlog is a .bat wrapper and cmd splits an argument on '='
# unless it is quoted, so a plain `-d BFM_RLAT=40` arrives as `-d BFM_RLAT` plus a file named `40`.
$defArgs = @()
# The head engine is on by default; -NoHead compiles the design without it.
if (-not $NoHead) { $defArgs += @("-d", "`"HD_PROBE_ON`"") } else { $Label = $Label + "_nohead" }
foreach ($d in ($Defines -split ',' | Where-Object { $_ -ne "" })) { $defArgs += @("-d", "`"$d`"") }
# The break define goes in with the rest, and the label carries it too, so a break run never
# reuses a clean run's work directory.
if ($Break -ne "") {
    $defArgs += @("-d", "`"$Break`"")
    $Label = $Label + "_" + $Break
    $work  = Join-Path "$env:TEMP\twn_sim" ("axitb_" + $Label + "_" + $PID)
    New-Item -ItemType Directory -Force $work | Out-Null
    Set-Location $work
}
# Both stages take their budget from -Cycles, each under its own macro name.
if ($Cycles -ne "") {
    $defArgs += @("-d", "`"FUSE_BOOT_CYCLES=$Cycles`"")
    $defArgs += @("-d", "`"FUSE_FRAME_CYCLES=$Cycles`"")
}

$pass = 0; $fail = 0; $total = 0; $bad = @(); $notes = @()

foreach ($t in $targets) {
    $n = $t.name
    foreach ($pat in $t.hex) { Copy-Item "$fuse\tb\$pat" . -Force -ErrorAction SilentlyContinue }

    # Delete the library and the snapshot first, so a stale snapshot cannot report a pass.
    foreach ($d in @($n, "s_$n")) { if (Test-Path $d) { Remove-Item -Recurse -Force -LiteralPath $d } }

    $a = @("--nolog", "-sv", "-work", $n, "-i", "$fuse\tb") + $defArgs + $src + @("$fuse\tb\$n.v")
    $r = & xvlog.bat @a 2>&1 | Out-String
    if ($r -match "ERROR") {
        Write-Output $r
        $fail++; $bad += "$n(compile)"; continue
    }

    # -debug typical, not off: the testbenches read DUT memories and the DDR model's memories and
    # counters by hierarchical reference.
    $r = & xelab.bat --nolog -debug typical -L $n -s "s_$n" "$n.$n" 2>&1 | Out-String
    if ($r -match "ERROR") {
        Write-Output $r
        $fail++; $bad += "$n(elab)"; continue
    }

    $r = & xsim.bat "s_$n" --nolog --runall 2>&1 | Out-String

    # twn_dw_array reports a clamp-bound assertion repeatedly in some configurations; those lines are
    # filtered out of the echo and counted in the notes below.
    $lines = $r -split "`r?`n"
    $noise = @($lines | Where-Object { $_ -match "twn_dw_array: clamp" }).Count
    if (-not $Quiet) {
        $lines | Where-Object { $_ -notmatch "twn_dw_array: clamp" } | ForEach-Object { Write-Output $_ }
    }
    if ($noise -gt 0) {
        $notes += ("{0}: {1} 'twn_dw_array: clamp (0,0) is not (0,127)' assertions -- the tie-off, not the design" -f $n, $noise)
    }

    if ($r -match "(\d+) checks, (\d+) errors") {
        $chk = [int]$Matches[1]; $err = [int]$Matches[2]; $total += $chk
        $ok = ($err -eq 0) -and ($chk -gt 0) -and ($r -match [regex]::Escape($t.verdict))
        if ($Break -ne "") {
            # Inverted on purpose: the defect is injected, so FAIL is the pass.
            if ($ok) {
                $fail++; $bad += "$n/$Break(STILL PASSES)"
                Write-Output ("  {0,-16} {1,6} checks  🔴 STILL PASSES with {2} defined -- the gate cannot see it" -f $n, $chk, $Break)
            } elseif ($chk -eq 0) {
                $fail++; $bad += "$n/$Break(broken run)"
                Write-Output ("  {0,-16} GATE BROKEN with {1} defined -- nothing was checked" -f $n, $Break)
            } else {
                $pass++
                Write-Output ("  {0,-16} {1,6} checks  {2} errors  BREAK BITES   {3}" -f $n, $chk, $err, $Break)
            }
        } elseif ($ok) {
            $pass++
            Write-Output ("  {0,-16} {1,6} checks  {2}   {3}" -f $n, $chk, $t.verdict, $t.what)
        } else {
            $fail++; $bad += $n
            Write-Output ("  {0,-16} {1,6} checks  {2} errors  FAIL   {3}" -f $n, $chk, $err, $t.what)
        }
        if ($r -match "frame: (.+) ===") { $notes += ("{0}: frame {1}" -f $n, $Matches[1].Trim()) }
    } else {
        # No result line (or one without counts): nothing was checked, which is a failure.
        $fail++; $bad += "$n(no result line)"
        Write-Output ("  {0,-16} produced no result line -- NOTHING WAS CHECKED" -f $n)
    }
}

Write-Output ""
Write-Output ("=== fuse AXI gate [" + $Label + "]: " + $pass + " pass, " + $fail +
              " fail, " + $total + " checks ===")
foreach ($nn in $notes) { Write-Output ("    " + $nn) }
if ($bad.Count -gt 0) { Write-Output ("    failing: " + ($bad -join ", ")) }
if ($fail -gt 0 -or $total -eq 0) { exit 1 }
