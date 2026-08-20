#
# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# VRK160 is a Versal Gen 2 ("VR" / RF series, ES1 silicon) board, unlike the
# Versal Gen 1 (AI Core) VCK190 this was ported from. This script is grounded
# against a real, validated VRK160 design and its exported BD tcl (AMD's
# Vivado-Design-Tutorials/Versal/IP_Integrator/Introduction_to_Versal_IPI,
# project_1/design_1.tcl, Vivado 2025.2, part xcvr1602-vsva2488-2MP-e-S-es1),
# plus one real build attempt of this file against Vivado 2025.2 (see the
# per-line notes below for what each round of that caught).
#
# Confirmed from design_1.tcl:
#   - the PS block is "ps_wizard" (xilinx.com:ip:ps_wizard:1.0), not
#     "versal_cips".
#   - PS_PMC_CONFIG is set key-by-key via CONFIG.PS_PMC_CONFIG(KEY) {value},
#     not as one flat {KEY VALUE KEY VALUE ...} list like versal_cips.
#   - NoC-related keys renamed: PMC_USE_PMC_AXI_NOC0, PS_USE_LPD_AXI_NOC0
#     (versal_cips: PMC_USE_PMC_NOC_AXI0, PS_USE_NOC_LPD_AXI0).
#     PS_USE_FPD_CCI_NOC and PS_USE_PMCPL_CLK0 kept their Gen 1 names.
#   - PS NoC clock pins renamed: fpd_cci_noc0_clk..fpd_cci_noc3_clk,
#     lpd_axi_noc0_clk, pmc_axi_noc0_clk (versal_cips: fpd_cci_noc_axi0_clk
#     etc., lpd_axi_noc_clk, pmc_axi_noc_axi0_clk). pl0_ref_clk/pl0_resetn
#     confirmed unchanged.
#   - there is no DDR4 on this board: memory is LPDDR5, reached through
#     "axi_noc2" (xilinx.com:ip:axi_noc2:1.1), not "axi_noc". The board's
#     LPDDR5 controllers/channels are named Lpddr5_Controller_C0_CH0..C3
#     (XilinxBoardStore vrk160 board.xml); this script wires up only C0
#     CH0+CH1 (one controller, 2 channels), matching the reference design.
#     Populate more channels the same way if a board revision needs the
#     extra capacity.
#   - the LPDDR5 address block is NOT per-NoC-slave-port like Gen 1's
#     C0_DDR_LOW0/LOW1 under axi_noc/S0x_AXI. It's one NoC-wide map,
#     axi_noc2-cell/DDR_MC_PORTS/DDR_CH0_LEGACY (2GB @ 0x0), and
#     assign_bd_address targets the PS core address spaces directly
#     (ps_wizard_0/pmcps_0_psv_cortexa72_0, ..._cortexr5_0, ..._pmc_0, etc.)
#     rather than the FPD_CCI_NOC0.../LPD_AXI_NOC0/PMC_AXI_NOC0 interfaces.
#
# Confirmed from two real build attempts (Vivado 19-7090/19-8017/BD 5-232
# on earlier versions of this file):
#   - PS_USE_M_AXI_FPD / PS_USE_M_AXI_LPD are not valid ps_wizard properties
#     at all ("Invalid parameter ... Ignoring"), and ps_wizard has NO
#     M_AXI_FPD/M_AXI_LPD pins at all -- confirmed directly ("No interface
#     pins matched 'get_bd_intf_pins ps_wizard_0/M_AXI_FPD'", "Arguments to
#     the connect_bd_intf_net command cannot be empty"). There is no
#     dedicated PS-to-PL control-path master pin on Gen 2 the way CIPS had
#     one on Gen 1. Instead (confirmed from design_1.tcl, where FPD_CCI_NOC0
#     reaches both MC_0 and M00_AXI as connection destinations), the PS-to-PL
#     path goes through the axi_noc2 instance's own PL-facing AXI master
#     port (M00_AXI here), fed from a PS NoC slave port (S00_AXI/
#     FPD_CCI_NOC0 below) alongside its DDR destination. See the M00_AXI
#     setup further down.
#   - PS_IRQ_USAGE is a real key, but flat (CH0 1 CH1 1 ...) rather than
#     CIPS's nested ({CH0 1} {CH1 1} ...) -- confirmed from the Vivado
#     19-8017 error text, which echoed the (all-zero) current value in this
#     flat form.
#
# Still NOT confirmed either way:
#   - PS_NUM_F2P0_INTR_INPUTS / PS_NUM_F2P1_INTR_INPUTS key names.
#   - pl1..3_ref_clk/resetn pin names (pattern-matched from pl0_ref_clk/
#     pl0_resetn, not directly observed).
#   - the M00_AXI APERTURES value (0x201_0000_0000, 1G) -- copied from the
#     reference design for the same part, likely a fixed per-device NoC
#     address convention, but not independently derived.
#   - whether axi_noc2 supports inter-NoC INI ports the same way axi_noc
#     does (used below, and in base.tcl, to keep the boot NoC solution
#     locked while the base overlay adds PL DMA masters).
#

namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}
variable script_folder
set script_folder [_tcl::get_script_folder]

set scripts_vivado_version 2025.2
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
    catch {common::send_gid_msg -ssname BD::TCL -id 2041 -severity "WARNING" \
        "This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version>."}
}

# BOARD STORE
# BOARD_PART is resolved against a XilinxBoardStore checkout
# named by BOARD_STORE_PATH.
if {![info exists ::env(BOARD_STORE_PATH)]} {
    error "BOARD_STORE_PATH is not set: point it at a XilinxBoardStore checkout"
}
set board_store $::env(BOARD_STORE_PATH)/boards
if {![file isdirectory $board_store]} {
    error "No boards directory under BOARD_STORE_PATH ($board_store)"
}
set_param board.repoPaths [list $board_store]
puts "Board store: $board_store"

# PROJECT

if {![info exists design_name] || $design_name eq ""} {
    set design_name golden
}

set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
    create_project $design_name $design_name -part xcvr1602-vsva2488-2MP-e-S-es1 -force
    set_property BOARD_PART xilinx.com:vrk160:part0:1.1 [current_project]
}

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

if { ${design_name} eq "" } {
    set errMsg "Please set the variable to a non-empty value."
    return 1
} elseif { ${cur_design} ne "" && ${list_cells} eq "" } {
    if { $cur_design ne $design_name } {
        set design_name [get_property NAME $cur_design]
    }
} elseif { ${cur_design} ne "" && $list_cells ne "" && $cur_design eq $design_name } {
    set errMsg "Design <$design_name> already exists in your project."
    return 1
} elseif { [get_files -quiet ${design_name}.bd] ne "" } {
    set errMsg "Design <$design_name> already exists in your project."
    return 2
} else {
    create_bd_design $design_name
    current_bd_design $design_name
}

# PS-TO-PL APERTURE CONTRACT
#
# The M00_AXI NSU records the *exact span of the address segments assigned
# behind it* -- not the declared CONFIG.APERTURES value, and not a rounded
# power-of-two bucket. Because M00_AXI is fed by S00_AXI, which is a boot
# partition NMU, segmented configuration requires that span to be byte-for-byte
# identical in the golden and in every overlay built against it. A mismatch is
# caught only at pr_verify (Dfx 88-139, "SegConfig-Validation-12"), 40 minutes
# into the overlay build.
#
# So the window is declared once, here. The golden reserves exactly this much
# with its tie-off; every overlay lays its peripherals out to fill exactly this
# much and asserts as much before it starts building.
#
# SIZING: this is deliberately far larger than any single overlay needs. The
# span must be identical across ALL overlays sharing this golden, so if an
# overlay needed a bigger window the golden -- and therefore BOOT.BIN --
# would have to be rebuilt, and one boot image could no longer serve several
# overlays. 256 MB out of the 1 GB declared aperture costs nothing physical
# (it is address space, not logic) and leaves room for a full QICK overlay
# (tProc memories, per-channel readout and signal-generator blocks) alongside
# the small "base" overlay. Treat it as fixed.
#
# An overlay fills the window by placing its LAST address segment so that it
# ends exactly at pl_aperture_base + pl_aperture_size. Overlays whose real
# peripherals do not reach that far use a small "aperture anchor" slave at the
# top -- see base.tcl for the pattern to copy.
set pl_aperture_base 0x020100000000
set pl_aperture_size 0x10000000

