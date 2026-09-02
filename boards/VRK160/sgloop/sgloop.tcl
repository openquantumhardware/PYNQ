#
# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# VRK160 "sgloop" overlay -- minimal RF loopback.
#
# DAC tile 0 slice 0 emits a tone, the XM855 daughterboard loops it back
# externally, ADC tile 3 slice 0 receives it, and a burst of samples is
# captured to DDR over DMA. Tile choice, sample rate and reference clock
# follow AMD's ftloop reference design for this board.
#
# The waveform comes from QICK's axis_signal_gen_v6: an envelope is streamed
# into it by an MM2S DMA, and a 160-bit descriptor is assembled through
# axi_gpio_desc at 0xA4020000 -- see hdl/sg_desc_src.v. This is the same
# generator QICK drives from its tProc; there is no tProc here yet.
#
# The converter's mixer is set to COARSE at -Fs/4, which is the configuration
# AMD's own generated example project for this IP uses. The fine mixer does
# not modulate on this part: its NCO registers read back correct -- FCW
# scaling linearly with frequency, phase accumulator enabled, mixer mode
# 0xC03 -- and the output does not follow them. Coarse is a fixed shift, so
# the output lands at f_DDS +/- 1966.08 MHz; that is enough to prove the
# mixer stage works at all, which no vendor example demonstrates.
#
# Requires the Versal RF Data Converter IP, which is not part of Vivado:
# point PYNQ_VRFDC_IP_REPO at the extracted VRFDC_Vivado_IP_Repo directory.

set design_name "sgloop"

# Vivado accepts CONFIG.* properties that an IP may then silently ignore.
# CONFIG.IS_ACLK_ASYNC on axis_data_fifo did exactly that here, and the
# consequence only surfaced much later as a clock-domain mismatch that
# pointed at the wrong cell. Read back anything whose silent loss would be
# expensive, and stop rather than build a design that is quietly wrong.
proc verify_config {cell args} {
    foreach {prop want} $args {
        set got [get_property CONFIG.$prop [get_bd_cells $cell]]
        if {$got ne $want} {
            puts "ERROR: $cell CONFIG.$prop reads back as '$got', expected '$want'."
            puts "       The IP did not accept the setting."
            exit 1
        }
    }
}

set script_dir  [file dirname [file normalize [info script]]]

# Step 0: user IP repository for vrf_data_converter
if {![info exists ::env(PYNQ_VRFDC_IP_REPO)]} {
    puts "ERROR: PYNQ_VRFDC_IP_REPO is not set."
    puts "       The Versal RF Data Converter IP does not ship with Vivado."
    puts "       Download the VRFDC Vivado IP repo from AMD and set, e.g.:"
    puts "         export PYNQ_VRFDC_IP_REPO=/path/to/VRFDC_Vivado_IP_Repo_v1_3_<id>"
    exit 1
}
set vrfdc_ip_repo [file normalize $::env(PYNQ_VRFDC_IP_REPO)]
if {![file isdirectory $vrfdc_ip_repo]} {
    puts "ERROR: PYNQ_VRFDC_IP_REPO is not a directory: $vrfdc_ip_repo"
    exit 1
}

# QICK's own IP. axis_signal_gen_v6 declares versal in its component.xml, so
# it can be instantiated for this part as-is; several other QICK cores still
# list only zynquplus and would need the family added before they can be
# used here.
if {![info exists ::env(QICK_IP_REPO)]} {
    puts "ERROR: QICK_IP_REPO is not set."
    puts "       This overlay uses QICK's axis_signal_gen_v6. Point it at the"
    puts "       ip/ directory of the QICK firmware tree, e.g.:"
    puts "         export QICK_IP_REPO=/path/to/qick_internal/firmware/ip"
    exit 1
}
set qick_ip_repo [file normalize $::env(QICK_IP_REPO)]
if {![file isdirectory $qick_ip_repo]} {
    puts "ERROR: QICK_IP_REPO is not a directory: $qick_ip_repo"
    exit 1
}

# Step 1: Source the golden reference design
source [file join $script_dir ../golden/golden_ref.tcl]

# The golden created the project; add the IP repo to it and re-scan.
set_property ip_repo_paths [concat [get_property ip_repo_paths [current_project]] \
                                   $vrfdc_ip_repo $qick_ip_repo] [current_project]
