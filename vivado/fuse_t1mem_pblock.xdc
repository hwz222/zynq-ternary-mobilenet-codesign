# ============================================================================
#  fuse_t1mem_pblock.xdc -- placement constraint for the RB_T1 block RAMs.
#
#  Puts the block RAM cells of RB_T1 (the expand's output rows, read as a 3-row
#  window and passed through ROT to the depthwise array) into RAMB36 columns X0..X2.
#  Only these cells are constrained. Y is left free.
#
#  Used only when build_bd_fuse.tcl is run with FUSE_T1_PBLOCK=1; it is added to
#  constrs_1 with USED_IN_SYNTHESIS false (placement only).
#
#  The range is a preference, not a fence: the placer can leave members outside it.
#  build_bd_fuse.tcl therefore prints where the cells ended up after implementation.
# ============================================================================

set t1mem [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == BLOCKRAM && NAME =~ *U_TOP/RB_T1/*}]
puts "T132 PBLOCK: RB_T1 block RAM cells matched = [llength $t1mem]"

# The constraint must match exactly the 18 RB_T1 block RAM cells expected for the
# default geometry (3 banks x 3 slices x 2 arrays); if the count differs the
# geometry changed, so stop instead of constraining a subset or nothing.
if {[llength $t1mem] != 18} {
    error "T132 PBLOCK: expected 18 RB_T1 block RAM cells, found [llength $t1mem] -- refusing to apply a constraint whose scope is not what it was reasoned about"
}

create_pblock pb_rb_t1_mem
add_cells_to_pblock [get_pblocks pb_rb_t1_mem] $t1mem
resize_pblock [get_pblocks pb_rb_t1_mem] -add {RAMB36_X0Y0:RAMB36_X2Y35}
resize_pblock [get_pblocks pb_rb_t1_mem] -add {RAMB18_X0Y0:RAMB18_X2Y71}

# Routing is not contained and placement is not exclusive.
set_property CONTAIN_ROUTING   false [get_pblocks pb_rb_t1_mem]
set_property EXCLUDE_PLACEMENT false [get_pblocks pb_rb_t1_mem]
