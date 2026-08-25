#!/bin/bash
# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause

set -x
set -e

. /etc/environment
for f in /etc/profile.d/*.sh; do source $f; done

export HOME=/root
export BOARD=${PYNQ_BOARD}

cd /root/xvrfdc_build
make libmetal
make
make install

cd /root
sudo rm -rf /root/xvrfdc_build