update_ip_catalog -rebuild

if {[llength [get_ipdefs -all xilinx.com:ip:vrf_data_converter:*]] == 0} {
    puts "ERROR: vrf_data_converter not found after adding $vrfdc_ip_repo"
    exit 1
}
# Match on the name, not the full VLNV. The IP in qick_internal/firmware/ip
# is packaged as qick:ip:axis_signal_gen_v6:1.0, while QICK's own ZCU216
# block design tcl instantiates QICK:QICK:axis_signal_gen_v6:1.0 -- the same
# core packaged differently. Pinning the vendor and library here would break
# on whichever of the two the IP repo happens to hold.
set sg_ipdefs [get_ipdefs -all *:axis_signal_gen_v6:*]
if {[llength $sg_ipdefs] == 0} {
    puts "ERROR: axis_signal_gen_v6 not found after adding $qick_ip_repo"
    exit 1
}
set sg_vlnv [lindex $sg_ipdefs 0]
puts "Using signal generator $sg_vlnv"

# Step 2: Remove the PL tie-offs this overlay replaces.
#
# pl_tieoff_pb is deliberately kept: this overlay has no use for the push
# buttons, whose cell the golden owns because their pins share bank silicon
# with LPDDR5. Leaving that stand-in in place keeps the design valid without
# adding logic that does nothing.
delete_bd_objs [get_bd_cells pl_tieoff_m00axi]
delete_bd_objs [get_bd_cells pl_tieoff_dma0]
# rfloop keeps pl_tieoff_dma1 because it has a single DMA. This design has
# two -- capture S2MM and envelope MM2S -- so both PL NoC slave ports are
# used and the stand-in has to go.
delete_bd_objs [get_bd_cells pl_tieoff_dma1]
foreach irq_pin [get_bd_pins ps_wizard_0/pl_ps_irq*] {
    set net [get_bd_nets -of_objects $irq_pin -quiet]
    if {$net ne ""} { delete_bd_objs $net }
}
delete_bd_objs [get_bd_cells pl_tieoff_irq]

# Step 3: RTL sources for the tone source and the capture gate, plus the
# reference-clock constraints for the converter tiles.
add_files -norecurse [glob [file join $script_dir hdl *.v]]
add_files -fileset constrs_1 -norecurse [file join $script_dir vrk160_rf_clocks.xdc]
update_compile_order -fileset sources_1

