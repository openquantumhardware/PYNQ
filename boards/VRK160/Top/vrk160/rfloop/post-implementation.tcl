# Runs as STEPS.ROUTE_DESIGN.TCL.POST -- inside route_design, BEFORE the
# routed checkpoint is written to disk.
#
# pr_verify used to live here and always failed with "no routed checkpoint
# found": at this point Vivado has not yet run "Writing XDEF routing" and the
# .dcp does not exist. It moved to post-bitstream.tcl, which Hog registers as
# STEPS.WRITE_DEVICE_IMAGE.TCL.POST and which therefore runs late enough.
#
# Kept as the place for anything that genuinely belongs inside route_design.
