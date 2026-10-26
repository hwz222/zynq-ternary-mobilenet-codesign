# run_p5.ps1 -- bit-exact gate for all 17 blocks of the MobileNetV2 body against the P1 golden vectors.
#
# Each block runs through the real twn_blockseq, twn_fuse_array (one instance serving both ternary
# convolutions), twn_dw_array and twn_res_add. Modelled in the testbench: the four row buffers
# (twn_rowbuf is tested separately) and the AXI masters. The activation producer is modelled with
# LFSR-varied latency and a ready line (see tb\tb_p4_block.v). A gate is blind to anything on the
# modelled side, in particular to how the real masters handshake, not only what they compute.
#
# Usage: .\run_p5.ps1 [-Quiet] [-Work dir] [-Blocks 0,1,2] [-Break DEFINE]
#   -Blocks  comma-separated block numbers (default 0..16; 0..6 with -Break)
#   -Break   compile with a negative-test define; each block must then FAIL. Defines in
#            twn_fuse_array.v: FUSE_NEG_ACT_NOWAIT (array does not wait for the next activation
#            word) and FUSE_NEG_ACT_NOREADY (array issues without checking act_ready).
#   -Work    work directory (default %TEMP%\twn_p5_gate_<pid>; per process so that concurrent runs
#            do not delete each other's libraries, since each block deletes its own first)
# Prerequisites: Vivado xvlog.bat / xelab.bat / xsim.bat; Python.
# Generated inputs: p1_golden\vec\b00_in.bin and b16_out.bin must exist; produce them from p1_golden
#   with `bash run_p1.sh` (Git Bash; needs gcc and the model blob). The script stops with MISSING if
#   they are absent. Per block, tb\gen_p4_block.py generates the testbench and data into the work
#   directory.
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin);
#   PYTHON = interpreter for gen_p4_block.py (default `python`).
# Result: one line per block, then "=== P5 bit-exact: N pass, M fail, K values checked ===" (or
#   "=== P5 break test [...] ===" with -Break). There is no explicit exit statement: read the summary
#   line and the "failing:" line. A block passes only if its verdict line says ALL PASS and it
#   checked more than zero values.
param([switch]$Quiet, [string]$Work = "", [string]$Break = "", [string]$Blocks = "")

$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
$tree = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path   # derived from this script's location
$fuse = "$tree\rtl\fuse"
$ip   = "$tree\rtl\src"
# Per process by default: the library and snapshot are deleted per block, so a shared directory
# would make concurrent runs invalidate each other. Pass -Work to pin a path deliberately.
if ($Work -eq "") { $Work = Join-Path $env:TEMP ("twn_p5_gate_" + $PID) }
$work = $Work
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

$py = if ($env:PYTHON) { $env:PYTHON } else { "python" }
# Check for generated vectors (outputs of run_p1.sh), not for tracked files.
foreach ($f in @("b00_in.bin", "b16_out.bin")) {
    if (-not (Test-Path "$tree\golden\p1_golden\vec\$f")) {
        Write-Output "MISSING $tree\golden\p1_golden\vec\$f -- the P1 golden vectors were never generated in this tree."
        Write-Output "  Run, in Git Bash from $tree :  ( cd p1_golden && bash run_p1.sh )   (README.md, step 1)"
        exit 1
    }
}
$src = @("$fuse\twn_fuse_select.v", "$fuse\twn_fuse_tree.v", "$fuse\twn_fuse_requant.v",
         "$ip\bram_sdp.v", "$fuse\twn_fuse_array.v", "$fuse\twn_dw_array.v",
         "$fuse\twn_res_add.v", "$fuse\twn_blockseq.v")

$blist =
    if ($Blocks -ne "") { $Blocks -split ',' | ForEach-Object { [int]$_.Trim() } }
    elseif ($Break -ne "") { 0..6 }        # see the header: 7-16 have nothing to break
    else { 0..16 }
# The library name carries the define, so a break run never reuses a clean snapshot.
$sfx = if ($Break -ne "") { "_" + $Break } else { "" }

