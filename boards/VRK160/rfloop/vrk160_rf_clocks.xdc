# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# Reference clocks for the RF data converter tiles used by this overlay.
#
# There are deliberately no LOC constraints here. The converter's analog and
# reference-clock pins are fixed by the silicon once DAC tile 0 and ADC tile
# 3 are selected in the IP, so nothing has to be placed by hand -- which is
# what makes this work on a golden that does not use the Vivado board preset.
# AMD's ftloop reference design constrains exactly these two clocks and
# nothing else.
#
# 491.52 MHz, declared as the 2 ns period the reference design uses.

create_clock -period 2 -name dac0_clk \
    [get_ports -filter { NAME =~ "dac0_clk_clk_p" && DIRECTION == "IN" }]
create_clock -period 2 -name adc3_clk \
    [get_ports -filter { NAME =~ "adc3_clk_clk_p" && DIRECTION == "IN" }]

set_clock_uncertainty -setup 0.05 [get_clocks dac0_clk]
set_clock_uncertainty -setup 0.05 [get_clocks adc3_clk]

# arm crosses from the AXI-Lite domain into the converter's fabric clock.
# adc_capture_gate synchronises it; tell the tool not to time the crossing,
# or it reports the launch clock against the capture clock and produces the
# large negative slack that this design first shipped with.
#
# The index is matched with "string first" on a literal, not with the filter's
# glob: in glob matching "[0]" is a character class that matches the single
# character 0, so the obvious pattern "arm_sync_reg[0]" silently matches
# nothing -- which is how this constraint came to be absent from a build that
# looked like it had one.
set arm_sync {}
foreach cell [get_cells -hier -filter {NAME =~ "*adc_capture_gate*arm_sync_reg*"}] {
    if {[string first {[0]} $cell] >= 0} {
        lappend arm_sync $cell
    }
}
if {[llength $arm_sync]} {
    set_false_path -to [get_pins -of_objects $arm_sync -filter {REF_PIN_NAME == D}]
    puts "vrk160_rf_clocks.xdc: arm CDC false_path applied to [llength $arm_sync] cell(s)"
} else {
    puts "CRITICAL WARNING: vrk160_rf_clocks.xdc: no arm_sync_reg\[0\] cell matched; the arm CDC is being timed and will not close"
}
