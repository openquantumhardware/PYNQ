#
# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#

# Step 1: Source the golden reference design
# Pre-set design_name so golden_ref.tcl creates project/BD named "base"
set design_name "base"
source [file join [file dirname [info script]] ../golden/golden_ref.tcl]

# Step 2: Remove PL tie-offs from the golden reference
delete_bd_objs [get_bd_cells pl_tieoff_m00axi]   ;# el tie-off de FPD_AXI_PL
delete_bd_objs [get_bd_cells pl_tieoff_dma0]
delete_bd_objs [get_bd_cells pl_tieoff_dma1]
# axi_gpio_pb itself comes from the golden (it claims the LPDDR5-bank IOB
# sites so pr_verify accepts this overlay); only its stand-in master goes.
delete_bd_objs [get_bd_cells pl_tieoff_pb]
# Disconnect all IRQ nets before deleting the tie-off, otherwise the
# sink pins remain connected and cannot be re-driven.
foreach irq_pin [get_bd_pins ps_wizard_0/pl_ps_irq*] {
    set net [get_bd_nets -of_objects $irq_pin -quiet]
    if {$net ne ""} { delete_bd_objs $net }
}
delete_bd_objs [get_bd_cells pl_tieoff_irq]

# Step 3: PL Peripherals -- Control Path (ps_wizard_0/FPD_AXI_PL)
# Gen 2 has no M_AXI_FPD pin; the direct PS-to-PL master is FPD_AXI_PL,
# enabled by PS_USE_FPD_AXI_PL in golden_ref.tcl. It bypasses the NoC, so
# peripherals sit at conventional 0xA400_0000 addresses and no NoC aperture
# has to be kept in sync with the golden.

# SmartConnect: fan-out ps_wizard_0/FPD_AXI_PL to the 6 PL slaves
set axi_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
set_property -dict [list CONFIG.NUM_MI {6} CONFIG.NUM_SI {1}] $axi_smc

# GPIO: LEDs (4-bit, output)
set axi_gpio_led [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_led]
set_property -dict [list \
    CONFIG.C_INTERRUPT_PRESENT {0} \
    CONFIG.GPIO_BOARD_INTERFACE {gpio_led} \
    CONFIG.USE_BOARD_FLOW {true} \
] $axi_gpio_led

# GPIO: Push buttons -- the cell, its GPIO port and its pin constraints all
# come from golden_ref.tcl, because gpio_pb_0/1 (BD37/BG35, LVSTL05_10) share
# I/O bank silicon with LPDDR5 and therefore belong to the boot partition.
# Here we only give it a real AXI master and an interrupt.

# GPIO: DIP switches (4-bit, input, interrupts enabled)
set axi_gpio_dip_sw [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_dip_sw]
 set_property -dict [list \
 CONFIG.C_INTERRUPT_PRESENT {1} \
 CONFIG.GPIO_BOARD_INTERFACE {gpio_dp} \
 CONFIG.USE_BOARD_FLOW {true} \
 ] $axi_gpio_dip_sw

# BRAM: 8KB read/write test memory
set axi_bram_ctrl_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_0]
set axi_bram_ctrl_0_bram [create_bd_cell -type ip -vlnv xilinx.com:ip:emb_mem_gen:1.0 axi_bram_ctrl_0_bram]
set_property CONFIG.MEMORY_TYPE {True_Dual_Port_RAM} $axi_bram_ctrl_0_bram

# DMA: AXI DMA engine with MM2S and S2MM (simple mode, no scatter-gather)
# c_addr_width 64 is required, not optional: DDR_CH0_MED sits at
# 0x8_0000_0000, above the 32-bit boundary. A 32-bit address width would
# silently truncate and hit the wrong memory.
set axi_dma_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
 set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_addr_width {64} \
    CONFIG.c_m_axi_mm2s_data_width {128} \
    CONFIG.c_m_axi_s2mm_data_width {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
    CONFIG.c_mm2s_burst_size {256} \
    CONFIG.c_s2mm_burst_size {256} \
] $axi_dma_0

# Step 3b: DMA Loopback via AXI Stream FIFO

# AXI Stream Data FIFO: connects DMA MM2S output back to S2MM input
set axis_data_fifo_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_data_fifo_0]
 set_property -dict [list \
    CONFIG.FIFO_DEPTH {1024} \
    CONFIG.TDATA_NUM_BYTES {16} \
] $axis_data_fifo_0

# Step 3c: UART (routed through axi_smc M05_AXI)

set axi_uartlite_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 axi_uartlite_0]
 set_property -dict [list \
 CONFIG.C_S_AXI_ACLK_FREQ_HZ {100000000} \
 CONFIG.UARTLITE_BOARD_INTERFACE {pl_uart_bank713} \
 CONFIG.USE_BOARD_FLOW {true} \
 ] $axi_uartlite_0
# 100 MHz matches PMC_CRP_PL0_REF_CTRL_FREQMHZ in golden_ref.tcl, which is
# the value AMD's own VRK160 designs use. The VCK190 port had 333.33 MHz
# here, which would have skewed the baud rate.

# Step 4: External board interfaces (GPIO, UART)
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0 gpio_led
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0 gpio_dp
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:uart_rtl:1.0 pl_uart_bank713

# Step 5: Interface connections

# BRAM
connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA] [get_bd_intf_pins axi_bram_ctrl_0_bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTB] [get_bd_intf_pins axi_bram_ctrl_0_bram/BRAM_PORTB]

