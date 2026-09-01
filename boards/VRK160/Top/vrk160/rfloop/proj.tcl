# Builds the rfloop block design inside the project Hog has already created.
#
# Hog sources this from list/others.src. It must not call create_project --
# golden_ref.tcl guards its own create_project on there being no open project,
# so sourcing rfloop.tcl here does the right thing under both flows: the
# Makefile flow creates the project, Hog's flow finds one already open.
#
# What the guard skips under Hog, and where it moved to:
#   create_project ... -part   -> hog.conf PART
#   BOARD_PART                 -> hog.conf BOARD_PART
#   vrk160_pl_io.xdc           -> list/constraints.con

set hog_root [file normalize [file join [file dirname [info script]] ../../..]]

if {![info exists ::env(PYNQ_VRFDC_IP_REPO)]} {
    error "PYNQ_VRFDC_IP_REPO is not set. The Versal RF Data Converter IP does\
           not ship with Vivado; point this at the AMD IP repository."
}

# rfloop.tcl resolves its own paths from [info script], so sourcing it by its
# real path is enough -- it finds ../golden and hdl/ on its own.
#
# uplevel #0 is NOT optional. Hog sources this file from inside AddHogFiles,
# so a plain "source" runs the whole design script in that proc's local
# scope. golden_ref.tcl sets design_name at script level and its
# create_root_design proc reads it as a global, which fails with
#
#   can't read "design_name": no such variable
#     while executing "apply_board_connection ... -diagram $design_name"
#
# The Makefile flow never hits this because there the script is sourced at
# global scope to begin with. uplevel #0 reproduces that.
uplevel #0 [list source [file join $hog_root rfloop rfloop.tcl]]

# The BD wrapper lands in the project's .gen/ tree, not in Top/. It is
# regenerated every build and must never be committed.
make_wrapper -files [get_files rfloop.bd] -top

set wrapper [get_files -quiet -of_objects [get_filesets sources_1] \
    -filter {NAME =~ "*/rfloop/hdl/rfloop_wrapper.v"}]
if {$wrapper eq ""} {
    set proj_dir  [get_property DIRECTORY [current_project]]
    set proj_name [get_property NAME      [current_project]]
    add_files -norecurse -fileset [get_filesets sources_1] \
        [file normalize \
            "$proj_dir/${proj_name}.gen/sources_1/bd/rfloop/hdl/rfloop_wrapper.v"]
}
