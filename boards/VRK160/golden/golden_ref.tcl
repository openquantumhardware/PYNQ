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
#     at all, and ps_wizard has NO M_AXI_FPD/M_AXI_LPD pins -- confirmed
#     directly ("No interface pins matched 'ps_wizard_0/M_AXI_FPD'"). The
#     Gen 2 equivalent is PS_USE_FPD_AXI_PL, which exposes an FPD_AXI_PL
#     master that reaches the PL *directly*, bypassing the NoC. PL
#     peripherals then live at conventional 0xA400_0000-range addresses.
#     (An earlier revision of this file routed PS-to-PL control through the
#     NoC's own M00_AXI port instead; that works and passes pr_verify, but
#     forces every overlay to reproduce the NoC NSU's address span exactly.
#     FPD_AXI_PL removes that constraint, and is what AMD's own VRK160
#     designs use.)
#   - PS_IRQ_USAGE is a real key, but flat (CH0 1 CH1 1 ...) rather than
#     CIPS's nested ({CH0 1} {CH1 1} ...) -- confirmed from the Vivado
#     19-8017 error text, which echoed the (all-zero) current value in this
#     flat form.
#
# Still NOT confirmed either way:
#   - PS_NUM_F2P0_INTR_INPUTS / PS_NUM_F2P1_INTR_INPUTS key names.
#   - whether the MIO peripheral set below is complete for every use case;
#     it is copied wholesale from AMD's ftloop demo for this board.
#   - pl1..3_ref_clk/resetn pin names (pattern-matched from pl0_ref_clk/
#     pl0_resetn, not directly observed).
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

    # PL pin constraints (push buttons). Sourced here so both the golden and
    # every overlay that sources this file get the same IO placement.
    add_files -fileset constrs_1 -norecurse \
        [file join [file dirname [info script]] vrk160_pl_io.xdc]
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

