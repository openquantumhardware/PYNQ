# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# VRK160 rfloop overlay -- minimal RF loopback (Segmented Configuration).
#
# Sources the golden reference, adds the RF data converter with a DC tone
# source and a burst capture path, then builds a PL PDI locked to the golden
# NoC solution.
#
# Needs PYNQ_VRFDC_IP_REPO pointing at AMD's Versal RF Data Converter Vivado
# IP repository; the IP does not ship with Vivado.

overlay_name := rfloop
design_name  := rfloop

GOLDEN_DIR := ../golden
GOLDEN_NCR := $(GOLDEN_DIR)/golden_noc.ncr

all: check_env $(GOLDEN_NCR) block_design pdi dtbo
	@echo
	@echo "Built $(overlay_name) for VRK160 (Segmented Configuration)"
	@echo "  PDI:  $(overlay_name).pdi   (load via PYNQ Overlay)"
	@echo "  HWH:  $(overlay_name).hwh"
	@echo "  DTBO: $(overlay_name).dtbo  (device tree node for the converter)"
	@echo

check_env:
	@if [ -z "$$PYNQ_VRFDC_IP_REPO" ]; then \
	    echo "ERROR: PYNQ_VRFDC_IP_REPO is not set."; \
	    echo "       The Versal RF Data Converter IP does not ship with Vivado."; \
	    echo "       export PYNQ_VRFDC_IP_REPO=/path/to/VRFDC_Vivado_IP_Repo_v1_3_<id>"; \
	    exit 1; \
	fi

# Same rule base/Makefile uses: an edit to the golden's sources has to
# rebuild the golden, or this overlay is locked to a stale NoC solution.
GOLDEN_SRC := $(wildcard $(GOLDEN_DIR)/*.tcl $(GOLDEN_DIR)/*.xdc)

$(GOLDEN_NCR): $(GOLDEN_SRC)
	$(MAKE) -C $(GOLDEN_DIR)

golden: $(GOLDEN_NCR)

block_design:
	vivado -mode batch -source $(overlay_name).tcl -notrace

pdi:
	vivado -mode batch -source build_pdi.tcl -notrace

# Device tree overlay for the PL.
#
# libmetal discovers the converter through sysfs, so without a device tree
# node XVRFdc_InstanceInit fails and the xvrfdc driver cannot open anything.
# PYNQ loads <overlay>.dtbo automatically when it sits next to the PDI
# (pynq/pl_server/embedded_device.py looks for the .dtbo suffix).
#
# sdtgen comes from Vivado/Vitis, the same tool build_edf_boot.sh runs on the
# golden XSA; dtc is in the sdbuild container.
DTBO_DIR := ./dt_$(overlay_name)

dtbo: $(overlay_name).dtbo

$(overlay_name).dtbo: $(overlay_name).xsa
	rm -rf $(DTBO_DIR) && mkdir -p $(DTBO_DIR)
	@command -v sdtgen >/dev/null || { \
	    echo "ERROR: sdtgen not on PATH. Source Vivado settings64.sh."; exit 1; }
	printf 'set_dt_param -dir %s\nset_dt_param -xsa %s\ngenerate_sdt\nexit\n' \
	    "$(DTBO_DIR)" "$(CURDIR)/$(overlay_name).xsa" | sdtgen
	@dtsi=$$(find $(DTBO_DIR) -name 'pl.dtsi' | head -1); \
	if [ -z "$$dtsi" ]; then \
	    echo "ERROR: sdtgen produced no pl.dtsi under $(DTBO_DIR)."; \
	    exit 1; \
	fi; \
	./mkdtbo.sh "$$dtsi" $(overlay_name).dtbo

clean:
	rm -rf $(overlay_name) $(DTBO_DIR) *.jou *.log NA .Xil .crashReporter \
	       *.pdi *.hwh *.xsa *.dtbo *.overlay.dts

.PHONY: all check_env golden block_design pdi dtbo clean
