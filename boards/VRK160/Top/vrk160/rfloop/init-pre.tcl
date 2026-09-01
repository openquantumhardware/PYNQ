# Runs as STEPS.INIT_DESIGN.TCL.PRE on impl_1, i.e. before link_design.
#
# CR-1223133: the RF data converter lays down one PVT_SAS per tile -- eight,
# since the IP instantiates all four ADC and all four DAC tiles whatever the
# per-slice enables say -- and the device model reserves those sites, so the
# DRC that precedes place_design refuses:
#
#   ERROR: [DRC UTLZ-1] Resource utilization: PVT_SAS over-utilized
#
# Timing is the whole point. Hog's own pre-implementation hook is registered
# as STEPS.INIT_DESIGN.TCL.POST, which is after link_design and therefore too
# late -- the reservation has already been computed and place_design still
# fails. The Makefile flow works because it sets the param in the session that
# calls launch_runs, and Vivado copies non-default set_param values into the
# top of the generated init_design step. This hook lands in the same place.
set_param device.unreserve_licensed_sites true
