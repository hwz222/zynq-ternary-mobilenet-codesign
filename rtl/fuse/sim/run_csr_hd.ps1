# run_csr_hd.ps1 -- unit gate for the head engine's register interface (twn_csr + twn_hd_seq,
# testbench tb\tb_csr_hd.v), with three destructive arms.
#
# Four runs: the intact arm must PASS; each defect arm must fail with a named failure.
#   CSR_HD_BREAK_ASYM    swaps hd_busy and hd_done_l in the HD_CTRL read data, so the read layout
#                        no longer matches the write side.
#   CSR_HD_BREAK_STREAM  pulses hd_d_we on every descriptor field write instead of only on the
#                        commit, so twn_hd_seq stores partial entries. This arm may end on
#                        twn_hd_seq's own mode-A capacity assertion before the testbench summary.
#   CSR_HD_BREAK_RQWIN   moves the requantisation window from 0x0400 to 0x1400, which overlaps the
#                        block descriptor window (0x1000..0x17ff). twn_csr's window-disjointness
#                        check must catch it before any transaction runs.
# Defines are valueless: on Windows `xvlog -d NAME=VALUE` splits on '='.
#
# Usage: powershell -ExecutionPolicy Bypass -File rtl\fuse\sim\run_csr_hd.ps1
# Prerequisites: Vivado xvlog.bat / xelab.bat / xsim.bat. No generated inputs.
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin);
#   TWN_SIM_KEEP = if set, keep the work directory %TEMP%\twn_csrhd_<pid>.
# Result: prints one verdict per arm, then CSR_HD_GATE_SELFTEST_PASS (exit 0) or
#   CSR_HD_GATE_SELFTEST_FAIL (exit 1). An arm that did not build or printed no verdict is a failure.
$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
$tree = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path   # derived from this script's location
$root = "$tree"
# Every arm's work directory sits under one per-process parent, removed at the end unless
# TWN_SIM_KEEP is set.
$workRoot = Join-Path $env:TEMP ("twn_csrhd_" + $PID)
function Run([string]$tag, [string[]]$defs) {
    $work = Join-Path $workRoot $tag
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    Set-Location $work
    # bram_sdp.v: twn_hd_seq holds the requantisation tables in one. xelab black-boxes an
    # instantiated module it was not given (a warning only), so every module must be listed.
    $a = @("--nolog","-sv") + $defs + @("$root\rtl\src\bram_sdp.v",
                                        "$root\rtl\fuse\twn_csr.v",
                                        "$root\rtl\fuse\twn_hd_seq.v",
                                        "$root\rtl\fuse\tb\tb_csr_hd.v")
    $r = & xvlog.bat @a 2>&1 | Out-String
    if ($r -match "ERROR") { Write-Host "$tag COMPILE ERROR"; Write-Host $r; return "ERR" }
    $r = & xelab.bat --nolog -debug off -s s tb_csr_hd 2>&1 | Out-String
    if ($r -match "ERROR") { Write-Host "$tag ELAB ERROR"; Write-Host $r; return "ERR" }
    $o = & xsim.bat s -runall --nolog 2>&1 | Out-String
    # Echo the first few named failures and every CAUSE line, and count the rest, so the reason an
    # arm stopped is visible.
    # Write-Host, not Write-Output: inside a function Write-Output joins the return value and
    # would turn the verdict comparisons into comparisons against an array.
    $named = @(); $shown = 0
    foreach ($l in ($o -split "`r?`n")) {
        if ($l -match "^FAIL: ") {
            $named += $l
            if ($shown -lt 6) { Write-Host "    $tag | $l"; $shown++ }
        }
        elseif ($l -match "^(FAIL hd_seq:|FAIL twn_csr:|\[twn_csr\]|tb_csr_hd: (CAUSE|TIMEOUT|requant))") {
            # [twn_csr] shows the window-disjointness check's verdict when it passes too.
            Write-Host "    $tag | $l"
        }
    }
    if ($named.Count -gt $shown) {
        Write-Host "    $tag | ... and $($named.Count - $shown) more named failures"
    }
    if ($o -match "tb_csr_hd: PASS") { return "PASS" }
    if ($o -match "tb_csr_hd: (\d+) FAILURES") { return "FAIL($($Matches[1]))" }
    # A defect can trip another module's assertion before this bench summarises; report it as such.
    if ($o -match "FAIL twn_csr:") {
        return "FAIL(twn_csr window-disjointness check)"
    }
    if ($o -match "FAIL hd_seq:") {
        return "FAIL($($named.Count) + hd_seq mode-A assert)"
    }
    if ($named.Count -gt 0) { return "FAIL($($named.Count), no summary)" }
    return "UNKNOWN"
}
$good   = Run "good"   @()
$asym   = Run "asym"   @("-d","CSR_HD_BREAK_ASYM")
$stream = Run "stream" @("-d","CSR_HD_BREAK_STREAM")
$rqwin  = Run "rqwin"  @("-d","CSR_HD_BREAK_RQWIN")
Write-Output ""
Write-Output "intact              = $good     (must be PASS)"
Write-Output "CSR_HD_BREAK_ASYM   = $asym     (must NOT be PASS)"
Write-Output "CSR_HD_BREAK_STREAM = $stream   (must NOT be PASS)"
Write-Output "CSR_HD_BREAK_RQWIN  = $rqwin    (must NOT be PASS)"
Set-Location $env:TEMP
if (-not $env:TWN_SIM_KEEP) { Remove-Item -Recurse -Force -LiteralPath $workRoot -ErrorAction SilentlyContinue }
# A break arm counts only if it compiled, ran, and a failure was named (every catch Run() reports
# starts with "FAIL("). ERR (compile/elab error) and UNKNOWN (no verdict) are not catches.
$errArms = @()
foreach ($p in @(@("intact", $good), @("CSR_HD_BREAK_ASYM", $asym), @("CSR_HD_BREAK_STREAM", $stream), @("CSR_HD_BREAK_RQWIN", $rqwin))) {
    if ($p[1] -eq "ERR" -or $p[1] -eq "UNKNOWN") { $errArms += ("{0}={1}" -f $p[0], $p[1]) }
}
if ($errArms.Count -gt 0) {
    Write-Output ("CSR_HD_GATE_SELFTEST_FAIL -- arm(s) did not build or printed no verdict: " + ($errArms -join ", "))
    exit 1
}
if ($good -eq "PASS" -and $asym -like "FAIL(*" -and $stream -like "FAIL(*" -and $rqwin -like "FAIL(*") {
    Write-Output "CSR_HD_GATE_SELFTEST_PASS"; exit 0
}
Write-Output "CSR_HD_GATE_SELFTEST_FAIL -- the gate does not distinguish a defect"
exit 1
