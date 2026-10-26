# ============================================================================
#  package_fuse_ip.tcl -- package twn_fuse_layer (the wrapper around twn_fuse_top)
#  as a Vivado IP, VLNV twn:user:twn_fuse:1.0, into rtl/ip/twn_fuse_ip.
#
#  - The source list is explicit (no glob). It is the same set of modules as
#    rtl/fuse/sim/elab_top.ps1 and vivado/elab_fuse_layer.ps1.
#  - bram_sdp is built through its inference path unless FUSE_XPM=1, which defines
#    USE_XPM=1 and enables XPM_MEMORY.
#  - Files are read as SystemVerilog.
#
#  Environment (optional)
#    FUSE_XPM=1      use bram_sdp's XPM path
#    FUSE_SRCDIR     package from a frozen copy: <dir>/fuse, <dir>/src and
#                    <dir>/twn_fuse_layer.v replace rtl/fuse, rtl/src and
#                    rtl/ip/twn_fuse_layer.v
#    FUSE_IPDIR      write the IP to this directory instead of rtl/ip/twn_fuse_ip
#                    (the scratch project goes to <dir>_pkgproj)
#
#  The IP directory and the scratch project are deleted and recreated.
#  Needs: Vivado 2023.2, part xczu2cg-sfvc784-1-e; the port list of
#  rtl/ip/twn_fuse_layer.v must match rtl/fuse/twn_fuse_top.v.
#  Run:   vivado -mode batch -source vivado/package_fuse_ip.tcl
# ============================================================================
set PART   xczu2cg-sfvc784-1-e
set here   [file normalize [file dirname [info script]]]
set root   [file normalize $here/..]
set fuse   $root/rtl/fuse
set src    $root/rtl/src
set layer  $root/rtl/ip/twn_fuse_layer.v
set ipdir  $root/rtl/ip/twn_fuse_ip
set proj   $root/rtl/ip/_pkg_fuse_proj
set XPM    [expr {[info exists ::env(FUSE_XPM)] && $::env(FUSE_XPM) == 1}]

# FUSE_SRCDIR / FUSE_IPDIR: see the header.
if {[info exists ::env(FUSE_SRCDIR)] && $::env(FUSE_SRCDIR) ne ""} {
    set snap  [file normalize $::env(FUSE_SRCDIR)]
    set fuse  $snap/fuse
    set src   $snap/src
    set layer $snap/twn_fuse_layer.v
    puts "== sources from SNAPSHOT $snap (not the working tree) =="
}
if {[info exists ::env(FUSE_IPDIR)] && $::env(FUSE_IPDIR) ne ""} {
    set ipdir [file normalize $::env(FUSE_IPDIR)]
    set proj  "${ipdir}_pkgproj"
    puts "== packaging into PRIVATE repo $ipdir =="
}
file delete -force $ipdir $proj
file mkdir $ipdir

create_project -force twn_fuse_pkg $proj -part $PART

# --- the module list, in dependency order ---
# twn_hd_compute is listed whether or not HD_PROBE is set, so both settings
# package the same file set.
set SRCS [list \
    $fuse/twn_fuse_select.v  $fuse/twn_fuse_tree.v    $fuse/twn_fuse_requant.v \
    $src/bram_sdp.v          $src/bram_sdp_bw.v \
    $fuse/twn_fuse_array.v   $fuse/twn_dw_array.v \
    $fuse/twn_blockseq.v     $fuse/twn_rowbuf.v       $fuse/twn_rowbuf_rot.v \
    $fuse/twn_wmem.v         $src/twn_axi_rd.v        $src/twn_axi_wr.v \
    $fuse/twn_wfetch.v       $fuse/twn_act_rd.v       $fuse/twn_act_wr.v \
    $fuse/twn_act_gather.v   $fuse/twn_act_scatter.v \
    $fuse/twn_res_add.v      $fuse/twn_res_buf.v \
    $fuse/twn_frameseq.v     $fuse/twn_csr.v          $fuse/twn_desctab.v \
    $fuse/twn_uop_enc.v      $fuse/twn_uop_issue.v    $fuse/twn_dw_pack.v \
    $fuse/twn_ring_warb.v    $fuse/twn_dwseq.v      $fuse/twn_hd_seq.v \
    $fuse/twn_fuse_top.v \
    $src/bram_tdp.v          $src/twn_hd_compute.v \
    $layer]