# GPIO board connections
connect_bd_intf_net [get_bd_intf_ports gpio_led] [get_bd_intf_pins axi_gpio_led/GPIO]
connect_bd_intf_net [get_bd_intf_ports gpio_dp]  [get_bd_intf_pins axi_gpio_dip_sw/GPIO]

# UART board connection
connect_bd_intf_net [get_bd_intf_ports pl_uart_bank713] [get_bd_intf_pins axi_uartlite_0/UART]

# FPD_AXI_PL -> SmartConnect -> {GPIO_DIP, GPIO_LED, GPIO_PB, BRAM, DMA_LITE, UART}
connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/FPD_AXI_PL] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins axi_gpio_dip_sw/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] [get_bd_intf_pins axi_gpio_led/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] [get_bd_intf_pins axi_gpio_pb/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M05_AXI] [get_bd_intf_pins axi_uartlite_0/S_AXI]

# DMA data ports -> PL NoC (to DDR)
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins axi_noc_pl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins axi_noc_pl/S01_AXI]

# DMA loopback: MM2S stream -> FIFO -> S2MM stream
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S]     [get_bd_intf_pins axis_data_fifo_0/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_0/M_AXIS]    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]


# Step 6: Clock connections

# pl0_ref_clk drives new PL peripherals (golden_ref.tcl already connected
# pl0_ref_clk to ps_wizard aclk pins, NoC clocks, and rst_pl0)
connect_bd_net [get_bd_pins ps_wizard_0/pl0_ref_clk] \
    [get_bd_pins axi_smc/aclk] \
    [get_bd_pins axi_gpio_dip_sw/s_axi_aclk] \
    [get_bd_pins axi_gpio_led/s_axi_aclk] \
    [get_bd_pins axi_bram_ctrl_0/s_axi_aclk] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins axis_data_fifo_0/s_axis_aclk] \
    [get_bd_pins axi_uartlite_0/s_axi_aclk]

# Step 7: Reset connections

connect_bd_net [get_bd_pins rst_pl0/peripheral_aresetn] \
    [get_bd_pins axi_smc/aresetn] \
    [get_bd_pins axi_gpio_dip_sw/s_axi_aresetn] \
    [get_bd_pins axi_gpio_led/s_axi_aresetn] \
    [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn] \
    [get_bd_pins axi_dma_0/axi_resetn] \
    [get_bd_pins axis_data_fifo_0/s_axis_aresetn] \
    [get_bd_pins axi_uartlite_0/s_axi_aresetn]

# Step 8: Interrupt connections

connect_bd_net [get_bd_pins axi_dma_0/mm2s_introut]        [get_bd_pins ps_wizard_0/pl_ps_irq0]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut]         [get_bd_pins ps_wizard_0/pl_ps_irq1]
connect_bd_net [get_bd_pins axi_gpio_dip_sw/ip2intc_irpt]   [get_bd_pins ps_wizard_0/pl_ps_irq8]
connect_bd_net [get_bd_pins axi_gpio_pb/ip2intc_irpt]        [get_bd_pins ps_wizard_0/pl_ps_irq9]
connect_bd_net [get_bd_pins axi_uartlite_0/interrupt]        [get_bd_pins ps_wizard_0/pl_ps_irq10]

# Tie-off unused IRQ inputs to constant 0
set irq_tieoff [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 irq_tieoff]
set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {1}] $irq_tieoff
foreach idx {2 3 4 5 6 7 11 12 13 14 15} {
    connect_bd_net [get_bd_pins irq_tieoff/dout] [get_bd_pins ps_wizard_0/pl_ps_irq${idx}]
}

# Step 9: Address assignments

# PL peripherals, reached from the PS cores through ps_wizard_0/FPD_AXI_PL.
#
# The direct PS-to-PL master decodes the conventional 0xA400_0000 range --
# the same window AMD's ftloop demo uses for this board. Because it bypasses
# the NoC there is no aperture span to keep byte-identical with the golden,
# which is what an earlier NoC-routed revision of this port required.
#
# The target is each PS core's own address space (Gen 2 assigns from the
# cores, not from a master port). Assigned for the cores that reach PL and
# excluded for the rest, or Vivado emits BD 41-1356 per address space.
set pl_segments {
    {axi_bram_ctrl_0/S_AXI/Mem0   0xA4000000 0x00002000}
    {axi_gpio_dip_sw/S_AXI/Reg    0xA4010000 0x00010000}
    {axi_gpio_led/S_AXI/Reg       0xA4020000 0x00010000}
    {axi_gpio_pb/S_AXI/Reg        0xA4030000 0x00010000}
    {axi_dma_0/S_AXI_LITE/Reg     0xA4040000 0x00010000}
    {axi_uartlite_0/S_AXI/Reg     0xA4050000 0x00010000}
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

# DMA data paths: MM2S and S2MM -> DDR via PL NoC
# Only the low 2GB LPDDR5 aperture is mapped (golden_ref.tcl doesn't wire up
# a second, higher aperture for this board -- see its header comment). If
# one gets added, the kernel's CMA pool needs to stay reachable from here
# too, same as the DDR_LOW1 mapping on the Gen1 VCK190 golden reference.
foreach ch {Data_MM2S Data_S2MM} {
    assign_bd_address -offset 0x00000000 -range 0x80000000 \
        -target_address_space [get_bd_addr_spaces axi_dma_0/$ch] \
        [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY] -force
    assign_bd_address -offset 0x000800000000 -range 0x80000000 \
        -target_address_space [get_bd_addr_spaces axi_dma_0/$ch] \
        [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_MED] -force
}

# Step 10: Validate and save

 validate_bd_design
 save_bd_design