# DESIGN CREATION
proc create_root_design { parentCell } {
    global design_name pl_aperture_base pl_aperture_size

    if { $parentCell eq "" } { set parentCell [get_bd_cells /] }
    set parentObj [get_bd_cells $parentCell]
    set parentType [get_property TYPE $parentObj]

    set oldCurInst [current_bd_instance .]
    current_bd_instance $parentObj

    # PS: ps_wizard replaces versal_cips on Versal Gen 2. PS_PMC_CONFIG is
    # set key-by-key via the indexed CONFIG.PS_PMC_CONFIG(KEY) syntax
    # (confirmed from a real, validated VRK160 design's exported BD tcl --
    # AMD's Vivado-Design-Tutorials/.../Introduction_to_Versal_IPI,
    # project_1/design_1.tcl), not as one flat list like versal_cips.
    set ps_wizard_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:ps_wizard:1.0 ps_wizard_0]

    set_property -dict [list \
        CONFIG.PS_BOARD_INTERFACE {ps_pmc_fixed_io} \
        CONFIG.PS_PMC_CONFIG(PMC_USE_PMC_AXI_NOC0) {1} \
        CONFIG.PS_PMC_CONFIG(PS_USE_LPD_AXI_NOC0)  {1} \
        CONFIG.PS_PMC_CONFIG(PS_USE_FPD_CCI_NOC)   {1} \
        CONFIG.PS_PMC_CONFIG(PS_USE_PMCPL_CLK0)    {1} \
        CONFIG.PS_PMC_CONFIG(PS_USE_PMCPL_CLK1)    {1} \
        CONFIG.PS_PMC_CONFIG(PS_USE_PMCPL_CLK2)    {1} \
        CONFIG.PS_PMC_CONFIG(PS_USE_PMCPL_CLK3)    {1} \
        CONFIG.PS_PMC_CONFIG(PS_NUM_FABRIC_RESETS) {4} \
        CONFIG.PS_PMC_CONFIG(PS_IRQ_USAGE) {CH0 1 CH1 1 CH2 1 CH3 1 CH4 1 CH5 1 CH6 1 CH7 1 CH8 1 CH9 1 CH10 1 CH11 1 CH12 1 CH13 1 CH14 1 CH15 1} \
        CONFIG.PS_PMC_CONFIG(PS_NUM_F2P0_INTR_INPUTS) {8} \
        CONFIG.PS_PMC_CONFIG(PS_NUM_F2P1_INTR_INPUTS) {8} \
    ] $ps_wizard_0
    # PMC_USE_PMC_AXI_NOC0/PS_USE_LPD_AXI_NOC0/PS_USE_FPD_CCI_NOC/
    # PS_USE_PMCPL_CLK0/PS_NUM_FABRIC_RESETS/PS_IRQ_USAGE (flat form) are
    # confirmed real keys. PS_USE_PMCPL_CLK1..3 and PS_NUM_F2P0/1_INTR_INPUTS
    # keep their Gen 1 names as a best guess -- NOT confirmed.
    #
    # PS_USE_M_AXI_FPD / PS_USE_M_AXI_LPD deliberately omitted: confirmed
    # invalid on ps_wizard, and confirmed to have no corresponding pins
    # either (see header comment). The PS-to-PL control path used by
    # base.tcl (GPIO/UART/DMA-lite) goes through axi_noc_ps/M00_AXI
    # instead -- set up further down, alongside the rest of axi_noc_ps.

    set_property SELECTED_SIM_MODEL tlm $ps_wizard_0

    # Clock / Reset infrastructure

    # proc_sys_reset for pl0_ref_clk (primary PL clock)
    set rst_pl0 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl0]

    set rst_pl1 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl1]

    set rst_pl2 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl2]

    set rst_pl3 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl3]

    # PS NoC: LPDDR5-only paths, all initial_boot (goes in boot PDI).
    # C0 CH0+CH1 only (one controller, 2 channels); see header comment for
    # extending to more LPDDR5 channels.
    set axi_noc_ps [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc2:1.1 axi_noc_ps]
    set_property -dict [list \
        CONFIG.C0_CH0_LPDDR5_BOARD_INTERFACE {Lpddr5_Controller_C0_CH0_Bank_700_701_702} \
        CONFIG.C0_CH1_LPDDR5_BOARD_INTERFACE {Lpddr5_Controller_C0_CH1_Bank_700_701_702} \
        CONFIG.DDR5_DEVICE_TYPE          {Components} \
        CONFIG.DDRMC5_NUM_CH             {2} \
        CONFIG.NUM_SI    {6} \
        CONFIG.NUM_MI    {1} \
        CONFIG.NUM_MC    {1} \
        CONFIG.NUM_NSI   {1} \
        CONFIG.NUM_NMI   {0} \
        CONFIG.NUM_CLKS  {8} \
    ] $axi_noc_ps
    apply_board_connection -board_interface "Lpddr5_Controller_C0_CH0_Bank_700_701_702" \
        -ip_intf "axi_noc_ps/C0_CH0_LPDDR5" -diagram $design_name
    apply_board_connection -board_interface "Lpddr5_Controller_C0_CH1_Bank_700_701_702" \
        -ip_intf "axi_noc_ps/C0_CH1_LPDDR5" -diagram $design_name
    set_property SELECTED_SIM_MODEL tlm $axi_noc_ps

    # LPDDR5 reference clock. The DDRMC needs sys_clk0 driven from the
    # board's differential LPDDR5 clock through an input buffer -- taken
    # from the reference design (lpddr5_clk0_1 @ 320 MHz -> util_ds_buf ->
    # axi_noc2/sys_clk0). Without it validate_bd_design fails with
    # "BD 41-758: clock pins are not connected to a valid clock source".
    set lpddr5_clk0_1 [create_bd_intf_port -mode Slave \
        -vlnv xilinx.com:interface:diff_clock_rtl:1.0 lpddr5_clk0_1]
    set_property CONFIG.FREQ_HZ {320000000} $lpddr5_clk0_1

    set util_ds_buf_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_0]
    set_property -dict [list \
        CONFIG.DIFF_CLK_IN_BOARD_INTERFACE {lpddr5_clk0_1} \
        CONFIG.USE_BOARD_FLOW {true} \
    ] $util_ds_buf_0

    connect_bd_intf_net [get_bd_intf_ports lpddr5_clk0_1] [get_bd_intf_pins util_ds_buf_0/CLK_IN_D]
    connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_OUT] [get_bd_pins axi_noc_ps/sys_clk0]

    # M00_AXI: PS-to-PL control-path master. Confirmed from the reference
    # design's exported tcl: ps_wizard has no M_AXI_FPD/M_AXI_LPD pins at
    # all on Gen 2 (also confirmed directly -- Vivado's "No interface pins
    # matched 'get_bd_intf_pins ps_wizard_0/M_AXI_FPD'" on a real build of
    # the earlier version of this file). Instead, axi_noc2 itself exposes a
    # PL-facing AXI master (M00_AXI), fed from a PS NoC slave port alongside
    # its DDR (MC_0) destination. APERTURES value copied from the reference
    # design for the same part (xcvr1602-vsva2488-2MP-e-S-es1) -- likely a
    # fixed per-device NoC address convention, but not independently
    # confirmed.
    set_property -dict [list \
        CONFIG.DATA_WIDTH {64} \
        CONFIG.APERTURES {{0x201_0000_0000 1G}} \
        CONFIG.CATEGORY {pl} \
    ] [get_bd_intf_pins /axi_noc_ps/M00_AXI]

    # S00-S03_AXI: FPD_CCI_NOC0..3 -> DDR (initial_boot). S00_AXI also
    # reaches M00_AXI (PS-to-PL control path, not initial_boot -- nothing
    # on the PL side exists until the base overlay loads).
    # Every NoC interface that reaches the DDR MC must connect to BOTH
    # channels (MC_0 and MC_1) -- all or none -- because the controller is
    # configured dual-channel (DDRMC5_NUM_CH 2). Connecting only MC_0 still
    # builds, but Vivado flags BD 41-3714 and the result has *incorrect DDR
    # addressing on hardware*. Confirmed against the reference design, whose
    # every PS slave port lists both MCs.
    set mc_boot {MC_0 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true}} MC_1 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true}}}

    set_property -dict [list \
        CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
        CONFIG.CONNECTIONS "$mc_boot M00_AXI {read_bw {5} write_bw {5}}" \
        CONFIG.DEST_IDS {M00_AXI:0x0} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {ps_cci} \
    ] [get_bd_intf_pins /axi_noc_ps/S00_AXI]
    foreach idx {1 2 3} {
        set_property -dict [list \
            CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
            CONFIG.CONNECTIONS $mc_boot \
            CONFIG.DEST_IDS {} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {ps_cci} \
        ] [get_bd_intf_pins /axi_noc_ps/S0${idx}_AXI]
    }

    # S04_AXI: LPD_AXI_NOC0 -> DDR (initial_boot)
    set_property -dict [list \
        CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
        CONFIG.CONNECTIONS $mc_boot \
        CONFIG.DEST_IDS {} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {ps_rpu} \
    ] [get_bd_intf_pins /axi_noc_ps/S04_AXI]

    # S05_AXI: PMC_AXI_NOC0 -> DDR (initial_boot)
    set_property -dict [list \
        CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
        CONFIG.CONNECTIONS $mc_boot \
        CONFIG.DEST_IDS {} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {ps_pmc} \
    ] [get_bd_intf_pins /axi_noc_ps/S05_AXI]

    # S00_INI: incoming inter-NoC from PL NoC (for PL DMA -> DDR).
    # Both MCs, same dual-channel rule as the PS ports above -- the PL DMA
    # masters reach the MC through this port, so connecting only MC_0 here
    # is what raises BD 41-3714 against /axi_noc_pl/S00_AXI and S01_AXI.
    set_property -dict [list \
        CONFIG.CONNECTIONS {MC_0 {read_bw {500} write_bw {500}} MC_1 {read_bw {500} write_bw {500}}} \
    ] [get_bd_intf_pins /axi_noc_ps/S00_INI]

    # Clock associations for PS NoC
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S00_AXI}] [get_bd_pins /axi_noc_ps/aclk0]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S01_AXI}] [get_bd_pins /axi_noc_ps/aclk1]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S02_AXI}] [get_bd_pins /axi_noc_ps/aclk2]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S03_AXI}] [get_bd_pins /axi_noc_ps/aclk3]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S04_AXI}] [get_bd_pins /axi_noc_ps/aclk4]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S05_AXI}] [get_bd_pins /axi_noc_ps/aclk5]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {M00_AXI}] [get_bd_pins /axi_noc_ps/aclk6]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S00_INI}] [get_bd_pins /axi_noc_ps/aclk7]

    # PL NoC: PL DMA paths to DDR via inter-NoC (no initial_boot)
    set axi_noc_pl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc2:1.1 axi_noc_pl]
    set_property -dict [list \
        CONFIG.NUM_SI    {2} \
        CONFIG.NUM_MI    {0} \
        CONFIG.NUM_MC    {0} \
        CONFIG.NUM_NMI   {1} \
        CONFIG.NUM_NSI   {0} \
        CONFIG.NUM_CLKS  {1} \
    ] $axi_noc_pl
    set_property SELECTED_SIM_MODEL tlm $axi_noc_pl

    # S00_AXI: PL DMA port 0 -> DDR via inter-NoC (M00_INI)
    set_property -dict [list \
        CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
        CONFIG.CONNECTIONS {M00_INI {read_bw {500} write_bw {500}}} \
        CONFIG.DEST_IDS {} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {pl} \
    ] [get_bd_intf_pins /axi_noc_pl/S00_AXI]

    # S01_AXI: PL DMA port 1 -> DDR via inter-NoC (M00_INI)
    set_property -dict [list \
        CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
        CONFIG.CONNECTIONS {M00_INI {read_bw {500} write_bw {500}}} \
        CONFIG.DEST_IDS {} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {pl} \
    ] [get_bd_intf_pins /axi_noc_pl/S01_AXI]

    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S00_AXI:S01_AXI}] [get_bd_pins /axi_noc_pl/aclk0]

    # PL Interface Tie-offs (DRC-clean standalone)

    # Tie-off for axi_noc_ps/M00_AXI (PS-to-PL control path; PS master ->
    # PL slave). Replaces the separate M_AXI_FPD/M_AXI_LPD tie-offs from
    # the Gen 1 port -- there's a single unified PS-to-PL master now.
    set pl_tieoff_m00axi [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vip:1.1 pl_tieoff_m00axi]
    set_property -dict [list \
        CONFIG.INTERFACE_MODE {SLAVE} \
        CONFIG.PROTOCOL {AXI4} \
        CONFIG.ADDR_WIDTH {64} \
        CONFIG.DATA_WIDTH {64} \
    ] $pl_tieoff_m00axi

    # Tie-off for PL NoC S00_AXI (PL DMA port 0 -- needs an AXI master)
    set pl_tieoff_dma0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vip:1.1 pl_tieoff_dma0]
    set_property -dict [list \
        CONFIG.INTERFACE_MODE {MASTER} \
        CONFIG.PROTOCOL {AXI4} \
        CONFIG.DATA_WIDTH {128} \
        CONFIG.ADDR_WIDTH {64} \
    ] $pl_tieoff_dma0

    # Tie-off for PL NoC S01_AXI (PL DMA port 1 -- needs an AXI master)
    set pl_tieoff_dma1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vip:1.1 pl_tieoff_dma1]
    set_property -dict [list \
        CONFIG.INTERFACE_MODE {MASTER} \
        CONFIG.PROTOCOL {AXI4} \
        CONFIG.DATA_WIDTH {128} \
        CONFIG.ADDR_WIDTH {64} \
    ] $pl_tieoff_dma1

    # Tie-off for PL interrupts: constant 0
    set pl_tieoff_irq [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 pl_tieoff_irq]
    set_property -dict [list \
        CONFIG.CONST_VAL {0} \
        CONFIG.CONST_WIDTH {1} \
    ] $pl_tieoff_irq

    # Interface connections
    # (LPDDR5 external ports and connections created by
    # apply_board_connection above)

    # PS -> NoC (DDR paths)
    connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/FPD_CCI_NOC0]  [get_bd_intf_pins axi_noc_ps/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/FPD_CCI_NOC1]  [get_bd_intf_pins axi_noc_ps/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/FPD_CCI_NOC2]  [get_bd_intf_pins axi_noc_ps/S02_AXI]
    connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/FPD_CCI_NOC3]  [get_bd_intf_pins axi_noc_ps/S03_AXI]
    connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/LPD_AXI_NOC0]  [get_bd_intf_pins axi_noc_ps/S04_AXI]
    connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/PMC_AXI_NOC0]  [get_bd_intf_pins axi_noc_ps/S05_AXI]

    # PL NoC inter-NoC connection (PL DMA -> DDR)
    connect_bd_intf_net [get_bd_intf_pins axi_noc_pl/M00_INI] [get_bd_intf_pins axi_noc_ps/S00_INI]

    # PS-to-PL control-path master -> tie-off
    connect_bd_intf_net [get_bd_intf_pins axi_noc_ps/M00_AXI] [get_bd_intf_pins pl_tieoff_m00axi/S_AXI]

    # PL NoC slave ports -> tie-off masters
    connect_bd_intf_net [get_bd_intf_pins pl_tieoff_dma0/M_AXI] [get_bd_intf_pins axi_noc_pl/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins pl_tieoff_dma1/M_AXI] [get_bd_intf_pins axi_noc_pl/S01_AXI]

    # Clock connections

    # PS NoC clocks from ps_wizard. Pin names confirmed from the VRK160
    # reference design's exported BD tcl (see header comment) -- these
    # differ from versal_cips's fpd_cci_noc_axi0_clk / lpd_axi_noc_clk /
    # pmc_axi_noc_axi0_clk.
    connect_bd_net [get_bd_pins ps_wizard_0/fpd_cci_noc0_clk]  [get_bd_pins axi_noc_ps/aclk0]
    connect_bd_net [get_bd_pins ps_wizard_0/fpd_cci_noc1_clk]  [get_bd_pins axi_noc_ps/aclk1]
    connect_bd_net [get_bd_pins ps_wizard_0/fpd_cci_noc2_clk]  [get_bd_pins axi_noc_ps/aclk2]
    connect_bd_net [get_bd_pins ps_wizard_0/fpd_cci_noc3_clk]  [get_bd_pins axi_noc_ps/aclk3]
    connect_bd_net [get_bd_pins ps_wizard_0/lpd_axi_noc0_clk]  [get_bd_pins axi_noc_ps/aclk4]
    connect_bd_net [get_bd_pins ps_wizard_0/pmc_axi_noc0_clk]  [get_bd_pins axi_noc_ps/aclk5]

    # PL clock (pl0_ref_clk) drives PL NoC, tie-offs, and reset
    connect_bd_net [get_bd_pins ps_wizard_0/pl0_ref_clk] \
        [get_bd_pins axi_noc_ps/aclk6] \
        [get_bd_pins axi_noc_ps/aclk7] \
        [get_bd_pins axi_noc_pl/aclk0] \
        [get_bd_pins rst_pl0/slowest_sync_clk] \
        [get_bd_pins pl_tieoff_m00axi/aclk] \
        [get_bd_pins pl_tieoff_dma0/aclk] \
        [get_bd_pins pl_tieoff_dma1/aclk]

    # PL resets -> proc_sys_reset
    connect_bd_net [get_bd_pins ps_wizard_0/pl0_resetn] [get_bd_pins rst_pl0/ext_reset_in]
    connect_bd_net [get_bd_pins ps_wizard_0/pl1_ref_clk] [get_bd_pins rst_pl1/slowest_sync_clk]
    connect_bd_net [get_bd_pins ps_wizard_0/pl1_resetn]  [get_bd_pins rst_pl1/ext_reset_in]
    connect_bd_net [get_bd_pins ps_wizard_0/pl2_ref_clk] [get_bd_pins rst_pl2/slowest_sync_clk]
    connect_bd_net [get_bd_pins ps_wizard_0/pl2_resetn]  [get_bd_pins rst_pl2/ext_reset_in]
    connect_bd_net [get_bd_pins ps_wizard_0/pl3_ref_clk] [get_bd_pins rst_pl3/slowest_sync_clk]
    connect_bd_net [get_bd_pins ps_wizard_0/pl3_resetn]  [get_bd_pins rst_pl3/ext_reset_in]

    # Tie-off resets
    connect_bd_net [get_bd_pins rst_pl0/peripheral_aresetn] \
        [get_bd_pins pl_tieoff_m00axi/aresetn] \
        [get_bd_pins pl_tieoff_dma0/aresetn] \
        [get_bd_pins pl_tieoff_dma1/aresetn]

    # Tie all interrupt inputs to 0
    foreach irq_pin [get_bd_pins ps_wizard_0/pl_ps_irq*] {
        connect_bd_net [get_bd_pins pl_tieoff_irq/dout] $irq_pin
    }

    # Address segments (PS -> DDR only in golden reference).
    # One 2GB LPDDR5 aperture at 0x0 (C0 CH0+CH1). Confirmed from
    # design_1.tcl: unlike Gen 1's axi_noc (one C0_DDR_LOW0/LOW1 pair per
    # NoC slave port), axi_noc2 exposes a single NoC-wide address block
    # (DDR_MC_PORTS/DDR_CH0_LEGACY) directly under the NoC cell, and
    # assign_bd_address targets it from each PS core's own address space,
    # not from the FPD_CCI_NOC0.../LPD_AXI_NOC0/PMC_AXI_NOC0 interfaces.
    # Unlike the Gen 1 golden reference, there is no confirmed high-aperture
    # (DDR_LOW1-equivalent) range for this LPDDR5 config -- add one only
    # after confirming its base/range in Vivado's Address Editor once more
    # channels are enabled.
    foreach core {pmcps_0_psv_cortexa72_0 pmcps_0_psv_cortexa72_1 \
                   pmcps_0_psv_cortexr5_0 pmcps_0_psv_cortexr5_1 \
                   pmcps_0_psv_dpc_0 pmcps_0_psv_pmc_0 pmcps_0_psv_psm_0} {
        assign_bd_address -offset 0x00000000 -range 0x80000000 \
            -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
            [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY] -force
    }

    # PL DMA -> DDR address assignments (through inter-NoC -> PS NoC)
    foreach idx {0 1} {
        assign_bd_address -offset 0x00000000 -range 0x80000000 \
            -target_address_space [get_bd_addr_spaces pl_tieoff_dma${idx}/Master_AXI] \
            [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY] -force
    }

    # PS -> PL control path (M00_AXI tie-off). The range is the reserved
    # aperture declared at the top of this file, NOT an arbitrary tie-off
    # size: the NSU records this span and the overlay must reproduce it
    # exactly. Assigned for the cores that reach PL in the reference design,
    # and explicitly excluded for the rest -- an unassigned, un-excluded
    # slave segment is a BD 41-1356 critical warning per address space.
    foreach core {pmcps_0_psv_cortexa72_0 pmcps_0_psv_cortexa72_1 \
                   pmcps_0_psv_dpc_0 pmcps_0_psv_pmc_0} {
        assign_bd_address -offset $pl_aperture_base -range $pl_aperture_size \
            -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
            [get_bd_addr_segs pl_tieoff_m00axi/S_AXI/Reg] -force
    }
    foreach core {pmcps_0_psv_cortexr5_0 pmcps_0_psv_cortexr5_1 pmcps_0_psv_psm_0} {
        catch {exclude_bd_addr_seg \
            -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
            [get_bd_addr_segs pl_tieoff_m00axi/S_AXI/Reg]}
    }

    current_bd_instance $oldCurInst

    validate_bd_design
    save_bd_design
}

# MAIN FLOW
create_root_design ""
