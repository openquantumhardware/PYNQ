# VRK160 PYNQ Board Port

Build notes for the VRK160 board directory: what the golden reference design
is, why Versal needs one, every place this port differs from the Versal
Gen 1 (VCK190) port it was derived from, and how to build an SD card from
scratch.

> New to Versal? [§12 Glossary](#13-glossary) explains every acronym used
> here — PLM, PDI, NoC, NMU/NSU, CCI and the rest — grouped by domain.
>
> Want to *build* something on this board rather than understand the port?
> Go straight to **[BUILDING_OVERLAYS.md](BUILDING_OVERLAYS.md)** — the full
> path from an empty directory to a PDI the board loads.

Status: **validated on hardware.** The board boots this port's own image to a
PYNQ Linux login, exposes all 16 GB of LPDDR5, loads the `base` overlay at
runtime through the FPGA manager, and passes GPIO, BRAM and DMA loopback
tests. See [§9 Verification status](#10-verification-status) for exactly what
was tested and what was not.

## What it took

Bring-up hit **six independent defects**, each capable of stopping the boot on
its own. They are listed here because every one of them is invisible in a
clean build log — the tools report success and the board simply does nothing.

| Layer | Defect | Symptom | Fix |
| --- | --- | --- | --- |
| PS | MIO peripherals never configured | total silence, not even the PLM banner | [§3.9](#39-mio-peripherals-are-not-set-by-the-board-preset) |
| PS | inter-processor interrupts disabled | PLM finishes, then nothing | [§3.10](#310-the-ps-needs-ipi-or-tf-a-never-starts) |
| Device tree | `no-1-8-v` missing on the SD controller | u-boot cannot read the card | [§3.12](#312-the-sd-controller-needs-no-1-8-v) |
| Python | `pynqmetadata` dependency unpinned | `import pynq` fails on any Versal board | [§8.1](#91-pynqmetadata-must-come-from-the-pynq-next-branch) |
| Python | `pydantic` pinned to an incompatible major | `ImportError: ConfigDict` | [§8.2](#92-pydantic-must-be-2x) |
| Python | `mem_dict_view.py` indexes the wrong dict | `KeyError` on any overlay with a BRAM | [§8.3](#93-mem_dict_view-looks-up-the-wrong-key) |

The last three are **upstream PYNQ defects**, not specific to this board. Any
Versal port hits the first two immediately; the third breaks any platform
whose overlay contains an AXI BRAM controller.

## How they were found

Every one of them fell out of the same method: **diff against something that
works**, rather than reasoning about what ought to be wrong.

* The IPI defect came from diffing this port's 24 `PS_PMC_CONFIG` keys against
  the 52 in AMD's own VRK160 reference design. The PLM had been printing
  `INFO: IPIs disabled` at every boot attempt for days.
* `no-1-8-v` came from diffing the generated `system.dtb`'s `mmc` node against
  a known-good image's. It was the only difference in the whole node.
* The `mem_dict_view` bug came from comparing it against `ip_dict_view.py`,
  which does the same lookup correctly.

If you are debugging this port and something does not boot, find a working
artefact and diff it before theorising.

> Two of the defects were **non-fatal messages that let a broken artefact
> through** — the dual-channel LPDDR5 warning
> ([§3.8](#38-dual-channel-lpddr5-connect-both-mcs)) and a `pr_verify` failure
> that `build_pdi.tcl` downgraded to a warning while still printing "built
> successfully". `build_pdi.tcl` now treats `pr_verify` failure as fatal.
> Treat a clean exit status as necessary, not sufficient.

---

## 1. Why a golden reference design

On Versal, the PL is not programmed from a bare bitstream. The platform boots
a **PDI** (Programmable Device Image) that the PLM loads, and PYNQ wants to
swap PL designs at runtime without rebooting.

Versal's **segmented configuration** makes that possible by splitting one
design into two images:

| Image | Contains | Loaded by |
| --- | --- | --- |
| `boot.pdi` | PS, NoC, memory controller | PLM at boot, inside `BOOT.BIN` |
| `pld.pdi` | PL logic only | Linux at runtime, via the FPGA manager |

The catch: a runtime `pld.pdi` is only accepted if it is a **segmented child
of the exact parent design** that produced the running `boot.pdi` — the
parent image ID and the NoC solution must match.

So the flow is:

1. **`golden/`** builds a minimal parent design (PS + NoC + LPDDR5, with the
   PL side stubbed out by AXI VIP tie-offs). It exports `golden.xsa`
   (→ `BOOT.BIN`), `golden_noc.ncr` (the NoC contract) and
   `golden_routed.dcp` (the `pr_verify` reference).
2. **`base/`** re-sources the same golden block design, deletes the tie-offs,
   drops in the real PL peripherals, and builds a `pld.pdi` **locked to
   `golden_noc.ncr`**, then `pr_verify`s it against `golden_routed.dcp`.

That lock is why `base.tcl` sources `golden_ref.tcl` instead of duplicating
it: any drift between the two would break the parent/child relationship.

---

## 2. Board facts

| | Value | Source |
| --- | --- | --- |
| Part | `xcvr1602-vsva2488-2MP-e-S-es1` | board store `board.xml`; note `-es1` (engineering sample silicon) |
| Board part | `xilinx.com:vrk160:part0:1.1` | versions `1.0` and `1.1` ship in Vivado 2025.2's board store |
| Family | Versal **Gen 2** (VR / RF series) | — |
| Memory | **LPDDR5**, 4 controllers / 6 channels | `Lpddr5_Controller_C0_CH0..C3` in `board.xml` |
| Memory clock | `lpddr5_clk0_1`, 320 MHz differential | `board.xml`, confirmed against reference design |
| PL UART | `pl_uart_bank713` | `board.xml` |
| GPIO | `gpio_led` (4), `gpio_dp` (4) `LVCMOS12`; `gpio_pb` (**2**) `LVSTL05_10` at BD37/BG35 | `board.xml`, `part0_pins.xml` |
| Vivado | 2025.2 | — |

This port wires up **all four controllers -- 16 GB**, matching AMD's own
working VRK160 image. C0 and C1 are dual-channel and share the 320 MHz board
clock; C2 and C3 are single-channel and take their reference from the PS's
`hsm1_ref_clk`. See [§3.11](#311-all-four-lpddr5-controllers).

`gpio_pb` needs special handling: its pins are `LVSTL05_10` and sit in an
LPDDR5 bank, so the golden has to claim them --
[§3.13](#313-push-buttons-share-an-lpddr5-io-bank).

---

## 3. Versal Gen 1 → Gen 2: what actually changes

This is the core of the port. The VCK190 directory is **not** a
search-and-replace away from working — the PS IP, the NoC IP, the memory
technology and the PS-to-PL path are all different.

### 3.1 IP swaps

| | VCK190 (Gen 1) | VRK160 (Gen 2) |
| --- | --- | --- |
| PS block | `xilinx.com:ip:versal_cips:3.4` | `xilinx.com:ip:ps_wizard:1.0` |
| NoC | `xilinx.com:ip:axi_noc:1.1` | `xilinx.com:ip:axi_noc2:1.1` |
| Memory | DDR4 (`ddr4_dimm1`) | LPDDR5 (`Lpddr5_Controller_C0_CH*`) |
| Reset | `proc_sys_reset:5.0` | `proc_sys_reset:5.0` (unchanged) |

### 3.2 `PS_PMC_CONFIG` is set differently

`versal_cips` takes one flat list. `ps_wizard` takes **indexed properties**,
one `set_property` key at a time:

```tcl
# Gen 1 (VCK190) — flat list, read-modify-write
set pmc_cfg [get_property CONFIG.PS_PMC_CONFIG $versal_cips_0]
dict_set_flat pmc_cfg PS_USE_FPD_CCI_NOC {1}
set_property CONFIG.PS_PMC_CONFIG $pmc_cfg $versal_cips_0

# Gen 2 (VRK160) — indexed, key by key
set_property -dict [list \
    CONFIG.PS_PMC_CONFIG(PS_USE_FPD_CCI_NOC) {1} \
] $ps_wizard_0
```

### 3.3 Renamed configuration keys

| Gen 1 key | Gen 2 key |
| --- | --- |
| `PMC_USE_PMC_NOC_AXI0` | `PMC_USE_PMC_AXI_NOC0` |
| `PS_USE_NOC_LPD_AXI0` | `PS_USE_LPD_AXI_NOC0` |
| `PS_USE_FPD_CCI_NOC` | unchanged |
| `PS_USE_PMCPL_CLK0` | unchanged |
| `PS_NUM_FABRIC_RESETS` | unchanged |

`PS_IRQ_USAGE` exists on both but takes a **different value shape**:

```tcl
# Gen 1: nested
{{CH0 1} {CH1 1} ... {CH15 1}}
# Gen 2: flat
{CH0 1 CH1 1 ... CH15 1}
```

### 3.4 Renamed interface and clock pins

| Gen 1 pin | Gen 2 pin |
| --- | --- |
| `PMC_NOC_AXI_0` | `PMC_AXI_NOC0` |
| `LPD_AXI_NOC_0` | `LPD_AXI_NOC0` |
| `FPD_CCI_NOC_0..3` | `FPD_CCI_NOC0..3` |
| `pmc_axi_noc_axi0_clk` | `pmc_axi_noc0_clk` |
| `lpd_axi_noc_clk` | `lpd_axi_noc0_clk` |
| `fpd_cci_noc_axi0..3_clk` | `fpd_cci_noc0..3_clk` |
| `pl0_ref_clk` / `pl0_resetn` | unchanged |

### 3.5 The PS-to-PL control path: `PS_USE_FPD_AXI_PL`

Gen 1 CIPS had dedicated `M_AXI_FPD` / `M_AXI_LPD` master pins for reaching
PL peripherals. `ps_wizard` has **no such pins at all**, and
`PS_USE_M_AXI_FPD` / `PS_USE_M_AXI_LPD` are not valid properties either.

The Gen 2 equivalent is **`PS_USE_FPD_AXI_PL`**, which exposes an
`FPD_AXI_PL` master reaching the PL **directly, bypassing the NoC**:

```tcl
CONFIG.PS_PMC_CONFIG(PS_USE_FPD_AXI_PL) {1}
```

```tcl
# base.tcl hangs its SmartConnect straight off the PS
connect_bd_intf_net [get_bd_intf_pins ps_wizard_0/FPD_AXI_PL] \
                    [get_bd_intf_pins axi_smc/S00_AXI]
```

PL peripherals then live at the **conventional `0xA400_0000` range** — the
same window AMD's own VRK160 designs use, and the same one Gen 1 used.

> **An earlier revision of this port took a different route** and it is worth
> knowing why it was abandoned. `axi_noc2` also exposes a PL-facing master
> (`M00_AXI`) fed from a PS NoC slave port; routing control through it works
> and passes `pr_verify`, but it drags in a hard constraint: the NoC NSU
> records the *exact address span* of the segments behind it, and because
> that port is fed by a boot-partition NMU, every overlay must reproduce that
> span byte-for-byte or `pr_verify` rejects it (`Dfx 88-139`,
> `SegConfig-Validation-12`). That forced a reserved-window contract, a
> dummy "aperture anchor" slave in every overlay, and a pre-build assertion.
> `FPD_AXI_PL` removes all of it.

### 3.6 Address assignment changed shape

Gen 1 `axi_noc` exposed a `C0_DDR_LOW0` / `C0_DDR_LOW1` pair **per NoC slave
port**, addressed from the NoC interface. Gen 2 `axi_noc2` exposes **one
NoC-wide block**, addressed from each **PS core's own address space**:

```tcl
# Gen 1
-target_address_space [get_bd_addr_spaces versal_cips_0/FPD_CCI_NOC_0]
[get_bd_addr_segs axi_noc_ps/S00_AXI/C0_DDR_LOW0]

# Gen 2
-target_address_space [get_bd_addr_spaces ps_wizard_0/pmcps_0_psv_cortexa72_0]
[get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY]
```

The PS core address spaces are:

```
pmcps_0_psv_cortexa72_0   pmcps_0_psv_cortexa72_1
pmcps_0_psv_cortexr5_0    pmcps_0_psv_cortexr5_1
pmcps_0_psv_dpc_0         pmcps_0_psv_pmc_0        pmcps_0_psv_psm_0
```

Every slave segment must be **assigned or explicitly excluded** in *each*
space, or Vivado emits `BD 41-1356` critical warnings. This port assigns PL
segments for `cortexa72_0/1`, `dpc_0`, `pmc_0` and excludes them for
`cortexr5_0/1`, `psm_0` — mirroring the AMD reference design.

### 3.7 The LPDDR5 reference clock is not automatic

`apply_board_connection` wires the LPDDR5 data interfaces but leaves
`sys_clk0` floating, which fails validation with `BD 41-758`. The board
clock has to be brought in through an input buffer explicitly:

```tcl
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
```

### 3.8 Dual-channel LPDDR5: connect both MCs

With `DDRMC5_NUM_CH 2`, **every** NoC interface that reaches the memory
controller must connect to `MC_0` *and* `MC_1` — all or none. Connecting only
`MC_0` still builds and still produces valid-looking PDIs, but Vivado raises:

```
CRITICAL WARNING: [BD 41-3714] NoC interface '/axi_noc_ps/S00_AXI' is connected
to 1 port(s) on DDR MC 'axi_noc_ps/inst/MC0_ddrc', but the interface should be
connected to exactly 2 ports on the DDR MC (all or none) in dual-channel
(CONFIG.DDRMC5_NUM_CH=2) configuration to ensure correct DDR addressing on
hardware.
```

Because it is a *warning*, the flow runs to completion and hands you
artefacts that are wrong on silicon. Every PS slave port in the AMD reference
design lists both MCs; so must these:

```tcl
set mc_boot {MC_0 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true}} \
             MC_1 {read_bw {5} write_bw {5} read_avg_burst {4} write_avg_burst {4} initial_boot {true}}}
```

This applies to `S00..S05_AXI` **and to `S00_INI`** — the PL DMA masters reach
the MC through the inter-NoC port, so a single-MC `S00_INI` is what raises
the warning against `axi_noc_pl/S00_AXI` and `S01_AXI`.

### 3.9 MIO peripherals are **not** set by the board preset

The `ps_pmc_fixed_io` board preset does **not** enable the PS MIO
peripherals. Every working VRK160 design sets them explicitly, and omitting
them produces a board that boots to **total silence** — no PLM output, no
console, and no way to read `BOOT.BIN` off the card at all:

| Key | Without it |
| --- | --- |
| `PS_UART0_PERIPHERAL` | no console anywhere in the boot chain |
| `PMC_SD1_30AD` + `_PERIPHERAL` | **the PLM cannot read the SD card** |
| `PS_ENET0_PERIPHERAL` + `_MDIO` | no Ethernet, so no Jupyter |
| `PS_I2C0/1`, `PMC_OSPI`, `PS_USB3` | those peripherals absent |

The values, including the SD tap delays, are copied from AMD's ftloop demo
for this board — board-specific timing that must not be invented.

> The generated device tree will show the UARTs as `status = "okay"`
> regardless: it describes the SoC, not what the PDI actually muxed. A
> healthy-looking `system.dtb` proves nothing here.

---

### 3.10 The PS needs IPI or TF-A never starts

`ps_wizard` leaves the **IPI** (Inter-Processor Interrupt) channels disabled
unless you ask for them. TF-A (the ARM Trusted Firmware, `BL31`) talks to the
PLM over IPI during `pm_setup()`, before it prints anything. With no IPI
channel the APU hand-off dies in silence: the PLM loads all eight partitions,
prints `Total PLM Boot Time`, and the board stops there.

The tell is in the PLM's own log, right after the first partition:

```
INFO: IPIs disabled: IPI-0 IPI-1 IPI-2 IPI-3 IPI-4 IPI-5
```

```tcl
CONFIG.PS_PMC_CONFIG(PS_GEN_IPI0_ENABLE) {1}
CONFIG.PS_PMC_CONFIG(PS_GEN_IPI1_ENABLE) {1}
CONFIG.PS_PMC_CONFIG(PS_GEN_IPI1_MASTER) {R5_0}
CONFIG.PS_PMC_CONFIG(PS_GEN_IPI2_ENABLE) {1}
CONFIG.PS_PMC_CONFIG(PS_GEN_IPI2_MASTER) {R5_1}
CONFIG.PS_PMC_CONFIG(PS_GEN_IPI3_ENABLE) {1}
...through IPI6
```

The same diff that surfaced this also added the TTC timers
(`PS_TTC0..3_PERIPHERAL_ENABLE`) and the HSM1 reference clock
(`PMC_HSM1_CLK_OUT_ENABLE`, `PMC_CRP_HSM1_REF_CTRL_FREQMHZ 200`) — the latter
turns out to be load-bearing, see [§3.11](#311-all-four-lpddr5-controllers).

### 3.11 All four LPDDR5 controllers

The board has **four LPDDR5 controllers, 16 GB total**. Wiring only C0 gives
you 4 GB and, more importantly, diverges from every known-good VRK160 design.

Topology — two aggregator NoCs, one per master domain, each with a direct
inter-NoC link to all four memory NoCs. Do **not** chain them (an INI link
must have a single driver or a single load, or you get `BD 41-2202`):

```
PS  → axi_noc_ps  ─┬─ MC0 local          C0  DDR_CH0_LEGACY + DDR_CH0_MED
                   ├─ M00_INI → axi_noc_c1   C1  DDR_CH1
                   ├─ M01_INI → axi_noc_c2   C2  DDR_CH2
                   └─ M02_INI → axi_noc_c3   C3  DDR_CH3
PL  → axi_noc_pl  ─┬─ M00_INI → axi_noc_ps/S00_INI
                   ├─ M01_INI → axi_noc_c1/S01_INI
                   ├─ M02_INI → axi_noc_c2/S01_INI
                   └─ M03_INI → axi_noc_c3/S01_INI
```

| Controller | Channels | Reference clock | Region | Base |
| --- | --- | --- | --- | --- |
| C0 | 2 | `util_ds_buf` ← `lpddr5_clk0_1` (320 MHz) | `DDR_CH0_LEGACY` | `0x0` |
| C0 | | | `DDR_CH0_MED` | `0x8_0000_0000` |
| C1 | 2 | same 320 MHz board clock | `DDR_CH1` | `0x500_0000_0000` |
| C2 | 1 | **`ps_wizard_0/hsm1_ref_clk`** (200 MHz) | `DDR_CH2` | `0x600_0000_0000` |
| C3 | 1 | **`ps_wizard_0/hsm1_ref_clk`** (200 MHz) | `DDR_CH3` | `0x700_0000_0000` |

Two traps:

* **`MC_CHAN_REGION1` declares the second region of C0.** Without it
  `DDR_CH0_MED` does not exist and `assign_bd_address` fails with
  *"No address segments matched DDR_CH0_MED"*. The Gen 1 port had the
  equivalent (`DDR_LOW1`) and it is easy to drop in translation.
* **Only the 64-bit cores can reach above 2 GB.** Assigning `DDR_CH0_MED`,
  `DDR_CH1/2/3` into `cortexr5_0`, `cortexr5_1` or `psm_0` fails with
  `BD 41-1075` (*"Valid apertures are {<0x0000_0000 [ 2G ]>}"*). Assign them
  to `cortexa72_0/1`, `dpc_0` and `pmc_0`, and **explicitly exclude** them from
  the other three or you get `BD 41-1356` critical warnings.

Verify from Linux — you want five ranges:

```
node 0: [mem 0x0000000000000000-0x000000007fffffff]   C0  2 GB
node 0: [mem 0x0000000800000000-0x000000087fffffff]   C0  2 GB
node 0: [mem 0x0000050000000000-0x00000500ffffffff]   C1  4 GB
node 0: [mem 0x0000060000000000-0x00000600ffffffff]   C2  4 GB
node 0: [mem 0x0000070000000000-0x00000700ffffffff]   C3  4 GB
```

### 3.12 The SD controller needs `no-1-8-v`

`edf.env` sets no `EDF_BOARD_DTS`, so the build uses the **generic Versal SoC
device tree** and `edf_bsp/board.dtsi` is the only source of board-specific
nodes. Three things must be added there, and the SD one is a hard boot
blocker:

```dts
&{/axi/mmc@f1050000} {
	no-1-8-v;
};
```

Without it u-boot negotiates 1.8 V UHS signalling that this board does not
support, and every read after the PLM hand-off fails:

```
Transfer data timeout
Error reading cluster
Failed to load 'Image'
** No partition table - mmc 0 **
```

The PLM is unaffected because the BootROM reads in low-speed mode
(`BOOTMODE: 0xE` = SD1_LS). `BOOT.BIN` therefore loads perfectly and only
u-boot dies, which makes it look like a design fault rather than a device-tree
one.

The same file also sets the board `model` string and the MDIO bus with the
DP83867 PHY. Without the PHY node u-boot reports `Net: No ethernet found`
(Linux still brings `eth0` up by probing, but with a random MAC).

> **u-boot reads the device tree embedded in the PDI** (`apu_ss.0.0`), not the
> `system.dtb` on the FAT partition. Editing `system.dtb` alone changes
> nothing for u-boot — `BOOT.BIN` has to be rebuilt and recopied. Check the
> embedded copy directly:
>
> ```bash
> bootgen -arch versal -dump BOOT.BIN -dump_dir /tmp/pdi
> dtc -I dtb -O dts /tmp/pdi/apu_ss.0.0.bin | grep -c no-1-8-v
> ```

### 3.13 Push buttons share an LPDDR5 I/O bank

`gpio_pb_0`/`gpio_pb_1` sit at **BD37 / BG35** with iostandard
**`LVSTL05_10`** — they share I/O bank silicon with the LPDDR5 interface. Once
the golden claims all four memory controllers, those pins belong to the boot
partition, and in segmented configuration **an overlay may not add
boot-partition IO**:

```
ERROR: [Dfx 88-162] SegConfig-Validation-18: Boot partition IO port
'gpio_pb_tri_i[1]' at site 'IOB_X6Y11' is used in the secondary design;
yet this site is not used in the initial design.
```

The working arrangement, in this order:

1. `axi_gpio_pb` (2 bits, all inputs) is instantiated in **`golden_ref.tcl`**,
   with its `gpio_pb` external port and a tie-off AXI master, so the golden
   claims the IOB sites.
2. Pin constraints live in **`golden/vrk160_pl_io.xdc`**, loaded by
   `golden_ref.tcl` — which `base.tcl` sources, so both designs get them.
3. `GPIO_BOARD_INTERFACE` is **`Custom`**, never the `gpio_pb` board preset.
   The preset makes the board flow re-declare the bank, which the DDRMC
   already owns. AMD's own working VRK160 image uses `Custom` for this reason.
4. `base.tcl` deletes only `pl_tieoff_pb`, keeps the cell and port, and wires
   `S_AXI` to its SmartConnect.

The buttons are **2 bits wide, not 4** — the VCK190-derived `base.py` claimed
4 and was wrong.

The LEDs, DIP switches and PL UART are `LVCMOS12` in ordinary PL banks and
need none of this.

## 4. File map

```
boards/VRK160/
├── VRK160.spec           # board identity for the sdbuild Makefile
├── edf.env               # Yocto/EDF machine config for BOOT.BIN
├── golden/
│   ├── Makefile          # make -> golden_ref.tcl, then build_golden.tcl
│   ├── golden_ref.tcl    # THE block design (PS + NoC + LPDDR5 + tie-offs)
│   └── build_golden.tcl  # synth/impl, exports xsa + ncr + dcp + boot.pdi
├── base/
│   ├── Makefile          # make -> base.tcl, then build_pdi.tcl
│   ├── base.tcl          # sources golden_ref.tcl, swaps tie-offs for real IP
│   ├── build_pdi.tcl     # impl locked to golden_noc.ncr, pr_verify, pld.pdi
│   ├── build_user_overlay.tcl
│   ├── base.py           # PYNQ BaseOverlay driver (leds/buttons/switches/dma)
│   └── __init__.py
├── rfloop/               # RF loopback overlay: PL DDS -> DAC0 -> XM855 -> ADC3
├── sgloop/               # the same loop driven by QICK's axis_signal_gen_v6
├── Top/vrk160/           # Hog projects for rfloop and sgloop
├── edf_bsp/board.dtsi    # CMA pool + zocl node, appended to the device tree
├── notebooks/            # copied into the image's Jupyter tree
└── selftest.json         # test manifest for sdbuild/packages/selftest
```

### How they chain together

```
sdbuild/Makefile
  discovers the board from the .spec FILENAME  ─────────┐
                                                        │
  BITSTREAM_VRK160 := base/base.pdi                     │
        └── runs `make` in base/ if base.pdi is missing │
              └── base/Makefile                         │
                    ├── needs ../golden/golden_noc.ncr  │
                    │     └── runs `make` in golden/    │
                    │           ├── golden_ref.tcl  → block design
                    │           └── build_golden.tcl → golden.xsa
                    │                                    golden_noc.ncr
                    │                                    golden_routed.dcp
                    │                                    golden_boot.pdi
                    ├── base.tcl      → block design (sources golden_ref.tcl)
                    └── build_pdi.tcl → base.pdi (NoC-locked + pr_verify)
                                                        │
  edf.env: BSP_XSA_PATH=golden/golden.xsa  ─────────────┘
        └── sdbuild/scripts/build_edf_boot.sh
              └── sdtgen + gen-machine-conf + bitbake → BOOT.BIN
```

> **The `.spec` filename is the board name.** `sdbuild/Makefile` derives
> `ALLBOARDS` from `$(basename $(notdir $(wildcard $(BOARDDIR)/*/*.spec)))`,
> then looks for `$(BOARDDIR)/<name>/`. A file named `VCK190.spec` inside
> `boards/VRK160/` silently makes the build treat this as the *VCK190* board
> and point at the wrong directory. The file must be `VRK160.spec`, and the
> variables inside it must use the `_VRK160` suffix.

---

## 5. Building

### Prerequisites

```bash
# Vivado 2025.2 on PATH
source /home/tools/xilinx/2025.2/Vivado/settings64.sh

# Board store containing the vrk160 definition
export BOARD_STORE_PATH="/home/tools/xilinx/2025.2/data/xhub/boards/XilinxBoardStore"

# Optional: parallel jobs for synth/impl (default 4)
export VIVADO_JOBS=8
```

`golden_ref.tcl` errors out early if `BOARD_STORE_PATH` is unset or has no
`boards/` subdirectory.

### Golden reference

```bash
cd boards/VRK160/golden
make
```

Produces:

| Artifact | Purpose |
| --- | --- |
| `golden.xsa` | input to EDF/`BOOT.BIN` generation (`BSP_XSA_PATH`) |
| `golden_noc.ncr` | NoC solution the base overlay is locked to |
| `golden_routed.dcp` | reference checkpoint for `pr_verify` |
| `golden_boot.pdi` | PS/DDR boot image |

### Base overlay

```bash
cd boards/VRK160/base
make          # builds ../golden first if golden_noc.ncr is missing
```

Produces `base.pdi` (the runtime PLD image), `base.hwh` and `base.xsa`.

One check gates this build and it is fatal on failure:

```
pr_verify PASSED -- overlay is compatible with golden reference
```

It runs after implementation. An overlay that fails `pr_verify` will not load
against the golden's boot PDI. The two failure modes seen on this board are an
NSU aperture mismatch (`SegConfig-Validation-12`) and an overlay introducing
boot-partition IO (`SegConfig-Validation-18`, see
[§3.13](#313-push-buttons-share-an-lpddr5-io-bank)).

### Boot artefacts only

```bash
cd sdbuild
make boot_VRK160
```

Runs just `scripts/build_edf_boot.sh`: `repo sync` of the EDF manifest,
`sdtgen` on `golden/golden.xsa`, `gen-machine-conf`, then bitbake. Produces
`BOOT.BIN`, `Image`, `system.dtb`, `modules.tgz` and `zocl.ko` under
`sdbuild/output/boot/VRK160/`. This is the target that exercises
`EDF_BOOT_MACHINE`, the omitted `EDF_BOARD_DTS` and `board.dtsi`, and it needs
neither `sudo` nor QEMU — only `repo`, Vivado (for `sdtgen`) and network.

### Full SD image

```bash
cd sdbuild
make BOARDS=VRK160 REBUILD_PYNQ_SDIST=1 REBUILD_PYNQ_ROOTFS=1
```

**The image build requires Ubuntu 24.04 and refuses to run anywhere else** —
`scripts/check_env.sh` checks `lsb_release -rs` and exits. Its dependency list
is Debian-only (`multistrap`, `qemu-user-static`, `binfmt-support`,
`crossbuild-essential-arm64`), so on any other distro the supported route is
the container described in [`sdbuild/README.md`](../../sdbuild/README.md).
The full build includes the boot artefacts, so it supersedes `boot_VRK160`
rather than complementing it.

See [§9 Troubleshooting](#11-troubleshooting) for host-environment problems hit
while bringing this board up, including one that is **not** solved by the
container.

### Rebuilding

The build now tracks its own sources: editing any `.tcl` or `.xdc` under
`boards/VRK160/` rebuilds the golden, the overlay and `BOOT.BIN` in order, and
editing `edf_bsp/board.dtsi` or `scripts/build_edf_boot.sh` rebuilds the boot
artefacts.

This was **not** true originally — `make` reported `Nothing to be done` and
silently shipped the previous bitstream. If you are working from an older
checkout and a change appears to have no effect, that is why. Three
prerequisites were added:

| File | Rule | Now depends on |
| --- | --- | --- |
| `sdbuild/Makefile` | `$(BITSTREAM_ABS_$1)` | the board's `*/*.tcl` and `*/*.xdc` |
| `sdbuild/Makefile` | `$(BOOT_STAMP_$1)` | `edf_bsp/*` and `build_edf_boot.sh` |
| `boards/VRK160/base/Makefile` | `$(GOLDEN_NCR)` | `../golden/*.tcl` and `*.xdc` |

To force a full rebuild anyway:

```bash
make -C boards/VRK160/golden clean
make -C boards/VRK160/base   clean
```

---

### The build environment

**The image build has to run in the sdbuild container.** `make BOARDS=...`
checks for `ct-ng` (crosstool-ng), which only the container provides -- it is
built into `/opt/crosstool-ng` by `sdbuild/Dockerfile` and is not something a
host normally has, so a native build fails at `checkenv` no matter what else
is installed. The Vivado steps (`make -C boards/VRK160/base`) do run natively.

```bash
cd sdbuild
podman build --build-arg USERNAME=$(whoami) --build-arg USER_UID=$(id -u) \
             --build-arg USER_GID=$(id -g) -t pynqdock:latest .
```

Running it, with everything this board actually needed:

```bash
export XILINX_TOOLS=/path/to/xilinx/2025.2
export XILINXD_LICENSE_FILE="2100@licence.server"     # or a path to .lic files

podman run --init --rm --network host \
  --userns=keep-id --security-opt label=disable \
  -e XILINX_TOOLS -e XILINXD_LICENSE_FILE \
  -e BOARD_STORE_PATH="$XILINX_TOOLS/data/xhub/boards/XilinxBoardStore" \
  -v "$XILINX_TOOLS:$XILINX_TOOLS:ro" \
  -v /path/to/xilinx/DocNav:/path/to/xilinx/DocNav:ro \
  -v "$PWD:$PWD" -w "$PWD" \
  --privileged pynqdock:latest \
  bash -lc "cd $PWD/sdbuild && make BOARDS=VRK160 REBUILD_PYNQ_SDIST=1 REBUILD_PYNQ_ROOTFS=1"
```

Five things there are not in [`sdbuild/README.md`](../../sdbuild/README.md),
and each one cost a failed run:

| Flag / mount | Why |
| --- | --- |
| `--security-opt label=disable` | SELinux on RHEL-family hosts blocks crun's runtime directory: *"crun: Permission denied: OCI permission denied"* |
| `--userns=keep-id` | Without it, rootless podman maps your host UID to a subuid and Vivado cannot write the bind-mounted tree: *"Failed to open handle vivado.jou"* |
| `BOARD_STORE_PATH` | `golden_ref.tcl` aborts without it; the container's own default points at `/opt/XilinxBoardStore`, which has no `vrk160` |
| the DocNav mount | `settings64.sh` sources DocNav by absolute path from *outside* the version directory, so mounting only `2025.2` breaks `build_edf_boot.sh` |
| `-v "$PWD:$PWD"` | not `:/workspace`. Yocto bakes absolute paths into `bblayers.conf`, sstate and `tmp/`, so mirroring the host path keeps a cache built elsewhere valid |

**A licence server needs no mount, but does need `--network host`.** Pointing
`XILINXD_LICENSE_FILE` at a directory with no `.lic` files fails subtly rather
than loudly: Vivado starts, `enable_beta_device` reports *"28 Beta devices
matching pattern found, 0 enabled"*, and the part is then not found. The
VRK160 is `-es1` engineering-sample silicon, so beta-device enablement is not
optional here.

**Turning `--userns=keep-id` on or off changes file ownership**, and a tree
written under one mapping can be undeletable under the other. `podman unshare
rm -rf <path>` clears files owned by a container UID; anything left by a build
that ran as real root needs real root to remove.

> Do not switch git branches while a build is running against the working
> tree. Checking out a branch that lacks `boards/VRK160/` deletes the tracked
> sources from disk mid-build. Use `git worktree` for parallel work.

## 6. Building an SD card, end to end

This is the whole path from a clean checkout to a booting card, with the
verification step after each stage. **Verify every stage.** Most of the time
lost on this port went to changes that silently never applied.

### Stage 1 — hardware

```bash
cd /path/to/PYNQ
export BOARD_STORE_PATH=/home/tools/xilinx/2025.2/data/xhub/boards/XilinxBoardStore
source /home/tools/xilinx/2025.2/Vivado/settings64.sh

make -C boards/VRK160/base       # builds golden first
```

Check: `pr_verify PASSED` near the end of the log. Nothing downstream is worth
doing until that line appears.

### Stage 2 — boot artefacts

```bash
cd sdbuild && make boot_VRK160
```

Check all three, because each one caught a real defect on this board:

```bash
B=sdbuild/output/boot/VRK160

# the board is named -- proves board.dtsi was picked up
dtc -I dtb -O dts $B/system.dtb | grep -m1 "model = "

# the SD fix is present -- without it u-boot cannot read the card
dtc -I dtb -O dts $B/system.dtb | grep -c no-1-8-v          # want 1

# all four controllers -- want five reg pairs
dtc -I dtb -O dts $B/system.dtb | awk '/^\tmemory@/,/^\t};/' | grep "reg ="
```

And confirm the fix reached the copy u-boot actually uses:

```bash
bootgen -arch versal -dump $B/BOOT.BIN -dump_dir /tmp/pdi
dtc -I dtb -O dts /tmp/pdi/apu_ss.0.0.bin | grep -c no-1-8-v   # want 1
```

### Stage 3 — full image

```bash
cd sdbuild
make BOARDS=VRK160 REBUILD_PYNQ_SDIST=1 REBUILD_PYNQ_ROOTFS=1
```

Produces `sdbuild/output/VRK160-<version>.img` (~7.5 GB). Needs Ubuntu 24.04
or the container — see [§5 Prerequisites](#5-building).

### Stage 4 — write the card

```bash
lsblk                       # identify the device, NOT a partition
sudo dd if=sdbuild/output/VRK160-4.0.0.img of=/dev/sdX \
        bs=64M oflag=direct conv=fsync status=progress
sync
```

`bs=64M` matters: the default 512-byte blocks make this glacial. Expect
20–40 MB/s with a decent reader. `status=progress` tells you whether it is
moving at all.

Verify the card rather than trusting the copy:

```bash
sudo mount /dev/sdX1 /mnt/chk
md5sum /mnt/chk/BOOT.BIN sdbuild/output/boot/VRK160/BOOT.BIN   # must match
sudo umount /mnt/chk
```

> The boot partition is labelled **`PYNQ`**. If your file manager mounted
> something at `/media/$USER/BOOT/`, that is a different card.

### Stage 5 — boot

Console is **`/dev/ttyUSB1`** at 115200 8N1 (`ttyUSB3` is the system
controller). Boot mode is **SD1_LS**, which the PLM confirms as
`BOOTMODE: 0xE`. Power-cycle rather than pressing reset.

Milestones, in order:

| Line | Confirms |
| --- | --- |
| `Xilinx Versal Platform Loader and Manager` | BootROM found and ran `BOOT.BIN` |
| `pl_cfi ... Size: 1820224` | *your* PDI — the size is a fingerprint |
| `NOTICE: TF-A running on SILICON 0` | IPI works, APU hand-off succeeded |
| `Model: Xilinx Versal VRK160 Eval board revA` | u-boot has the board device tree |
| `33870336 bytes read` | the SD fix works |
| five `[mem ...]` ranges | all four controllers |
| `cma: Reserved 512 MiB` | CMA pool for DMA |
| `pynq login:` | done |

### Iterating without rewriting 8 GB

Once a card works, updating it is a file copy. Rebuild, then:

```bash
B=sdbuild/output/boot/VRK160
S=boards/VRK160

sudo mount /dev/sdX1 /mnt/p1
sudo \cp -f $B/BOOT.BIN $B/Image $B/system.dtb /mnt/p1/
sudo \cp -f $B/extlinux/extlinux.conf /mnt/p1/extlinux/
sudo umount /mnt/p1

sudo mount /dev/sdX2 /mnt/p2
D=/mnt/p2/usr/local/share/pynq-venv/lib/python3.12/site-packages/pynq/overlays/base
sudo \cp -f $S/base/base.pdi $S/base/base.hwh $S/base/base.py $D/
sudo umount /mnt/p2 && sync
```

Use `\cp -f`: `cp` is aliased to `cp -i` for root, and a prompt answered in a
pasted block does not always register. **Then check the file size or md5** —
this exact trap wasted an afternoon here.

Copy `BOOT.BIN` whenever the golden changed, and `base.pdi`/`base.hwh`
whenever the overlay changed. Only the overlay changed? The `BOOT.BIN` can
stay.

### Bisecting a card that will not boot

With two cards, one known good, you can isolate any failure in one boot:

| Test | Meaning |
| --- | --- |
| your `BOOT.BIN` on the working card | isolates your PDI from your rootfs |
| working `BOOT.BIN` on your card | isolates the card and the FAT partition |

The `pl_cfi` size in the PLM log tells you unambiguously which PDI is running.

A card that produces **no PLM banner at all** is almost never a design
problem — the BootROM never read `BOOT.BIN`. Check that `dd` went to the disk
and not a partition, that the copy completed, and try another card. One
physically bad card cost hours here while every measurable property of it —
FAT32 geometry, cluster count, file contiguity, `md5sum` — checked out
perfectly.

### After first boot

The rootfs ships an XRT setup script, but confirm it took effect: PYNQ shells
out to `xclbinutil` and fails with `FileNotFoundError` if `/opt/xilinx/xrt/bin`
is not on `PATH`. A login shell gets it:

```bash
sudo -i bash -lc 'source /usr/local/share/pynq-venv/bin/activate; cd /root; python3'
```

`cd /root` matters — a stray `pynq` source checkout in `/home/xilinx` shadows
the installed package, and the non-root user may lack access to `/dev/dri`.

Smoke test:

```python
from pynq.overlays.base import BaseOverlay
base = BaseOverlay("base.pdi")
base.leds[0].on()
print([base.buttons[i].read() for i in range(2)])
print(f"0b{base.switches.read():04b}")
```

Then run `getting_started.ipynb`, which exercises GPIO, BRAM and a DMA
loopback.

## 7. NoC topology

Six `axi_noc2` instances: two aggregators and four memory controllers. Read
back from the generated traffic file
(`golden/golden.gen/sources_1/bd/golden/nsln/golden.nts`) after a build.

| Instance | `NUM_MC` | Role |
| --- | --- | --- |
| `axi_noc_ps` | 1 | 6 PS masters + C0's controller + 3 NMIs to C1/C2/C3 |
| `axi_noc_pl` | 0 | 2 PL DMA ports, 4 NMIs — one to each memory NoC |
| `axi_noc_c1` | 1 | C1, dual channel, `DDR_CH1` |
| `axi_noc_c2` | 1 | C2, single channel, `DDR_CH2` |
| `axi_noc_c3` | 1 | C3, single channel, `DDR_CH3` |

The PS masters are `FPD_CCI_NOC0..3` (`CATEGORY {ps_cci}`), `LPD_AXI_NOC0`
(`ps_rpu`) and `PMC_AXI_NOC0` (`ps_pmc`), all with `initial_boot {true}` so
their paths land in `boot.pdi`. The PL DMA paths carry no `initial_boot` and
belong to the runtime overlay.

Each memory NoC takes **two** NSI ports: `S00_INI` from the PS aggregator and
`S01_INI` from the PL aggregator. Both aggregators reach every controller
directly. Chaining them — routing the PL through the PS NoC's `S00_INI` and
fanning out from there — fails:

```
ERROR: [BD 41-2202] NoC INI Connection Strategy: The following INIs have
multiple drivers and multiple loads.
```

An INI link must have a single driver or a single load, never a fan-out of
both.

Every interface that reaches a dual-channel controller must connect to
**both** `MC_0` and `MC_1`; single-channel C2 and C3 expose only `MC_0`. See
[§3.8](#38-dual-channel-lpddr5-connect-both-mcs) for why connecting one is
worse than failing outright.

> An `Ipconfig 75-709` INFO line reporting `0 INI` paths is **not** a
> problem: that counter tracks INI paths *within* one NoC instance, not the
> links between them.

---

## 8. Address map

### LPDDR5 — 16 GB across four controllers

| Segment | Base | Size | Assigned to |
| --- | --- | --- | --- |
| `axi_noc_ps/.../DDR_CH0_LEGACY` | `0x0` | 2 GB | all seven PS cores + both PL DMA spaces |
| `axi_noc_ps/.../DDR_CH0_MED` | `0x8_0000_0000` | 2 GB | 64-bit cores + PL DMA |
| `axi_noc_c1/.../DDR_CH1` | `0x500_0000_0000` | 4 GB | 64-bit cores + PL DMA |
| `axi_noc_c2/.../DDR_CH2` | `0x600_0000_0000` | 4 GB | 64-bit cores + PL DMA |
| `axi_noc_c3/.../DDR_CH3` | `0x700_0000_0000` | 4 GB | 64-bit cores + PL DMA |

"64-bit cores" means `cortexa72_0`, `cortexa72_1`, `dpc_0` and `pmc_0`. The
R5s and the PSM top out at a 2 GB aperture and everything above `DDR_CH0_LEGACY`
must be **explicitly excluded** from them — see
[§3.11](#311-all-four-lpddr5-controllers).

The CMA pool in `edf_bsp/board.dtsi` is deliberately pinned into the low 2 GB
(`alloc-ranges = <0x0 0x0 0x0 0x80000000>`) so DMA buffers stay
DMA-reachable, and `cma=512M` is set in the kernel command line. A verified
`pynq.allocate()` returns a physical address inside that pool.

### PL peripherals — conventional `0xA400_0000` range

Reached through `ps_wizard_0/FPD_AXI_PL` (see
[§3.5](#35-the-ps-to-pl-control-path-ps_use_fpd_axi_pl)), which bypasses the
NoC entirely.

| Peripheral | Address | Range |
| --- | --- | --- |
| `axi_bram_ctrl_0` | `0xA400_0000` | 8 KB |
| `axi_gpio_dip_sw` | `0xA401_0000` | 64 KB |
| `axi_gpio_led` | `0xA402_0000` | 64 KB |
| `axi_gpio_pb` | `0xA403_0000` | 64 KB |
| `axi_dma_0` (lite) | `0xA404_0000` | 64 KB |
| `axi_uartlite_0` | `0xA405_0000` | 64 KB |

`base.py` resolves IP by name through the HWH, so it is unaffected by the
addresses; notebooks with hard-coded ones are not.

### Interrupts

`pl_ps_irq0..15`, wired in `base.tcl`:

| Channel | Source |
| --- | --- |
| 0, 1 | DMA `mm2s_introut`, `s2mm_introut` |
| 8 | `axi_gpio_dip_sw` |
| 9 | `axi_gpio_pb` |
| 10 | `axi_uartlite_0` |
| rest | tied to constant 0 |

---

## 9. Upstream PYNQ defects

Three defects in PYNQ itself block Versal boards. All three are fixed in this
fork; they are documented here because they are worth reporting upstream and
because anyone building PYNQ 4.0 for a Versal part will hit the first two
before they ever reach a board.

### 9.1 `pynqmetadata` must come from the `pynq-next` branch

`pynq/metadata/clock_dict_view.py` imports `VersalProcSysCore`. That symbol
exists **only** on PYNQ-Metadata's `pynq-next` branch (0.2.0) — not on `main`
(0.1.x) and not on PyPI. `setup.py` listed the dependency unpinned, so pip
installed the PyPI release and `import pynq` failed:

```
ImportError: cannot import name 'VersalProcSysCore' from 'pynqmetadata'
```

Fixed by pinning to the branch. **Caveat:** a branch is not a commit, so this
is not fully reproducible; pin a SHA if you need it to be.

### 9.2 `pydantic` must be 2.x

`pynqmetadata` 0.2.0 requires `pydantic>=2.0`;
`sdbuild/packages/python_packages_noble/requirements.txt` pinned
`pydantic==1.9.1`:

```
ImportError: cannot import name 'ConfigDict' from 'pydantic'
```

Bumped to `2.9.2`. PYNQ's own code only uses `Field` and `BaseModel`, which
exist in both majors, but v2's validation differences are not fully vetted
here.

### 9.3 `mem_dict_view` looks up the wrong key

`pynq/metadata/mem_dict_view.py` iterated `port.addrmap.values()` and indexed
`port._addrmap_obj` with the value's `subord_port` field. The two dicts are
parallel and keyed by the **full** reference including the address block
(`...:S_AXI[port]:Mem0`), which `subord_port` omits, so the lookup always
fails:

```
KeyError: 'base:axi_bram_ctrl_0[block]:S_AXI[port]'
```

`ip_dict_view.py` iterates the keys correctly; `mem_dict_view.py` now matches
it. **This is not Versal-specific** — it breaks any platform whose overlay
contains a subordinate with `memtype == "memory"`, i.e. an AXI BRAM
controller. AMD's own VRK160 reference design has no BRAM, which is presumably
why it went unnoticed.

---

## 10. Verification status

### Verified on hardware

| Item | Evidence |
| --- | --- |
| Boot from this port's own image | PLM → TF-A → u-boot → Linux 6.12 → PYNQ Linux login |
| All four LPDDR5 controllers | five `[mem ...]` ranges in the kernel log, 16 GB |
| Segmented configuration | `Loading PDI from DDR` / `Subsystem PDI Load: Done` — the FPGA manager reconfigures the PL at runtime against the golden's boot PDI |
| `ip_dict` / `mem_dict` | `axi_gpio_dip_sw`, `axi_gpio_led`, `axi_gpio_pb`, `axi_dma_0`, `axi_uartlite_0`, `ps_wizard_0`; memories `axi_bram_ctrl_0`, the four NoCs and `PSDDR` |
| GPIO | LEDs drive, DIP switches and push buttons read correctly |
| CMA | `pynq.allocate()` returns a physical address inside the pinned 512 MB pool |
| DMA | 1024-word loopback PL↔DDR passes, data intact |
| BRAM | read/write through `0xA400_0000` passes |
| Ethernet | `eth0` up, 1 Gbps, routable |

### Verified in tooling only

| Item | Evidence |
| --- | --- |
| `pr_verify` | passes with the buttons in place; the overlay is a valid segmented child of the golden |
| Timing | *"All user specified timing constraints are met"* |
| `write_noc_solution` with `axi_noc2` | `golden_noc.ncr` written |
| `write_hw_platform` / `validate_hw_platform` | `golden.xsa` created and validated |

### Not yet confirmed

| Item | Risk |
| --- | --- |
| **A clean `make BOARDS=VRK160`** | The validated card was built from an image predating several fixes, with `base.pdi`, `base.hwh`, `base.py`, the notebooks and three Python packages patched in by hand. The full build has not been run since, so **the image is not yet reproducible from a clean checkout** |
| `zocl_overlay.dtbo` | AMD's working image ships one; this port does not generate it. `zocl.ko` loads, but XRT behaviour beyond `pynq.allocate()` is untested |
| `/home/xilinx/pynq` shadowing | A stray source checkout in the home directory shadows the installed package, so `import pynq` fails for the non-root user from their own home |
| `/dev/dri` permissions | The `xilinx` user could not open the XRT device; only root was tested |
| `pl1..3_ref_clk` / `pl1..3_resetn` | Connect during the build, but only `pl0_*` carries real traffic |
| `PS_NUM_F2P0_INTR_INPUTS` / `PS_NUM_F2P1_INTR_INPUTS` | Key names carried from Gen 1, never echoed back by Vivado |

---

## 11. Troubleshooting

Errors hit while bringing this port up, and what each one meant.

**`Invalid parameter 'PS_USE_M_AXI_FPD' provided, Ignoring` (19-7090)**
The property does not exist on `ps_wizard`. There is no PS-to-PL AXI master
enable on Gen 2 — see [§3.5](35-the-ps-to-pl-control-path-psusefpdaxipl).

**`Validation failed for parameter 'IRQ(PS_IRQ_USAGE)'` (19-8017)**
Wrong value shape. Gen 2 wants the flat form. Usefully, the error text
echoes the *current* value, which reveals the expected shape.

**`No interface pins matched 'ps_wizard_0/M_AXI_FPD'` (BD 5-232)**
Confirms the pins do not exist. Route PS→PL traffic through
`axi_noc2/M00_AXI` instead.

**`clock pins are not connected to a valid clock source: /axi_noc_ps/sys_clk0` (BD 41-758)**
The LPDDR5 reference clock is missing — see [§3.7](#37-the-lpddr5-reference-clock-is-not-automatic).

**`Slave segment ... is not assigned into address space ...` (BD 41-1356)**
A slave is neither assigned nor excluded in one of the seven PS core address
spaces — see [§3.6](#36-address-assignment-changed-shape).

**`Cachable transactions are enabled ... master data width (128) > slave data width (32)`**
The AXI VIP tie-off defaulted to 32 bits. Set its `DATA_WIDTH` to match
`M00_AXI` (64).

**`BD 41-3714` — interface connected to 1 port, should be 2 (dual-channel)**
A NoC interface reaches only `MC_0` while the controller is dual-channel.
**Do not ignore this one.** It is a warning, so the build completes and
produces artefacts, but DDR addressing is wrong on hardware — see
[§3.8](#38-dual-channel-lpddr5-connect-both-mcs).

**`BD 41-1075` — cannot assign segment at `0x8_0000_0000`**
*"Valid apertures are {<0x0000_0000 [ 2G ]>}"*. The R5s and the PSM cannot
reach above 2 GB. Assign the high DDR regions only to `cortexa72_0/1`,
`dpc_0` and `pmc_0`, and exclude them from the rest — see
[§3.11](#311-all-four-lpddr5-controllers).

**`No address segments matched DDR_CH0_MED`**
`CONFIG.MC_CHAN_REGION1` is not set, so the second region of controller C0
does not exist. The Gen 1 port had the equivalent (`DDR_LOW1`) and it is easy
to lose in translation.

**`BD 41-2202` — INIs have multiple drivers and multiple loads**
An inter-NoC link is chained: something feeds a NoC's `S00_INI` which then
fans out to further INIs. Give each aggregator its own direct link to every
memory NoC — see [§7](#7-noc-topology).

**`Dfx 88-162` / `SegConfig-Validation-18` — overlay adds IO the golden lacks**
The overlay uses an IOB site the golden does not. In segmented configuration
that is forbidden. On this board it is `gpio_pb`, whose pins live in an
LPDDR5 bank — see [§3.13](#313-push-buttons-share-an-lpddr5-io-bank).

**PLM prints, then nothing at all**
The APU never started. Check the PLM log for `INFO: IPIs disabled` — TF-A
needs IPI to reach the PLM and dies before printing — see
[§3.10](#310-the-ps-needs-ipi-or-tf-a-never-starts).

**`Transfer data timeout` / `Failed to load 'Image'` in u-boot**
`no-1-8-v` is missing from the SD controller node. The BootROM reads in
low-speed mode so `BOOT.BIN` loads fine and only u-boot fails, which makes it
look like a design problem — see [§3.12](#312-the-sd-controller-needs-no-1-8-v).

**No PLM banner at all**
The BootROM never read `BOOT.BIN`. In order of likelihood: `dd` went to a
partition instead of the disk; the write did not complete; MIO peripherals are
unconfigured ([§3.9](#39-mio-peripherals-are-not-set-by-the-board-preset)); or
the card is bad. One physically bad card cost hours here while every
measurable property of it — FAT32 geometry, cluster count, file contiguity,
`md5sum` of `BOOT.BIN` — was perfect. Swap the card before doubting the
design.

**`cannot open include file '..._phy_static_reg.vh'` (Synth 8-9263)**
Only in the sdbuild container. Versal DDRMC generation compiles a small
*native* helper with Vivado's bundled gcc, and that helper emits the PHY
register headers. Vivado's gcc is built RHEL-style and does not know Debian's
multiarch layout, so it cannot find `bits/libc-header-start.h` (headers) or
`crt1.o`/`crti.o` (link). MemGen swallows the failure, `generate_target`
reports success, and synthesis dies much later pointing at the include rather
than the cause. The evidence is at the end of `MemGen.log`, next to the
generated IP:

```
/usr/include/stdio.h:28:10: fatal error: bits/libc-header-start.h: No such file or directory
./make_gcc.sh: 25: ./bd_XXXX_MC0_ddrc_0_phy.exe: not found
```

Fixed in `sdbuild/Dockerfile` with `C_INCLUDE_PATH=/usr/include/x86_64-linux-gnu`
and `LIBRARY_PATH=/usr/lib/x86_64-linux-gnu`. Native builds on an RHEL-family
host are unaffected, because there the headers sit directly in `/usr/include`.

**`make` says `Nothing to be done` after an edit**
Older checkouts did not track the Vivado and BSP sources, so edits were
silently ignored and the previous artefact shipped. Fixed — see
[§5 Rebuilding](#5-building). If you suspect it, check the artefact's
timestamp before testing it.

**A copied file did not change**
`cp` is aliased to `cp -i` for root and a prompt answered inside a pasted
block does not always register. Use `\cp -f`, then verify by size and
`md5sum`. Note also that this port's boot partition is labelled `PYNQ`, so an
auto-mounted `/media/$USER/BOOT/` is some *other* card.

**`ImportError: cannot import name 'VersalProcSysCore'` / `'ConfigDict'`**
See [§9 Upstream PYNQ defects](#9-upstream-pynq-defects).

**`KeyError: '...axi_bram_ctrl_0[block]:S_AXI[port]'`**
Same section — `mem_dict_view.py` indexes the wrong dict.

**`FileNotFoundError: 'xclbinutil'`**
`/opt/xilinx/xrt/bin` is not on `PATH`. A login shell picks it up from
`/etc/profile.d/xrt_setup.sh`; a shell started another way may not.

**`RuntimeError: No such device with index '0'`**
`pyxrt` cannot open the XRT device. Run as root — the `xilinx` user was not
able to. Also `cd /root` first: a stray `pynq` checkout in `/home/xilinx`
shadows the installed package.

**`Dfx 88-139` / `SegConfig-Validation-12` — NSU has different apertures**
The PS-to-PL address window differs between the overlay and the golden. See
[§3.9](#39-mio-peripherals-are-not-set-by-the-board-preset). `base.tcl` now catches the common
case up front, so hitting this at `pr_verify` means something changed the
span in a way the pre-check does not model — compare the `SysAddresses`
entries for `M00_AXI_nsu` in each design's `.nts` file:

```bash
python3 - <<'EOF'
import json
for tag, p in [("golden", "golden/golden/golden.gen/sources_1/bd/golden/nsln/golden.nts"),
               ("base",   "base/base/base.gen/sources_1/bd/base/nsln/base.nts")]:
    for i in json.load(open(p))["LogicalInstances"]:
        if "M00_AXI_nsu" in i.get("Name", ""):
            print(tag, i["SysAddresses"])
EOF
```

### Build-host problems (boot artefacts and image)

Everything in this subsection is about the *build machine*, not the board.
It is recorded because getting the Yocto/EDF side to run cost far more time
than the port itself, and because the same problems were hit on **two very
different hosts** — AlmaLinux 9.8 (kernel 5.14, XFS) and Ubuntu 24.04
(kernel 6.8, ext4).

Four fixes from this exercise are now **in the tree**, so a fresh checkout
should not hit them:

| Fix | Where |
| --- | --- |
| tar pinned to `1.35+dfsg-3build1` and held | `sdbuild/Dockerfile` |
| GCC fetched from the GitHub mirror, not `gcc.gnu.org` | `sdbuild/packages/gcc-mb/samples/*/crosstool.config` |
| `kernel-devsrc` RPM glob no longer picks the `-lic` subpackage | `sdbuild/scripts/build_edf_boot.sh` |
| `pr_verify` failure is fatal | `boards/VRK160/base/build_pdi.tcl`, `base.tcl` |

The rest below still needs doing by hand on a non-container host.

#### The one that matters: GNU tar breaks `pseudo`

**Symptom.** Every `do_package` task dies with:

```
got *at() syscall for unknown directory, fd 4
couldn't allocate absolute path for 'share'.
tar: ./usr/share: Cannot mkdir: Bad address
```

`Bad address` (EFAULT) from `mkdir` is not a filesystem error: it is Yocto's
`pseudo` (its `LD_PRELOAD` fakeroot) failing to resolve a directory file
descriptor that `tar` opened.

**Cause.** Recent GNU tar changed how it opens the extraction directory, and
`pseudo` 1.9.0 does not track that descriptor. This is a **known upstream
Yocto issue with no connection to this board** — reported through 2025-2026
against NXP i.MX, STM32MP and others. The breaking change arrives through
*distro patches*, which is why both hosts were affected:

| Host | tar | Result |
| --- | --- | --- |
| AlmaLinux 9.8 | `tar-1.34-11.el9` | fails |
| Ubuntu 24.04 | `1.35+dfsg-3ubuntu0.3` | fails |
| Ubuntu 24.04 | `1.35+dfsg-3build1` | works (per upstream reports) |

**Fix (container).** `sdbuild/Dockerfile` installs
`tar=1.35+dfsg-3build1` and `apt-mark hold`s it, so a freshly built
container is already fixed.

**Fix (bare host).** Downgrading the system tar would affect every user, so
build an unpatched one and put it ahead of the host's on `PATH` instead.
BitBake symlinks `tmp/hosttools/tar` from whatever `PATH` gives it at
startup, so this stays scoped to your user.

```sh
cd /tmp && wget https://ftp.gnu.org/gnu/tar/tar-1.33.tar.gz
tar -xf tar-1.33.tar.gz && cd tar-1.33
./configure --prefix=$HOME --without-posix-acls --without-selinux
make -j$(nproc) && make install        # -> ~/bin/tar
```

`--without-posix-acls --without-selinux` are needed because tar 1.33 predates
the `acl_*_at()` signature change in modern libacl and will not compile
otherwise. Packaging invokes `tar -cf - -p -S`, which uses neither, so
nothing is lost.

> **Delete the hosttools symlinks for *every* multiconfig, not just the main
> one.** Each `tmp*` tree has its own, and one stale symlink is enough to
> keep failing — this port has three (`tmp`, `…-microblaze-pmc`,
> `…-microblaze-psm`):
> ```sh
> rm -rf .../pynq-edf/build/tmp*/hosttools
> ```
> Then verify before starting a long run:
> ```sh
> ls -la .../build/tmp/hosttools/tar     # must point at ~/bin/tar
> ```

What does **not** work: `PACKAGE_DEPENDS += "tar-native"` in `local.conf`.
It looks like it should — `STAGING_BINDIR_NATIVE` precedes `tmp/hosttools`
in the task `PATH` — but `tar-native` never lands in the `do_package`
sysroot. Tried and discarded.

#### `mkimage` / `mkenvimage` are missing

`build_edf_boot.sh` step 7 needs both, from `u-boot-tools`. The package name
is `uboot-tools` on RHEL family and `u-boot-tools` on Debian family. No root
needed, though: **the build has already compiled them**, so symlink them:

```sh
U=.../pynq-edf/build/tmp/sysroots-components/x86_64/u-boot-tools-xlnx-native/usr/bin
ln -sf $U/mkimage    ~/bin/mkimage
ln -sf $U/mkenvimage ~/bin/mkenvimage
```

Those are the only two external tools the script calls, so this is the whole
list. They point into the build tree, so a `tmp/` wipe leaves them dangling —
install the package if you want something durable.

#### crosstool-NG cannot fetch GCC (HTTP 429)

`REBUILD_PYNQ_SDIST=1` builds a MicroBlaze cross-compiler with crosstool-NG,
which cloned GCC straight from `gcc.gnu.org`:

```
fatal: unable to access 'https://gcc.gnu.org/git/gcc.git/': The requested URL returned error: 429
[ERROR]  Failed to find git ref releases/gcc-9.2.0
```

429 is rate limiting, and cloning the full GCC history just to reach a
release tag is slow and fragile. Both `gcc-mb` samples now point at the
GitHub mirror instead, which carries the same refs:

```
CT_GCC_DEVEL_URL="https://github.com/gcc-mirror/gcc.git"
CT_GCC_DEVEL_BRANCH="releases/gcc-9.2.0"     # unchanged
```

The ARM sample additionally used `git://`, a protocol many networks block.

> The working copy is `sdbuild/build/gcc-mb/.config`, regenerated from the
> sample. Patch the sample for a durable fix; patch the working copy to
> unblock a build already in progress.

This only matters for `REBUILD_PYNQ_SDIST=1`, and the MicroBlaze toolchain it
builds is for PYNQ's IOP/PMOD subsystems on Zynq boards — the VRK160 does not
use it, but the sdist is board-agnostic.

#### Ubuntu 24.04: AppArmor blocks BitBake

```
ERROR: User namespaces are not usable by BitBake, possibly due to AppArmor.
```

Ubuntu 24.04 restricts unprivileged user namespaces. Any `mconf` /
`kconfig-frontends-native` error that follows is a *consequence*, not the
cause.

```sh
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | \
  sudo tee /etc/sysctl.d/60-apparmor-namespace.conf     # persist
```

This is a system-level security setting, not a build detail: it reverts to
pre-24.04 behaviour, which is what Yocto assumes.

#### Host tools, per distro

Neither host had everything. `boot_VRK160` needs `repo`, `chrpath`,
`rpcgen`, `makeinfo` and Vivado (for `sdtgen`); it needs neither `sudo` nor
QEMU.

| Tool | RHEL family | Debian family |
| --- | --- | --- |
| `rpcgen` | **not** `rpcsvc-proto` — find it with `dnf provides '*/bin/rpcgen'`, or build [rpcsvc-proto](https://github.com/thkukuk/rpcsvc-proto) into `~/bin` | `rpcsvc-proto` |
| `makeinfo` | `texinfo` | `texinfo` |
| `mkimage` | `uboot-tools` | `u-boot-tools` |
| `repo` | not packaged — `curl -o ~/bin/repo https://storage.googleapis.com/git-repo-downloads/repo` | `repo` |

> `dnf` aborts the **whole transaction** on a single unmatched argument, so
> one wrong package name means nothing at all gets installed. Check the
> output, don't assume.

#### Extra tools for the full image

`make BOARDS=<board>` fails immediately unless `sdbuild/prebuilt/` holds
`pynq_sdist.tar.gz` and `pynq_rootfs.<arch>.tar.gz`. Without them, pass
`REBUILD_PYNQ_SDIST=1 REBUILD_PYNQ_ROOTFS=1` — and note what each then
demands of the host:

| Flag | Rebuilds | Requires |
| --- | --- | --- |
| `REBUILD_PYNQ_SDIST=1` | the PYNQ Python package | `microblaze-xilinx-elf-gcc`, from Vitis's embedded/bare-metal component — a Vitis install without it silently lacks `Vitis/gnu/microblaze/lin/bin` |
| `REBUILD_PYNQ_ROOTFS=1` | the Ubuntu rootfs | `ct-ng` — crosstool-NG **1.24.0 built from source**, not the distro package (this is the version `sdbuild/Dockerfile` uses) |

Also worth copying from the Dockerfile even though no check enforces them:
`ln -s /usr/bin/make /usr/bin/gmake` (Vitis calls `gmake`) and
`pip3 install --upgrade "setuptools>=24.2.0,<81" numpy cffi`.

#### Xilinx tooling contaminates the environment

`gen-machine-conf` warns `Vitis environment(XILINX_VITIS) found, this may
lead to failures`. On the AlmaLinux host `.bash_profile` sourced Vivado's
`settings64.sh`, which **itself sources Vitis**, so "start a new bash shell"
does not help — every login shell reintroduces it. A non-login shell with a
clean environment does:

```sh
env -i HOME="$HOME" USER="$USER" \
    PATH="$HOME/bin:<xilinx>/Vivado/bin:/usr/local/bin:/usr/bin:/bin" \
    bash -c 'cd .../sdbuild && make boot_VRK160'
```

Putting `Vivado/bin` on `PATH` directly, rather than exporting
`VIVADO_PATH`, stops `build_edf_boot.sh` from sourcing all of
`settings64.sh` — `sdtgen` is found on `PATH` and configures itself. Keep
`$HOME/bin` first so the tar and u-boot tools above win.

> `env -i` strips **everything**, including `BOARD_STORE_PATH`. That only
> bites when the same invocation also builds the overlay — `golden_ref.tcl`
> errors out on it by design — so pass it through explicitly:
> ```sh
> BOARD_STORE_PATH="<tools>/data/xhub/boards/XilinxBoardStore"
> ```

This warning turned out to be **noise, not a cause** — it persisted in a
fully clean environment while the real problem was tar. It does make logs
much harder to read.

#### Running the sdbuild container

The full image build requires Ubuntu 24.04 (see [§5](#5-building)), so on any
other distro the container is the supported route. It solves the distro
requirement and every host-tool gap. Four things about invoking it are not
obvious:

**Mount the Xilinx tools' parent directory, not just the version directory.**
`settings64.sh` sources companions by absolute path and can reach *outside*
`XILINX_TOOLS` — ours sources `<tools>/DocNav/.settings64-DocNav.sh`, a
sibling of `2025.2/`. When that file is missing the `source` returns
non-zero, and `build_edf_boot.sh` runs under `set -euo pipefail`, so the
build dies immediately with only a cryptic DocNav message.

**Bind-mount the repo at the same path it has on the host**, not at
`/workspace`: `bblayers.conf` holds ~43 absolute host paths and `local.conf`
pins `SSTATE_DIR`/`DL_DIR` the same way.

**Register `binfmt_misc` on the host first.** `create_rootfs.sh` copies the
static QEMU into the rootfs then runs `chroot <rootfs> bash` — an aarch64
binary on x86_64, which only works through a registered handler. It is
kernel-global, cannot be registered from a rootless container, and **is lost
on reboot**:

```sh
docker run --rm --privileged docker.io/multiarch/qemu-user-static --reset -p yes
```

**Run the container rootful.** The rootfs stages `mount` and `chroot`, which
need real `CAP_SYS_ADMIN`; rootless podman's `--privileged` does not grant
it. Build the image as root too — a rootless-built image is invisible to
root. Pass `--build-arg USERNAME/USER_UID/USER_GID` matching your user so
outputs stay yours.

> On a shared machine, `--privileged`, `--network host` and a global
> `binfmt_misc` registration all affect other users — check local policy.
> Never add `:z`/`:Z` to the Xilinx tools mount: `:Z` relabels the host files
> and would break the shared install for everyone.

The container used to inherit the tar/`pseudo` problem — its own Ubuntu tar
carries the same breaking patch. `sdbuild/Dockerfile` now pins tar to
`1.35+dfsg-3build1` and holds it, so a freshly built container is already
fixed. If you are using an older image, either rebuild it or mount a working
tar in and prepend it:

```sh
-v $HOME/bin:/opt/hostbin:ro ... bash -lc 'export PATH=/opt/hostbin:$PATH; ...'
```

Either way, delete `tmp*/hosttools` afterwards so BitBake re-links.

#### Disk space

The full image needs ~100 GB and the EDF tree alone runs to tens of GB.
Yocto's `BB_DISKMON` aborts the build when space runs low, so check before
starting a multi-hour run.

### Warnings that are expected

These appear on a correct build of `base/`. Knowing they are benign saves
chasing them.

| Warning | Why it's fine |
| --- | --- |
| `BD 41-237` — `RUSER/WUSER/AWUSER/ARUSER_WIDTH does not match` | Optional AXI sideband signals; the NoC ports carry 17–18 bits of USER and the PS/BRAM ends carry 0. Vivado connects them regardless |
| `BD 41-1265` — GIC / TCM segments at the same offset | Versal PS internals: the R5 and A72 GICs both sit at `0xF900_0000`, and the R5 ATCM aliases the global TCM window. Present in any Versal design, not caused by this port |
| `BD 41-3097` — empty PL aperture on `M00_AXI` will be ignored | Emitted while `base.tcl` has deleted the tie-off and not yet assigned the real peripherals, so the aperture is momentarily empty. See [§3.9](#39-mio-peripherals-are-not-set-by-the-board-preset) for what the aperture actually ends up being |
| `Ipconfig 75-698` — *Problem reading NoC solution file … Could not find Logical Master/Slave Traffic Instance* | Names in the `.ncr` are keyed to the golden's hierarchy (`golden_i/…`) and its block-design hashes, which do not exist in the overlay. Only the **PL DMA** paths are affected — 4 of them, being 2 ports × 2 memory channels — and those are non-boot paths that the overlay is free to re-route. Confirmed harmless: `pr_verify` passes with these present, having compared all 24 initial-boot paths equal |
| Utility IP / `xlconstant:1.1` inline-HDL recommendation | `irq_tieoff` still builds in 2025.2. Migrating to `inline_hdl:ilconstant` is future-proofing, not a fix |

`BD 41-2645` and `BD 41-3565` (CCI NMU wider than the PL slave) applied to
the earlier NoC-routed control path. With `FPD_AXI_PL` the control path no
longer crosses the coherent NoC port, so they should not reappear.

> **On `M00_AXI` `APERTURES`:** the declared value is *not* what the hardware
> records. See [§3.9](#39-mio-peripherals-are-not-set-by-the-board-preset) — the NSU stores the
> exact span of the segments assigned behind it, and getting that wrong is a
> `pr_verify` failure rather than a warning.

**Board part not found**
`BOARD_STORE_PATH` must point at a checkout containing
`boards/Xilinx/vrk160/`. Vivado 2025.2 ships `1.0` and `1.1`; this port
requests `1.1`.

---

## 12. Adding another overlay

The board directory is set up so a second overlay can share the golden — and
therefore the same `BOOT.BIN` — with `base`. Two already do: `rfloop` and
`sgloop`, both RF loopback designs.

**The full procedure is [BUILDING_OVERLAYS.md](BUILDING_OVERLAYS.md)**: the
directory layout, the shape of `<name>.tcl` step by step, the address and
clock rules the golden imposes, the RF converter's traps, the Hog flow, how
to get the result onto the board, and a symptom-to-cause table for the
failures that do not say what they are.

The constraints that decide whether your overlay is feasible at all:

* **The golden is a contract, not a template.** Editing it changes
  `golden_noc.ncr`, which invalidates every other overlay *and* `BOOT.BIN`.
* **`BITSTREAM_VRK160` in `VRK160.spec` names the overlay loaded at boot.**
  It can stay `base/base.pdi`; yours is then loaded on demand from Python.
  Only one overlay is the boot default.
* **Four PL clocks** (`pl0..pl3_ref_clk`), each with a `proc_sys_reset`.
  `base` uses only `pl0`; a design needing separate converter and fabric
  clocks has the other three, though both RF overlays instead derive their
  fast domain from a converter output clock through a `clkx5_wiz`.
* **All 16 `pl_ps_irq` lines** are enabled in the golden. Retie whatever you
  do not drive.
* **All 16 GB of LPDDR5** is mapped ([§8](#8-address-map)), and `axi_noc_pl`
  already has a direct inter-NoC link to each of the four controllers — so an
  overlay moving large sample buffers has the bandwidth without a golden
  change. What it *does* need is more PL master ports on `axi_noc_pl`, which
  is a golden change and a full rebuild.
* **Versal RF devices do not support PL Reload**: one PDI download per boot.
  A driver must be able to attach to an already-loaded overlay instead of
  downloading again.

---

## 13. Glossary

Grouped by domain rather than alphabetically, because most of these only make
sense next to their neighbours.

### Versal platform and boot

| Term | Meaning |
| --- | --- |
| **PLM** | **Platform Loader and Manager** — the firmware that runs on the PMC. It is what actually loads a PDI at boot, brings up the PS and NoC, and handles configuration requests afterwards. When this doc says "the PLM loads `boot.pdi`", that is the entity doing it |
| **PMC** | **Platform Management Controller** — the hardened block that owns boot, configuration and security on Versal. The PLM is the software running on it |
| **PSM** | **Platform System Manager** — the power-management processor inside the PS. Appears as the `pmcps_0_psv_psm_0` address space |
| **PS** | **Processing System** — the hardened processors and their peripherals (A72s, R5s, UARTs, SD, Ethernet …) |
| **PL** | **Programmable Logic** — the FPGA fabric, where the base overlay's GPIO/DMA/UART live |
| **APU** | **Application Processing Unit** — the Cortex-A72 cluster. This is where Linux and PYNQ run |
| **RPU** | **Real-time Processing Unit** — the Cortex-R5 cluster. Not used by PYNQ, which is why PL peripherals are *excluded* from its address spaces |
| **DPC** | **Debug Packet Controller** — the debug/JTAG access master. Appears as the `pmcps_0_psv_dpc_0` address space |
| **CIPS** | **Control, Interfaces and Processing System** — the Gen 1 IP wrapping the PS and PMC. Replaced by `ps_wizard` on Gen 2 |
| **PDI** | **Programmable Device Image** — Versal's configuration image format. It replaces the classic `.bit` bitstream and can carry PS, NoC and PL content |
| **ES1** | **Engineering Sample**, silicon revision 1 — pre-production silicon, as in `…-es1` in this board's part number |
| **FPD / LPD** | **Full Power Domain** / **Low Power Domain** — the two main PS power domains. `FPD_CCI_NOC*` and `LPD_AXI_NOC0` are their respective NoC ports |
| **CCI** | **Cache Coherent Interconnect** — the coherent path from the APU into the NoC, so DMA and CPU see the same memory contents without manual cache maintenance |

### Network on Chip

| Term | Meaning |
| --- | --- |
| **NoC** | **Network on Chip** — the packet-switched fabric that carries all traffic between the PS, the PL and the memory controllers on Versal. Nothing reaches DDR without crossing it |
| **NMU** | **NoC Master Unit** — the ingress point where a *master* (a CPU, a DMA) attaches to the NoC. The `S0x_AXI_nmu` instances in [§6](#7-noc-topology) |
| **NSU** | **NoC Slave Unit** — the egress point where the NoC hands off to a *slave*. `M00_AXI_nsu` is the one feeding the PL peripherals |
| **INI** | **Inter-NoC Interface** — the link joining two NoC instances. `axi_noc_pl/M00_INI` → `axi_noc_ps/S00_INI` is how PL DMA traffic reaches the memory controller |
| **MC / DDRMC** | **Memory Controller** — `MC_0` and `MC_1` are the two channels of this board's dual-channel LPDDR5 controller. Connecting to only one is the [§3.8](#38-dual-channel-lpddr5-connect-both-mcs) bug |
| **NoC solution** | The computed placement and routing of NoC traffic, written to a `.ncr` file by `write_noc_solution`. The base overlay is *locked* to the golden's solution so parent and child agree |
| **`.nts`** | The NoC traffic-spec file listing every master→slave path and its bandwidth. Reading it is how [§6](#7-noc-topology) was verified |

### AXI and peripherals

| Term | Meaning |
| --- | --- |
| **AXI** | **Advanced eXtensible Interface** — the ARM AMBA bus protocol everything here speaks |
| **AXI4-Lite** | The cut-down AXI variant for simple register access. The DMA's control port (`S_AXI_LITE`) uses it |
| **MM2S / S2MM** | **Memory-Map to Stream** / **Stream to Memory-Map** — the two DMA directions: reading DDR into a stream, and writing a stream back to DDR |
| **SG** | **Scatter-Gather** — descriptor-driven DMA. Disabled here (`c_include_sg 0`), so transfers are simple single-buffer |
| **VIP** | **Verification IP** — a protocol-correct dummy endpoint. Used as tie-offs in the golden so the design is DRC-clean with no real PL logic |
| **BRAM** | **Block RAM** — on-chip memory blocks; the 8 KB scratch memory in the base overlay |
| **GPIO / UART** | **General Purpose I/O** / **Universal Asynchronous Receiver-Transmitter** — the LEDs, buttons, DIP switches and serial port |
| **IRQ** | **Interrupt Request** — `pl_ps_irq0..15` are the PL-to-PS interrupt lines |
| **GIC** | **Generic Interrupt Controller** — ARM's interrupt controller. The A72 and R5 each have one, which is why they alias at `0xF900_0000` in the `BD 41-1265` warning |
| **TCM / ATCM** | **Tightly Coupled Memory** — the R5's local low-latency RAM. Also part of that same benign warning |
| **USER signals** | `AWUSER`/`ARUSER`/`RUSER`/`WUSER` — optional AXI sideband. Width mismatches between them are the harmless `BD 41-237` warnings |
| **MMIO** | **Memory-Mapped I/O** — reaching peripheral registers by reading and writing addresses. How PYNQ drives everything in the PL |

### Vivado flow and artefacts

| Term | Meaning |
| --- | --- |
| **BD** | **Block Design** — the schematic-level design built by the `.tcl` scripts here. Vivado error codes prefixed `BD` come from it |
| **IPI** | **IP Integrator** — the Vivado tool that edits block designs |
| **IP** | **Intellectual Property** — a reusable hardware block (`axi_noc2`, `ps_wizard`, `axi_dma` …) |
| **VLNV** | **Vendor:Library:Name:Version** — an IP's unique identifier, e.g. `xilinx.com:ip:ps_wizard:1.0` |
| **XSA** | Xilinx Support Archive — the hardware handoff bundle consumed by the software flow. `golden.xsa` is what the boot image is generated from |
| **HWH** | **Hardware Handoff** — the XML metadata describing the design's IP and addresses. **This is what PYNQ parses at runtime** to expose peripherals by name |
| **DCP** | **Design Checkpoint** — a snapshot of a placed/routed design. `golden_routed.dcp` is `pr_verify`'s reference |
| **XDC** | **Xilinx Design Constraints** — timing and pin constraints |
| **PR / DFX** | **Partial Reconfiguration** / **Dynamic Function eXchange** — reprogramming part of the fabric at runtime. `pr_verify` borrows that flow's checker to confirm the overlay matches the golden |
| **DRC** | **Design Rule Check** — Vivado's structural validation |

### Linux, boot and PYNQ runtime

| Term | Meaning |
| --- | --- |
| **EDF** | AMD's Yocto/bitbake-based embedded build flow, used here to produce `BOOT.BIN`, the kernel and the device tree. The tree never spells the acronym out, only referring to "AMD's EDF/bitbake flow" |
| **BSP** | **Board Support Package** — the board-specific software layer |
| **SDT** | **System Device Tree** — the device tree generated from an XSA by `sdtgen`, describing the whole system rather than just Linux's view |
| **DTS / DTSI / DTB / DTBO** | Device Tree **Source** / **Source Include** / **Blob** (compiled) / **Blob Overlay** (a patch applied at runtime). `board.dtsi` is an include merged into the machine's device tree |
| **CMA** | **Contiguous Memory Allocator** — the Linux allocator that hands out physically contiguous buffers. DMA needs these, which is why `board.dtsi` pins a CMA pool into the low 2 GB |
| **XRT** | **Xilinx Runtime** — the userspace/kernel runtime for accelerator access |
| **zocl** | XRT's kernel driver for embedded platforms. Without its device-tree node it never probes, and `pyxrt.device(0)` fails |
| **PYNQ** | **Python Productivity for Zynq** — this project. The name predates its expansion to Versal and other adaptive-computing platforms |
| **`BOOT.BIN`** | The boot image the platform loads from the SD card. Carries the PLM, the golden `boot.pdi`, u-boot and friends |

---

## 14. Useful references

| What | Where |
| --- | --- |
| sdbuild board-directory contract | [`sdbuild/BUILD_SYSTEM.md`](../../sdbuild/BUILD_SYSTEM.md) |
| Gen 1 equivalent of this port | [`boards/VCK190/`](../VCK190/) |
| AMD VRK160 reference design | `Vivado-Design-Tutorials/Versal/IP_Integrator/Introduction_to_Versal_IPI` |
| Board definition | `$BOARD_STORE_PATH/boards/Xilinx/vrk160/1.1/board.xml` |
