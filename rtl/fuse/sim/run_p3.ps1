# run_p3.ps1 -- gate for twn_dw_array: eight depthwise rows against the P1 golden vectors.
#
# Each case is one row of one block, chosen so that every boundary has its own case:
#   b02_r0 / b02_r63    stride 1, top pad / bottom pad
#   b00_r127            stride 1, bottom pad, 128 rows
#   b16_r0 / b16_r7     8x8 block, both edges, 960 channels
#   b01_r0 / b01_r31    stride 2, top pad / interior
#   b01_r63             stride 2, last row, no bottom pad
# Each case gets a fresh work library and snapshot. The testbenches are generated per run into the
# work directory by p1_golden\gen_tb.py from p1_golden\vec.
#
# Usage: .\run_p3.ps1 [-Defines A,B] [-Label name] [-Keep]
#   -Defines  comma-separated xvlog defines (for a break run with a deliberate defect)
#   -Label    text printed in the summary line;  -Keep  keep the work directory
# Prerequisites: Vivado xvlog.bat / xelab.bat / xsim.bat; Python.
# Generated inputs: p1_golden\vec\b00_in.bin and b16_out.bin must exist. Produce them from p1_golden
#   with `bash run_p1.sh` (Git Bash; it needs gcc and the model blob, and runs p0_fused first).
#   The script stops with MISSING if they are absent.
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin);
#   PYTHON = interpreter for gen_tb.py (default `python`).
# Work directory: %TEMP%\twn_sim\p3run_<pid>.
# Result: one line per case, then "=== P3 dw [label]: N pass, M fail (...) ===". Exit 0 only if all
#   eight cases built, checked more than zero values and printed ALL PASS. A case that did not
#   build is counted as a build error, not as a failed check.
param([string]$Defines = "", [string]$Label = "default", [switch]$Keep)

$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
$tree = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path   # derived from this script's location
$fuse = "$tree\rtl\fuse"
$gold = "$tree\golden\p1_golden"
# Per process: each case deletes its library before compiling, so concurrent runs must not share
# a directory. Removed at the end unless -Keep.
$work = Join-Path $env:TEMP ("twn_sim\p3run_" + $PID)
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

$cases = @("tb_p1_dw_b00_r127","tb_p1_dw_b01_r0","tb_p1_dw_b01_r31","tb_p1_dw_b01_r63",
           "tb_p1_dw_b02_r0","tb_p1_dw_b02_r63","tb_p1_dw_b16_r0","tb_p1_dw_b16_r7")

# The eight testbenches are generated here, into the work directory, from p1_golden\vec.
$py = if ($env:PYTHON) { $env:PYTHON } else { "python" }
# Check for generated vectors (outputs of run_p1.sh), not for tracked files.
foreach ($f in @("b00_in.bin", "b16_out.bin")) {
    if (-not (Test-Path "$gold\vec\$f")) {
        Write-Output "MISSING $gold\vec\$f -- the P1 golden vectors were never generated in this tree."
        Write-Output "  Run, in Git Bash from $tree :  ( cd p1_golden && bash run_p1.sh )   (README.md, step 1)"
        exit 1
    }
}
foreach ($t in $cases) {
    if ($t -match "^tb_p1_dw_b(\d\d)_r(\d+)$") {
        & $py "$gold\gen_tb.py" --dw ([int]$Matches[1]) --row ([int]$Matches[2]) -o "$work\$t.v" | Out-Null
    }
}
$gold = $work   # the cases and their _in.hex now live in the work directory

$defArgs = @()
foreach ($d in ($Defines -split ',' | Where-Object { $_ -ne "" })) { $defArgs += @("-d", $d) }

# Failures are counted by kind: a case that did not build (no input hex, compile or elaboration
# error) is a build error, not a failed check, so a break run is only meaningful when no build
# error is reported.
$pass = 0; $fail = 0; $bad = @(); $totalChecked = 0
$ranFail = 0; $buildErr = 0; $noResult = 0
foreach ($t in $cases) {
    if (-not (Test-Path "$t`_in.hex")) { Write-Output ("  {0,-22} input hex was not generated" -f $t); $fail++; $buildErr++; $bad += "$t(no input)"; continue }
    $lib = "w_$t"
    if (Test-Path $lib)   { Remove-Item -Recurse -Force -LiteralPath $lib }
    if (Test-Path "s_$t") { Remove-Item -Recurse -Force -LiteralPath "s_$t" }

    # twn_dw_array uses twn_fuse_requant, hence it is in the file list.
    $a = @("--nolog","-sv","-work",$lib) + $defArgs +
         @("$fuse\twn_fuse_requant.v","$fuse\twn_dw_array.v","$gold\$t.v")
    $r = & xvlog.bat @a 2>&1 | Out-String
    if ($r -match "ERROR") {
        $fail++; $buildErr++; $bad += "$t(compile)"
        Write-Output ("  {0,-22} COMPILE ERROR: {1}" -f $t, (($r -split "`n" | Select-String "ERROR" | Select-Object -First 1) -join "").Trim())
        continue
    }
    $r = & xelab.bat --nolog -debug off -L $lib -s "s_$t" "$lib.$t" 2>&1 | Out-String
    if ($r -match "ERROR") {
        $fail++; $buildErr++; $bad += "$t(elab)"
        Write-Output ("  {0,-22} ELAB ERROR: {1}" -f $t, (($r -split "`n" | Select-String "ERROR" | Select-Object -First 1) -join "").Trim())
        continue
    }
    $r = & xsim.bat "s_$t" --nolog --runall 2>&1 | Out-String

    if ($r -match "(\d+) values checked, (\d+) errors") {
        $chk = [int]$Matches[1]; $err = [int]$Matches[2]; $totalChecked += $chk
        # A case that checked nothing is not a pass: a driver that produces no beats
        # would otherwise print "0 errors".
        if ($err -eq 0 -and $chk -gt 0 -and $r -match "ALL PASS") {
            $pass++; Write-Output ("  {0,-22} {1,8} values  PASS" -f $t, $chk)
        } else {
            $fail++; $bad += $t
            # ran and failed: a check reported errors (or checked nothing)
            if ($err -gt 0) { $ranFail++ } else { $noResult++ }
            Write-Output ("  {0,-22} {1,8} values  {2} errors  FAIL" -f $t, $chk, $err)
        }
    } else { $fail++; $noResult++; $bad += "$t(no result line)"; Write-Output ("  {0,-22} produced no result line" -f $t) }
}
Write-Output ""
Write-Output ("=== P3 dw [" + $Label + "]: " + $pass + " pass, " + $fail + " fail (" + $ranFail + " ran and failed, " +
              $buildErr + " build errors, " + $noResult + " no result), " + $totalChecked + " values checked ===")
if ($bad.Count -gt 0) { Write-Output ("    failing: " + ($bad -join ", ")) }
if ($buildErr -gt 0) { Write-Output ("P3 BUILD ERRORS: {0} case(s) did not compile/elaborate -- not a test result" -f $buildErr) }
Set-Location $env:TEMP
if (-not $Keep) { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue }
if ($fail -gt 0) { exit 1 }
exit 0
