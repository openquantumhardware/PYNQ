# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause

ARCH_VRK160 := aarch64
BITSTREAM_VRK160 := base/base.pdi
FPGA_MANAGER_VRK160 := 1

STAGE4_PACKAGES_VRK160 := xrt pynq ethernet selftest

# The sdist's default extras (ZCU104 base overlay + PMOD BSP) need the ZCU104
# part installed. Skip them: this board's overlay is copied in separately.
export SDIST_BOARD_ARTEFACTS := 0