# Step 4: The converter.
#
# DAC0/ADC3 at 7.86432 GSps from a 491.52 MHz reference with the internal
# PLL, interpolation and decimation by 2, 16-bit data -- AMD's ftloop
# configuration for VRK160. Every parameter name exists unchanged in IP v1.2
# and v1.3.
#
# The DAC mixer settings match the IP's own generated example project
# (vrf_data_converter_0_ex) exactly on the active path. That was established
# by diffing its .xci against this design: on DAC00 + ADC30 the only
# parameters that differed were the three set below.
#
# The IP's coarse-mixer enum is NOT the driver's, and reading one with the
# other cost a week. From component.xml, choice_pairs_3f1ccca9:
#
#     value 0 = Fs/2      value 1 = Fs/4
#     value 2 = -Fs/4     value 3 = 0
#
# whereas XVRFDC_CRS_MIX_* in xvrfdc.h is OFF=0, BYPASS=1, FS_DIV_2=2,
# FS_DIV_4=3, MINUS_FS_DIV_4=4, ... Same concept, disjoint encodings. The GUI
# labels are "Frequency DUC0" for DAC_Coarse_Mixer_Freq00 and "Frequency DDC0"
# for ADC_Coarse_Mixer_Freq30.
#
# So: DAC DUC0 at -Fs/4 (value 2) and ADC DDC0 at Fs/4 (value 1). The two
# shifts cancel, which makes the loopback transparent -- a baseband tone from
# the PL DDS should come back at baseband, with no folding arithmetic needed
# to read the capture. That is the point of the example's choice.
#
# Leaving DAC_Coarse_Mixer_Freq00 unset is not neutral: the parameter defaults
# to 0, which in this enum is Fs/2, not "off". This design had it unset.
#
# DAC_Data_Type is the format of the **analog output**, not of the digital
# input. Setting it to I/Q asks the DAC to drive I and Q on two separate
# analog outputs, which is why the IP then demands "Converter 1 must be
# enabled to output I/Q data". We want one real RF output, so it stays 0 --
# the digital input is still I/Q, and the mixer converts.
#
# Valid (Data_Type, Mixer_Type, Mixer_Mode) triples, found by enumerating the
# IP's rather than reasoning about them:
#
#   0, 1, 0  -> NCO settable   <- used here (low power, as the example does)
#   0, 1, 2  -> NCO disabled
#   0, 2, 0  -> NCO settable   (fine)
#   1, 1, 1  -> NCO settable   } both need the converter pair, and the DAC
#   1, 2, 1  -> NCO settable   } tile does not leave reset in that mode
#
# Mixer_Type 1 is the low-power mixer and 2 is the fine one. PG443 p.151:
# the first-stage low-power mixer supports +/-Fs/4 and +/-Fs/2 only, and is
# independent from the second-stage coarse mixer, which works on an Fs/8 grid
# and hops coherently across all eight of its frequencies.
#
# The low-power baseline above was validated on hardware (build 13): a PL DDS
# tone comes back through DAC -> XM855 -> ADC at the requested frequency to
# within 0.04 MHz across 200 MHz - 3.5 GHz, 85-88 dB over the floor, a single
# clean tone. The two -Fs/4 and Fs/4 shifts cancel, so the capture reads the
# DDS frequency directly. Artifacts kept as sgloop_run13.{pdi,hwh,dtbo}.
#
# This build changes exactly one thing from that baseline: Mixer_Type00 goes
# from 1 (low power) to 2 (fine), to get an NCO that tunes to an arbitrary
# frequency rather than the four values low power allows. Coarse_Mixer_Freq00
# stays at 2.
#
# An earlier fine-mixer attempt produced a three-line comb at 1766.04 /
# 1274.52 / 783.00 MHz -- spacing exactly Fs/8 = 491.52 MHz -- static against
# eight NCO settings from 0 to 900 MHz and visible as a beat on a scope. That
# build had Coarse_Mixer_Freq00 sitting at its default of 0, which in the IP's
# enum is Fs/2, not off; whether that caused the comb is exactly what this
# build tests.
#
# Open question to settle from the generated .hwh, before touching hardware:
# whether Coarse_Mixer_Freq00 survives with Mixer_Type00 = 2 at all. Its
# enablement in component.xml is resolve="generated", so Vivado may drop it.
set vrfdc [create_bd_cell -type ip -vlnv xilinx.com:ip:vrf_data_converter vrf_data_converter_0]
set_property -dict [list \
    CONFIG.ADC3_Outclk_Freq         {491.520} \
    CONFIG.ADC3_PLL_Enable          {true} \
    CONFIG.ADC3_Refclk_Freq         {491.520} \
    CONFIG.ADC3_Sampling_Rate       {7.864320} \
    CONFIG.ADC_Coarse_Mixer_Freq30  {1} \
    CONFIG.ADC_Data_Type30          {1} \
    CONFIG.ADC_Data_Width30         {16} \
    CONFIG.ADC_Decimation_Mode30    {2} \
    CONFIG.ADC_Dither30             {false} \
    CONFIG.ADC_Mode30               {1} \
    CONFIG.ADC_Slice00_Enable       {false} \
    CONFIG.ADC_Slice10_Enable       {false} \
    CONFIG.ADC_Slice20_Enable       {false} \
    CONFIG.ADC_Slice30_Enable       {true} \
    CONFIG.ADC_Sysref_Source        {1} \
    CONFIG.DAC0_Outclk_Freq         {491.520} \
    CONFIG.DAC0_PLL_Enable          {true} \
    CONFIG.DAC0_Refclk_Freq         {491.520} \
    CONFIG.DAC0_Sampling_Rate       {7.864320} \
    CONFIG.DAC_Data_Type00          {0} \
    CONFIG.DAC_Data_Width00         {16} \
    CONFIG.DAC_Interpolation_Mode00 {1} \
    CONFIG.DAC_Coarse_Mixer_Freq00  {3} \
    CONFIG.DAC_Mixer_Mode00         {2} \
    CONFIG.DAC_Mixer_Type00         {1} \
    CONFIG.DAC_NCO_Freq00           {0.0} \
    CONFIG.DAC_Mode00               {1} \
    CONFIG.DAC_RTS                  {false} \
    CONFIG.DAC_Slice00_Enable       {true} \
    CONFIG.DAC_Slice10_Enable       {false} \
    CONFIG.DAC_Slice20_Enable       {false} \
    CONFIG.DAC_Slice30_Enable       {false} \
] $vrfdc

