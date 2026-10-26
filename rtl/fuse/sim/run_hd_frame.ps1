# run_hd_frame.ps1 -- bit-exact gate for the head engine twn_hd_compute (testbench
# tb\tb_hd_frame.v, all four head operators, every output element), with a destructive arm.
#
# Two arms:
#   1 intact     must print "tb_hd_frame: PASS".
#   2 perturbed  one nibble of one golden byte (beat 4096 of hd_op63_out.hex, in the arm's scratch
#                copy) is flipped. The gate must FAIL, with exactly one wrong element at max|diff| 1.
# The second arm perturbs the golden data, not the design: it catches a comparison loop that walks
# no elements or compares the captured data with itself, and a report that cannot localise.
#
# Before simulating, the script checks that the vectors in rtl\fuse\tb\hd_vec exist, that every file
# has the beat count tb_hd_frame.v assumes (a short file is not an error for $readmemh), and that
# each operator's golden output file is identical to the next operator's input file. Any failure
# prints the reason and exits 1. The vectors are copied into each arm's scratch directory.
#
# Usage: powershell -ExecutionPolicy Bypass -File rtl\fuse\sim\run_hd_frame.ps1
#          [-Defines NAME1,NAME2]   valueless xvlog defines only (e.g. HD_FRAME_STALL); a valued
#                                   define is refused because `xvlog -d NAME=VALUE` splits on '='
#          [-SkipBreak]             run arm 1 only; exits 1, because the failure path did not run
# Prerequisites: Vivado xvlog.bat / xelab.bat / xsim.bat. Generated inputs: rtl\fuse\tb\hd_vec,
#   produced by `python tools\hd_ref_export.py` (needs numpy, models\mbv2_pose\model_meta.c, models\mbv2_pose\model_mbv2.bin,
#   models\mbv2_pose\fixtures\fix_0.bin).
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin).
#   TWN_SIM_KEEP = if set, keep the work directory %TEMP%\twn_hdframe_<pid>.
# Result: prints both verdicts and the localisation, then HD_FRAME_GATE_SELFTEST_PASS (exit 0) or
#   HD_FRAME_GATE_SELFTEST_FAIL (exit 1).
param([string]$Defines = "", [switch]$SkipBreak)

$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
$tree = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path   # derived from this script's location
$root = "$tree"
$vec  = "$root\rtl\fuse\tb\hd_vec"

$rtl = @("$root\rtl\src\bram_sdp.v",
         "$root\rtl\src\bram_tdp.v",
         "$root\rtl\src\twn_hd_compute.v",
         "$root\rtl\fuse\twn_hd_seq.v",
         "$root\rtl\fuse\tb\tb_hd_frame.v")

# The beat counts tb_hd_frame.v hard-codes, checked before a simulator is started.
$expect = [ordered]@{
    "hd_op61_in.hex"  =  1280; "hd_op61_w.hex" = 10240; "hd_op61_out.hex" =   512
    "hd_op62_in.hex"  =   512; "hd_op62_w.hex" =  1024; "hd_op62_out.hex" =  2048
    "hd_op63_in.hex"  =  2048; "hd_op63_w.hex" =  1024; "hd_op63_out.hex" =  8192
    "hd_op64_in.hex"  =  8192; "hd_op64_w.hex" =    32; "hd_op64_out.hex" = 16384
    "hd_rq.hex"       =   128
}

# --- provenance -------------------------------------------------------------
# Print what is being compared (hash and time of each source, the vector manifest) before comparing.
Write-Output "=== inputs ==="
foreach ($f in $rtl) {
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
        Write-Output ("  STALE  {0}: {1} beats, tb_hd_frame.v assumes {2}" -f $k, $n, $expect[$k])
        $bad++
    }
}
if ($bad -gt 0) {
    Write-Output "vector set does not match the testbench -- rerun tools\hd_ref_export.py"
    exit 1
}
Write-Output ("  {0} vector files, all beat counts as expected" -f $expect.Count)

# Operator N's golden output file must be operator N+1's input file; otherwise the four operators
# would be scored against unrelated references.
foreach ($pair in @(@("hd_op61_out.hex","hd_op62_in.hex"),
                    @("hd_op62_out.hex","hd_op63_in.hex"),
                    @("hd_op63_out.hex","hd_op64_in.hex"))) {
    $a = (Get-FileHash (Join-Path $vec $pair[0]) -Algorithm SHA256).Hash
    $b = (Get-FileHash (Join-Path $vec $pair[1]) -Algorithm SHA256).Hash
    if ($a -ne $b) {
        Write-Output ("  CHAIN BROKEN: {0} != {1}" -f $pair[0], $pair[1])
        exit 1
    }
    Write-Output ("  chain {0} == {1}  sha {2}" -f $pair[0], $pair[1], $a.Substring(0,16).ToLower())
}

