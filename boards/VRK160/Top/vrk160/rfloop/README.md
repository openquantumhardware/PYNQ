# rfloop under Hog

Same design as `boards/VRK160/rfloop`, driven by Hog instead of the Makefile.
The point is to validate the flow on a design already proven on hardware
before porting the QICK firmware the same way.

## Layout

The Hog root is `boards/VRK160` -- the directory holding `Hog/` and `Top/`.
Paths inside `list/` are relative to it, not to the git root.

    boards/VRK160/
      Hog/              <- submodule, see below
      Top/vrk160/rfloop/ <- this project
      golden/           <- golden reference, must be built first
      rfloop/           <- the design sources, unchanged

## One-time setup

    cd boards/VRK160
    git submodule add https://gitlab.com/hog-cern/Hog.git Hog
    git submodule update --init --recursive

## Building

    make -C boards/VRK160/golden          # golden_noc.ncr + golden_routed.dcp
    export PYNQ_VRFDC_IP_REPO=/path/to/VRFDC_Vivado_IP_Repo_v1_3_<id>
    cd boards/VRK160
    ./Hog/Do CREATE   Top/vrk160/rfloop
    ./Hog/Do WORKFLOW Top/vrk160/rfloop
    make -C rfloop dtbo                   # needs sdtgen from Vitis on PATH

## Why Top/vrk160/rfloop and not Top/rfloop

Only `post-creation.tcl` is a per-project hook that Hog finds on its own. The
implementation and bitstream hooks live in `Hog/Tcl/integrated/`, and each one
sources a user file at

    ./Top/$group_name/$proj_name/<hook>.tcl

so a project with no group never gets its hooks sourced. That is why the first
attempt died in place_design on the PVT_SAS DRC: `pre-implementation.tcl` was
sitting in `Top/rfloop/` and was never read.

## What runs where

    hog.conf                  PART, BOARD_PART
    list/constraints.con      vrk160_pl_io.xdc
    list/others.src           sources proj.tcl
    proj.tcl                  sources rfloop/rfloop.tcl, builds the BD wrapper
    post-creation.tcl         top, segmented_configuration, NoC lock
    init-pre.tcl              CR-1223133 PVT_SAS workaround, before link_design
    pre-implementation.tcl    (empty -- see below)
    post-implementation.tcl   (empty -- runs before the routed .dcp exists)
    post-bitstream.tcl        pr_verify against the golden, then writes rfloop.xsa

## Why init-pre.tcl exists

Hog's `pre-implementation.tcl` is registered as `STEPS.INIT_DESIGN.TCL.POST`,
which runs *after* `link_design`. The CR-1223133 `set_param` has to be in
effect before that, or the DRC preceding `place_design` still fails on
PVT_SAS. The Makefile flow gets this right by accident: it sets the param in
the session that calls `launch_runs`, and Vivado copies non-default set_params
into the top of the generated `init_design` step.

`post-creation.tcl` therefore registers `init-pre.tcl` as
`STEPS.INIT_DESIGN.TCL.PRE`, which Hog does not use and which lands in the
same place.

## Hook timing, the short version

Three of the four hooks needed their timing worked out by failing:

| hook | Hog registers it as | consequence |
|---|---|---|
| `post-creation.tcl` | per-project, after CreateProject | the only one Hog finds by name |
| `init-pre.tcl` | `STEPS.INIT_DESIGN.TCL.PRE` (ours) | before `link_design` -- where the CR-1223133 set_param has to be |
| `pre-implementation.tcl` | `STEPS.INIT_DESIGN.TCL.POST` | after `link_design`; too late for the above |
| `post-implementation.tcl` | `STEPS.ROUTE_DESIGN.TCL.POST` | inside route_design, **before** the routed `.dcp` is written |
| `post-bitstream.tcl` | `STEPS.<binary>.TCL.POST` | after `write_device_image`; the first point where the routed `.dcp` exists |

## Known gaps

* `list/src.src` is empty on purpose. `rfloop.tcl` adds its own HDL and
  constraints, and listing them twice makes Vivado warn on every build. The
  cost is that Hog's uncommitted-file check and changelog do not cover them.
  Moving the file lists out of `rfloop.tcl` and into `list/` is the follow-up.
* **Hog only sees committed files.** An untracked file is ignored silently.
* The `.dtbo` step stays in the Makefile because sdtgen is a Vitis tool.