# Step 5: AXIS clock domain.
#
# clk_adc3 is an output of the converter at 491.52 MHz. It is regenerated
# through a clocking wizard onto a BUFG, as the ftloop reference does, and
# that is the clock for everything on the converter side.
#
# It used to be clk_dac0, and the change is deliberate. Reloading the PDI
# without rebooting leaves DAC0 in STATE_OFF while ADC3 comes through
# untouched -- measured, both tiles, clock detector and restart FSM read out
# in sgloop-tile-up.py. With the whole 491.52 MHz fabric domain hanging off
# clk_dac0, the tile that dies is also the one supplying the clock the fabric
# needs to bring it back. Hanging it off clk_adc3 instead breaks that loop:
# ADC3 keeps the fabric clocked while DAC0 restarts.
#
# Both tiles take the same 491.52 MHz board reference (dac0_clk, adc3_clk) and
# both run at 7.86432 GSps, so the AXIS domain stays synchronous to the
# converters -- which is the property QICK relies on and the reason for using
# a converter output clock here rather than an unrelated PL clock. The VRK160
# board file offers no 491.52 MHz to the fabric anyway: its only clock
# interfaces are lpddr5_clk0_1 and lpddr5_clk2_3.
#
# This rests on ADC3 continuing to survive a reload. That is an observation
# from one measurement, not a guarantee.
set clk_rf [create_bd_cell -type ip -vlnv xilinx.com:ip:clkx5_wiz clk_rf_wiz]
set_property -dict [list \
    CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY {491.520,100.000,100.000,100.000,100.000,100.000,100.000} \
    CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
    CONFIG.PRIM_IN_FREQ {491.520} \
    CONFIG.PRIM_SOURCE {No_buffer} \
    CONFIG.RESET_TYPE {ACTIVE_LOW} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {true} \
] $clk_rf

set rst_rf [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_rf]

# Step 6: Datapath
# QICK's signal generator, in place of rfloop's dac_tone_src.
#
# Its m_axis is N_DDS*16 = 256 bits, but those are 16 REAL 16-bit samples,
# not 8 complex ones. That is why this design configures the DAC the way
# QICK's does -- Data_Type 0, Interpolation 1x, Mixer_Mode 2 (Real->Real) --
# rather than the way rfloop does. 16 real samples at 491.52 MHz is 7864.32
# GSps, exactly the converter rate with no interpolation.
#
# N is the envelope memory address width, not the number of DDS lanes: 12
# gives 4096 samples, which is what QICK's tpv2_1ch uses.
set siggen [create_bd_cell -type ip -vlnv $sg_vlnv axis_signal_gen_v6_0]
set_property CONFIG.N {12} $siggen

# The 160-bit descriptor queue. In QICK this comes from the tProc through
# sg_translator; here software assembles it through two GPIO words. See
# hdl/sg_desc_src.v.
set desc_src [create_bd_cell -type module -reference sg_desc_src sg_desc_src_0]

set cap_gate [create_bd_cell -type module -reference adc_capture_gate adc_capture_gate_0]

# The burst buffer, entirely in the 491.52 MHz domain. Its depth is what
# bounds the capture -- see the gate's header.
#
# This FIFO does not cross clock domains. An earlier revision asked it to,
# through CONFIG.IS_ACLK_ASYNC, and the property did not take: M_AXIS kept
# advertising the input clock and validation failed with
#   ERROR: [BD 41-237] FREQ_HZ does not match between
#          /cap_dwidth/S_AXIS(99999001) and /cap_fifo/M_AXIS(491520000)
# The crossing is an axis_clock_converter now, which is unambiguous about
# having two clocks.
set cap_fifo [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo cap_fifo]
set_property -dict [list \
    CONFIG.FIFO_DEPTH {8192} \
    CONFIG.FIFO_MEMORY_TYPE {ultra} \
    CONFIG.TDATA_NUM_BYTES {32} \
    CONFIG.HAS_TLAST {1} \
] $cap_fifo