foreach f $SRCS {
    if {![file exists $f]} { puts "FATAL: source missing: $f"; exit 1 }
}
add_files -norecurse $SRCS
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1]]
set_property top twn_fuse_layer [current_fileset]
if {$XPM} {
    puts "== bram_sdp: XPM path (FUSE_XPM=1) =="
    set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
    set_property verilog_define {USE_XPM=1} [current_fileset]
} else {
    puts "== bram_sdp: inference path (ram_style), matching ooc_top.tcl =="
}
update_compile_order -fileset sources_1

# ---- package (bus interfaces are inferred from the AXI port names) ----
ipx::package_project -root_dir $ipdir -vendor twn -library user -taxonomy /UserIP \
    -import_files -set_current true -force
set core [ipx::current_core]
set_property name         twn_fuse $core
set_property version      1.0 $core
set_property display_name {TWN MobileNetV2 FUSE row-streaming accelerator (Verilog)} $core
set_property description   {Fused ternary/depthwise row-streaming PL accelerator, twn_fuse_top} $core

# ---- clock/reset associations ----
ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
ipx::associate_bus_interfaces -busif m_axi_gmem0   -clock ap_clk $core
ipx::associate_bus_interfaces -busif m_axi_gmem1   -clock ap_clk $core
# the head's two master interfaces: each AXI interface must be associated with a clock
ipx::associate_bus_interfaces -busif m_axi_gmem2   -clock ap_clk $core
ipx::associate_bus_interfaces -busif m_axi_gmem3   -clock ap_clk $core
# The packager infers buses from port names; fail here if an interface was not
# inferred (it would otherwise appear as loose scalar ports).
foreach want {s_axi_control m_axi_gmem0 m_axi_gmem1 m_axi_gmem2 m_axi_gmem3} {
    if {[llength [ipx::get_bus_interfaces $want -of_objects $core]] != 1} {
        puts "FATAL: bus interface $want was not inferred -- check the port names in"
        puts "       rtl/ip/twn_fuse_layer.v against the AXI naming the packager expects"
        exit 1
    }
}
set rstif [ipx::get_bus_interfaces ap_rst_n -of_objects $core]
if {$rstif ne ""} {
    set p [ipx::get_bus_parameters POLARITY -of_objects $rstif]
    if {$p ne ""} { set_property value ACTIVE_LOW $p }
}

# ---- s_axi_control memory map ----
# 64 KB, matching the 16-bit address port of twn_fuse_top.
set mm [ipx::get_memory_maps s_axi_control -of_objects $core]
if {$mm ne ""} {
    foreach b [ipx::get_address_blocks -of_objects $mm *] { set_property range 65536 $b }
}

# twn_hd_seq is instantiated only inside twn_fuse_top's HD_PROBE generate block, which
# the packager's reference walk does not follow; it is copied and added to the file
# group explicitly so that both HD_PROBE settings get the same file set.
file copy -force $fuse/twn_hd_seq.v $ipdir/src/twn_hd_seq.v
set _fg [ipx::get_file_groups xilinx_anylanguagesynthesis -of_objects $core]
if {[llength [ipx::get_files src/twn_hd_seq.v -of_objects $_fg]] == 0} {
    set _f [ipx::add_file src/twn_hd_seq.v $_fg]
    set_property type systemVerilogSource $_f
}
ipx::create_xgui_files $core
ipx::update_checksums   $core
ipx::save_core          $core

# ---- print the inferred interfaces ----
puts "==== PACKAGED IP INTERFACES ===="
foreach bif [ipx::get_bus_interfaces -of_objects $core] {
    puts "  [get_property NAME $bif]  |  [get_property BUS_TYPE_VLNV $bif]  |  mode=[get_property INTERFACE_MODE $bif]"
}
puts "==== IP written to: $ipdir ===="
close_project
