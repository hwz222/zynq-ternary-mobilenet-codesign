# ============================================================================
#  build_bd_fuse.tcl -- Vivado block design, synthesis and (optionally)
#  implementation for twn_fuse_top, packaged as IP twn:user:twn_fuse:1.0.
#
#  Block design "system" (the script creates no external ports):
#    ps        zynq_ultra_ps_e 3.5. BOARD_PS=1 applies alinx_ps/ps_config.tcl.
#              Enabled: M_AXI_HPM0_FPD (32-bit), S_AXI_HP0..HP2 (128-bit), PL clock 0
#              at TWN_FREQ MHz, IRQ0. FUSE_HP3_SPLIT=1 also enables S_AXI_HP3_FPD.
#    rst_pl    proc_sys_reset on pl_clk0 / pl_resetn0.
#    fuse_0    the accelerator IP (rtl/ip/twn_fuse_layer.v, packaged by
#              package_fuse_ip.tcl). HD_PROBE is set to 1 when FUSE_HD_PROBE=1.
#    sc_ctl    smartconnect, 1 SI x 2 MI: M_AXI_HPM0_FPD -> fuse_0/s_axi_control at
#              0xA0000000 and -> obs_gpio at 0xA0010000 (64 KB each).
#    obs_gpio  axi_gpio, 32 bits, inputs only, driven by fuse_0/obs.
#    sc_hp0    axi_interconnect 1 SI x 1 MI, STRATEGY 2: fuse_0/m_axi_gmem0 -> HP0.
#    sc_hp1    axi_interconnect 1 SI x 1 MI, STRATEGY 2: fuse_0/m_axi_gmem1 -> HP1.
#    sc_hp2    axi_interconnect, STRATEGY 2: m_axi_gmem2 and m_axi_gmem3 (2 SI x 1 MI)
#              -> HP2. With FUSE_HP3_SPLIT=1 it is 1 SI x 1 MI (gmem2 only) and a
#              second 1 SI x 1 MI interconnect, sc_hp3, takes gmem3 -> HP3.
#    irq_zero  xlconstant 0 -> ps/pl_ps_irq0.
#  Every cell is clocked from pl_clk0; resets come from rst_pl/peripheral_aresetn.
#  The only constraint file added is fuse_t1mem_pblock.xdc (FUSE_T1_PBLOCK=1).
#
#  Environment (all optional)
#    BOARD_PS=1        apply the ALINX AXU2CGB PS preset; without it the PS is Vivado's
#                      default (not board-bootable)
#    TWN_FREQ          PL clock request in MHz, default 250; the PS divider chain
#                      decides the frequency actually obtained
#    TWN_PROJDIR       project directory, default vivado/proj_fuse_250
#    FUSE_IMPL=1       also run implementation (default: stop after synthesis)
#    FUSE_BIT=1        with FUSE_IMPL=1 and WNS >= 0, write the bitstream and XSA
#    BUILD_STRATEGY    implementation strategy, default Performance_ExplorePostRoutePhysOpt
#    FUSE_TAG          suffix appended to every report / bitstream / XSA name
#    FUSE_HD_PROBE=1   build the head engine (see below)
#    FUSE_HP3_SPLIT=1  give gmem3 its own PS port, HP3 (see below)
#    FUSE_IPDIR        IP repository to use, default rtl/ip/twn_fuse_ip
#    FUSE_T1_PBLOCK=1  add fuse_t1mem_pblock.xdc to the implementation constraints
#    FUSE_CC_ROWS3=1   -verilog_define FUSE_CC_ROWS3 on synth_1 (RingC 3 rows deep)
#
#  Reports written under vivado/ (FUSE_TAG appended before .rpt if set):
#    util_synth_fuse.rpt, util_hier_synth_fuse.rpt, timing_synth_fuse.rpt,
#    dpcheck_synth_fuse.rpt, and the *_impl_fuse.rpt counterparts.
#
#  Needs: Vivado 2023.2 and the IP already packaged (vivado/package_fuse_ip.tcl).
#  Run:   vivado -mode batch -source vivado/build_bd_fuse.tcl
# ============================================================================
set PART xczu2cg-sfvc784-1-e
set ROOT [file normalize [file dirname [info script]]/..]
set BOARD_PS [expr {[info exists ::env(BOARD_PS)] && $::env(BOARD_PS) == 1}]
set FREQ     [expr {[info exists ::env(TWN_FREQ)]    ? $::env(TWN_FREQ)    : 250}]
set PROJDIR  [expr {[info exists ::env(TWN_PROJDIR)] ? $::env(TWN_PROJDIR) : "$ROOT/build/vivado_proj"}]
set DO_IMPL  [expr {[info exists ::env(FUSE_IMPL)] && $::env(FUSE_IMPL) == 1}]
set DO_BIT   [expr {[info exists ::env(FUSE_BIT)]  && $::env(FUSE_BIT)  == 1}]
set STRAT    [expr {[info exists ::env(BUILD_STRATEGY)] ? $::env(BUILD_STRATEGY) : "Performance_ExplorePostRoutePhysOpt"}]
# Suffix appended to every report and artefact name; empty by default.
set TAG      [expr {[info exists ::env(FUSE_TAG)] ? "_$::env(FUSE_TAG)" : ""}]
# reports, bitstream and XSA are written here
set OUTD $ROOT/build
file mkdir $OUTD