# 491.52 MHz -> 100 MHz. Still 256 bits wide here; narrowing happens after.
set cap_cc [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter cap_cc]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {32} \
    CONFIG.HAS_TLAST {1} \
] $cap_cc

# 256 -> 128 bits: the PL NoC slave ports are 128-bit and defined by the
# golden, so the DMA cannot be widened to match the converter.
set dwidth [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter cap_dwidth]
set_property -dict [list \
    CONFIG.S_TDATA_NUM_BYTES {32} \
    CONFIG.M_TDATA_NUM_BYTES {16} \
    CONFIG.HAS_TLAST {1} \
] $dwidth

# Integer widths and depth are echoed back verbatim, so they are safe to
# assert on; the converter's float and enum settings are not.
verify_config cap_fifo   FIFO_DEPTH 8192 TDATA_NUM_BYTES 32
verify_config cap_cc     TDATA_NUM_BYTES 32
verify_config cap_dwidth S_TDATA_NUM_BYTES 32 M_TDATA_NUM_BYTES 16

# S2MM only: nothing streams towards the DAC over DMA.
#
# c_sg_length_width is not optional here. Without scatter-gather the buffer
# length register defaults to 14 bits, so a transfer is capped at 16383
# bytes and PYNQ refuses anything larger:
#   ValueError: Transfer size is 262144 bytes, which exceeds the maximum
#   DMA buffer size 16383
# A burst is CAPTURE_BEATS * 32 bytes, 256 KB, so the register has to be
# wide enough to count it. 26 bits is the maximum the IP offers.
set axi_dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_addr_width {64} \
    CONFIG.c_m_axi_s2mm_data_width {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
    CONFIG.c_s2mm_burst_size {256} \
    CONFIG.c_sg_length_width {26} \
] $axi_dma

# MM2S only, feeding the generator's 32-bit envelope port s0_axis. Separate
# from the capture DMA because that one is S2MM only and a single axi_dma
# channel carries one direction.
#
# c_sg_length_width matters here for the same reason it does on the capture
# side: without it the length register is 14 bits and PYNQ refuses any
# envelope longer than 16383 bytes.
set dma_gen [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_gen]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_addr_width {64} \
    CONFIG.c_m_axi_mm2s_data_width {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {256} \
    CONFIG.c_sg_length_width {26} \
] $dma_gen

# Channel 1 out = arm, channel 2 in = busy.
set gpio_cap [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_capture]
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {1}  CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {1} CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_INTERRUPT_PRESENT {0} \
] $gpio_cap

# Descriptor assembly for sg_desc_src: channel 1 is the data word, channel 2
# the control word ({go[16], we[8], index[2:0]}). Both outputs -- the
# readback lives on its own GPIO below.
set gpio_desc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_desc]
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {32}  CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_OUTPUTS_2 {1} \
    CONFIG.C_INTERRUPT_PRESENT {0} \
] $gpio_desc

# sg_desc_src's readback. Same reasoning as dac_tone_src's dbg word in
# rfloop: without it a descriptor that was never latched and one that was
# latched wrong are indistinguishable from software.
set gpio_dbg [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_dbg]
set_property -dict [list \
    CONFIG.C_IS_DUAL {0} \
    CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_INPUTS {1} \
    CONFIG.C_INTERRUPT_PRESENT {0} \
] $gpio_dbg

# Step 7: Control path -- SmartConnect fanning FPD_AXI_PL out to 7 slaves.
# Cells only here; every interface is connected in step 11, after the clocks.
set axi_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
# One clock domain: FPD_AXI_PL and all four AXI-Lite slaves are on
# pl0_ref_clk. The converter's register interface is there too -- only its
# data streams live in the 491.52 MHz domain.
set_property -dict [list CONFIG.NUM_MI {7} CONFIG.NUM_SI {1} CONFIG.NUM_CLKS {1}] $axi_smc


# Step 8: External RF ports (declared here, connected in step 11).
#
# No LOC constraints are needed: the converter's analog and reference-clock
# pins are fixed by the silicon once the tiles are chosen, which is why the
# ftloop XDC only declares the two input clocks. That matters here because
# this board's golden deliberately does not use the Vivado board preset.
create_bd_intf_port -mode Slave  -vlnv xilinx.com:interface:diff_clock_rtl:1.0 dac0_clk
create_bd_intf_port -mode Slave  -vlnv xilinx.com:interface:diff_clock_rtl:1.0 adc3_clk
create_bd_intf_port -mode Slave  -vlnv xilinx.com:display_vrf_data_converter:diff_pins_rtl:1.0 sysref_dac_in
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 vout00
create_bd_intf_port -mode Slave  -vlnv xilinx.com:interface:diff_analog_io_rtl:1.0 vin30


