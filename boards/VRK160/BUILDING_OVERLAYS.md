# Building a Versal project for the VRK160

The path from an empty directory to a PDI the board actually loads, written
as a reference. [README.md](README.md) documents the *port* — why the board
directory looks the way it does and what it took to boot it. This documents
the *procedure*: what you do, in what order, and which steps fail silently
if you skip them.

Two overlays already follow it end to end and are the worked examples
referred to throughout:

| overlay | what it is |
| --- | --- |
| [`rfloop/`](rfloop/) | PL DDS → DAC0 → XM855 → ADC3 → capture. Tunes 200 MHz–3.5 GHz to within 0.04 MHz at 85–88 dB. The known-good reference. |
| [`sgloop/`](sgloop/) | the same loop driven by QICK's `axis_signal_gen_v6`, plus an MM2S DMA for the envelope. |

---

## Contents

1. [The one idea you need first](#1-the-one-idea-you-need-first)
2. [Prerequisites](#2-prerequisites)
3. [The eight artifacts](#3-the-eight-artifacts)
4. [Step by step](#4-step-by-step)
5. [Rules the golden imposes](#5-rules-the-golden-imposes)
6. [If your design has RF](#6-if-your-design-has-rf)
7. [The same build under Hog](#7-the-same-build-under-hog)
8. [Getting it onto the board](#8-getting-it-onto-the-board)
9. [Verifying you got it right](#9-verifying-you-got-it-right)
10. [Failure catalogue](#10-failure-catalogue)

---

## 1. The one idea you need first

On Zynq and RFSoC an overlay is a bitstream: you build whatever you like and
load it. On Versal it is not. The PS, the DDR controllers and the NoC are
configured by the **PLM at boot** from `BOOT.BIN`, and the PL image loaded
later must agree with the configuration already running. Two designs that
disagree about the NoC cannot both be loaded on one boot.

The mechanism that makes runtime overlays possible is **Segmented
Configuration**, and it works by making one design authoritative:

```
        golden/                        your overlay
        ───────                        ────────────
    golden_ref.tcl   ──── sourced by ──→  <name>.tcl
      (PS + NoC + LPDDR5 + tie-offs)         adds your IP in place of tie-offs

    golden_noc.ncr   ──── locked to ───→  impl_1 NOC_SOLUTION_FILE
      (the NoC solution)                     your routing must reproduce it

    golden_routed.dcp ─── compared ────→  pr_verify
      (the reference checkpoint)             fatal if they differ

    golden_boot.pdi  ──── becomes ─────→  BOOT.BIN
      (PS + DDR bring-up)                    loaded once, at power-on
```

So the golden is a **contract**, not a starting template. Every overlay is
the golden plus your logic, locked to the golden's NoC solution and proved
identical in the static region by `pr_verify`. Three consequences that decide
how you write everything below:

* **You never edit the golden to make an overlay fit.** Editing it changes
  `golden_noc.ncr`, which invalidates every other overlay *and* `BOOT.BIN`.
  If you genuinely need a golden change (more PL master ports on
  `axi_noc_pl`, say), it is a full rebuild of everything, including the SD
  image's boot artifacts.
* **You start from `source ../golden/golden_ref.tcl`,** then delete the
  tie-off cells standing in for the ports you want.
* **`pr_verify` is not optional.** It is the only thing between you and a PDI
  that loads and then behaves incorrectly in ways nothing reports.

### One PDI per boot

**Versal RF devices do not support PL Reload.** This is in AMD's RF known
issues, filed under excessive current draw for PL Reload and DFX use cases.
The second `Overlay()` of a boot leaves the DAC tile in `STATE_OFF` and no
sequence of driver calls brings it back.

This is silicon, not your design, and it cost five eliminated hypotheses
before the document turned up. Plan one measurement session per reboot, or
attach to the already-loaded design instead of downloading again — see
[§8](#8-getting-it-onto-the-board).

---

## 2. Prerequisites

```bash
# Vivado 2025.2
source /home/tools/xilinx/2025.2/Vivado/settings64.sh

# Board definition store (golden_ref.tcl errors out early without it)
export BOARD_STORE_PATH="/home/tools/xilinx/2025.2/data/xhub/boards/XilinxBoardStore"

# Only if your design instantiates the RF converter: the IP is NOT in Vivado
export PYNQ_VRFDC_IP_REPO=/path/to/VRFDC_Vivado_IP_Repo_v1_3_<id>

# Only if you use QICK IP
export QICK_IP_REPO=/path/to/qick_internal/firmware/ip

export VIVADO_JOBS=8          # optional, default 4
```

`sdtgen` for the device tree comes from the same install; sourcing
`settings64.sh` puts it on `PATH`.

Build the golden once, before anything else:

```bash
cd boards/VRK160/golden && make
```

It emits `golden.xsa`, `golden_noc.ncr`, `golden_routed.dcp` and
`golden_boot.pdi`. Every overlay Makefile has a dependency rule that rebuilds
it if any `golden/*.tcl` or `golden/*.xdc` is newer — because an overlay
locked to a stale NoC solution is exactly the failure that is hardest to see.

---

## 3. The eight artifacts

A finished overlay directory holds these. Knowing what each is for saves
guessing when one is missing:

| file | produced by | needed for |
| --- | --- | --- |
| `<name>.tcl` | you | the block design |
| `build_pdi.tcl` | copied verbatim | implementation, NoC lock, `pr_verify` |
| `Makefile` | copied, two variables changed | the whole chain |
| `<name>.pdi` | `build_pdi.tcl` | what `Overlay()` downloads |
| `<name>.hwh` | `build_pdi.tcl` | how PYNQ discovers your IP by name |
| `<name>.xsa` | `build_pdi.tcl` | input to `sdtgen` |
| `<name>.dtbo` | `mkdtbo.py` | **libmetal**: no node in sysfs, no converter |
| `<name>.py` | you | the PYNQ driver / `Overlay` subclass |

`build_pdi.tcl`, `Makefile` and `mkdtbo.py` are overlay-agnostic apart from
the `overlay_name` / `design_name` variables at the top. Copy them from
[`rfloop/`](rfloop/) unchanged.

---

## 4. Step by step

### 4.1 Create the directory

```bash
cd boards/VRK160
mkdir myoverlay && cd myoverlay
cp ../rfloop/{Makefile,build_pdi.tcl,mkdtbo.py} .
sed -i 's/rfloop/myoverlay/g' Makefile build_pdi.tcl
```

Any directory within two levels of the board directory that holds a `.pdi`
becomes an importable overlay in the SD image, so `myoverlay/myoverlay.pdi`
plus its `.hwh` and `.py` install as `pynq.overlays.myoverlay`.

### 4.2 Write `<name>.tcl`

The shape both existing overlays follow, in order. The order is not
cosmetic — two of these steps fail if moved (4.2.9 and 4.2.11).

**1 — name and environment.** `set design_name "myoverlay"`, then check every
env var you need and `exit 1` with a message naming the variable. A Tcl error
1500 lines into a Vivado log is much worse than a refusal in the first ten.

**2 — source the golden.**

```tcl
set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir ../golden/golden_ref.tcl]
```

This creates the project *and* the block design. Everything after operates on
an open design.

**3 — add your IP repositories,** if any, and re-scan:

```tcl
set_property ip_repo_paths [concat [get_property ip_repo_paths [current_project]] \
                                   $my_ip_repo] [current_project]
update_ip_catalog -rebuild
```

Then check `get_ipdefs` actually finds what you expect and stop if not.
Prefer matching on the core name (`*:axis_signal_gen_v6:*`) over a full
VLNV: the same core packaged by two different flows has two different
vendor/library prefixes.

**4 — delete the tie-offs you are replacing.** The golden ties off every port
an overlay might use so that it is a valid standalone design:

| tie-off | stands in for |
| --- | --- |
| `pl_tieoff_m00axi` | `ps_wizard_0/FPD_AXI_PL`, the PS→PL control path |
| `pl_tieoff_dma0` | `axi_noc_pl/S00_AXI`, first PL→DDR master port |
| `pl_tieoff_dma1` | `axi_noc_pl/S01_AXI`, second PL→DDR master port |
| `pl_tieoff_irq` | the 16 `pl_ps_irq` lines |
| `pl_tieoff_pb` | `axi_gpio_pb` — **keep this one** |

Delete only what you replace. `rfloop` keeps `pl_tieoff_dma1` because it has
one DMA; `sgloop` deletes it because it has two.

`pl_tieoff_pb` is different in kind: the push-button pins share bank silicon
with LPDDR5, so the *golden* must own that cell. Keep it unless your design
genuinely drives the buttons. See README §3.13.

**5 — instantiate your IP.** Read back anything whose silent loss would be
expensive. Vivado accepts `CONFIG.*` properties that an IP then ignores
without a warning — `CONFIG.IS_ACLK_ASYNC` on `axis_data_fifo` did exactly
that here, and the consequence surfaced much later as a clock-domain
mismatch pointing at a different cell. Both overlays carry a helper:

```tcl
proc verify_config {cell args} {
    foreach {prop want} $args {
        set got [get_property CONFIG.$prop [get_bd_cells $cell]]
        if {$got ne $want} {
            puts "ERROR: $cell CONFIG.$prop reads back as '$got', expected '$want'."
            exit 1
        }
    }
}
```

**6 — external ports,** if you have any (`create_bd_intf_port`).

**7 — the control path.** A SmartConnect off `ps_wizard_0/FPD_AXI_PL`, one
master per AXI-Lite slave. `NUM_CLKS 1` if everything is on `pl0_ref_clk`,
which is the simple and usually correct answer — put only data streams in a
faster domain.

**8 — clocks,** then **9 — resets**, then **10 — interface connections.**

> **This order matters and is the single most common self-inflicted failure.**
> IPI propagates `FREQ_HZ` and `CLK_DOMAIN` along an interface *at the moment
> it is connected*. Wire the streams before the clocks and a FIFO still
> advertises its input clock when its output is attached, so validation dies
> with `ERROR: [BD 41-237] Bus Interface property FREQ_HZ does not match` —
> naming two cells that are both configured correctly.

**11 — tie off unused interrupts.** All 16 `pl_ps_irq` lines are enabled in
the golden. Drive what you use, tie the rest to an `xlconstant` of 0.

**12 — addresses.** See [§5.2](#52-the-address-window).

**13 — `validate_bd_design`** then **`save_bd_design`**.

### 4.3 Build

```bash
make            # golden if stale, block design, PDI + pr_verify, dtbo
```

or a stage at a time while iterating:

```bash
make block_design   # vivado -mode batch -source myoverlay.tcl
make pdi            # vivado -mode batch -source build_pdi.tcl
make dtbo           # sdtgen on the .xsa, then mkdtbo.py
```

`build_pdi.tcl` does, in order: set the wrapper as top; set
`segmented_configuration true`; point `impl_1`'s `NOC_SOLUTION_FILE` at
`../golden/golden_noc.ncr`; `set_param device.unreserve_licensed_sites true`
(CR-1223133 — without it `place_design` refuses to start on this ES part);
run to `write_device_image`; **`pr_verify` against `golden_routed.dcp` and
abort if it fails**; `write_hw_platform -fixed -include_bit`; copy the `.hwh`
out of the `hw_handoff` directory.

### 4.4 Write `<name>.py`

A PYNQ `Overlay` subclass. The IP names you chose in the block design are the
attribute names PYNQ gives you, via the `.hwh`. Look at
[`rfloop/rfloop.py`](rfloop/rfloop.py) and
[`sgloop/sgloop.py`](sgloop/sgloop.py).

---

## 5. Rules the golden imposes

### 5.1 Clocks

Four PL clocks come from the golden — `pl0..pl3_ref_clk` — each with its own
`proc_sys_reset` (`rst_pl0`…). `pl0_ref_clk` is 100 MHz and is the natural
control and DMA domain.

For a faster datapath domain, derive it from a converter output clock through
a `clkx5_wiz`, not from another `plN_ref_clk`. Both RF overlays run the
fabric at 491.52 MHz from `clk_adc3`.

### 5.2 The address window

PL peripherals live in the conventional `0xA400_0000` window. Two things
about it are not obvious:

**`0xA403_0000` is taken.** The golden's `axi_gpio_pb` is there, reached
through `pl_tieoff_pb`. `validate_bd_design` does *not* flag the overlap —
the two are in different address spaces — so it surfaces only in `mkdtbo.py`,
as two device tree nodes at one address. `rfloop` stops below it; `sgloop`
skips over it.

**The AXI-Lite segment is not always called `Reg`.** Xilinx IP names it
`Reg`; QICK's names it `reg0`. Getting it wrong gives you

```
ERROR: [BD 5-432] A peripheral must be specified when '-offset and -range' option exists
```

which names neither the segment nor the cell.

Assign each segment to the four cores that should see it and *explicitly
exclude* it from the three that should not. Vivado raises a CRITICAL WARNING
for every segment left neither assigned nor excluded, and a log full of them
hides the one that matters:

```tcl
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
```

Lay the segments out inside the reserved window and **end exactly at the
top** — keep the `pl_aperture_anchor` block if your peripherals do not reach
`0x…0FFF_0000` on their own.

### 5.3 DMA masters and DDR

Every DMA address space needs the two DDR channel-0 segments mapped, and the
other three channels explicitly excluded:

```tcl
assign_bd_address -offset 0x00000000     -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_LEGACY] -force
assign_bd_address -offset 0x000800000000 -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
    [get_bd_addr_segs axi_noc_ps/DDR_MC_PORTS/DDR_CH0_MED] -force
```

A DMA with both directions needs this for `Data_MM2S` **and** `Data_S2MM`.
Miss one and validation fails on an unassigned master, which does not point
at the DMA.

All 16 GB across four controllers is mapped and `axi_noc_pl` has a direct
inter-NoC link to each, so bandwidth is not the constraint. **More PL master
ports is a golden change**, and therefore a rebuild of everything.

---

## 6. If your design has RF

### 6.1 The IP is not the RFSoC one

`vrf_data_converter`, not `usp_rf_data_converter`. Same concept, different
port names, different parameter names, and — the expensive part —
**different enum encodings, which are also not the driver's**. From
`component.xml`:

```
coarse mixer frequency   0 = Fs/2   1 = Fs/4   2 = -Fs/4   3 = 0
DAC mixer mode           0 = I/Q->Real   1 = I/Q->I/Q   2 = Real->Real
mixer type               0 = Bypassed   1 = Low_Power   2 = Fine   3 = Off
```

against the driver's `XVRFDC_CRS_MIX_*`, which is `OFF=0, BYPASS=1,
FS_DIV_2=2, FS_DIV_4=3, MINUS_FS_DIV_4=4, …`. Reading an IP value with the
driver's table produces conclusions that look sound and are wrong. **Always
read the enum out of `component.xml`.** This cost a week.

### 6.2 Start from AMD's own example

`vrf_data_converter`'s generated example project and the `ftloop` reference
design for this board are the configurations known to work. The validated
setup here is a diff against them: DUC0 coarse at −Fs/4 (`{2}`), DDC0 coarse
at Fs/4 (`{1}`), **low-power** mixer type (`{1}`), NCO 0.0.

The fine mixer does not modulate on this part. Its NCO registers read back
correct — FCW scaling linearly with frequency, phase accumulator enabled,
mixer mode `0xC03` — and the output does not follow them.

### 6.3 Rate arithmetic

```
PLDataRate  = (DACDataRate × IQMode) / InterpolationRate
PLFclock × PLNumWords = PLDataRate
```

The ADC's Real→I/Q conversion *is* the Fs/4 coarse mixer, so a capture folds
around ±1966.08 MHz: a tone at `f_rf` appears at `fold(f_rf − Fs/4)`, and any
observed peak has two possible RF sources. `sgloop.py` has `rf_to_capture()`
and `capture_to_rf()` for this.

### 6.4 Two sizing traps

* **2 MB at `0xA420_0000` for the converter.** 256 KB is not enough and the
  shortfall is not diagnosed anywhere useful: the driver's `XVRFDC_REGION_SIZE`
  is `0x140000`, so tiles whose registers fall past a short mapping take
  libmetal down with `metal_io_read: Assertion '0' failed`. DAC tile 0 reads
  fine from 256 KB and ADC tile 3 does not — which makes it look like a tile
  problem.
* **A capture must request twice `DEPTH`** to drain the FIFO, and must wait
  for *idle*, not for "not halted".

### 6.5 Do not copy QICK's clock distribution

QICK's ZCU216 designs enable extra DAC tiles purely to distribute the clock.
**EN340 warns that internal clock distribution degrades RF-DAC NSD on this
family.** Both overlays here use one DAC tile and one ADC tile, which is also
what every AMD example for this board does.

### 6.6 No LOC constraints for the analog pins

The converter's analog and reference-clock pins are fixed by silicon once the
tiles are chosen. `ftloop`'s XDC declares only the two input clocks, and this
port does the same — which matters because the golden deliberately does not
use the Vivado board preset.

---

## 7. The same build under Hog

[Hog](https://hog.readthedocs.io) gives you reproducible builds tagged with
the git SHA. The Hog root here is `boards/VRK160` — the directory holding
`Hog/` and `Top/` — and every path in a project's `list/` is relative to it.

```
Top/vrk160/<project>/
├── hog.conf                  # "#vivado 2025.2" MUST be the literal first line
├── proj.tcl                  # sources ../../../<project>/<project>.tcl
├── list/                     # source lists (empty here; the design tcl adds sources)
├── post-creation.tcl         # top, segmented_configuration, NoC lock, INIT_DESIGN.TCL.PRE
├── init-pre.tcl              # CR-1223133 unreserve_licensed_sites
├── pre-implementation.tcl    # = STEPS.INIT_DESIGN.TCL.POST
├── post-implementation.tcl   # = STEPS.ROUTE_DESIGN.TCL.POST
└── post-bitstream.tcl        # pr_verify + write_hw_platform
```

```bash
export VRK160_GOLDEN_DIR=$PWD/golden
./Hog/Do CREATE   Top/vrk160/<project>
./Hog/Do WORKFLOW Top/vrk160/<project>
```

**Pin Hog to 2026.1-4.** In 2026.2 `GetSHA` regressed and returns an empty
SHA whenever the Hog root is not the git root, which breaks the workflow
after synthesis once the project files are committed.

Six incompatibilities between a Makefile-driven Vivado flow and Hog were
found here. **Five of them fail silently or point somewhere else:**

| | |
| --- | --- |
| `uplevel #0` | Hog sources your script from inside a proc, so bare `set` lands in a local scope. |
| first line of `hog.conf` | `#vivado <version>` must be literally line 1. |
| `Top/<group>/<project>` | without a group directory the implementation hooks are **never sourced** and nothing says so. |
| `pre-implementation.tcl` | runs *after* `link_design` — too late for anything that must precede it. That is why `init-pre.tcl` is registered separately as `STEPS.INIT_DESIGN.TCL.PRE`. |
| `post-implementation.tcl` | runs *before* the routed `.dcp` is written, so `pr_verify` belongs in `post-bitstream.tcl`. |
| no open project in a run step | `get_runs` returns nothing and `current_project`'s directory is `.`. Derive paths from `[info script]`. |

Hog does not produce the `.dtbo` — that needs `sdtgen`. Run `mkdtbo.py` on
the `.xsa` afterwards.

The same projects live in `qick_internal` on the `versal_dev` branch, under
`firmware/Top/vrk160/`, where the golden is supplied through
`VRK160_GOLDEN_DIR` rather than vendored: two copies of that contract
drifting apart is exactly the failure it exists to prevent.

---

## 8. Getting it onto the board

Copy four files next to each other:

```bash
scp myoverlay.pdi myoverlay.hwh myoverlay.dtbo myoverlay.py \
    xilinx@<board>:/home/xilinx/jupyter_notebooks/myoverlay/
```

PYNQ loads `<overlay>.dtbo` automatically when it sits beside the PDI —
`pynq/pl_server/embedded_device.py` looks for the `.dtbo` suffix. Without the
device tree node, libmetal cannot find the converter in sysfs and
`XVRFdc_InstanceInit` fails at import with an error that does not mention the
device tree.

Then, in a notebook:

```python
from pynq import Overlay
ol = Overlay("myoverlay.pdi")
```

**Because of the PL Reload limitation ([§1](#one-pdi-per-boot)), download
once per boot.** Both overlay drivers detect an already-loaded design through
sysfs and attach instead of re-downloading:

```python
loop = SgLoop()                  # auto-detects; downloads only if needed
loop = SgLoop(download=False)    # attach to what is already there
SgLoop.is_loaded()               # ask first
```

`BITSTREAM_VRK160` in `VRK160.spec` names the overlay loaded **at boot**; it
can stay `base/base.pdi` and yours is loaded on demand.

---

## 9. Verifying you got it right

In the build log:

```
pr_verify PASSED -- overlay is compatible with golden reference
```

If that line is absent the build did not finish, whatever else it printed.

On the board:

```bash
# the device tree node exists and libmetal can see it
ls /sys/bus/platform/devices/ | grep -i vrf

# the converter answers at the address you assigned
devmem 0xA4200000

# tile state -- 15 is fully up, 0 is STATE_OFF (see the PL Reload note)
python3 -c "import xvrfdc; ..."
```

Expected warnings that are **not** problems are catalogued in README §11.

---

## 10. Failure catalogue

Ordered by how long each one takes to identify from its symptom, worst first.

| symptom | cause |
| --- | --- |
| tone appears at the wrong frequency, everything else correct | an enum read with the driver's table instead of the IP's ([§6.1](#61-the-ip-is-not-the-rfsoc-one)) |
| DAC tile reads `STATE_OFF`, driver calls have no effect | second PDI download of the boot; reboot ([§1](#one-pdi-per-boot)) |
| `metal_io_read: Assertion '0' failed`, one tile fine and another not | converter address range too small ([§6.4](#64-two-sizing-traps)) |
| clock-domain mismatch pointing at a correctly configured cell | a `CONFIG.*` the IP silently ignored ([§4.2](#42-write-nametcl) step 5), or interfaces wired before clocks (step 10) |
| `[BD 41-237] FREQ_HZ does not match` on two correct cells | interfaces connected before clocks |
| `[BD 5-432] A peripheral must be specified…` | AXI-Lite segment named `reg0`, not `Reg` ([§5.2](#52-the-address-window)) |
| two device tree nodes at one address, from `mkdtbo.py` | you assigned `0xA403_0000` — the golden's `axi_gpio_pb` ([§5.2](#52-the-address-window)) |
| validation fails on an unassigned master | a DMA direction with no DDR segments ([§5.3](#53-dma-masters-and-ddr)) |
| `place_design` refuses before it starts | missing `set_param device.unreserve_licensed_sites true` (CR-1223133) |
| Hog builds but implementation hooks never run | project not under `Top/<group>/<project>` ([§7](#7-the-same-build-under-hog)) |
| Hog workflow fails after synthesis with an empty SHA | Hog 2026.2 `GetSHA` regression; pin 2026.1-4 |
| capture is short or stale | request twice `DEPTH` and wait for idle ([§6.4](#64-two-sizing-traps)) |
| nothing below 50 MHz | the XM855 balun, not your design |

---

## Further reading

* [README.md](README.md) — the port itself: board facts, Gen 1 → Gen 2
  differences, NoC topology, address map, SD image, troubleshooting, glossary
* [`Top/vrk160/rfloop/README.md`](Top/vrk160/rfloop/README.md) and
  [`Top/vrk160/sgloop/README.md`](Top/vrk160/sgloop/README.md) — Hog details
  per project
* PG443 — `vrf_data_converter` product guide
* EN340 — RF-DAC/RF-ADC clocking and NSD notes for this family
* AMD Versal RF known issues — the PL Reload restriction
