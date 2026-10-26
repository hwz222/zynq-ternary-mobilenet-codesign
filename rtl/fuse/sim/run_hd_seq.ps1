# run_hd_seq.ps1 -- unit gate for twn_hd_seq (testbench tb\tb_hd_seq.v), with three destructive arms.
#
# Four runs: the intact sequencer must PASS; each defect arm must report failures.
#   HD_SEQ_BREAK_DRAIN  skips the write drain: the next operator starts before the writer has
#                       put the last beats in memory.
#   HD_SEQ_BREAK_PASS   drops the mode-A input re-issue (the input reader is not restarted for
#                       the remaining passes).
#   HD_SEQ_BREAK_RQOP   replays operator 0's requantisation table for every operator.
# Each define removes exactly one thing, so each arm can only fail for its own mechanism.
# Defines are valueless: on Windows `xvlog -d NAME=VALUE` splits on '='.
#
# Usage: powershell -ExecutionPolicy Bypass -File rtl\fuse\sim\run_hd_seq.ps1
# Prerequisites: Vivado xvlog.bat / xelab.bat / xsim.bat. No generated inputs.
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin);
#   TWN_SIM_KEEP = if set, keep the work directory %TEMP%\twn_hdseq_<pid>.
# Result: prints one verdict per arm, then HD_SEQ_GATE_SELFTEST_PASS (exit 0) or
#   HD_SEQ_GATE_SELFTEST_FAIL (exit 1). An arm that did not build or printed no verdict is a failure.
$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
$tree = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path   # derived from this script's location
$root = "$tree"
# bram_sdp.v is listed because twn_hd_seq holds the requantisation tables in one. xelab
# black-boxes an instantiated module it was not given (a warning only), so every module must be
# listed.
$srcs = @("$root\rtl\src\bram_sdp.v",
          "$root\rtl\fuse\twn_hd_seq.v",
          "$root\rtl\fuse\tb\tb_hd_seq.v")
# Every arm's work directory sits under one per-process parent, removed at the end unless
# TWN_SIM_KEEP is set.
$workRoot = Join-Path $env:TEMP ("twn_hdseq_" + $PID)
function Run([string]$tag, [string[]]$defs) {
    $work = Join-Path $workRoot $tag
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    Set-Location $work
    $a = @("--nolog","-sv") + $defs + $srcs
    $r = & xvlog.bat @a 2>&1 | Out-String
    if ($r -match "ERROR") { Write-Host "$tag COMPILE ERROR"; Write-Host $r; return "ERR" }
    $r = & xelab.bat --nolog -debug off -s s tb_hd_seq 2>&1 | Out-String
    if ($r -match "ERROR") { Write-Host "$tag ELAB ERROR"; Write-Host $r; return "ERR" }
    $o = & xsim.bat s -runall --nolog 2>&1 | Out-String
    # Echo the named failures and the CAUSE line, so the reason an arm stopped is visible.
    # Write-Host, not Write-Output: inside a function Write-Output joins the return value and
    # would turn the verdict comparisons into comparisons against an array.
    foreach ($l in ($o -split "`r?`n")) {
        if ($l -match "^(FAIL: |FAIL hd_seq:|tb_hd_seq: (CAUSE|TIMEOUT|input starts|requant))") {
            Write-Host "    $tag | $l"
        }
    }
    if ($o -match "tb_hd_seq: PASS") { return "PASS" }
    if ($o -match "tb_hd_seq: (\d+) FAILURES") { return "FAIL($($Matches[1]))" }
    return "UNKNOWN"
}
$good = Run "good"  @()
$brk  = Run "brk"   @("-d","HD_SEQ_BREAK_DRAIN")
$pas  = Run "pass"  @("-d","HD_SEQ_BREAK_PASS")
$rqop = Run "rqop"  @("-d","HD_SEQ_BREAK_RQOP")
Write-Output ""
Write-Output "intact               = $good   (must be PASS)"
Write-Output "HD_SEQ_BREAK_DRAIN   = $brk    (must NOT be PASS)"
Write-Output "HD_SEQ_BREAK_PASS    = $pas    (must NOT be PASS)"
Write-Output "HD_SEQ_BREAK_RQOP    = $rqop   (must NOT be PASS)"
Set-Location $env:TEMP
if (-not $env:TWN_SIM_KEEP) { Remove-Item -Recurse -Force -LiteralPath $workRoot -ErrorAction SilentlyContinue }
# A break arm counts only if it compiled, ran, and the bench reported FAILURES ("FAIL(n)").
# ERR (compile/elab error) and UNKNOWN (no verdict) are not catches.
$errArms = @()
foreach ($p in @(@("intact", $good), @("HD_SEQ_BREAK_DRAIN", $brk), @("HD_SEQ_BREAK_PASS", $pas), @("HD_SEQ_BREAK_RQOP", $rqop))) {
    if ($p[1] -eq "ERR" -or $p[1] -eq "UNKNOWN") { $errArms += ("{0}={1}" -f $p[0], $p[1]) }
}
if ($errArms.Count -gt 0) {
    Write-Output ("HD_SEQ_GATE_SELFTEST_FAIL -- arm(s) did not build or printed no verdict: " + ($errArms -join ", "))
    exit 1
}
if ($good -eq "PASS" -and $brk -like "FAIL(*" -and $pas -like "FAIL(*" -and $rqop -like "FAIL(*") {
    Write-Output "HD_SEQ_GATE_SELFTEST_PASS"; exit 0
}
Write-Output "HD_SEQ_GATE_SELFTEST_FAIL -- the gate does not distinguish a defect"
exit 1