$pass = 0; $fail = 0; $total = 0; $bad = @()
foreach ($b in $blist) {
    $t = if ($b -eq 1) { "tb_p4_block" } else { "tb_p4_block_b{0:d2}" -f $b }
    $lib = "$t$sfx"
    # The block's data (and, for every block but 1, its testbench) is generated here from
    # p1_golden\vec by tb\gen_p4_block.py. Block 1's testbench is the template tb\tb_p4_block.v;
    # the others are substitutions of it.
    $tbv = if ($b -eq 1) { "$work\tb_p4_block.v" } else { "$work\$t.v" }
    & $py "$fuse\tb\gen_p4_block.py" --block $b -o $tbv | Out-Null
    if ($b -eq 1) { Copy-Item "$fuse\tb\tb_p4_block.v" $tbv -Force }
    if (-not (Test-Path $tbv)) { $fail++; $bad += "b$b(generate)"; continue }
    foreach ($d in @($lib, "s_$lib")) { if (Test-Path $d) { Remove-Item -Recurse -Force -LiteralPath $d } }

    # The quotes around a -d argument are needed: xvlog is a .bat wrapper and cmd splits on '='
    # unless quoted.
    $a = @("--nolog", "-sv", "-work", $lib)
    if ($Break -ne "") { $a += @("-d", "`"$Break`"") }
    $a += $src + @($tbv)

    $r = & xvlog.bat @a 2>&1 | Out-String
    if ($r -match "ERROR") { $fail++; $bad += "b$b(compile)"; continue }
    $r = & xelab.bat --nolog -debug off -L $lib -s "s_$lib" "$lib.$t" 2>&1 | Out-String
    if ($r -match "ERROR") { $fail++; $bad += "b$b(elab)"; continue }
    $r = & xsim.bat "s_$lib" --nolog --runall 2>&1 | Out-String

    # The verdict line is the authority, not the counts: a deadlocked block prints
    # "FAIL (no completion)" and never reaches the count. No verdict line at all means broken.
    $v = ($r -split "`r?`n" | Where-Object { $_ -match "^=== tb_p4_block" } | Select-Object -Last 1)
    if ($r -match "(\d+) values checked, (\d+) errors") {
        $chk = [int]$Matches[1]; $err = [int]$Matches[2]; $total += $chk
    } else { $chk = 0; $err = -1 }
    # A block that checked nothing is not a pass.
    $ok = ($err -eq 0 -and $chk -gt 0 -and $v -match "ALL PASS")

    if (-not $v) {
        $fail++; $bad += "b$b(no verdict)"; Write-Output ("  b{0:d2}  no verdict line -- nothing was checked" -f $b)
    } elseif ($Break -ne "") {
        # inverted: the defect is injected, so FAIL is the pass
        if ($ok) {
            $fail++; $bad += "b$b"
            Write-Output ("  b{0:d2}  {1,8} values  🔴 STILL PASSES -- the gate cannot see {2}" -f $b, $chk, $Break)
        } else {
            $pass++
            if (-not $Quiet) { Write-Output ("  b{0:d2}  bites   {1}" -f $b, $v.Trim()) }
        }
    } elseif ($ok) {
        $pass++
        if (-not $Quiet) { Write-Output ("  b{0:d2}  {1,8} values  PASS" -f $b, $chk) }
    } else {
        $fail++; $bad += "b$b"
        Write-Output ("  b{0:d2}  {1,8} values  {2} errors  FAIL   {3}" -f $b, $chk, $err, $v.Trim())
    }
}
Write-Output ""
if ($Break -ne "") {
    Write-Output ("=== P5 break test [{0}]: {1} bite, {2} did not, {3} values checked ===" -f
                  $Break, $pass, $fail, $total)
} else {
    Write-Output ("=== P5 bit-exact: {0} pass, {1} fail, {2} values checked ===" -f $pass, $fail, $total)
}
if ($bad.Count -gt 0) { Write-Output ("    failing: " + ($bad -join ", ")) }