# Step 9: Clocks
#
# clk_adc3, not clk_dac0 -- see Step 5 for why.
connect_bd_net [get_bd_pins $vrfdc/clk_adc3] [get_bd_pins clk_rf_wiz/clk_in1]

set rf_clk [get_bd_pins clk_rf_wiz/clk_out1]
connect_bd_net $rf_clk \
    [get_bd_pins rst_rf/slowest_sync_clk] \
    [get_bd_pins $vrfdc/s0_axis_aclk] \
    [get_bd_pins $vrfdc/m3_axis_aclk] \
    [get_bd_pins axis_signal_gen_v6_0/aclk] \
    [get_bd_pins sg_desc_src_0/aclk] \
    [get_bd_pins adc_capture_gate_0/aclk] \
    [get_bd_pins cap_fifo/s_axis_aclk] \
    [get_bd_pins cap_cc/s_axis_aclk]

# pl0_ref_clk (100 MHz) is the control and DMA domain.
#
# The generator's s0_axis and s_axi belong here, not in the fast domain: only
# aclk (m_axis and s1_axis) runs at 491.52 MHz. That split is what QICK's
# Top/216/tpv2_1ch does -- aclk from clk_dac2, s_axi_aclk and s0_axis_aclk
# both from pl_clk0 -- and it is why the envelope DMA can sit in the control
# domain with no clock converter.
#
# This only works with an IP whose packaging says the same. A packager
# regression (qick_internal deec5846, fixed by 37ee5268) left aclk claiming
# m_axis:s0_axis:s1_axis:s_axi, and IPI then propagates 491.52 MHz onto
# s0_axis and s_axi whatever they are wired to, failing validation with
# FREQ_HZ/CLK_DOMAIN mismatches. If that comes back, repackage the IP rather
# than moving clocks around here.
connect_bd_net [get_bd_pins ps_wizard_0/pl0_ref_clk] \
    [get_bd_pins axi_smc/aclk] \
    [get_bd_pins $vrfdc/s_axi_aclk] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins axi_gpio_capture/s_axi_aclk] \
    [get_bd_pins axi_gpio_desc/s_axi_aclk] \
    [get_bd_pins axi_gpio_dbg/s_axi_aclk] \
    [get_bd_pins axi_dma_gen/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_gen/m_axi_mm2s_aclk] \
    [get_bd_pins axis_signal_gen_v6_0/s_axi_aclk] \
    [get_bd_pins axis_signal_gen_v6_0/s0_axis_aclk] \
    [get_bd_pins cap_cc/m_axis_aclk] \
    [get_bd_pins cap_dwidth/aclk]


# Step 10: Resets
connect_bd_net [get_bd_pins rst_pl0/peripheral_aresetn] \
    [get_bd_pins clk_rf_wiz/resetn] \
    [get_bd_pins rst_rf/ext_reset_in] \
    [get_bd_pins axi_smc/aresetn] \
    [get_bd_pins $vrfdc/s_axi_aresetn] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins axi_gpio_capture/s_axi_aresetn] \
    [get_bd_pins axi_gpio_desc/s_axi_aresetn] \
    [get_bd_pins axi_gpio_dbg/s_axi_aresetn] \
    [get_bd_pins axi_dma_gen/axi_resetn] \
    [get_bd_pins axis_signal_gen_v6_0/s_axi_aresetn] \
    [get_bd_pins axis_signal_gen_v6_0/s0_axis_aresetn] \
    [get_bd_pins cap_cc/m_axis_aresetn] \
    [get_bd_pins cap_dwidth/aresetn]

connect_bd_net [get_bd_pins clk_rf_wiz/locked] [get_bd_pins rst_rf/dcm_locked]

