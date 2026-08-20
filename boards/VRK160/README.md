# VRK160 PYNQ Board Port

Build notes for the VRK160 board directory: what the golden reference design
is, why Versal needs one, and every place this port differs from the Versal
Gen 1 (VCK190) port it was derived from.

> New to Versal? [§11 Glossary](#11-glossary) explains every acronym used
> here — PLM, PDI, NoC, NMU/NSU, CCI and the rest — grouped by domain.

Status: **the full hardware flow works.** The golden reference and the base
overlay both build clean on Vivado 2025.2, and **`pr_verify` passes** — the
overlay is a valid segmented child of the golden, which is the thing that
makes PYNQ's runtime overlay model possible on this board. Segmented
configuration, the biggest open risk in the port, is proven on Versal Gen 2.

What remains is the software side: no `BOOT.BIN` has been built and nothing
has been run on hardware. See
[Verification status](#8-verification-status) for the exact line between
proven and assumed.

> Both defects found during this port were **non-fatal messages that let a
> broken artefact through** — the dual-channel LPDDR5 warning
> ([§3.8](#38-dual-channel-lpddr5-connect-both-mcs)) and a `pr_verify`
> failure that `build_pdi.tcl` downgraded to a warning while still printing
> "built successfully". `build_pdi.tcl` now treats `pr_verify` failure as
> fatal, and `base.tcl` checks the aperture contract before building. Treat a
> clean exit status here as necessary, not sufficient.

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
| GPIO | `gpio_led`, `gpio_pb`, `gpio_dp` | `board.xml` — same names as VCK190 |
| Vivado | 2025.2 | — |

This port wires up **only controller C0, channels CH0+CH1** (2 GB at
`0x0`), matching what the AMD reference design exercises. Enabling more
LPDDR5 channels means adding `C<n>_CH<n>_LPDDR5_BOARD_INTERFACE` properties
and re-deriving the address map.

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

### 3.5 The PS-to-PL control path moved into the NoC

**This is the largest architectural change.** Gen 1 CIPS had dedicated
`M_AXI_FPD` / `M_AXI_LPD` master pins for reaching PL peripherals.
`ps_wizard` has **no such pins at all** — and `PS_USE_M_AXI_FPD` /
`PS_USE_M_AXI_LPD` are not valid properties either.

Instead, `axi_noc2` itself exposes a PL-facing AXI master. A PS NoC slave
port is given **two destinations**: the memory controller *and* that master
port.

```tcl
# axi_noc2 gets a master port (NUM_MI 1) aimed at the PL
set_property -dict [list \
    CONFIG.DATA_WIDTH {64} \
    CONFIG.APERTURES {{0x201_0000_0000 1G}} \
    CONFIG.CATEGORY {pl} \
] [get_bd_intf_pins /axi_noc_ps/M00_AXI]

# S00_AXI (fed by FPD_CCI_NOC0) reaches BOTH the DDR and the PL master
set_property -dict [list \
    CONFIG.CONNECTIONS {MC_0 {... initial_boot {true}} M00_AXI {read_bw {5} write_bw {5}}} \
    CONFIG.DEST_IDS {M00_AXI:0x0} \
] [get_bd_intf_pins /axi_noc_ps/S00_AXI]
```

Consequences:

* `base.tcl` hangs its SmartConnect off `axi_noc_ps/M00_AXI`, not off a PS pin.
* PL peripherals must live **inside the NoC aperture** at `0x201_0000_0000`.
  The Gen 1 addresses (`0xA4000000`) are not decoded to the PL at all.
* The golden's tie-off occupies the base of that aperture so the parent
  design reserves the same decode window the child overlay will use.

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

### 3.9 The PS-to-PL aperture contract

The single hardest constraint in this port, and the one that costs a full
overlay build to discover.

`M00_AXI` is fed by `S00_AXI`, which is a **boot partition NMU** (its DDR
paths are `initial_boot`). Segmented configuration therefore requires the
`M00_AXI` NSU to be configured **identically** in the golden and in every
overlay built against it. Get it wrong and `pr_verify` rejects the overlay:

```
ERROR: [Dfx 88-139] SegConfig-Validation-12: NOC NSU .../M00_AXI_nsu/... is
connected to a boot partition NMU .../S00_AXI_nmu/... This NSU has different
apertures (address map) or destination IDs in checkpoint golden_routed.dcp and
checkpoint base_wrapper_routed.dcp.
```

What the NSU actually records is neither the declared `CONFIG.APERTURES` value
nor a rounded power-of-two bucket — it is **the exact span of the address
segments assigned behind it**. Read back from the two `.nts` files of a
mismatched pair:

Read back from the two `.nts` files of the pair that first failed this check:

| Design | NSU `Base` | NSU `Size` | Why |
| --- | --- | --- | --- |
| `golden` | `0x20100000000` | `0x10000` | the tie-off was given a 64 KB range |
| `base` | `0x20100000000` | `0x60000` | six peripherals spanning 0 … `0x5FFFF` |

Note `0x60000` is not a power of two: the span is taken literally.

### One window, many overlays

The window is declared once, in `golden_ref.tcl`:

```tcl
set pl_aperture_base 0x020100000000
set pl_aperture_size 0x10000000        ;# 256 MB
```

It is sized for the **largest** overlay that will ever share this golden, not
for the smallest. That is a deliberate call: the span must be identical
across every overlay built against a given golden, so if one overlay needed a
larger window, the golden — and therefore `BOOT.BIN` — would have to be
rebuilt, and a single boot image could no longer serve several overlays. 256 MB
out of the 1 GB declared aperture costs nothing physical; it is address space,
not logic.

An overlay fills the window by placing its **last address segment so that it
ends exactly at `pl_aperture_base + pl_aperture_size`**. `base` only needs
`0x60000` for real peripherals, so it pins the top with a dummy AXI VIP slave:

```tcl
set pl_segments {
    {axi_bram_ctrl_0/S_AXI/Mem0   0x00000000 0x00002000}
    ...
    {axi_uartlite_0/S_AXI/Reg     0x00050000 0x00010000}
    {pl_aperture_anchor/S_AXI/Reg 0x0FFF0000 0x00010000}   ;# ends at 0x10000000
}
```

Nothing addresses the anchor at runtime — it exists purely to pin the span.
Copy that block and its `pl_segments` entry into any new overlay whose real
peripherals do not reach the top of the window.

`base.tcl` then **asserts the span before building**:

```tcl
if {$pl_span != $pl_aperture_size} {
    error "PL peripheral layout spans 0x... but golden_ref.tcl reserves 0x..."
}
```

That check exists because the alternative is finding out at `pr_verify`, at
the very end of a ~40-minute implementation run.

> **Changing `pl_aperture_size` means rebuilding the golden and regenerating
> `BOOT.BIN`, and invalidates every overlay already built against it.** Adding
> peripherals to an overlay does *not*, as long as they fit below the anchor.
> That is the whole point of reserving generously up front.

---

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
├── edf_bsp/board.dtsi    # CMA pool + zocl node, appended to the device tree
├── notebooks/            # copied into the image's Jupyter tree
└── packages/selftest/    # pynq-selftest, installed into the rootfs
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

Two checks gate this build, and both must pass:

```
PL aperture check: layout spans 0x60000, matches reserved 0x60000
...
pr_verify PASSED -- overlay is compatible with golden reference
```

The first runs in the opening seconds ([§3.9](#39-the-ps-to-pl-aperture-contract));
the second runs after implementation and is fatal on failure. An overlay that
fails `pr_verify` will not load correctly against the golden's boot PDI.

### Full SD image

```bash
cd sdbuild
make BOARDS=VRK160
```

Needs the full sdbuild environment (Ubuntu rootfs, `sudo`, `qemu-*-static`,
package repos). Do not attempt this until `golden/` and `base/` both build
cleanly on their own.

### Rebuilding

Artefacts are only rebuilt when missing. Delete them to force a rebuild:

```bash
make -C boards/VRK160/golden clean
make -C boards/VRK160/base   clean
```

---

## 6. Verified NoC topology

Read back from the generated traffic file
(`golden/golden.gen/sources_1/bd/golden/nsln/golden.nts`) after a successful
block design build:

| Logical instance | Role |
| --- | --- |
| `axi_noc_ps/S00..S03_AXI_nmu` | the 4 PS CCI ports → LPDDR5 |
| `axi_noc_ps/S04_AXI_rpu` | LPD (`CATEGORY {ps_rpu}`) |
| `axi_noc_ps/S05_AXI_nmu` | PMC |
| `axi_noc_ps/M00_AXI_nsu` | PS → PL control path |
| `axi_noc_ps/MC0_ddrc` | LPDDR5 controller + inter-NoC link |
| `axi_noc_pl/S00,S01_AXI_nmu` | PL DMA read/write ports |

The inter-NoC link between the two `axi_noc2` instances is **doubled**, one
leg per LPDDR5 channel:

```json
"ExternalConn": "axi_noc_ps/inst/DDR_INI[0] axi_noc_pl/inst/M00_INI[0],
                 axi_noc_ps/inst/DDR_INI[1] axi_noc_pl/inst/M00_INI[1]"
```

17 traffic paths, split exactly as the segmented model requires:

* **12 with `InitialBoot: true`** — the 6 PS masters × 2 memory channels.
  These land in `boot.pdi`.
* **5 without** — the 2 PL DMA paths × 2 channels (via inter-NoC), plus the
  PS → PL control path. These belong to the runtime overlay.

The arithmetic is a useful sanity check after any NoC change: every
DDR-bound interface contributes one path per channel, so
`(6 PS + 2 DMA) × 2 + 1 control = 17`. A count of 9 means something is
connected to only one MC — see [§3.8](#38-dual-channel-lpddr5-connect-both-mcs).

> An `Ipconfig 75-709` INFO line reporting `0 INI` paths is **not** a
> problem: that counter tracks INI paths *within* one NoC instance. The
> link between instances is the `ExternalConn` entry above.

---

## 7. Address map

### LPDDR5 — 2 GB at `0x0`

Segment `axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY`, assigned into all seven PS
core address spaces, plus both PL DMA master spaces (through the inter-NoC).

There is **no high aperture** (no Gen 1 `DDR_LOW1` equivalent) in this
configuration. If more LPDDR5 channels are enabled, confirm the new base and
range in Vivado's Address Editor before mapping them, and keep
`edf_bsp/board.dtsi`'s CMA `alloc-ranges` consistent.

### PL peripherals — inside the `0x201_0000_0000` NoC aperture

| Peripheral | Address | Range |
| --- | --- | --- |
| `axi_bram_ctrl_0` | `0x0201_0000_0000` | 8 KB |
| `axi_gpio_dip_sw` | `0x0201_0001_0000` | 64 KB |
| `axi_gpio_led` | `0x0201_0002_0000` | 64 KB |
| `axi_gpio_pb` | `0x0201_0003_0000` | 64 KB |
| `axi_dma_0` (lite) | `0x0201_0004_0000` | 64 KB |
| `axi_uartlite_0` | `0x0201_0005_0000` | 64 KB |
| `pl_aperture_anchor` | `0x0201_0FFF_0000` | 64 KB |

The window runs from `0x0201_0000_0000` to `0x0201_1000_0000` (256 MB). The
anchor pins its top and is not addressed at runtime — see
[§3.9](#39-the-ps-to-pl-aperture-contract). Everything between `0x…0006_0000`
and the anchor is free for a larger overlay to use.

> These differ from the VCK190 port, which used `0xA400_0000`+. `base.py`
> resolves IP by name through the HWH so it is unaffected, but any notebook
> or script with hard-coded peripheral addresses needs updating.

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

## 8. Verification status

### Confirmed against real tooling

Everything in [§3](#3-versal-gen-1--gen-2-what-actually-changes) is grounded
in one of:

* the XilinxBoardStore `vrk160` `board.xml` shipped with Vivado 2025.2;
* AMD's `Vivado-Design-Tutorials/Versal/IP_Integrator/Introduction_to_Versal_IPI`,
  `project_1/design_1.tcl` — a real, validated VRK160 design on the same part;
* Vivado errors from building *this* design (`19-7090`, `19-8017`, `BD 5-232`,
  `BD 41-758`, `BD 41-1356`).

The golden reference **builds end to end** on Vivado 2025.2:

| Proven | Evidence |
| --- | --- |
| Block design validates | clean `validate_bd_design` |
| NoC topology | read back from the generated `.nts` — see [§6](#6-verified-noc-topology) |
| Synthesis + implementation | `impl_1` complete, *"All user specified timing constraints are met"* |
| **Segmented configuration on Gen 2** | both `golden_wrapper_boot.pdi` and `golden_wrapper_pld.pdi` produced — the parent/child overlay model is viable on Versal Gen 2 |
| `write_noc_solution` with `axi_noc2` | `golden_noc.ncr` written (57 KB) |
| `write_hw_platform` / `validate_hw_platform` | `golden.xsa` created and validated |
| Dual-channel LPDDR5 wiring | zero `BD 41-3714` warnings; 17 traffic paths and a doubled inter-NoC link — see [§6](#6-verified-noc-topology) |
| **The base overlay** | builds clean and produces `base.pdi`, `base.hwh`, `base.xsa` |
| **`pr_verify` passes** | `PR_VERIFY: check points … are compatible`. 24 initial-boot paths, 96 boot routes, 12 boot NMU configs, 150 boot IO and 2 PS-to-PL interfaces all compared equal — the overlay is a valid segmented child of the golden |
| **Shared 256 MB PS-to-PL window** | golden and overlay both record `Base 0x20100000000, Size 0x10000000` in their NSU, and `pr_verify` passes — so one golden and one `BOOT.BIN` can serve `base` and a future `qick` overlay ([§3.9](#39-the-ps-to-pl-aperture-contract)) |
| PL peripherals reach PYNQ | all six IPs (`axi_gpio_led/pb/dip_sw`, `axi_dma_0`, `axi_bram_ctrl_0`, `axi_uartlite_0`) present in `base.hwh`, which is what `base.py` resolves by name |

### Not yet confirmed

| Item | Risk |
| --- | --- |
| **The software side** | No `BOOT.BIN` has been built (`make BOARDS=VRK160` in `sdbuild/`), so `EDF_BOOT_MACHINE`, the omitted `EDF_BOARD_DTS` and `board.dtsi` are all still untested |
| Anything on real hardware | Nothing has been booted. `pr_verify` proves the overlay is *structurally* loadable against the golden; it does not prove the design works on silicon |
| `PS_NUM_F2P0_INTR_INPUTS` / `PS_NUM_F2P1_INTR_INPUTS` | Key names carried over from Gen 1, never echoed back by Vivado. The golden ties all IRQs to 0, so a wrong key would only surface in `base/` |
| `pl1..3_ref_clk` / `pl1..3_resetn` pin names | Pattern-matched from `pl0_*`. These *did* connect during the golden build, so they exist — but only `pl0_*` carries real traffic so far |
| ~~`M00_AXI` `APERTURES` value~~ | **Resolved.** `BD 41-3097` shows Vivado recomputes the aperture from the real address assignments, so the constant is a hint rather than a contract |
| UART `C_S_AXI_ACLK_FREQ_HZ` (333329987) | Carried over from VCK190's `pl0_ref_clk`; a wrong value skews the baud rate |
| `EDF_BOOT_MACHINE` / omitted `EDF_BOARD_DTS` | No confirmed VRK160 machine or board DTS in `meta-amd-adaptive-socs-bsp` |

---

## 9. Troubleshooting

Errors hit while bringing this port up, and what each one meant.

**`Invalid parameter 'PS_USE_M_AXI_FPD' provided, Ignoring` (19-7090)**
The property does not exist on `ps_wizard`. There is no PS-to-PL AXI master
enable on Gen 2 — see [§3.5](#35-the-ps-to-pl-control-path-moved-into-the-noc).

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

**`Dfx 88-139` / `SegConfig-Validation-12` — NSU has different apertures**
The PS-to-PL address window differs between the overlay and the golden. See
[§3.9](#39-the-ps-to-pl-aperture-contract). `base.tcl` now catches the common
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

### Warnings that are expected

These appear on a correct build of `base/`. Knowing they are benign saves
chasing them.

| Warning | Why it's fine |
| --- | --- |
| `BD 41-237` — `RUSER/WUSER/AWUSER/ARUSER_WIDTH does not match` | Optional AXI sideband signals; the NoC ports carry 17–18 bits of USER and the PS/BRAM ends carry 0. Vivado connects them regardless |
| `BD 41-1265` — GIC / TCM segments at the same offset | Versal PS internals: the R5 and A72 GICs both sit at `0xF900_0000`, and the R5 ATCM aliases the global TCM window. Present in any Versal design, not caused by this port |
| `BD 41-3097` — empty PL aperture on `M00_AXI` will be ignored | Emitted while `base.tcl` has deleted the tie-off and not yet assigned the real peripherals, so the aperture is momentarily empty. See [§3.9](#39-the-ps-to-pl-aperture-contract) for what the aperture actually ends up being |
| `Ipconfig 75-698` — *Problem reading NoC solution file … Could not find Logical Master/Slave Traffic Instance* | Names in the `.ncr` are keyed to the golden's hierarchy (`golden_i/…`) and its block-design hashes, which do not exist in the overlay. Only the **PL DMA** paths are affected — 4 of them, being 2 ports × 2 memory channels — and those are non-boot paths that the overlay is free to re-route. Confirmed harmless: `pr_verify` passes with these present, having compared all 24 initial-boot paths equal |
| Utility IP / `xlconstant:1.1` inline-HDL recommendation | `irq_tieoff` still builds in 2025.2. Migrating to `inline_hdl:ilconstant` is future-proofing, not a fix |

Two warnings are conditional rather than benign, and worth understanding:

**`BD 41-2645`** (128-bit CCI NMU → 32/64-bit PL NSU) and **`BD 41-3565`**
(cacheable path, master 128 bits wider than slave) both say the same thing:
the PS-to-PL control path runs through the *coherent* CCI port down to
32-bit peripheral registers, and CPU-generated **wrap bursts would fail if
that region were mapped cacheable**.

For PYNQ this is fine — Linux maps MMIO as device memory, not cacheable, so
wrap bursts never reach it. It becomes a real bug only if something maps the
`0x201_0000_0000` region cacheable. Note this is the sanctioned pattern: the
AMD reference design routes its PL master off the same `ps_cci` port.

> **On `M00_AXI` `APERTURES`:** the declared value is *not* what the hardware
> records. See [§3.9](#39-the-ps-to-pl-aperture-contract) — the NSU stores the
> exact span of the segments assigned behind it, and getting that wrong is a
> `pr_verify` failure rather than a warning.

**Board part not found**
`BOARD_STORE_PATH` must point at a checkout containing
`boards/Xilinx/vrk160/`. Vivado 2025.2 ships `1.0` and `1.1`; this port
requests `1.1`.

---

## 10. Adding another overlay

The board directory is set up so a second overlay — the planned `qick` design
carrying the ADC/DAC handling — can share the golden, and therefore the same
`BOOT.BIN`, with `base`.

Create `boards/VRK160/qick/` alongside `base/`, copying `Makefile` and
`build_pdi.tcl` unchanged (both are overlay-agnostic apart from the
`overlay_name`/`design_name` variables at the top). Then write `qick.tcl`
following `base.tcl`'s shape:

1. `set design_name "qick"`, then `source ../golden/golden_ref.tcl`.
2. Delete the golden's tie-offs (`pl_tieoff_m00axi`, `pl_tieoff_dma0/1`,
   `pl_tieoff_irq`) and the IRQ nets, exactly as `base.tcl` does.
3. Hang a SmartConnect off `axi_noc_ps/M00_AXI` and fan out to your IP.
4. Route bulk data to DDR through `axi_noc_pl/S00_AXI` / `S01_AXI`, which
   reach the memory controller over the inter-NoC link.
5. Lay out `pl_segments` inside the reserved window, **ending exactly at the
   top** — keep the `pl_aperture_anchor` block if your peripherals do not
   reach `0x…0FFF_0000` on their own.

Both overlays are then discovered automatically: any directory within two
levels of the board directory holding a `.pdi` becomes an overlay in the
image, so `qick/qick.pdi` and its `.hwh`/`.py` are installed under
`pynq.overlays.qick`.

Things worth knowing before starting:

* `BITSTREAM_VRK160` in `VRK160.spec` names the overlay loaded **at boot**.
  It can stay `base/base.pdi`; `qick.pdi` is then loaded on demand from
  Python. Only one overlay is the boot default.
* The golden gives an overlay four PL clocks (`pl0..pl3_ref_clk`) with a
  `proc_sys_reset` on each. `base` uses only `pl0`; a QICK design needing
  separate converter and fabric clocks has the other three available.
* All 16 `pl_ps_irq` lines are enabled in the golden. `base` uses 0, 1, 8, 9
  and 10 and ties the rest to zero — retie whatever you do not drive.
* Only 2 GB of LPDDR5 at `0x0` is mapped ([§7](#7-address-map)). A QICK
  overlay moving large sample buffers may want more channels enabled, which
  is a golden change and a rebuild.

---

## 11. Glossary

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
| **NMU** | **NoC Master Unit** — the ingress point where a *master* (a CPU, a DMA) attaches to the NoC. The `S0x_AXI_nmu` instances in [§6](#6-verified-noc-topology) |
| **NSU** | **NoC Slave Unit** — the egress point where the NoC hands off to a *slave*. `M00_AXI_nsu` is the one feeding the PL peripherals |
| **INI** | **Inter-NoC Interface** — the link joining two NoC instances. `axi_noc_pl/M00_INI` → `axi_noc_ps/S00_INI` is how PL DMA traffic reaches the memory controller |
| **MC / DDRMC** | **Memory Controller** — `MC_0` and `MC_1` are the two channels of this board's dual-channel LPDDR5 controller. Connecting to only one is the [§3.8](#38-dual-channel-lpddr5-connect-both-mcs) bug |
| **NoC solution** | The computed placement and routing of NoC traffic, written to a `.ncr` file by `write_noc_solution`. The base overlay is *locked* to the golden's solution so parent and child agree |
| **`.nts`** | The NoC traffic-spec file listing every master→slave path and its bandwidth. Reading it is how [§6](#6-verified-noc-topology) was verified |

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

## 12. Useful references

| What | Where |
| --- | --- |
| sdbuild board-directory contract | [`sdbuild/BUILD_SYSTEM.md`](../../sdbuild/BUILD_SYSTEM.md) |
| Gen 1 equivalent of this port | [`boards/VCK190/`](../VCK190/) |
| AMD VRK160 reference design | `Vivado-Design-Tutorials/Versal/IP_Integrator/Introduction_to_Versal_IPI` |
| Board definition | `$BOARD_STORE_PATH/boards/Xilinx/vrk160/1.1/board.xml` |