# FUSE_HP3_SPLIT=1 gives the head's weight master (m_axi_gmem3) its own PS port,
# S_AXI_HP3_FPD, through a 1x1 interconnect (sc_hp3), instead of sharing sc_hp2 with
# the head's activation master (m_axi_gmem2). No RTL changes; only the port each
# master reaches differs. It enables HP3 (S_AXI_GP5, 128-bit) in the PS, which
# changes the PS configuration: take FSBL/psu_init from this build's XSA instead of
# swapping only the bitstream.
set HP3_SPLIT [expr {[info exists ::env(FUSE_HP3_SPLIT)] && $::env(FUSE_HP3_SPLIT) == 1}]
set HP3_PS_CFG [expr {$HP3_SPLIT
                      ? {CONFIG.PSU__USE__S_AXI_GP5 {1} CONFIG.PSU__SAXIGP5__DATA_WIDTH {128}}
                      : {}}]

# FUSE_IPDIR: build from another IP repository, e.g. the one package_fuse_ip.tcl
# writes when the same variable is set.
set IPDIR [expr {[info exists ::env(FUSE_IPDIR)] && $::env(FUSE_IPDIR) ne ""
                 ? [file normalize $::env(FUSE_IPDIR)] : "$ROOT/rtl/ip/twn_fuse_ip"}]
if {![file exists $IPDIR/component.xml]} {
    puts "FATAL: $IPDIR/component.xml missing -- run vivado/package_fuse_ip.tcl first"
    exit 1
}
set ::fuse_dp_sourced 1
source $ROOT/vivado/fuse_dp_check.tcl

create_project mbv2_bd_fuse $PROJDIR -part $PART -force
set_property ip_repo_paths [list $IPDIR] [current_project]
update_ip_catalog

create_bd_design "system"

# --- Zynq UltraScale+ processing system ---
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps]
if {$BOARD_PS} {
    source $ROOT/vivado/alinx_ps/ps_config.tcl
    set_ps_config ps
    puts "PS: ALINX AXU2CGB preset applied (DDR4 + MIO) -> board-bootable"
} else {
    puts "PS: Vivado default (sign-off only, NOT board-bootable)"
}
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
    CONFIG.PSU__USE__S_AXI_GP3 {1} \
    CONFIG.PSU__SAXIGP3__DATA_WIDTH {128} \
    CONFIG.PSU__USE__S_AXI_GP4 {1} \
    CONFIG.PSU__SAXIGP4__DATA_WIDTH {128} \
    {*}$HP3_PS_CFG \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $FREQ \
    CONFIG.PSU__USE__IRQ0 {1} \
] $ps

# --- the accelerator ---
set krn [create_bd_cell -type ip -vlnv twn:user:twn_fuse:1.0 fuse_0]

# FUSE_HD_PROBE=1 sets the IP's HD_PROBE parameter, which builds the head engine
# (HSEQ and HDP in twn_fuse_top's g_hd_probe) on m_axi_gmem2 / m_axi_gmem3.
# Without it (the default of this script) no head engine is built in the fabric:
# the build still validates and the head would have to run on the processor.
set HD_PROBE [expr {[info exists ::env(FUSE_HD_PROBE)] && $::env(FUSE_HD_PROBE) == 1}]
if {$HD_PROBE} {
    set_property CONFIG.HD_PROBE {1} $krn
    puts "== HD_PROBE=1: head engine in the fabric on HP2 -- THE SHIPPING CONFIGURATION =="
} else {
    puts "== 🔴 HD_PROBE=0: NO HEAD ENGINE IN THE FABRIC. Legal, but NOT what ships --"
    puts "==    the head falls back to the processor and the board loses about 33.5 fps. =="
}

