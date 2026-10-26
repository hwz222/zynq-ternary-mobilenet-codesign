# ============================================================================
#  fuse_dp_check.tcl -- check that the datapath instances survived synthesis.
#
#  A utilization total cannot tell "the modules fit" from "synthesis removed one".
#  fuse_dp_check counts LUT / FF / DSP / RAMB cells per instance under U_TOP and
#  reports the instance names in the want list (23, plus HSEQ and HDP when the head
#  is expected) that have no cells at all.
#
#  Use
#    sourced from build_bd_fuse.tcl with a design open (set ::fuse_dp_sourced first,
#    then call  fuse_dp_check <rptfile> [<expect_head>] ), or standalone:
#      vivado -mode batch -source vivado/fuse_dp_check.tcl -tclargs <dcp> [<rpt>]
#
#  expect_head: 1 / 0, or "auto" (default) to read FUSE_HD_PROBE from the
#  environment. The expectation is never inferred from the netlist; when it is
#  unknown the head instances are only reported, not asserted.
#
#  Assumes the accelerator instance is named U_TOP (twn_fuse_layer.v). If synthesis
#  flattened the hierarchy every name matches nothing and the verdict says
#  "flattened" instead of "missing". Capacities (47232 LUT, 94464 FF, 150 BRAM,
#  240 DSP) are those of the XCZU2CG, hard-coded below.
# ============================================================================

proc _fdp_get {cntname kind t} {
    upvar 1 $cntname c
    return [expr {[info exists c($kind,$t)] ? $c($kind,$t) : 0}]
}

# Resolve a wanted instance name to the hierarchy segment that holds it. Vivado puts
# a generate-block scope into the path segment (g_hd_probe.HDP for HDP). An exact
# match wins; otherwise a segment whose last dot-separated component equals the name
# is accepted and reported. More than one such segment is AMBIGUOUS and resolves to
# nothing.
proc _fdp_resolve {seenname t} {
    upvar 1 $seenname seen
    if {[lsearch -exact $seen $t] >= 0} { return [list $t ""] }
    set hits {}
    foreach s $seen {
        if {[string first "." $s] < 0} { continue }
        if {[lindex [split $s "."] end] eq $t} { lappend hits $s }
    }
    if {[llength $hits] == 1} { return [list [lindex $hits 0] [lindex $hits 0]] }
    if {[llength $hits] > 1}  { return [list $t "AMBIGUOUS: $hits"] }
    return [list $t ""]
}

