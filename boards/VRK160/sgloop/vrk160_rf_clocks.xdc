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
# large negative slack this design first shipped with.
#
# Two things make this harder to write than it looks, and both produced
# builds that silently carried no constraint at all:
#
#   - XDC is a restricted Tcl subset. "if" and "foreach" are rejected with
#     Designutils 20-1307, so anything conditional here does nothing, and a
#     guard like "if {[llength $sel]}" hides its own failure.
#   - The filter's =~ is glob matching, where [0] is a character class that
#     matches the single character 0. "arm_sync_reg[0]" therefore selects
#     nothing, and escaping the brackets does not help either -- measured
#     against a routed checkpoint, it still returns an empty collection.
#
# Selecting by the net avoids both: the name has no glob metacharacters and
# the whole thing is one command. It resolves to the D pin of the first
# synchroniser flop plus the two hierarchical boundary pins, which are
# harmless as false-path endpoints. Verified on a routed checkpoint: WNS
# goes from -3.914 ns to +0.234 ns.
set_false_path -to [get_pins -quiet -of_objects \
    [get_nets -quiet -hier -filter {NAME =~ "*adc_capture_gate*/arm"}] \
    -filter {DIRECTION == IN}]

# freq_word crosses the same way arm does: AXI-Lite domain to the converter's
# fabric clock, taken through two ranks inside dac_tone_src. Target the
# synchroniser's own D pins: selecting by the freq_word net picked up the
# block-design boundary pins instead, which Vivado rejects one bus bit at a
# time with "is not a valid endpoint" -- 32 warnings and no constraint.
#
# This also covers the second rank, whose D is a same-clock path from the
# first and always meets timing. Narrowing it would need "[0]" in the
# pattern, which glob treats as a character class and which therefore
# matches nothing. Verified against a routed checkpoint: 64 pins, both
# ranks, all 32 bits.
set_false_path -to [get_pins -quiet -hier -filter \
    {NAME =~ "*dac_tone_src*fw_sync_reg*/D" && DIRECTION == IN}]