$defArgs = @()
foreach ($d in ($Defines -split '[,\s]+' | Where-Object { $_ -ne "" })) {
    if ($d -match '=') { Write-Output "valued define '$d' cannot survive xvlog on Windows"; exit 1 }
    $defArgs += @("-d", $d)
}

# Every arm's work directory sits under one per-process parent, removed at the end unless
# TWN_SIM_KEEP is set.
$workRoot = Join-Path $env:TEMP ("twn_hdframe_" + $PID)
function Run([string]$tag, [bool]$perturb) {
    $work = Join-Path $workRoot $tag
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    Copy-Item (Join-Path $vec "*.hex") $work
    if ($perturb) {
        # One nibble of one golden byte: beat 4096 of op63's output, byte 0's low nibble.
        # XOR 1 moves that int8 by exactly +-1, so the gate must report "wrong 1 ... max|diff| 1".
        $p = Join-Path $work "hd_op63_out.hex"
        $lines = Get-Content $p
        $old = $lines[4096]
        $nib = [Convert]::ToInt32($old.Substring(31,1), 16)
        $lines[4096] = $old.Substring(0,31) + ("{0:x}" -f ($nib -bxor 1))
        Set-Content -Path $p -Value $lines -Encoding ascii
        Write-Output ("  perturbed hd_op63_out.hex beat 4096: {0} -> {1}" -f $old, $lines[4096])
    }
    Set-Location $work
    $a = @("--nolog","-sv") + $defArgs + $rtl
    $r = & xvlog.bat @a 2>&1 | Out-String
    if ($r -match "ERROR") { Write-Output "$tag COMPILE ERROR"; Write-Output $r; return @{v="ERR"} }
    $r = & xelab.bat --nolog -debug off -s s tb_hd_frame 2>&1 | Out-String
    if ($r -match "ERROR") { Write-Output "$tag ELAB ERROR"; Write-Output $r; return @{v="ERR"} }
    $o = & xsim.bat s -runall --nolog 2>&1 | Out-String
    $verdict = "UNKNOWN"
    if ($o -match "tb_hd_frame: PASS")              { $verdict = "PASS" }
    elseif ($o -match "tb_hd_frame: (\d+) FAILURES"){ $verdict = "FAIL($($Matches[1]))" }
    return @{ v = $verdict; out = $o }
}

Write-Output ""
Write-Output "=== arm 1: intact ==="
$g = Run "good" $false
# Print the per-operator report, not only the verdict line.
($g.out -split "`r?`n" | Where-Object {
    $_ -match "^(op6|      |=== tb_hd_frame|--- |FAIL|\[tb_hd_frame\])" }) |
    ForEach-Object { Write-Output $_ }

Write-Output ""
# Remove this run's work directories on every exit below.
function Remove-Work { Set-Location $env:TEMP; if (-not $env:TWN_SIM_KEEP) { Remove-Item -Recurse -Force -LiteralPath $workRoot -ErrorAction SilentlyContinue } }
if ($SkipBreak) {
    Write-Output "=== arm 2: SKIPPED (-SkipBreak) -- the gate's failure path did NOT run ==="
    Write-Output "intact = $($g.v)"
    Remove-Work
    exit 1
}
Write-Output "=== arm 2: one golden byte perturbed (the gate must catch it) ==="
$b = Run "brk" $true
($b.out -split "`r?`n" | Where-Object {
    $_ -match "^(op6|      elements|      FIRST|      of which|FAIL)" }) |
    ForEach-Object { Write-Output $_ }

# Localisation: exactly one element, and off by exactly one.
$loc = ($b.out -match "elements 131072   wrong 1   max\|diff\| 1")

Write-Output ""
Write-Output "intact   = $($g.v)      (must be PASS)"
Write-Output "perturbed= $($b.v)      (must NOT be PASS)"
Write-Output "localised= $loc      (must be True: one element, max|diff| 1)"
Remove-Work
if (($g.v -eq "PASS") -and ($b.v -ne "PASS") -and ($b.v -ne "ERR") -and $loc) {
    Write-Output "HD_FRAME_GATE_SELFTEST_PASS"
    exit 0
}
Write-Output "HD_FRAME_GATE_SELFTEST_FAIL -- the gate does not distinguish the perturbation"
exit 1
