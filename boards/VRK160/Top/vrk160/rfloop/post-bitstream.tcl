# Runs as STEPS.<binary step>.TCL.POST -- on Versal, after write_device_image.
# By this point the routed checkpoint exists and the PDI has been written.
#
# Two jobs: verify the overlay against the golden, then export the platform.
# pr_verify goes first on purpose -- an incompatible overlay should not leave
# a .xsa behind for someone to pick up.

# Do not ask Vivado where anything is. Inside a run step there is no open
# project: [get_runs impl_1] returns an empty object and kills the hook with
# "Invalid option value '' specified for 'object'", and
# [get_property DIRECTORY [current_project]] returns a bare ".", which is the
# Hog root at this point rather than the project.
#
# The script's own path is reliable, and Hog's layout is fixed:
#
#   <hog root>/Top/<group>/<project>/post-bitstream.tcl   <- this file
#   <hog root>/Projects/<group>/<project>/<project>.runs/impl_1/
#
set script_dir [file normalize [file dirname [info script]]]
set project    [file tail $script_dir]
set group      [file tail [file dirname $script_dir]]
set hog_root   [file normalize [file join $script_dir ../../..]]

set dcp_glob [file join $hog_root Projects $group $project *.runs impl_1 *routed.dcp]
set overlay_dcps [glob -nocomplain $dcp_glob]

# ---------------------------------------------------------------------------
# pr_verify -- the only thing that proves this overlay's PDI is compatible
# with the golden boot PDI. A failure is fatal: loading an incompatible PDI on
# the board reports no error, it just misbehaves.
# ---------------------------------------------------------------------------
set golden_dcp [file normalize [file join $script_dir ../../../golden/golden_routed.dcp]]
if {![file exists $golden_dcp]} {
    error "pr_verify: golden checkpoint not found at $golden_dcp.\
           Build the golden first: make -C boards/VRK160/golden"
}



# Vivado leaves a *_routed_error.dcp behind when a step failed. Comparing
# against that would be meaningless, so exclude it explicitly.
set candidates {}
foreach d $overlay_dcps {
    if {![string match "*_routed_error.dcp" $d]} { lappend candidates $d }
}
if {[llength $candidates] == 0} {
    error "pr_verify: no routed checkpoint matched\n  $dcp_glob"
}

set overlay_dcp [lindex $candidates 0]
puts "Hog: pr_verify $golden_dcp against $overlay_dcp"
if {[catch {pr_verify $golden_dcp $overlay_dcp} msg]} {
    error "pr_verify FAILED -- this overlay is NOT compatible with the golden\
           reference, do not load it on the board.\n$msg"
}
puts "Hog: pr_verify PASSED -- overlay is compatible with the golden reference"

# ---------------------------------------------------------------------------
# Export what PYNQ needs.
#
# The .dtbo is NOT built here: it needs sdtgen, a Vitis tool that is not on
# PATH inside a Hog run. Produce it from this .xsa with
#
#     make -C boards/VRK160/rfloop dtbo
#
# Without a .dtbo there is no device tree node, libmetal cannot find the
# converter in sysfs, and the xvrfdc driver fails at import.
# ---------------------------------------------------------------------------
# Not fatal. Hog itself warns "No XSA will be produced in post-bitstream for
# segmented configuration mode", and this runs in the same context, so it may
# well refuse here too. The Makefile flow exports the platform from the
# launching session, where it works, so a failure here costs nothing beyond
# having to run that step by hand.
set out [file normalize [file join $script_dir ../../../rfloop]]
set xsa [file join $out rfloop.xsa]
if {[catch {write_hw_platform -fixed -include_bit -force $xsa} msg]} {
    puts "Hog: could not write $xsa from post-bitstream ($msg)"
    puts "Hog: segmented configuration does not allow it here. Export it with"
    puts "Hog:   make -C boards/VRK160/rfloop pdi"
    puts "Hog: or from the Vivado GUI Tcl console with write_hw_platform."
} else {
    puts "Hog: wrote $xsa"
}
puts "Hog: then 'make -C boards/VRK160/rfloop dtbo' for the device tree overlay"