# DESIGN CREATION
proc create_root_design { parentCell } {
    global design_name

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

    # MIO peripherals.
    #
    # The ps_pmc_fixed_io board preset does NOT enable these -- every working
    # VRK160 design sets them explicitly. Without them the pins are simply not
    # muxed to the peripherals, and the symptom is a board that boots to total
    # silence: no PLM output, no console, and (without SD1) no way to read
    # BOOT.BIN off the card at all.
    #
    # Values taken from AMD's ftloop demo for this board
    # (demo_examples/ftloop_CL6323708/.../bd_seg.tcl), which is known to boot.
    # The SD tap delays in particular are board-specific timing and must not
    # be invented.
    set_property -dict [list \
        CONFIG.PS_BOARD_INTERFACE {ps_pmc_fixed_io} \
        CONFIG.PS_PMC_CONFIG(PS_UART0_PERIPHERAL) {ENABLE 1 IO PMC_MIO_42:43 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PS_UART1_PERIPHERAL) {ENABLE 1 IO PMC_MIO_38:39 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PMC_SD1_30AD) {CD_ENABLE 1 POW_ENABLE 1 WP_ENABLE 0 RESET_ENABLE 0 CD_IO PMC_MIO_28 POW_IO PMC_MIO_51 WP_IO PMC_MIO_1 RESET_IO PMC_MIO_12 CLK_50_SDR_ITAP_DLY 0x25 CLK_50_SDR_OTAP_DLY 0x4 CLK_50_DDR_ITAP_DLY 0x2A CLK_50_DDR_OTAP_DLY 0x3 CLK_100_SDR_OTAP_DLY 0x3 CLK_200_SDR_OTAP_DLY 0x2} \
        CONFIG.PS_PMC_CONFIG(PMC_SD1_30AD_PERIPHERAL) {PRIMARY_ENABLE 0 SECONDARY_ENABLE 1 IO PMC_MIO_26:36 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PS_ENET0_PERIPHERAL) {ENABLE 1 IO PS_MIO_0:11 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PS_ENET0_MDIO) {ENABLE 1 IO PS_MIO_24:25 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PS_I2C0_PERIPHERAL) {ENABLE 1 IO PMC_MIO_46:47 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PS_I2C1_PERIPHERAL) {ENABLE 1 IO PMC_MIO_44:45 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PMC_OSPI_PERIPHERAL) {PRIMARY_ENABLE 1 SECONDARY_ENABLE 0 IO PMC_MIO_0:13 MODE Single} \
        CONFIG.PS_PMC_CONFIG(PS_USB3_PERIPHERAL) {ENABLE 1 IO PMC_MIO_13:25 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PMC_CRP_PL0_REF_CTRL_FREQMHZ) {100} \
        CONFIG.PS_PMC_CONFIG(PS_USE_FPD_AXI_PL) {1} \
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
        CONFIG.PS_PMC_CONFIG(PS_GEN_IPI0_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_GEN_IPI1_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_GEN_IPI1_MASTER) {R5_0} \
        CONFIG.PS_PMC_CONFIG(PS_GEN_IPI2_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_GEN_IPI2_MASTER) {R5_1} \
        CONFIG.PS_PMC_CONFIG(PS_GEN_IPI3_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_GEN_IPI4_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_GEN_IPI5_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_GEN_IPI6_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_TTC0_PERIPHERAL_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_TTC0_WAVEOUT) {ENABLE 1 IO PS_MIO_23 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PS_TTC1_PERIPHERAL_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_TTC2_PERIPHERAL_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_TTC3_PERIPHERAL_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PMC_CRP_HSM1_REF_CTRL_FREQMHZ) {200} \
        CONFIG.PS_PMC_CONFIG(PMC_HSM1_CLK_OUT_ENABLE) {1} \
        CONFIG.PS_PMC_CONFIG(PS_I2CSYSMON_PERIPHERAL) {ENABLE 0 IO_TYPE MIO IO PS_MIO_13:14} \
        CONFIG.PS_PMC_CONFIG(SMON_INTERFACE_TO_USE) {I2C} \
        CONFIG.PS_PMC_CONFIG(SMON_PMBUS_ADDRESS) {0x18} \
        CONFIG.PS_PMC_CONFIG(PS_SLR_ID) {0} \
        CONFIG.PS_PMC_CONFIG(PMC_SD0_30AD_PERIPHERAL) {PRIMARY_ENABLE 0 SECONDARY_ENABLE 0 IO PMC_MIO_13:25 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PMC_SD0_30_PERIPHERAL) {PRIMARY_ENABLE 0 SECONDARY_ENABLE 0 IO PMC_MIO_13:25 IO_TYPE MIO} \
        CONFIG.PS_PMC_CONFIG(PMC_MIO12) {DRIVE_STRENGTH 8mA SLEW slow PULL pullup SCHMITT 0 AUX_IO 0 USAGE GPIO OUTPUT_DATA default DIRECTION out} \
        CONFIG.PS_PMC_CONFIG(PS_MIO7)  {DRIVE_STRENGTH 8mA SLEW slow PULL disable SCHMITT 0 AUX_IO 0 USAGE Reserved OUTPUT_DATA default DIRECTION in} \
        CONFIG.PS_PMC_CONFIG(PS_MIO9)  {DRIVE_STRENGTH 8mA SLEW slow PULL disable SCHMITT 0 AUX_IO 0 USAGE Reserved OUTPUT_DATA default DIRECTION in} \
        CONFIG.PS_PMC_CONFIG(PS_MIO11) {DRIVE_STRENGTH 8mA SLEW slow PULL disable SCHMITT 0 AUX_IO 0 USAGE Reserved OUTPUT_DATA default DIRECTION in} \
        CONFIG.PS_PMC_CONFIG(PS_MIO12) {DRIVE_STRENGTH 8mA SLEW slow PULL pullup SCHMITT 0 AUX_IO 0 USAGE GPIO OUTPUT_DATA default DIRECTION out} \
        CONFIG.PS_PMC_CONFIG(PS_MIO15) {DRIVE_STRENGTH 8mA SLEW slow PULL pullup SCHMITT 0 AUX_IO 0 USAGE GPIO OUTPUT_DATA default DIRECTION in} \
        CONFIG.PS_PMC_CONFIG(PS_MIO16) {DRIVE_STRENGTH 8mA SLEW slow PULL pullup SCHMITT 0 AUX_IO 0 USAGE GPIO OUTPUT_DATA default DIRECTION out} \
        CONFIG.PS_PMC_CONFIG(PS_MIO21) {DRIVE_STRENGTH 8mA SLEW slow PULL pullup SCHMITT 0 AUX_IO 0 USAGE GPIO OUTPUT_DATA default DIRECTION in} \
        CONFIG.PS_PMC_CONFIG(PS_MIO22) {DRIVE_STRENGTH 8mA SLEW slow PULL pullup SCHMITT 0 AUX_IO 0 USAGE GPIO OUTPUT_DATA default DIRECTION out} \
] $ps_wizard_0
    # PMC_USE_PMC_AXI_NOC0/PS_USE_LPD_AXI_NOC0/PS_USE_FPD_CCI_NOC/
    # PS_USE_PMCPL_CLK0/PS_NUM_FABRIC_RESETS/PS_IRQ_USAGE (flat form) are
    # confirmed real keys. PS_USE_PMCPL_CLK1..3 and PS_NUM_F2P0/1_INTR_INPUTS
    # keep their Gen 1 names as a best guess -- NOT confirmed.
    #
    # PS_USE_M_AXI_FPD / PS_USE_M_AXI_LPD deliberately omitted: confirmed
    # invalid on ps_wizard, and confirmed to have no corresponding pins
    # either (see header comment). The PS-to-PL control path used by
    # base.tcl (GPIO/UART/DMA-lite) goes through ps_wizard_0/FPD_AXI_PL
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
        CONFIG.MC_CHAN_REGION1 {DDR_CH0_MED} \
        CONFIG.DDR5_DEVICE_TYPE          {Components} \
        CONFIG.DDRMC5_NUM_CH             {2} \
        CONFIG.NUM_SI    {6} \
        CONFIG.NUM_MI    {0} \
        CONFIG.NUM_MC    {1} \
        CONFIG.NUM_NSI   {1} \
        CONFIG.NUM_NMI   {3} \
        CONFIG.NUM_CLKS  {7} \
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

    # LPDDR5 controllers C1, C2 and C3 (12 GB on top of C0's 4 GB).
    # Mirrors the known-good reference design: C1 is dual-channel and shares
    # the 320 MHz board clock with C0; C2 and C3 are single-channel and take
    # their reference from the PS's hsm1_ref_clk (200 MHz), which is why
    # PMC_HSM1_CLK_OUT_ENABLE is set above.
    foreach {inst ch region bif0 bif1} {
        axi_noc_c1 2 DDR_CH1 Lpddr5_Controller_C1_CH0_Bank_703_704_705 Lpddr5_Controller_C1_CH1_Bank_703_704_705
        axi_noc_c2 1 DDR_CH2 Lpddr5_Controller_C2_Bank_706_707_int {}
        axi_noc_c3 1 DDR_CH3 Lpddr5_Controller_C3_Bank_709_710_int {}
    } {
        set cell [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc2:1.1 $inst]
        set cfg [list \
            CONFIG.C0_CH0_LPDDR5_BOARD_INTERFACE $bif0 \
            CONFIG.MC_CHAN_REGION0 $region \
            CONFIG.DDR5_DEVICE_TYPE {Components} \
            CONFIG.DDRMC5_NUM_CH   $ch \
            CONFIG.NUM_SI  {0} CONFIG.NUM_MI {0} CONFIG.NUM_MC {1} \
            CONFIG.NUM_NSI {2} CONFIG.NUM_NMI {0} CONFIG.NUM_CLKS {0}]
        if {$bif1 ne {}} { lappend cfg CONFIG.C0_CH1_LPDDR5_BOARD_INTERFACE $bif1 }
        set_property -dict $cfg $cell
        apply_board_connection -board_interface $bif0 \
            -ip_intf "$inst/C0_CH0_LPDDR5" -diagram $design_name
        if {$bif1 ne {}} {
            apply_board_connection -board_interface $bif1 \
                -ip_intf "$inst/C0_CH1_LPDDR5" -diagram $design_name
        }
        set_property SELECTED_SIM_MODEL tlm $cell

        # Single-channel controllers expose MC_0 only.
        if {$ch == 2} {
            set conn {MC_0 {read_bw {500} write_bw {500} read_avg_burst {4} write_avg_burst {4} initial_boot {true}} MC_1 {read_bw {500} write_bw {500} read_avg_burst {4} write_avg_burst {4} initial_boot {true}}}
        } else {
            set conn {MC_0 {read_bw {500} write_bw {500} read_avg_burst {4} write_avg_burst {4} initial_boot {true}}}
        }
        foreach nsi {S00_INI S01_INI} {
            set_property -dict [list CONFIG.INI_STRATEGY {load} CONFIG.CONNECTIONS $conn] \
                [get_bd_intf_pins $inst/$nsi]
        }
    }

    # Inter-NoC links: PS NoC -> each remote controller
    connect_bd_intf_net [get_bd_intf_pins axi_noc_ps/M00_INI] [get_bd_intf_pins axi_noc_c1/S00_INI]
    connect_bd_intf_net [get_bd_intf_pins axi_noc_ps/M01_INI] [get_bd_intf_pins axi_noc_c2/S00_INI]
    connect_bd_intf_net [get_bd_intf_pins axi_noc_ps/M02_INI] [get_bd_intf_pins axi_noc_c3/S00_INI]
    foreach nmi {M00_INI M01_INI M02_INI} {
        set_property -dict [list CONFIG.INI_STRATEGY {load}] [get_bd_intf_pins axi_noc_ps/$nmi]
    }

    # Reference clocks: C1 shares the board LPDDR5 clock, C2/C3 use hsm1_ref_clk
    connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_OUT] [get_bd_pins axi_noc_c1/sys_clk0]
    connect_bd_net [get_bd_pins ps_wizard_0/hsm1_ref_clk] \
        [get_bd_pins axi_noc_c2/sys_clk0] \
        [get_bd_pins axi_noc_c3/sys_clk0]

    # S00-S03_AXI: FPD_CCI_NOC0..3 -> DDR (initial_boot).
    #
    # Every NoC interface that reaches the DDR MC must connect to BOTH
    # channels (MC_0 and MC_1) -- all or none -- because the controller is
    # configured dual-channel (DDRMC5_NUM_CH 2). Connecting only MC_0 still
    # builds, but Vivado flags BD 41-3714 and the result has *incorrect DDR
    # addressing on hardware*. Confirmed against the reference design, whose
    # every PS slave port lists both MCs.
    # Remote controllers C1/C2/C3 are reached through inter-NoC links
    # (M00/M01/M02_INI). Every PS master must list them alongside the local
    # MC or it can only ever see the first 4 GB.
    set ini_boot {M00_INI {read_bw {500} write_bw {500} initial_boot {true}} M01_INI {read_bw {500} write_bw {500} initial_boot {true}} M02_INI {read_bw {500} write_bw {500} initial_boot {true}}}

    set mc_boot {MC_0 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true}} MC_1 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true}}}

    foreach idx {0 1 2 3} {
        set_property -dict [list \
            CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
            CONFIG.CONNECTIONS [concat $mc_boot $ini_boot] \
            CONFIG.DEST_IDS {} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {ps_cci} \
        ] [get_bd_intf_pins /axi_noc_ps/S0${idx}_AXI]
    }

    # S04_AXI: LPD_AXI_NOC0 -> DDR (initial_boot)
    set_property -dict [list \
        CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
        CONFIG.CONNECTIONS [concat $mc_boot $ini_boot] \
        CONFIG.DEST_IDS {} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {ps_rpu} \
    ] [get_bd_intf_pins /axi_noc_ps/S04_AXI]

    # S05_AXI: PMC_AXI_NOC0 -> DDR (initial_boot)
    set_property -dict [list \
        CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
        CONFIG.CONNECTIONS [concat $mc_boot $ini_boot] \
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
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S00_INI}] [get_bd_pins /axi_noc_ps/aclk6]

    # PL NoC: PL DMA paths to DDR via inter-NoC (no initial_boot)
    set axi_noc_pl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc2:1.1 axi_noc_pl]
    set_property -dict [list \
        CONFIG.NUM_SI    {2} \
        CONFIG.NUM_MI    {0} \
        CONFIG.NUM_MC    {0} \
        CONFIG.NUM_NMI   {4} \
        CONFIG.NUM_NSI   {0} \
        CONFIG.NUM_CLKS  {1} \
    ] $axi_noc_pl
    set_property SELECTED_SIM_MODEL tlm $axi_noc_pl

    # PL masters reach all four controllers directly -- one NMI each. Chaining
    # them through the PS NoC's S00_INI instead fails with BD 41-2202: an INI
    # link must have a single driver or a single load, not a fan-out of both.
    set pl_ini {M00_INI {read_bw {500} write_bw {500}} M01_INI {read_bw {500} write_bw {500}} M02_INI {read_bw {500} write_bw {500}} M03_INI {read_bw {500} write_bw {500}}}

    # S00_AXI: PL DMA port 0 -> DDR via inter-NoC
    set_property -dict [list \
        CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
        CONFIG.CONNECTIONS $pl_ini \
        CONFIG.DEST_IDS {} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {pl} \
    ] [get_bd_intf_pins /axi_noc_pl/S00_AXI]

    # S01_AXI: PL DMA port 1 -> DDR via inter-NoC
    set_property -dict [list \
        CONFIG.DATA_WIDTH {128} CONFIG.REGION {0} \
        CONFIG.CONNECTIONS $pl_ini \
        CONFIG.DEST_IDS {} CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {pl} \
    ] [get_bd_intf_pins /axi_noc_pl/S01_AXI]

    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S00_AXI:S01_AXI}] [get_bd_pins /axi_noc_pl/aclk0]

    # PL Interface Tie-offs (DRC-clean standalone)

    # Tie-off for ps_wizard_0/FPD_AXI_PL -- the direct PS-to-PL control
    # master. Enabled by PS_USE_FPD_AXI_PL above; it bypasses the NoC
    # entirely, so PL peripherals live at conventional 0xA400_0000-range
    # addresses and there is no NoC aperture to keep in sync between the
    # golden and its overlays.
    set pl_tieoff_m00axi [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vip:1.1 pl_tieoff_m00axi]
    set_property -dict [list \
        CONFIG.INTERFACE_MODE {SLAVE} \
        CONFIG.PROTOCOL {AXI4} \
        CONFIG.ADDR_WIDTH {64} \
        CONFIG.DATA_WIDTH {128} \
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

    # Push buttons (2 bits, inputs, interrupts enabled).
    #
    # Instantiated in the *golden* so the boot partition claims IOB sites
    # BD37/BG35; an overlay may not add boot-partition IO. The board preset is
    # deliberately not used -- see vrk160_pl_io.xdc for why. Overlays keep this
    # cell and simply re-point its S_AXI at their own interconnect.
    set axi_gpio_pb [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_pb]
    set_property -dict [list \
        CONFIG.C_GPIO_WIDTH {2} \
        CONFIG.C_ALL_INPUTS {1} \
        CONFIG.C_IS_DUAL {0} \
        CONFIG.C_INTERRUPT_PRESENT {1} \
        CONFIG.GPIO_BOARD_INTERFACE {Custom} \
        CONFIG.USE_BOARD_FLOW {false} \
    ] $axi_gpio_pb

    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0 gpio_pb
    connect_bd_intf_net [get_bd_intf_ports gpio_pb] [get_bd_intf_pins axi_gpio_pb/GPIO]

    # Tie-off master so the GPIO has a driver in the standalone golden.
    # Overlays delete just this cell and drive S_AXI from their interconnect.
    set pl_tieoff_pb [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vip:1.1 pl_tieoff_pb]
    set_property -dict [list \
        CONFIG.INTERFACE_MODE {MASTER} CONFIG.PROTOCOL {AXI4LITE} \
        CONFIG.ADDR_WIDTH {64} CONFIG.DATA_WIDTH {32} \
    ] $pl_tieoff_pb
    connect_bd_intf_net [get_bd_intf_pins pl_tieoff_pb/M_AXI] [get_bd_intf_pins axi_gpio_pb/S_AXI]

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
    connect_bd_intf_net [get_bd_intf_pins axi_noc_pl/M01_INI] [get_bd_intf_pins axi_noc_c1/S01_INI]
    connect_bd_intf_net [get_bd_intf_pins axi_noc_pl/M02_INI] [get_bd_intf_pins axi_noc_c2/S01_INI]
    connect_bd_intf_net [get_bd_intf_pins axi_noc_pl/M03_INI] [get_bd_intf_pins axi_noc_c3/S01_INI]
    foreach nmi {M00_INI M01_INI M02_INI M03_INI} {
        set_property -dict [list CONFIG.INI_STRATEGY {load}] [get_bd_intf_pins axi_noc_pl/$nmi]
    }

    # PS-to-PL control-path master (direct, not via NoC) -> tie-off
    connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/FPD_AXI_PL] [get_bd_intf_pins pl_tieoff_m00axi/S_AXI]

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

    # PL clock (pl0_ref_clk) drives PL NoC, tie-offs, and reset.
    # fpd_axi_pl_aclk is the FPD_AXI_PL port's own clock input -- the Gen 2
    # counterpart of Gen 1's m_axi_fpd_aclk. Leaving it unconnected fails
    # validation with BD 41-758.
    connect_bd_net [get_bd_pins ps_wizard_0/pl0_ref_clk] \
        [get_bd_pins axi_noc_ps/aclk6] \
        [get_bd_pins axi_noc_pl/aclk0] \
        [get_bd_pins rst_pl0/slowest_sync_clk] \
        [get_bd_pins ps_wizard_0/fpd_axi_pl_aclk] \
        [get_bd_pins pl_tieoff_m00axi/aclk] \
        [get_bd_pins pl_tieoff_dma0/aclk] \
        [get_bd_pins pl_tieoff_dma1/aclk] \
        [get_bd_pins pl_tieoff_pb/aclk] \
        [get_bd_pins axi_gpio_pb/s_axi_aclk]

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
        [get_bd_pins pl_tieoff_dma1/aresetn] \
        [get_bd_pins pl_tieoff_pb/aresetn] \
        [get_bd_pins axi_gpio_pb/s_axi_aresetn]

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
    # Both DDR regions of controller C0 must be mapped: LEGACY (2 GB at 0x0)
    # and MED (2 GB at 0x8_0000_0000). A working VRK160 image declares both in
    # its memory node -- reg = <0x0 0x0 0x0 0x80000000  0x8 0x0 0x0 0x80000000>
    # -- and AMD's ftloop demo assigns both. With only LEGACY the PLM still
    # loads the whole boot PDI without complaint, but the handoff to u-boot
    # dies silently right after "Total PLM Boot Time".
    # LEGACY (2 GB at 0x0) is reachable by every PS core.
    foreach core {pmcps_0_psv_cortexa72_0 pmcps_0_psv_cortexa72_1 \
                   pmcps_0_psv_cortexr5_0 pmcps_0_psv_cortexr5_1 \
                   pmcps_0_psv_dpc_0 pmcps_0_psv_pmc_0 pmcps_0_psv_psm_0} {
        assign_bd_address -offset 0x00000000 -range 0x80000000 \
            -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
            [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY] -force
    }

    # MED (2 GB at 0x8_0000_0000) only for the cores whose address aperture
    # reaches above 32 bits. The R5s and the PSM are limited to <0x0 [2G]>
    # and Vivado rejects the assignment with BD 41-1075.
    foreach core {pmcps_0_psv_cortexa72_0 pmcps_0_psv_cortexa72_1 \
                   pmcps_0_psv_dpc_0 pmcps_0_psv_pmc_0} {
        assign_bd_address -offset 0x000800000000 -range 0x80000000 \
            -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
            [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_MED] -force
    }

    # Remote controllers C1/C2/C3: 4 GB each, at the same base addresses a
    # working VRK160 image reports (0x500/0x600/0x700_0000_0000). Only the
    # 64-bit-capable cores, same aperture limit as DDR_CH0_MED above.
    foreach {inst region base} {
        axi_noc_c1 DDR_CH1 0x050000000000
        axi_noc_c2 DDR_CH2 0x060000000000
        axi_noc_c3 DDR_CH3 0x070000000000
    } {
        foreach core {pmcps_0_psv_cortexa72_0 pmcps_0_psv_cortexa72_1 \
                       pmcps_0_psv_dpc_0 pmcps_0_psv_pmc_0} {
            assign_bd_address -offset $base -range 0x000100000000 \
                -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
                [get_bd_addr_segs ${inst}/DDR_MC_PORTS/${region}] -force
        }
        foreach idx {0 1} {
            assign_bd_address -offset $base -range 0x000100000000 \
                -target_address_space [get_bd_addr_spaces pl_tieoff_dma${idx}/Master_AXI] \
                [get_bd_addr_segs ${inst}/DDR_MC_PORTS/${region}] -force
        }
    }

    # PL DMA -> DDR address assignments (through inter-NoC -> PS NoC)
    foreach idx {0 1} {
        assign_bd_address -offset 0x00000000 -range 0x80000000 \
            -target_address_space [get_bd_addr_spaces pl_tieoff_dma${idx}/Master_AXI] \
            [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY] -force
        assign_bd_address -offset 0x000800000000 -range 0x80000000 \
            -target_address_space [get_bd_addr_spaces pl_tieoff_dma${idx}/Master_AXI] \
            [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_MED] -force
    }

    # The tie-off master needs the GPIO mapped in its own address space.
    assign_bd_address -offset 0xA4030000 -range 0x00010000 \
        -target_address_space [get_bd_addr_spaces pl_tieoff_pb/Master_AXI] \
        [get_bd_addr_segs axi_gpio_pb/S_AXI/Reg] -force

    # PS -> PL control path (FPD_AXI_PL tie-off) at the conventional
    # 0xA400_0000 PL range -- the same window the AMD ftloop demo uses for
    # its PL peripherals. Assigned for the cores that reach PL, excluded for
    # the rest, so no BD 41-1356 critical warnings.
    foreach core {pmcps_0_psv_cortexa72_0 pmcps_0_psv_cortexa72_1 \
                   pmcps_0_psv_dpc_0 pmcps_0_psv_pmc_0} {
        assign_bd_address -offset 0xA4000000 -range 0x00010000 \
            -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
            [get_bd_addr_segs pl_tieoff_m00axi/S_AXI/Reg] -force
    }
    foreach core {pmcps_0_psv_cortexr5_0 pmcps_0_psv_cortexr5_1 pmcps_0_psv_psm_0} {
        catch {exclude_bd_addr_seg \
            -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
            [get_bd_addr_segs pl_tieoff_m00axi/S_AXI/Reg]}
        # The R5s and the PSM top out at a 2 GB aperture, so every segment
        # above it must be explicitly excluded or Vivado raises BD 41-1356.
        foreach seg {axi_noc_ps/DDR_MC_PORTS/DDR_CH0_MED \
                     axi_noc_c1/DDR_MC_PORTS/DDR_CH1 \
                     axi_noc_c2/DDR_MC_PORTS/DDR_CH2 \
                     axi_noc_c3/DDR_MC_PORTS/DDR_CH3} {
            catch {exclude_bd_addr_seg \
                -target_address_space [get_bd_addr_spaces ps_wizard_0/${core}] \
                [get_bd_addr_segs $seg]}
        }
    }

    current_bd_instance $oldCurInst

    validate_bd_design
    save_bd_design
}

# MAIN FLOW
create_root_design ""