# --- clocking / reset ---
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl]
connect_bd_net [get_bd_pins ps/pl_clk0]    [get_bd_pins rst_pl/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst_pl/ext_reset_in]

# --- control path: M_AXI_HPM0_FPD -> s_axi_control ---
set sc_ctl [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_ctl]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $sc_ctl
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins sc_ctl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M00_AXI]    [get_bd_intf_pins fuse_0/s_axi_control]

# --- the observation word's sink: an AXI GPIO the processing system can read ---
# obs_gpio is an input-only AXI GPIO that loads fuse_0/obs. It gives the observation
# word a sink inside the design, so no package pins are driven, and makes the word
# readable from the PS over AXI.
set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 obs_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
                         CONFIG.C_IS_DUAL {0} CONFIG.C_INTERRUPT_PRESENT {0}] $gpio
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M01_AXI] [get_bd_intf_pins obs_gpio/S_AXI]
connect_bd_net [get_bd_pins fuse_0/obs] [get_bd_pins obs_gpio/gpio_io_i]

# --- data paths: one master per port, §7.3 ---
set sc0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 sc_hp0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.STRATEGY {2}] $sc0
connect_bd_intf_net [get_bd_intf_pins fuse_0/m_axi_gmem0] [get_bd_intf_pins sc_hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_hp0/M00_AXI]     [get_bd_intf_pins ps/S_AXI_HP0_FPD]

set sc1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 sc_hp1]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.STRATEGY {2}] $sc1
connect_bd_intf_net [get_bd_intf_pins fuse_0/m_axi_gmem1] [get_bd_intf_pins sc_hp1/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_hp1/M00_AXI]     [get_bd_intf_pins ps/S_AXI_HP1_FPD]

# --- head stage: m_axi_gmem2 (activations, read and write) and m_axi_gmem3
# (weights, read only) ---
# Default: both masters into one 2 SI x 1 MI interconnect on HP2.
# FUSE_HP3_SPLIT=1: one 1x1 interconnect per master, on HP2 and HP3.
set sc2 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 sc_hp2]
if {$HP3_SPLIT} {
    # split: one master per port, so sc_hp2 is 1x1 like sc_hp0
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.STRATEGY {2}] $sc2
    connect_bd_intf_net [get_bd_intf_pins fuse_0/m_axi_gmem2] [get_bd_intf_pins sc_hp2/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins sc_hp2/M00_AXI]     [get_bd_intf_pins ps/S_AXI_HP2_FPD]

    set sc3 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 sc_hp3]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.STRATEGY {2}] $sc3
    connect_bd_intf_net [get_bd_intf_pins fuse_0/m_axi_gmem3] [get_bd_intf_pins sc_hp3/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins sc_hp3/M00_AXI]     [get_bd_intf_pins ps/S_AXI_HP3_FPD]
    puts "== 🔴 task #134: HP3 SPLIT -- gmem2 -> sc_hp2 -> HP2, gmem3 -> sc_hp3 -> HP3 =="
} else {
    set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1} CONFIG.STRATEGY {2}] $sc2
    connect_bd_intf_net [get_bd_intf_pins fuse_0/m_axi_gmem2] [get_bd_intf_pins sc_hp2/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins fuse_0/m_axi_gmem3] [get_bd_intf_pins sc_hp2/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins sc_hp2/M00_AXI]     [get_bd_intf_pins ps/S_AXI_HP2_FPD]
}

# --- one PL clock domain ---
set HP3_CLKS [expr {$HP3_SPLIT
    ? {ps/saxihp3_fpd_aclk sc_hp3/ACLK sc_hp3/S00_ACLK sc_hp3/M00_ACLK}
    : {sc_hp2/S01_ACLK}}]
set HP3_RSTS [expr {$HP3_SPLIT
    ? {sc_hp3/ARESETN sc_hp3/S00_ARESETN sc_hp3/M00_ARESETN}
    : {sc_hp2/S01_ARESETN}}]