proc fuse_dp_check {rptfile {expect_head auto}} {
    # the datapath instances under U_TOP
    set want {SEQ ARR WMEM WF ARD AWR CSR DT GATH SCAT RB_A RB_C RB_T1 ROT DW RB_OU \
              ENC ISS DWS DWP WARB RESB RES}

    # The head instances are added only when the head is expected. The expectation
    # is an argument (default: FUSE_HD_PROBE) and is not derived from the netlist:
    # inferring it from what the design contains would accept a design with the head
    # deleted.
    if {$expect_head eq "auto"} {
        if {[info exists ::env(FUSE_HD_PROBE)]} {
            set expect_head [expr {$::env(FUSE_HD_PROBE) == 1}]
            set head_src "FUSE_HD_PROBE=$::env(FUSE_HD_PROBE)"
        } else {
            set expect_head "unknown"
            set head_src "neither an argument nor FUSE_HD_PROBE"
        }
    } else {
        set head_src "explicit argument"
    }
    if {$expect_head eq 1} {
        lappend want HSEQ HDP
        set head_note "  head engine: ASSERTED (HSEQ, HDP) -- source: $head_src"
    } elseif {$expect_head eq "unknown"} {
        set head_note "  head engine: NOT ASSERTED -- $head_src. HSEQ/HDP are only REPORTED\n                 below. Every shipping build is FUSE_HD_PROBE=1; if this is one,\n                 this report does not cover a quarter of its logic."
    } else {
        set head_note "  head engine: not expected in this configuration -- source: $head_src"
    }

    array set cnt {}
    set seen {}
    foreach pair [list {lut {REF_NAME =~ LUT*}}      {ff  {REF_NAME =~ FD*}} \
                       {dsp {REF_NAME =~ DSP48E2*}}  {r36 {REF_NAME =~ RAMB36*}} \
                       {r18 {REF_NAME =~ RAMB18*}}] {
        set kind [lindex $pair 0]
        set filt [lindex $pair 1]
        foreach c [get_cells -hier -filter $filt] {
            set i [string first "U_TOP/" $c]
            if {$i < 0} {
                set t "(outside U_TOP)"
            } else {
                set t [lindex [split [string range $c [expr {$i+6}] end] "/"] 0]
            }
            if {[lsearch -exact $seen $t] < 0} { lappend seen $t }
            set k "$kind,$t"
            if {![info exists cnt($k)]} { set cnt($k) 0 }
            incr cnt($k)
        }
    }
    set lut [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
    set ff  [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
    set dsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48E2*}]]
    set r36 [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
    set r18 [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
    set bram [expr {$r36 + 0.5*$r18}]

    set out {}
    lappend out "================ whole design, counted from the netlist ================"
    lappend out [format "  LUT  %6d / 47232  = %5.1f%%" $lut [expr {100.0*$lut/47232}]]
    lappend out [format "  FF   %6d / 94464  = %5.1f%%" $ff  [expr {100.0*$ff/94464}]]
    lappend out [format "  BRAM %6.1f / 150    = %5.1f%%   (%d x RAMB36, %d x RAMB18)" \
                        $bram [expr {100.0*$bram/150}] $r36 $r18]
    lappend out [format "  DSP  %6d / 240    = %5.1f%%" $dsp [expr {100.0*$dsp/240}]]
    lappend out "  ---- datapath instances under U_TOP (0 means synthesis deleted it) ----"
    lappend out $head_note
    set dead {}
    foreach i $want {
        set r  [_fdp_resolve seen $i]
        set ri [lindex $r 0]
        set rn [lindex $r 1]
        lappend resolved_seg $ri
        set l [_fdp_get cnt lut $ri]
        set f [_fdp_get cnt ff  $ri]
        set d [_fdp_get cnt dsp $ri]
        set b [expr {[_fdp_get cnt r36 $ri] + 0.5*[_fdp_get cnt r18 $ri]}]
        if {$l == 0 && $f == 0 && $d == 0 && $b == 0} { lappend dead $i }
        if {$rn ne "" && [string match "AMBIGUOUS*" $rn]} {
            lappend out [format "    %-6s %s" $i $rn]
        } elseif {$rn ne ""} {
            lappend out [format "    %-6s LUT %6d  FF %6d  DSP %4d  BRAM %5.1f   (in %s)"                                 $i $l $f $d $b $rn]
        } else {
            lappend out [format "    %-6s LUT %6d  FF %6d  DSP %4d  BRAM %5.1f" $i $l $f $d $b]
        }
    }
    lappend out "  ---- everything else, so nothing hides in an unnamed bucket ----"
    foreach t [lsort $seen] {
        if {[lsearch -exact $want $t] >= 0} { continue }
        # a segment already reported above under its bare name is not repeated here
        if {[info exists resolved_seg] && [lsearch -exact $resolved_seg $t] >= 0} { continue }
        set l [_fdp_get cnt lut $t]
        set f [_fdp_get cnt ff  $t]
        set d [_fdp_get cnt dsp $t]
        set b [expr {[_fdp_get cnt r36 $t] + 0.5*[_fdp_get cnt r18 $t]}]
        if {$l == 0 && $f == 0 && $d == 0 && $b == 0} { continue }
        lappend out [format "    %-34s LUT %6d  FF %6d  DSP %4d  BRAM %5.1f" $t $l $f $d $b]
    }
    if {[llength $dead] == 0} {
        lappend out "  VERDICT: all [llength $want] datapath instances are present in the netlist."
    } elseif {[llength $dead] == [llength $want]} {
        lappend out "  VERDICT: NONE of the [llength $want] names matched -- this is a FLATTENED"
        lappend out "           hierarchy, not a deletion. Compare the totals above against the"
        lappend out "           out-of-context run before concluding anything."
    } else {
        lappend out "  VERDICT: MISSING -- [join $dead {, }]"
    }
    lappend out "======================================================================="
    set fh [open $rptfile w]
    foreach l $out { puts $l; puts $fh $l }
    close $fh
    return [llength $dead]
}

# standalone entry point (skipped when build_bd_fuse.tcl sources this file)
if {![info exists ::fuse_dp_sourced] && [info exists ::argv] && [llength $::argv] >= 1} {
    open_checkpoint [lindex $::argv 0]
    fuse_dp_check [expr {[llength $::argv] >= 2 ? [lindex $::argv 1] : "fuse_dp_check.rpt"}]
    exit
}
