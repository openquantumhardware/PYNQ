# Copyright (c) 2026, Advanced Micro Devices, Inc.
# SPDX-License-Identifier: BSD-3-Clause

from setuptools import setup

setup(
    name="xvrfdc",
    version="0.1",
    description="PYNQ driver for the Versal RF Data Converter IP",
    license="BSD 3-Clause",
    packages=["xvrfdc"],
    package_data={"xvrfdc": ["libvrfdc.so", "xvrfdc_functions.c", "*.h"]},
    install_requires=["cffi", "pynq"],
)