foreach c [list ps/maxihpm0_fpd_aclk ps/saxihp0_fpd_aclk ps/saxihp1_fpd_aclk \
                ps/saxihp2_fpd_aclk \
                fuse_0/ap_clk sc_ctl/aclk obs_gpio/s_axi_aclk \
                sc_hp0/ACLK sc_hp0/S00_ACLK sc_hp0/M00_ACLK \
                sc_hp1/ACLK sc_hp1/S00_ACLK sc_hp1/M00_ACLK \
                sc_hp2/ACLK sc_hp2/S00_ACLK sc_hp2/M00_ACLK \
                {*}$HP3_CLKS] {
    connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins $c]
}
foreach r [list fuse_0/ap_rst_n sc_ctl/aresetn obs_gpio/s_axi_aresetn \
                sc_hp0/ARESETN sc_hp0/S00_ARESETN sc_hp0/M00_ARESETN \
                sc_hp1/ARESETN sc_hp1/S00_ARESETN sc_hp1/M00_ARESETN \
                sc_hp2/ARESETN sc_hp2/S00_ARESETN sc_hp2/M00_ARESETN \
                {*}$HP3_RSTS] {
    connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins $r]
}

# --- no interrupt output; keep IRQ0 enabled so the PS pinout is unchanged ---
set irqz [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 irq_zero]
set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {1}] $irqz
connect_bd_net [get_bd_pins irq_zero/dout] [get_bd_pins ps/pl_ps_irq0]

# --- addresses ---
# The control window and obs_gpio are placed explicitly before the automatic
# assignment, and the control window is then asserted to be at 0xA0000000.
assign_bd_address -target_address_space /ps/Data \
    [get_bd_addr_segs fuse_0/s_axi_control/reg0] -offset 0xA0000000 -range 0x10000
assign_bd_address -target_address_space /ps/Data \
    [get_bd_addr_segs obs_gpio/S_AXI/Reg]        -offset 0xA0010000 -range 0x10000
assign_bd_address
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data]] {
    puts [format "  PS address map: %-44s offset %s range %s" \
          $s [get_property offset $s] [get_property range $s]]
}
set ctlseg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data] \
            -filter {NAME =~ "*fuse_0*" || NAME =~ "*reg0*"}]
if {[llength $ctlseg] != 1 || [get_property offset [lindex $ctlseg 0]] != 0xA0000000} {
    puts "FATAL: s_axi_control is not at 0xA000_0000 -- sw/app/mbv2_fuse_ps.c would miss it"
    exit 1
}

# Connectivity check. A master connected to nothing still synthesises and validates,
# but the logic behind it is trimmed and the area numbers look plausible. All four
# masters are checked for an interface net; the check is connectivity, not an
# address segment.
foreach m {gmem0 gmem1 gmem2 gmem3} {
    set pin [get_bd_intf_pins -quiet fuse_0/m_axi_$m]
    if {[llength $pin] == 0} {
        puts "FATAL: fuse_0/m_axi_$m is not an interface pin -- the packager did not"
        puts "       infer it as an AXI master; check the port names in twn_fuse_layer.v"
        exit 1
    }
    set net [get_bd_intf_nets -quiet -of_objects $pin]
    if {[llength $net] == 0} {
        puts "FATAL: fuse_0/m_axi_$m is not connected to anything. Its transfers would"
        puts "       go nowhere and every number this build reports would look normal."
        exit 1
    }
    puts [format "  master wiring: m_axi_%-6s -> %s" $m [get_property NAME [lindex $net 0]]]
}
# Each PS HP port in use must be driven by an interconnect (HP3 only with the split).
foreach hp [concat {S_AXI_HP0_FPD S_AXI_HP1_FPD S_AXI_HP2_FPD} \
                   [expr {$HP3_SPLIT ? {S_AXI_HP3_FPD} : {}}]] {
    set net [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins -quiet ps/$hp]]
    if {[llength $net] == 0} {
        puts "FATAL: ps/$hp has nothing driving it -- the interconnect for it was not"
        puts "       connected, so that whole port is dead in this build"
        exit 1
    }
    puts [format "  PS port:       %-16s <- %s" $hp [get_property NAME [lindex $net 0]]]
}
validate_bd_design
save_bd_design

# global (non-out-of-context) synthesis, so top-level constraints can see the cells
set_property synth_checkpoint_mode None [get_files system.bd]

make_wrapper -files [get_files system.bd] -top
add_files -norecurse [get_property DIRECTORY [current_project]]/mbv2_bd_fuse.gen/sources_1/bd/system/hdl/system_wrapper.v
set_property top system_wrapper [current_fileset]

