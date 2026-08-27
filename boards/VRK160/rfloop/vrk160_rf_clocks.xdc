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
