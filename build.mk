# Copyright (C) 2022 Xilinx, Inc
# SPDX-License-Identifier: BSD-3-Clause

# Builds final pynq source distribution with overlays and BSPs included

VERSION := 4.0.0
SDIST := dist/pynq-$(VERSION).tar.gz

# The sdist normally bundles the ZCU104 base overlay and the PMOD BSP built
# from its XSA. Both need the ZCU104 part installed, which a Vivado install
# targeting other devices will not have:
#
#   ERROR: [HLS 200-1023] Part 'xczu7ev-ffvc1156-2-i' is not installed.
#
# Set SDIST_BOARD_ARTEFACTS=0 to build the sdist without them. Images for
# other boards do not use either, and the sdbuild flow copies each board's
# own overlay in separately.
SDIST_BOARD_ARTEFACTS ?= 1

ifeq ($(SDIST_BOARD_ARTEFACTS),1)
BITS := boards/ZCU104/base/base.bit
BASE_BSP := pynq/lib/pmod/bsp_iop_pmod/iop_pmoda_mb/lib/libxil.a
else
BITS :=
BASE_BSP :=
endif


all: gitsubmodule $(BITS) $(BASE_BSP) $(SDIST)
	echo "Build completed: $(SDIST)"

gitsubmodule:
	git submodule update

%.bit: %.tcl
	cd $(dir $@) ; make clean all

$(BASE_BSP):
	cd boards/sw_repo ; make clean ; make XSA=../ZCU104/base/base.xsa
	rm -rf boards/sw_repo/*/*/*/*/*/code
	rm -rf boards/sw_repo/*/*/*/*/*/libsrc
	cp -rf boards/sw_repo/bsp_iop_pmod0_mb/iop_pmod0_mb/standalone_domain/bsp pynq/lib/pmod/bsp_iop_pmod
	mv pynq/lib/pmod/bsp_iop_pmod/iop_pmod0_mb pynq/lib/pmod/bsp_iop_pmod/iop_pmoda_mb

	cd pynq/lib/pmod && make && make clean
	cd boards/sw_repo && make clean

$(SDIST):
	python3 setup.py sdist

clean:
	rm -rf $(BITS) pynq/lib/*/bsp_* $(SDIST)
