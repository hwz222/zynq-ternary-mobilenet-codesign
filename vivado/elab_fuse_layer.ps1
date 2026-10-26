# elab_fuse_layer.ps1 -- elaborate twn_fuse_layer (the IP wrapper in rtl\ip) with xvlog + xelab.
#
# Runs two arms in separate work libraries: default (HD_PROBE = 0) and `-d HD_PROBE_ON` (HD_PROBE = 1).
# Catches port-list drift between the wrapper and twn_fuse_top, and unresolved modules, which xelab
# only warns about. The source list is the one in vivado\package_fuse_ip.tcl.
# Prerequisites: Vivado xvlog.bat / xelab.bat. No generated inputs; reads rtl\fuse, rtl\src, rtl\ip.
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin).
# Argument: -SelfTest withholds bram_tdp.v from the second arm and requires the unresolved-module
#   check to fire (exit 0 means it did).
# Work directory: %TEMP%\twn_elab_fuse_layer.
# Result: exit 0 and "=== elab_fuse_layer: ... ELABORATES ..." for both arms; otherwise the tool output
#   and a "... FAIL", "MISSING: <file>" or "WRONG ARM" line, exit 1.
# Run: powershell -ExecutionPolicy Bypass -File vivado\elab_fuse_layer.ps1 [-SelfTest]
$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"

# An unresolved (black-boxed) module is a failure: xelab only warns about it.
# Unresolved() looks for that in the output text.
function Unresolved([string]$txt) {
    return ($txt -match "(?i)not found|black.?box|cannot find design unit|unresolved")
}
$SelfTest = ($args -contains "-SelfTest")

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$fuse = "$root\rtl\fuse"
$src  = "$root\rtl\src"
$work = "$env:TEMP\twn_elab_fuse_layer"
# Fresh work library every run: xvlog adds to the library, so modules compiled by an
# earlier run would otherwise still resolve.
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

$srcs = @(
    "$fuse\twn_fuse_select.v", "$fuse\twn_fuse_tree.v",  "$fuse\twn_fuse_requant.v",
    "$src\bram_sdp.v",         "$src\bram_sdp_bw.v",
    "$fuse\twn_fuse_array.v",  "$fuse\twn_dw_array.v",
    "$fuse\twn_blockseq.v",    "$fuse\twn_rowbuf.v",     "$fuse\twn_rowbuf_rot.v",
    "$fuse\twn_wmem.v",        "$src\twn_axi_rd.v",      "$src\twn_axi_wr.v",
    "$fuse\twn_wfetch.v",      "$fuse\twn_act_rd.v",     "$fuse\twn_act_wr.v",
    "$fuse\twn_act_gather.v",  "$fuse\twn_act_scatter.v",
    "$fuse\twn_res_add.v",     "$fuse\twn_res_buf.v",
    "$fuse\twn_frameseq.v",    "$fuse\twn_csr.v",        "$fuse\twn_desctab.v",
    "$fuse\twn_uop_enc.v",     "$fuse\twn_uop_issue.v",  "$fuse\twn_dw_pack.v",
    "$fuse\twn_ring_warb.v",   "$fuse\twn_dwseq.v",     "$fuse\twn_hd_seq.v",
    "$fuse\twn_fuse_top.v",    "$src\bram_tdp.v", "$src\twn_hd_compute.v",
    "$root\rtl\ip\twn_fuse_layer.v")

foreach ($f in $srcs) { if (-not (Test-Path $f)) { Write-Output "MISSING: $f"; exit 1 } }

$r = & xvlog.bat --nolog -sv @srcs 2>&1 | Out-String
if ($r -match "ERROR") { Write-Output $r; Write-Output "=== elab_fuse_layer: COMPILE FAIL ==="; exit 1 }
$r = & xelab.bat --nolog -debug off -s snap_fuse_layer twn_fuse_layer 2>&1 | Out-String
if ($r -match "ERROR") { Write-Output $r; Write-Output "=== elab_fuse_layer: ELABORATE FAIL ==="; exit 1 }
Write-Output "=== elab_fuse_layer: twn_fuse_layer ELABORATES (HD_PROBE=0, shipping) ==="

# Second arm: the same sources compiled with -d HD_PROBE_ON in a separate work library.
# The define is valueless; twn_fuse_top maps it to the HD_PROBE parameter default.
$work2 = "$work\hdprobe"
New-Item -ItemType Directory -Force $work2 | Out-Null
Set-Location $work2
# -SelfTest: drop bram_tdp.v; the unresolved-module check must then fire.
$psrcs = $srcs
if ($SelfTest) {
    $psrcs = $srcs | Where-Object { $_ -notmatch "bram_tdp\.v$" }
    Write-Output "=== SELFTEST: bram_tdp.v withheld, the check MUST fire ==="
}
$rc = & xvlog.bat --nolog -sv -d HD_PROBE_ON @psrcs 2>&1 | Out-String
$re = ""
if ($rc -notmatch "ERROR") {
    $re = & xelab.bat --nolog -debug off -s snap_fuse_hdprobe twn_fuse_layer 2>&1 | Out-String
}
$r = "$rc`n$re"

# In self-test the withheld module must surface (as a hard xvlog/xelab error).
if ($SelfTest) {
    if (Unresolved $r) {
        Write-Output "=== SELFTEST PASS: withholding bram_tdp.v is caught ==="
        Write-Output ($r -split "`n" | Where-Object { $_ -match "not found" } | Select-Object -First 1)
        exit 0
    }
    Write-Output $r
    Write-Output "=== SELFTEST FAIL: bram_tdp.v was withheld and nothing complained."
    Write-Output "    This gate is not guarding anything. ==="
    exit 1
}
if ($rc -match "ERROR") { Write-Output $rc; Write-Output "=== elab_fuse_layer: HD_PROBE COMPILE FAIL ==="; exit 1 }
if ($re -match "ERROR") { Write-Output $re; Write-Output "=== elab_fuse_layer: HD_PROBE=1 ELABORATE FAIL ==="; exit 1 }
$r = $re

# The arm is HD_PROBE=1 only if xelab compiled twn_hd_compute; check that in its output.
if ($r -notmatch "Compiling module work\.twn_hd_compute") {
    Write-Output $r
    Write-Output "=== elab_fuse_layer: WRONG ARM -- xelab never compiled twn_hd_compute,"
    Write-Output "    so -d HD_PROBE_ON did not reach the generate branch and this run"
    Write-Output "    proves nothing about the probe. ==="
    exit 1
}
if (Unresolved $r) {
    Write-Output $r
    Write-Output "=== elab_fuse_layer: HD_PROBE=1 UNRESOLVED MODULE ==="
    exit 1
}
Write-Output "=== elab_fuse_layer: twn_fuse_layer ELABORATES (HD_PROBE=1, probe) ==="
exit 0
