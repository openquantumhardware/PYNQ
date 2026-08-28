#!/bin/bash
# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# Turn sdtgen's pl.dtsi into a device tree overlay PYNQ can load.
#
# Two things have to be added. sdtgen emits a plain fragment: it opens with
# "/ {" and closes with "};" and carries no /dts-v1/ header, so dtc rejects
# it outright. And the kernel's overlay loader needs fragment@N nodes with a
# target -- a flat "/ { ... }" compiled with /plugin/; produces a valid dtb
# that applies nothing, which is worse than a build error because it fails
# silently at runtime.
#
# The shape below matches the zocl overlay that already works on this board.
#
# sdtgen has no -dt_overlay option in Vivado 2025.2; it is rejected with
# "set_dt_param bad option" and the run continues, so do not add it back
# expecting sdtgen to do this itself.

set -euo pipefail

DTSI="${1:?usage: mkdtbo.sh <pl.dtsi> <out.dtbo>}"
OUT="${2:?usage: mkdtbo.sh <pl.dtsi> <out.dtbo>}"
DTS="${OUT%.dtbo}.overlay.dts"

[ -s "$DTSI" ] || { echo "ERROR: $DTSI is missing or empty." >&2; exit 1; }

first=$(grep -n . "$DTSI" | head -1)
last=$(grep -n . "$DTSI" | tail -1)
[[ ${first#*:} =~ ^[[:space:]]*/[[:space:]]*\{ ]] || {
    echo "ERROR: $DTSI does not start with '/ {' -- sdtgen's output format" >&2
    echo "       changed; the wrapping below would produce a broken overlay." >&2
    exit 1
}
[[ ${last#*:} =~ ^[[:space:]]*\}\; ]] || {
    echo "ERROR: $DTSI does not end with '};' (last content line: ${last%%:*})" >&2
    exit 1
}

{
    echo "/dts-v1/;"
    echo "/plugin/;"
    echo
    echo "/ {"
    echo "	fragment@0 {"
    echo '		target-path = "/";'
    echo "		__overlay__ {"
    sed -n "$(( ${first%%:*} + 1 )),$(( ${last%%:*} - 1 ))p" "$DTSI"
    echo "		};"
    echo "	};"
    echo "};"
} > "$DTS"

dtc -@ -I dts -O dtb -o "$OUT" "$DTS"

# A dtbo with no fragment applies nothing at runtime and reports no error,
# so check rather than trust.
if ! dtc -I dtb -O dts "$OUT" 2>/dev/null | grep -q 'fragment@0'; then
    echo "ERROR: $OUT has no fragment@0; it would apply nothing." >&2
    exit 1
fi

echo "  wrote $OUT (from $DTSI via $DTS)"