# ---- FUSE_T1_PBLOCK: RB_T1 block RAM pblock ----
# Unset, nothing is added. See fuse_t1mem_pblock.xdc; where the cells ended up is
# printed after implementation.
set T1PB [expr {[info exists ::env(FUSE_T1_PBLOCK)] && $::env(FUSE_T1_PBLOCK) == 1}]
if {$T1PB} {
    add_files -fileset constrs_1 -norecurse $ROOT/vivado/fuse_t1mem_pblock.xdc
    set_property USED_IN_SYNTHESIS false [get_files fuse_t1mem_pblock.xdc]
    puts "== FUSE_T1_PBLOCK=1: RB_T1 block RAM pblock added to constrs_1 =="
} else {
    puts "== FUSE_T1_PBLOCK unset: no floorplan constraint (shipping default) =="
}

# ---- FUSE_CC_ROWS3: RingC (RB_C) three rows deep instead of two ----
# Passes -verilog_define FUSE_CC_ROWS3 to synth_1 (CC_ROWS in twn_fuse_top.v). Synthesis
# is global (synth_checkpoint_mode None above), so the define reaches the IP sources;
# the check after synthesis confirms it from the netlist. Meant to be used together
# with FUSE_T1_PBLOCK=1 (a warning is printed otherwise).
set CC3 [expr {[info exists ::env(FUSE_CC_ROWS3)] && $::env(FUSE_CC_ROWS3) == 1}]
if {$CC3} {
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
                 -value {-verilog_define FUSE_CC_ROWS3} -objects [get_runs synth_1]
    puts "== FUSE_CC_ROWS3=1: RingC depth 3 requested (-verilog_define on synth_1) =="
    if {!$T1PB} {
        puts "== 🔴 WARNING: FUSE_CC_ROWS3 without FUSE_T1_PBLOCK. Depth 3 moves RB_T1's"
        puts "==    18 block RAMs across a clock-region boundary and the pblock is worth"
        puts "==    0.104 ns of the loss. Building this arm without it wastes the build."
    }
} else {
    # CC_ROWS defaults to 2 in twn_fuse_top.v when the define is absent.
    puts "== FUSE_CC_ROWS3 unset: RingC depth 2 (the shipping depth) =="
}