connect_bd_net [get_bd_pins rst_rf/peripheral_aresetn] \
    [get_bd_pins $vrfdc/s0_axis_aresetn] \
    [get_bd_pins $vrfdc/m3_axis_aresetn] \
    [get_bd_pins axis_signal_gen_v6_0/aresetn] \
    [get_bd_pins sg_desc_src_0/aresetn] \
    [get_bd_pins adc_capture_gate_0/aresetn] \
    [get_bd_pins cap_fifo/s_axis_aresetn] \
    [get_bd_pins cap_cc/s_axis_aresetn]

# Step 11: All interface connections.
#
# Deliberately after the clocks. IPI propagates FREQ_HZ and
# CLK_DOMAIN along an interface at the moment it is connected, so wiring the
# streams first leaves cap_fifo/M_AXIS still advertising its input clock and
# validation fails against cap_dwidth/S_AXIS:
#   ERROR: [BD 41-237] Bus Interface property FREQ_HZ does not match
# Control path
connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/FPD_AXI_PL] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins $vrfdc/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] [get_bd_intf_pins axi_gpio_capture/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] [get_bd_intf_pins axi_gpio_desc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] [get_bd_intf_pins axi_gpio_dbg/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M05_AXI] [get_bd_intf_pins axis_signal_gen_v6_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M06_AXI] [get_bd_intf_pins axi_dma_gen/S_AXI_LITE]

# External RF pins
connect_bd_intf_net [get_bd_intf_ports dac0_clk]      [get_bd_intf_pins $vrfdc/dac0_clk]
connect_bd_intf_net [get_bd_intf_ports adc3_clk]      [get_bd_intf_pins $vrfdc/adc3_clk]
connect_bd_intf_net [get_bd_intf_ports sysref_dac_in] [get_bd_intf_pins $vrfdc/sysref_dac_in]
connect_bd_intf_net [get_bd_intf_ports vout00]        [get_bd_intf_pins $vrfdc/vout00]
connect_bd_intf_net [get_bd_intf_ports vin30]         [get_bd_intf_pins $vrfdc/vin30]

# Datapath
connect_bd_intf_net [get_bd_intf_pins axis_signal_gen_v6_0/m_axis] [get_bd_intf_pins $vrfdc/s00_axis]
connect_bd_intf_net [get_bd_intf_pins axi_dma_gen/M_AXIS_MM2S]    [get_bd_intf_pins axis_signal_gen_v6_0/s0_axis]
connect_bd_intf_net [get_bd_intf_pins sg_desc_src_0/m_axis]       [get_bd_intf_pins axis_signal_gen_v6_0/s1_axis]
connect_bd_intf_net [get_bd_intf_pins axi_dma_gen/M_AXI_MM2S]     [get_bd_intf_pins axi_noc_pl/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins $vrfdc/m30_axis]            [get_bd_intf_pins adc_capture_gate_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins adc_capture_gate_0/m_axis]  [get_bd_intf_pins cap_fifo/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins cap_fifo/M_AXIS]            [get_bd_intf_pins cap_cc/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins cap_cc/M_AXIS]              [get_bd_intf_pins cap_dwidth/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins cap_dwidth/M_AXIS]          [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM]       [get_bd_intf_pins axi_noc_pl/S00_AXI]

# Step 12: Capture control and interrupts
connect_bd_net [get_bd_pins axi_gpio_capture/gpio_io_o]  [get_bd_pins adc_capture_gate_0/arm]
connect_bd_net [get_bd_pins adc_capture_gate_0/busy]     [get_bd_pins axi_gpio_capture/gpio2_io_i]
connect_bd_net [get_bd_pins axi_gpio_desc/gpio_io_o]     [get_bd_pins sg_desc_src_0/data]
connect_bd_net [get_bd_pins axi_gpio_desc/gpio2_io_o]    [get_bd_pins sg_desc_src_0/ctrl]
connect_bd_net [get_bd_pins sg_desc_src_0/dbg]           [get_bd_pins axi_gpio_dbg/gpio_io_i]

connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins ps_wizard_0/pl_ps_irq0]
connect_bd_net [get_bd_pins $vrfdc/irq]             [get_bd_pins ps_wizard_0/pl_ps_irq1]

set irq_tieoff [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 irq_tieoff]
set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {1}] $irq_tieoff
foreach idx {2 3 4 5 6 7 8 9 10 11 12 13 14 15} {
    connect_bd_net [get_bd_pins irq_tieoff/dout] [get_bd_pins ps_wizard_0/pl_ps_irq${idx}]
}

