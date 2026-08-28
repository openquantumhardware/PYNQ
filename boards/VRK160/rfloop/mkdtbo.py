#!/usr/bin/env python3
# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause
"""Turn sdtgen's pl.dtsi into a device tree overlay the kernel will populate.

Three things have to change, and only the first is obvious.

sdtgen emits a bare fragment: it opens with "/ {", closes with "};" and has
no /dts-v1/ header, so dtc rejects it outright.

The kernel's overlay loader needs fragment@N nodes with a target. A flat
"/ { ... }" compiled with /plugin/; produces a valid dtb that applies
nothing and reports no error.

And the fragment has to target **/axi**, not the root. sdtgen wraps
everything in a new "amba_pl" simple-bus, but the kernel does not populate a
bus node that an overlay has just created: the device tree node appears
under /proc/device-tree and no platform device is ever made. libmetal --
which is how XVRFdc_InstanceInit finds the converter -- scans
/sys/bus/platform/devices, so the driver would never see it. /axi is an
existing, already-populated simple-bus with the same #address-cells and
#size-cells, so children added there do get platform devices. It is what the
working zocl overlay on this board targets, which is why dmesg names that
device "axi:zyxclmm_drm".

/axi also carries its own interrupt-parent, which the children inherit. That
matters because the interrupt-parent in sdtgen's output is a phandle to
"imux"; carrying it into the overlay adds a __fixups__ entry, and resolving
it is what made the kernel refuse the overlay with -ENOENT.
"""

import argparse
import os
import re
import subprocess
import sys

WRAPPER_PROPS = ("ranges", "compatible", "#address-cells", "#size-cells",
                 "firmware-name")
IRQ_PROPS = ("interrupt-parent", "interrupts", "interrupt-names")


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def body_of(lines, start):
    """Lines strictly inside the block opened on `lines[start]`."""
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0 and i > start:
            return lines[start + 1:i]
    die("unbalanced braces: the block opened at line %d never closes" % (start + 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dtsi")
    ap.add_argument("out")
    ap.add_argument("--target", default="/axi")
    ap.add_argument("--keep-interrupts", action="store_true",
                    help="keep interrupt properties; adds a __fixups__ entry "
                         "for the imux phandle, which the kernel could not "
                         "resolve on this board")
    args = ap.parse_args()

    if not os.path.isfile(args.dtsi) or os.path.getsize(args.dtsi) == 0:
        die(f"{args.dtsi} is missing or empty")

    lines = open(args.dtsi).read().splitlines()

    root = next((i for i, l in enumerate(lines) if re.match(r"^\s*/\s*\{", l)), None)
    if root is None:
        die(f"{args.dtsi} has no root '/ {{' node -- sdtgen's output format changed")

    inner = body_of(lines, root)

    bus = next((i for i, l in enumerate(inner) if re.match(r"^\s*\w+\s*:\s*amba_pl\s*\{|^\s*amba_pl\s*\{", l)), None)
    if bus is None:
        die("no amba_pl node inside the root -- sdtgen's output format changed")

    contents = body_of(inner, bus)

    # Drop the wrapper's own properties: the children are being reparented
    # onto /axi, which already declares all of them.
    # Match "prop = <...>;" and bare "prop;" alike -- ranges has no value.
    def is_prop(line, names):
        return any(re.match(r"^\s*%s\s*[=;]" % re.escape(n), line) for n in names)

    kept = [l for l in contents if not is_prop(l, WRAPPER_PROPS)]
    if not args.keep_interrupts:
        kept = [l for l in kept if not is_prop(l, IRQ_PROPS)]

    if not any("{" in l for l in kept):
        die("nothing left to place under %s -- refusing to write an empty overlay"
            % args.target)

    dts = os.path.splitext(args.out)[0] + ".overlay.dts"
    with open(dts, "w") as f:
        f.write("/dts-v1/;\n/plugin/;\n\n/ {\n")
        f.write("\tfragment@0 {\n")
        f.write('\t\ttarget-path = "%s";\n\n' % args.target)
        f.write("\t\t__overlay__ {\n")
        f.write("\n".join(kept) + "\n")
        f.write("\t\t};\n\t};\n};\n")

    subprocess.run(["dtc", "-@", "-I", "dts", "-O", "dtb", "-o", args.out, dts],
                   check=True)

    # A dtbo with no fragment applies nothing and reports no error, and one
    # with a __fixups__ the base tree cannot resolve is refused with -ENOENT.
    # Check both rather than trust.
    back = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", args.out],
                          capture_output=True, text=True).stdout
    if "fragment@0" not in back:
        die(f"{args.out} has no fragment@0; it would apply nothing")
    if not args.keep_interrupts and "__fixups__" in back:
        die(f"{args.out} still has a __fixups__ node; the kernel refused these "
            "with -ENOENT on this board")

    n = len(re.findall(r"vrf_data_converter@", back))
    print(f"  wrote {args.out} -> target {args.target}, "
          f"{n} vrf_data_converter reference(s), via {dts}")


if __name__ == "__main__":
    main()