# ============================ synthesis ============================
puts "== launching synthesis @ $FREQ MHz request =="
launch_runs synth_1 -jobs 8
wait_on_runs synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "SYNTHESIS FAILED -- see $PROJDIR/mbv2_bd_fuse.runs/synth_1/runme.log"
    exit 1
}
open_run synth_1 -name synth_1
report_utilization -file $OUTD/util_synth_fuse${TAG}.rpt
report_utilization -hierarchical -hierarchical_depth 5 -file $OUTD/util_hier_synth_fuse${TAG}.rpt
report_timing_summary -file $OUTD/timing_synth_fuse${TAG}.rpt
set swns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "=================================================================="
puts "POST-SYNTHESIS (FUSE, whole design incl. PS + interconnects) @ $FREQ MHz"
set dead [fuse_dp_check $OUTD/dpcheck_synth_fuse${TAG}.rpt $HD_PROBE]
puts [format "  post-synth WNS (estimated routing) = %s ns" $swns]
puts "  reports: vivado/util_synth_fuse.rpt vivado/util_hier_synth_fuse.rpt"
puts "           vivado/timing_synth_fuse.rpt vivado/dpcheck_synth_fuse.rpt"
if {$dead > 0} { puts "  ^^ DATAPATH CHECK FAILED: $dead instance(s) absent" }
# Check the netlist, not the option: RB_C's slot select is a bit at depth 2 and a
# mod-3 decode at depth 3 (twn_rowbuf), so its LUT count rises. The threshold below
# (45 LUT) is a constant taken from an earlier build, not derived from this tree.
if {$CC3} {
    set rbc [get_cells -quiet -hier -filter {NAME =~ *U_TOP/RB_C/* && REF_NAME =~ LUT*}]
    set n_rbc [llength $rbc]
    if {$n_rbc > 45} {
        puts "  CC_ROWS3 VERDICT: RB_C has $n_rbc LUT (> 45, the depth-2 count) -- the define TOOK EFFECT"
    } else {
        puts "  🔴 CC_ROWS3 VERDICT: RB_C has $n_rbc LUT, which is the DEPTH-2 signature."
        puts "     -verilog_define FUSE_CC_ROWS3 did not reach twn_fuse_top.v. Every cycle"
        puts "     number from this build describes depth 2. DO NOT read it as depth 3."
    }
}
puts "=================================================================="
if {!$DO_IMPL} {
    puts "FUSE_IMPL not set -- stopping after synthesis (the block RAM verdict is above)."
    exit 0
}

# ========================= implementation =========================
puts "== impl strategy: $STRAT =="
set_property strategy $STRAT [get_runs impl_1]
launch_runs impl_1 -jobs 8
wait_on_runs impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "IMPLEMENTATION FAILED -- see $PROJDIR/mbv2_bd_fuse.runs/impl_1/runme.log"
    exit 1
}
open_run impl_1
proc slack_setup {} { return [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] }
proc slack_hold  {} { return [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]] }
set wns [slack_setup]
# The implementation strategy can end a few picoseconds below zero. Re-optimise the routed
# design in place (post-route phys_opt, then a re-route and one more pass) before giving up.
puts "POSTROUTE start: WNS $wns WHS [slack_hold]"
foreach d {AggressiveExplore AlternateFlowWithRetiming AggressiveExplore} {
    if {$wns >= 0} break
    phys_opt_design -directive $d
    set wns [slack_setup]
    puts "POSTROUTE phys_opt $d: WNS $wns WHS [slack_hold]"
}
if {$wns < 0} {
    route_design -directive AggressiveExplore -tns_cleanup
    phys_opt_design -directive AggressiveExplore
    set wns [slack_setup]
    puts "POSTROUTE re-route + phys_opt: WNS $wns WHS [slack_hold]"
}
set whs [slack_hold]
report_utilization -file $OUTD/util_impl_fuse${TAG}.rpt
report_utilization -hierarchical -hierarchical_depth 5 -file $OUTD/util_hier_impl_fuse${TAG}.rpt
report_timing_summary -file $OUTD/timing_impl_fuse${TAG}.rpt
puts "=================================================================="
puts "IMPL RESULT (FUSE): WNS = $wns ns @ $FREQ MHz  ([expr {$wns >= 0 ? "TIMING MET" : "TIMING FAILED"}])"
fuse_dp_check $OUTD/dpcheck_impl_fuse${TAG}.rpt $HD_PROBE
puts "  reports: vivado/util_impl_fuse.rpt vivado/util_hier_impl_fuse.rpt"
puts "           vivado/timing_impl_fuse.rpt vivado/dpcheck_impl_fuse.rpt"
puts "=================================================================="

# Read back where the RB_T1 block RAMs were placed: a pblock can exist without the
# cells being inside it. Columns RAMB36_X0..X2 are the expected ones.
if {$T1PB} {
    set t1chk [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == BLOCKRAM && NAME =~ *U_TOP/RB_T1/*}]
    set outside {}
    array unset colhist
    foreach c $t1chk {
        set l [get_property LOC $c]
        if {[regexp {_X(\d+)Y} $l -> cx]} {
            if {![info exists colhist($cx)]} { set colhist($cx) 0 }
            incr colhist($cx)
            if {$cx > 2} { lappend outside "$l  $c" }
        } else { lappend outside "(unplaced)  $c" }
    }
    set hist {}
    foreach k [lsort -integer [array names colhist]] { lappend hist "X$k:$colhist($k)" }
    puts "T132 PBLOCK VERDICT: [llength $t1chk] RB_T1 block RAMs, columns $hist"
    if {[llength $outside] == 0} {
        puts "T132 PBLOCK VERDICT: ALL inside RAMB columns X0..X2 -- the constraint HELD"
    } else {
        puts "T132 PBLOCK VERDICT: [llength $outside] OUTSIDE X0..X2 -- the constraint DID NOT HOLD"
        foreach b $outside { puts "    $b" }
    }
    puts "=================================================================="
}

if {$DO_BIT && $wns >= 0 && $whs >= 0} {
    # No design rule check is waived: the design has no PL package pins (obs goes to
    # obs_gpio).
    # written from the open design, so that any post-route recovery above is what gets built
    write_bitstream -force $PROJDIR/mbv2_bd_fuse.runs/impl_1/system_wrapper.bit
    file copy -force $PROJDIR/mbv2_bd_fuse.runs/impl_1/system_wrapper.bit $OUTD/system_fuse${TAG}.bit
    write_hw_platform -fixed -include_bit -force $OUTD/system_fuse${TAG}.xsa
    puts "bitstream: $OUTD/system_fuse${TAG}.bit   XSA: $OUTD/system_fuse${TAG}.xsa"
} elseif {$DO_BIT} {
    puts "FUSE_BIT set but WNS = $wns, WHS = $whs -- no bitstream written."
}
exit
