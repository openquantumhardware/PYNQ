# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause

ARCH_VRK160 := aarch64
BITSTREAM_VRK160 := base/base.pdi
FPGA_MANAGER_VRK160 := 1

# xvrfdc wraps AMD's libvrfdc for the RF data converter, which the rfloop
# overlay needs. It is a stage4 package, so adding it rebuilds only the
# board rootfs and the image, not stage2 or stage3.
#
# It makes the build depend on the VRFDC driver sources: set PYNQ_VRFDC_SRC
# to the directory holding the driver's src/, e.g.
#   .../vrfdc-1.0-EA/XilinxProcessorIPLib/drivers/vrfdc
# Drop xvrfdc from this line to build an image without RF support.
STAGE4_PACKAGES_VRK160 := xrt pynq ethernet selftest xvrfdc

# The sdist's default extras (ZCU104 base overlay + PMOD BSP) need the ZCU104
# part installed. Skip them: this board's overlay is copied in separately.
export SDIST_BOARD_ARTEFACTS := 0
