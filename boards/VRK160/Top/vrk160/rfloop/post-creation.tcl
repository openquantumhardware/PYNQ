# Runs last in Hog's CreateProject, after others.src and constraints.con.
#
# The top has to be set here rather than in proj.tcl: Hog overrides it to
# top_<project> after others.src runs.
set_property top rfloop_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Segmented Configuration produces boot.pdi + pld.pdi instead of one image.
set_property segmented_configuration true [current_project]

# Lock the NoC solution to the golden's. Without this the overlay solves the
# NoC on its own and pr_verify in post-implementation.tcl fails -- which is
# the whole point of that check.
set golden_ncr [file normalize [file join [file dirname [info script]] \
                                ../../../golden/golden_noc.ncr]]
if {[file exists $golden_ncr]} {
    set_property NOC_SOLUTION_FILE $golden_ncr [get_runs impl_1]
    puts "Hog: NoC solution locked to $golden_ncr"
} else {
    puts "Hog: WARNING -- $golden_ncr not found. Build the golden first\
          (make -C boards/VRK160/golden), or this overlay will not be\
          compatible with the boot PDI."
}

set_property strategy "Flow_PerfOptimized_high"   [get_runs synth_1]

# CR-1223133: register init-pre.tcl to run BEFORE link_design.
#
# Hog's own pre-implementation hook is STEPS.INIT_DESIGN.TCL.POST, which runs
# after link_design and is too late -- measured: the hook is sourced, and
# place_design still fails the PVT_SAS DRC. INIT_DESIGN.TCL.PRE is not used by
# Hog, so it is free for us.
set_property STEPS.INIT_DESIGN.TCL.PRE \
    [file normalize [file join [file dirname [info script]] init-pre.tcl]] \
    [get_runs impl_1]
