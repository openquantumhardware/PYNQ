#   Copyright (c) 2026, Advanced Micro Devices, Inc.
#   SPDX-License-Identifier: BSD-3-Clause
"""PYNQ driver for the Versal RF Data Converter (``vrf_data_converter``).

This is the Versal Gen 2 counterpart of :mod:`xrfdc`, and it is a different
IP with a different bare-metal driver -- AMD's ``rfdc`` driver supports only
``usp_rf_data_converter`` (RFSoC). The Versal one is ``libvrfdc``, MIT
licensed, wrapped here through CFFI.

Two things differ from the RFSoC driver and are worth knowing:

* **No config struct.** ``XRFdc`` has to be handed an ``XRFdc_Config``
  populated from the HWH. ``XVRFdc_InstanceInit`` takes a device-tree address
  and lets libmetal find the device, so there is no HWH-to-struct mapping
  here.
* **libmetal does the discovery.** The converter must be visible to libmetal
  (a UIO node in the device tree). If ``InstanceInit`` fails, check the
  device tree before suspecting this driver.

The upstream driver is an Early Access release: of its ~142 documented API
calls, 76 are marked ready, 28 partially ready and 38 not ready. Only ready
calls are wrapped here. Notably **not** available yet, and needed by most
real applications: ``SetDecimation``, ``SetInterpolation``,
``SetFabWrWords``/``SetFabRdWords``, ``SetFs`` and the whole MTS
(multi-tile synchronisation) group. Set those in the Vivado design instead.
"""

import os
import warnings

import cffi
import pynq

_THIS_DIR = os.path.dirname(__file__)

with open(os.path.join(_THIS_DIR, "xvrfdc_functions.c")) as f:
    _header_text = f.read()

_ffi = cffi.FFI()
_ffi.cdef(_header_text)
_lib = _ffi.dlopen(os.path.join(_THIS_DIR, "libvrfdc.so"))

ADC_TILE = 0
DAC_TILE = 1
TILE_ID_MAX = 3


def _check(name, *args):
    """Call into the library, raising on a non-zero return code."""
    if not hasattr(_lib, name):
        raise RuntimeError(f"{name} is not present in libvrfdc.so")
    ret = getattr(_lib, name)(*args)
    if ret:
        raise RuntimeError(f"{name} failed with status {ret}")
    return ret


class _Tile:
    """One ADC or DAC tile."""

    def __init__(self, parent, tile_type, tile_id):
        self._parent = parent
        self._type = tile_type
        self._id = tile_id

    @property
    def enabled(self):
        out = _ffi.new("u32*")
        _check("XVRFdc_GetTileEnabled", self._parent._inst, self._type,
               self._id, out)
        return bool(out[0])

    @property
    def state(self):
        out = _ffi.new("u32*")
        _check("XVRFdc_GetTileCurrentState", self._parent._inst, self._type,
               self._id, out)
        return out[0]

    @property
    def status(self):
        out = _ffi.new("u32*")
        _check("XVRFdc_GetTileCommonStatus", self._parent._inst, self._type,
               self._id, out)
        return out[0]

    def __repr__(self):
        kind = "ADC" if self._type == ADC_TILE else "DAC"
        return f"<{kind} tile {self._id}>"


class VRFdc(pynq.DefaultIP):
    """Driver for the Versal RF Data Converter.

    Exposes ``adc_tiles`` and ``dac_tiles``, four of each.
    """

    bindto = [
        "xilinx.com:ip:vrf_data_converter:1.3",
        "xilinx.com:ip:vrf_data_converter:1.2",
    ]

    def __init__(self, description):
        super().__init__(description)
        self._inst = _ffi.new("XVRFdc*")
        self._device = _ffi.new("void**")

        base = description.get("phys_addr", 0)
        status = _lib.XVRFdc_InstanceInit(self._inst, base, self._device)
        if status:
            raise RuntimeError(
                f"XVRFdc_InstanceInit failed with status {status}. libmetal "
                "could not open the converter -- check that the device tree "
                "exposes it (see the module docstring)."
            )

        self.adc_tiles = [_Tile(self, ADC_TILE, i) for i in range(TILE_ID_MAX + 1)]
        self.dac_tiles = [_Tile(self, DAC_TILE, i) for i in range(TILE_ID_MAX + 1)]

    @property
    def versions(self):
        """``(software, ip)`` version tuples as ``(major, minor)``."""
        sw = _ffi.new("XVRFdc_Version*")
        ip = _ffi.new("XVRFdc_Version*")
        _lib.XVRFdc_GetVersions(self._inst, sw, ip)
        return (sw.Major, sw.Minor), (ip.Major, ip.Minor)

    def close(self):
        _lib.XVRFdc_InstanceClose(self._inst)