# Step 13: Addresses -- same 0xA400_0000 window and the same per-core
# assign/exclude dance base.tcl documents.
# The converter needs 2 MB at 0xA4200000, which is what AMD's ftloop
# reference design assigns it on this board. 256 KB is not enough and the
# shortfall is not diagnosed anywhere useful: the driver's own
# XVRFDC_REGION_SIZE is 0x140000, so tiles whose registers sit past the end
# of a short mapping simply take libmetal down --
#   metal_io_read: Assertion `0' failed
# DAC tile 0 reads fine from a 256 KB window and ADC tile 3 does not, which
# makes it look like a tile problem rather than an address-map one.
# 0xA4030000 is NOT free: the golden's axi_gpio_pb lives there, reached
# through pl_tieoff_pb, which this overlay keeps. rfloop stops at 0xA4020000
# for exactly that reason. validate_bd_design does not flag the overlap --
# the two are in different address spaces -- but mkdtbo.py sees both nodes at
# the same address, which is how it surfaced. Skip 0xA4030000 here.
#
# Note the segment names. Xilinx IP calls its AXI-Lite segment "Reg"; QICK's
# calls it "reg0". Getting it wrong fails as
#   ERROR: [BD 5-432] A peripheral must be specified when '-offset and
#          -range' option exists
# which names neither the segment nor the cell.
set pl_segments {
    {axi_dma_0/S_AXI_LITE/Reg        0xA4000000 0x00010000}
    {axi_gpio_capture/S_AXI/Reg      0xA4010000 0x00010000}
    {axi_gpio_desc/S_AXI/Reg         0xA4020000 0x00010000}
    {axi_gpio_dbg/S_AXI/Reg          0xA4050000 0x00010000}
    {axi_dma_gen/S_AXI_LITE/Reg      0xA4040000 0x00010000}
    {axis_signal_gen_v6_0/s_axi/reg0 0xA4100000 0x00010000}
    {vrf_data_converter_0/s_axi/Reg  0xA4200000 0x00200000}
}

foreach seg $pl_segments {
    lassign $seg seg_path seg_offset seg_range
    foreach core {pmcps_0_psv_cortexa72_0 pmcps_0_psv_cortexa72_1 \
                   pmcps_0_psv_dpc_0 pmcps_0_psv_pmc_0} {
        assign_bd_address -offset $seg_offset -range $seg_range \
            -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
            [get_bd_addr_segs $seg_path] -force
    }
    foreach core {pmcps_0_psv_cortexr5_0 pmcps_0_psv_cortexr5_1 pmcps_0_psv_psm_0} {
        catch {exclude_bd_addr_seg \
            -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
            [get_bd_addr_segs $seg_path]}
    }
}

assign_bd_address -offset 0x00000000 -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY] -force
assign_bd_address -offset 0x000800000000 -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_MED] -force

# The envelope DMA reads from DDR, so its MM2S master needs the same two
# segments the capture DMA's S2MM master has. Without this the address
# editor leaves Data_MM2S unmapped and validation fails on an unassigned
# master rather than on anything that hints at the DMA.
assign_bd_address -offset 0x00000000 -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces axi_dma_gen/Data_MM2S] \
    [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY] -force
assign_bd_address -offset 0x000800000000 -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces axi_dma_gen/Data_MM2S] \
    [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_MED] -force

# The golden wires all four LPDDR5 controllers, but only channel 0 is mapped
# here. Vivado raises a CRITICAL WARNING (BD 41-1356) for every segment that
# is neither assigned nor excluded, so say so explicitly rather than leave
# three of them in the log for someone to wonder about later.
foreach space {axi_dma_0/Data_S2MM axi_dma_gen/Data_MM2S} {
    foreach seg {axi_noc_c1/DDR_MC_PORTS/DDR_CH1 \
                 axi_noc_c2/DDR_MC_PORTS/DDR_CH2 \
                 axi_noc_c3/DDR_MC_PORTS/DDR_CH3} {
        catch {exclude_bd_addr_seg \
            -target_address_space [get_bd_addr_spaces $space] \
            [get_bd_addr_segs $seg]}
    }
}

# Step 14: Validate and save
validate_bd_design
save_bd_design
