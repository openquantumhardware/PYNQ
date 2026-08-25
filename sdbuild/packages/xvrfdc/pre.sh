#!/bin/bash
# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# Stages the VRFDC driver sources and the Python package into the rootfs.
#
# The driver is MIT-licensed but is not published to any public git remote --
# AMD's own recipe fetches it from an internal server. It therefore has to be
# downloaded from AMD (the "Versal RF Data Converter Driver" EA package) and
# pointed at with PYNQ_VRFDC_SRC, the same way the Xilinx tools themselves are
# supplied rather than vendored.

set -e
set -x

target=$1
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

: "${PYNQ_VRFDC_SRC:=}"

if [ -z "${PYNQ_VRFDC_SRC}" ]; then
    cat >&2 <<'MSG'
ERROR: PYNQ_VRFDC_SRC is not set.

  The VRFDC driver sources are not redistributed with PYNQ. Download the
  Versal RF Data Converter driver from AMD (MIT licensed, e.g.
  vrfdc-1.0-EA_<date>.zip), extract it, and point PYNQ_VRFDC_SRC at the
  directory holding the driver's src/, for example:

    export PYNQ_VRFDC_SRC=/path/to/vrfdc-1.0-EA/XilinxProcessorIPLib/drivers/vrfdc

  Then rebuild. To build an image without RF support, drop xvrfdc from
  STAGE4_PACKAGES in the board .spec instead.
MSG
    exit 1
fi

if [ ! -f "${PYNQ_VRFDC_SRC}/src/xvrfdc.h" ]; then
    echo "ERROR: ${PYNQ_VRFDC_SRC}/src/xvrfdc.h not found -- is PYNQ_VRFDC_SRC pointing at the driver directory?" >&2
    exit 1
fi

sudo cp -r "$script_dir/package" "$target/root/xvrfdc_build"
sudo cp -r "${PYNQ_VRFDC_SRC}/src" "$target/root/xvrfdc_build/vrfdc_src"
