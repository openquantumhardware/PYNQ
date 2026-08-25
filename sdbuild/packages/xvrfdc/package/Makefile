# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# Builds libvrfdc.so from the AMD VRFDC driver sources staged by pre.sh.
#
# Unlike the RFSoC xrfdc package, which compiles the bare-metal driver with
# -D__BAREMETAL__ against libmetal *stubs*, the Versal driver ships a real
# Linux build (Makefile.Linux) that links against libmetal proper. libmetal
# does the device discovery, so the converter has to be visible in sysfs --
# see the note in xvrfdc/__init__.py.

PACKAGE   := xvrfdc
LIBRARY   := lib$(PACKAGE:x%=%).so
VRFDC_SRC := vrfdc_src

LIBMETAL_REPO := https://github.com/OpenAMP/libmetal.git
LIBMETAL_REF  := v2024.05.0
LIBMETAL_DIR  := libmetal
LIBMETAL_INS  := $(CURDIR)/libmetal-install

CFLAGS  += -fPIC -O2 -I$(LIBMETAL_INS)/include
LDFLAGS += -L$(LIBMETAL_INS)/lib

SRCS := $(wildcard $(VRFDC_SRC)/*.c)
OBJS := $(SRCS:.c=.o)

all: $(LIBRARY)

$(LIBRARY): $(OBJS)
	$(CC) $(LDFLAGS) $(OBJS) -shared -Wl,-soname,$(LIBRARY) \
		-o $(LIBRARY) -lmetal -lm

%.o: %.c
	$(CC) $(CFLAGS) -I$(VRFDC_SRC) -c $< -o $@

# libmetal is not packaged by Ubuntu; build it from OpenAMP.
libmetal: $(LIBMETAL_INS)/lib/libmetal.so

$(LIBMETAL_INS)/lib/libmetal.so:
	git clone --depth 1 -b $(LIBMETAL_REF) $(LIBMETAL_REPO) $(LIBMETAL_DIR)
	cmake -S $(LIBMETAL_DIR) -B $(LIBMETAL_DIR)/build \
		-DCMAKE_INSTALL_PREFIX=$(LIBMETAL_INS) \
		-DWITH_DOC=OFF -DWITH_TESTS=OFF -DWITH_EXAMPLES=OFF
	cmake --build $(LIBMETAL_DIR)/build --target install -j$(shell nproc)
	install -m 0644 $(LIBMETAL_INS)/lib/libmetal.so* /usr/lib/ || true
	ldconfig

install:
	cp $(LIBRARY) $(PACKAGE)/
	cp $(VRFDC_SRC)/xvrfdc.h $(PACKAGE)/ 2>/dev/null || true
	pip3 install --break-system-packages .

clean:
	rm -f $(OBJS) $(LIBRARY)
	rm -rf $(LIBMETAL_DIR) $(LIBMETAL_INS)

.PHONY: all install clean libmetal
