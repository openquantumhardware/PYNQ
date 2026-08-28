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

import errno
import os
import warnings

import cffi
import pynq

_THIS_DIR = os.path.dirname(__file__)

with open(os.path.join(_THIS_DIR, "xvrfdc_functions.c")) as f:
    _header_text = f.read()

_ffi = cffi.FFI()
# pack=1 is not optional. xvrfdc.h wraps everything from XVRFdc_Config to
# XVRFdc down to byte alignment with #pragma pack(1), which cffi cannot see.
# Without it XVRFdc_Mixer_Settings comes out 40 bytes instead of 33 and every
# field after Band sits at the wrong offset -- the NCO would be programmed
# from whatever happened to land there.
_ffi.cdef(_header_text, pack=1)
_lib = _ffi.dlopen(os.path.join(_THIS_DIR, "libvrfdc.so"))

# sizeof(XVRFdc), measured on the target by the Makefile. The instance is
# opaque to this module -- see the note at the top of xvrfdc_functions.c for
# why it cannot simply be declared as a struct.
try:
    from ._size import _SIZE as _INSTANCE_SIZE
except ImportError:
    raise ImportError(
        "xvrfdc/_size.py is missing. It carries sizeof(XVRFdc) as measured on "
        "the target; run 'make' in the package directory before installing."
    ) from None

ADC_TILE = 0
DAC_TILE = 1
TILE_ID_MAX = 3

# Mixer constants, from xvrfdc.h.
MIXER_TYPE_OFF = 0
MIXER_TYPE_LOW_POWER = 1
MIXER_TYPE_FINE = 2
MIXER_TYPE_COARSE = 3

MIXER_MODE_OFF = 0
MIXER_MODE_C2C = 1
MIXER_MODE_C2R = 2
MIXER_MODE_R2C = 3
MIXER_MODE_R2R = 4

CRS_MIX_BYPASS = 1

EVNT_SRC_IMMEDIATE = 0


def _check(name, *args):
    """Call into the library, raising on a non-zero return code."""
    if not hasattr(_lib, name):
        raise RuntimeError(f"{name} is not present in libvrfdc.so")
    ret = getattr(_lib, name)(*args)
    if ret:
        raise RuntimeError(f"{name} failed with status {ret}")
    return ret


PLATFORM_DEVICES = "/sys/bus/platform/devices"
SIGNATURE = "vrf_data_converter"
COMPATIBLE_PREFIX = "xlnx,vrf-data-converter-"


_metal_ready = False


def _metal_init():
    """Initialise libmetal once per process.

    libvrfdc leaves this to its caller -- AMD's examples call metal_init()
    before XVRFdc_InstanceInit -- and skipping it is what made the driver
    segfault: the bus registry stays empty, metal_device_open() fails, and
    XVRFdc_InstanceInit dereferences the NULL device pointer.
    """
    global _metal_ready
    if _metal_ready:
        return
    status = _lib.xvrfdc_metal_init()
    # Re-initialisation is reported as an error and is harmless.
    if status and status != -errno.EALREADY:
        raise RuntimeError(f"metal_init failed with status {status}")
    _metal_ready = True


def _preflight(base_addr):
    """Fail with an explanation rather than a segmentation fault.

    XVRFdc_InstanceInit walks /sys/bus/platform/devices looking for a name
    ending in "vrf_data_converter", opens it through libmetal and matches
    its compatible and reg. If metal_device_open fails it carries on and
    dereferences the NULL device pointer it was handed, which takes the
    whole interpreter down with no message. Everything it needs is
    observable from here first.
    """
    if not os.path.isdir(PLATFORM_DEVICES):
        raise RuntimeError(f"{PLATFORM_DEVICES} does not exist")

    devs = [d for d in os.listdir(PLATFORM_DEVICES) if d.endswith(SIGNATURE)]
    if not devs:
        raise RuntimeError(
            "No platform device ending in %r under %s. The overlay's device "
            "tree node has to be added under an already-populated bus -- on "
            "Versal /axi -- or the kernel creates the node and no device."
            % (SIGNATURE, PLATFORM_DEVICES))

    problems = []
    for d in devs:
        path = os.path.join(PLATFORM_DEVICES, d)
        compat_file = os.path.join(path, "of_node", "compatible")
        try:
            with open(compat_file, "rb") as f:
                compat = f.read().decode(errors="replace").split("\0")
        except OSError:
            problems.append(f"{d}: no of_node/compatible")
            continue
        compat = [c for c in compat if c]
        if not any(c.startswith(COMPATIBLE_PREFIX) for c in compat):
            problems.append(f"{d}: compatible {compat} has no "
                            f"{COMPATIBLE_PREFIX!r} entry")
            continue
        if not os.path.isdir(os.path.join(path, "uio")):
            problems.append(
                f"{d}: no uio/ -- libmetal opens devices through UIO. Add "
                f'"generic-uio" to the node\'s compatible list (the kernel '
                "binds uio_pdrv_genirq to whatever uio_pdrv_genirq.of_id "
                "names, which this image sets to generic-uio).")
            continue
        return  # this one is usable

    raise RuntimeError(
        "Found %s but none is usable:\n  %s" % (devs, "\n  ".join(problems)))


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
        self._inst = _ffi.new("char[]", _INSTANCE_SIZE)
        self._device = _ffi.new("void**")

        base = description.get("phys_addr", 0)
        _preflight(base)
        _metal_init()
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
        """``(software, ip)`` version tuples as ``(major, minor, revision)``."""
        sw = _ffi.new("XVRFdc_Version*")
        ip = _ffi.new("XVRFdc_Version*")
        _lib.XVRFdc_GetVersions(self._inst, sw, ip)
        return ((sw.Major, sw.Minor, sw.Revision),
                (ip.Major, ip.Minor, ip.Revision))

    def get_mixer(self, tile_type, tile, block, mixer_type=MIXER_TYPE_FINE, band=0):
        """Read a block's mixer settings as a cffi struct."""
        cfg = _ffi.new("XVRFdc_Mixer_Settings*")
        _check("XVRFdc_GetMixerSettings", self._inst, tile_type, tile, block,
               mixer_type, band, cfg)
        return cfg

    def set_mixer_freq(self, tile_type, tile, block, freq_mhz, phase_deg=0.0):
        """Retune a block's NCO.

        Read-modify-write rather than building the struct from scratch: the
        other fields (mixer mode, scale, Nyquist zone) come from the Vivado
        configuration and must not be disturbed by a retune.

        ``freq_mhz`` is signed -- the NCO shifts in either direction.

        On Versal this is how a tone is generated from a DC input, and it is
        also the call the QICK port depends on for ``set_mixer_freq``.
        """
        cfg = self.get_mixer(tile_type, tile, block)
        cfg.Freq = float(freq_mhz)
        cfg.PhaseOffset = float(phase_deg)
        cfg.EventSource = EVNT_SRC_IMMEDIATE
        _check("XVRFdc_SetMixerSettings", self._inst, tile_type, tile, block, cfg)
        return cfg

    def get_mixer_freq(self, tile_type, tile, block):
        """The block's current NCO frequency in MHz."""
        return self.get_mixer(tile_type, tile, block).Freq

    def close(self):
        _lib.XVRFdc_InstanceClose(self._inst)
