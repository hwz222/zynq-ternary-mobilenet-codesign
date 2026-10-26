# elab_top.ps1 -- elaborate twn_fuse_top with xvlog + xelab (no simulation, nothing is driven or checked).
#
# Purpose: a quick gate before a Vivado build. It catches unresolved modules, undeclared identifiers
# and forward references (the sources use `default_nettype none) that xelab rejects.
# Prerequisites: Vivado xvlog.bat / xelab.bat. No generated inputs are needed; it reads the .v files
#   under rtl\fuse and rtl\src of this tree (the tree root is derived from the script location).
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin).
# Work directory: %TEMP%\twn_elab_top.
# Result: prints "=== elab_top: twn_fuse_top ELABORATES ===" on success; on failure prints the tool
#   output and "COMPILE FAIL" or "ELABORATE FAIL" and exits 1.
# Maintenance: every new module must be added to $src, otherwise the check cannot see it.
$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
$tree = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path   # derived from this script's location
$fuse = "$tree\rtl\fuse"
$ip   = "$tree\rtl\src"
$rsrc = "$tree\rtl\src"
$work = "$env:TEMP\twn_elab_top"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

$src = @(
    "$fuse\twn_fuse_select.v", "$fuse\twn_fuse_tree.v", "$fuse\twn_fuse_requant.v",
    "$ip\bram_sdp.v",          "$ip\bram_sdp_bw.v",      "$rsrc\bram_tdp.v",
    "$fuse\twn_hd_seq.v",      "$rsrc\twn_hd_compute.v",
    "$fuse\twn_fuse_array.v",  "$fuse\twn_dw_array.v",
    "$fuse\twn_blockseq.v",    "$fuse\twn_rowbuf.v",     "$fuse\twn_rowbuf_rot.v",
    "$fuse\twn_wmem.v",        "$rsrc\twn_axi_rd.v",     "$rsrc\twn_axi_wr.v",
    "$fuse\twn_wfetch.v",      "$fuse\twn_act_rd.v",     "$fuse\twn_act_wr.v",
    "$fuse\twn_act_gather.v",  "$fuse\twn_act_scatter.v","$fuse\twn_res_add.v",
    "$fuse\twn_frameseq.v",    "$fuse\twn_csr.v",        "$fuse\twn_desctab.v",
    "$fuse\twn_uop_enc.v",     "$fuse\twn_uop_issue.v",  "$fuse\twn_dw_pack.v",
    "$fuse\twn_ring_warb.v",   "$fuse\twn_dwseq.v",     "$fuse\twn_res_buf.v",
    "$fuse\twn_fuse_top.v")

# HD_PROBE_ON selects the head engine (twn_hd_seq / twn_hd_compute), as the shipping build does.
$r = & xvlog.bat --nolog -sv -d HD_PROBE_ON @src 2>&1 | Out-String
if ($r -match "ERROR") { Write-Output $r; Write-Output "=== elab_top: COMPILE FAIL ==="; exit 1 }
$r = & xelab.bat --nolog -debug off -s snap_elab twn_fuse_top 2>&1 | Out-String
if ($r -match "ERROR") { Write-Output $r; Write-Output "=== elab_top: ELABORATE FAIL ==="; exit 1 }
Write-Output "=== elab_top: twn_fuse_top ELABORATES ==="
