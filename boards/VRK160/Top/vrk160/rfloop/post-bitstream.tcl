# Runs as STEPS.<binary step>.TCL.POST -- on Versal, after write_device_image.
# By this point the routed checkpoint exists and the PDI has been written.
#
# Two jobs: verify the overlay against the golden, then export the platform.
# pr_verify goes first on purpose -- an incompatible overlay should not leave
# a .xsa behind for someone to pick up.

set here [file dirname [info script]]

# ---------------------------------------------------------------------------
# pr_verify -- the only thing that proves this overlay's PDI is compatible
# with the golden boot PDI. A failure is fatal: loading an incompatible PDI on
# the board reports no error, it just misbehaves.
# ---------------------------------------------------------------------------
set golden_dcp [file normalize [file join $here ../../../golden/golden_routed.dcp]]
if {![file exists $golden_dcp]} {
    error "pr_verify: golden checkpoint not found at $golden_dcp.\
           Build the golden first: make -C boards/VRK160/golden"
}

# The run directory rather than a glob over *.runs: less to get wrong, and it
# follows Hog's Projects/<group>/<project> layout without knowing about it.
set run_dir [get_property DIRECTORY [get_runs impl_1]]
set overlay_dcps [glob -nocomplain [file join $run_dir *routed.dcp]]

# Vivado leaves a *_routed_error.dcp behind when a step failed. Comparing
# against that would be meaningless, so exclude it explicitly.
set candidates {}
foreach d $overlay_dcps {
    if {![string match "*_routed_error.dcp" $d]} { lappend candidates $d }
}
if {[llength $candidates] == 0} {
    error "pr_verify: no routed checkpoint in $run_dir (found: $overlay_dcps)"
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
set out [file normalize [file join $here ../../../rfloop]]
write_hw_platform -fixed -include_bit -force [file join $out rfloop.xsa]
puts "Hog: wrote [file join $out rfloop.xsa]"
puts "Hog: now run 'make -C boards/VRK160/rfloop dtbo' for the device tree overlay"
