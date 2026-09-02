# Runs as STEPS.INIT_DESIGN.TCL.POST -- after link_design.
#
# The CR-1223133 set_param lives in init-pre.tcl, not here. Measured: this
# hook is sourced correctly (the run log says "Sourcing user pre-implementation
# file"), and place_design still fails the PVT_SAS DRC, because by the time
# init_design has finished the site reservation is already computed. Setting it
# here as well would only make it look like this is what fixed it.
#
# Kept as the place for anything that genuinely belongs after link_design.
