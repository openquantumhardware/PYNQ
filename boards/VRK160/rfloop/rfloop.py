#   Copyright (c) 2026, Advanced Micro Devices, Inc.
#   SPDX-License-Identifier: BSD-3-Clause

"""VRK160 rfloop overlay -- minimal RF loopback.

DAC tile 0 slice 0 emits a tone, the XM855 daughterboard loops it back
externally into ADC tile 3 slice 0, and a burst of samples is captured to
DDR::

    from pynq.overlays.rfloop import RFLoopOverlay

    ov = RFLoopOverlay("rfloop.pdi")
    ov.set_tone(100.0)          # MHz, from the DAC's own NCO
    x = ov.capture()            # complex64, one burst
    ov.set_tone(250.0)
    y = ov.capture()

There is no DDS in the PL. The tone comes from the converter's fine mixer
NCO fed with a DC input, so ``set_tone`` is a single
``XVRFdc_SetMixerSettings`` call -- the same one a QICK port needs for
``set_mixer_freq``.

Capture is a burst, not a stream. The ADC produces 256 bits every cycle at
491.52 MHz (~15.7 GB/s) and the path to DDR is a 128-bit DMA on the 100 MHz
clock (~1.6 GB/s), so the PL gate opens for exactly one FIFO's worth of
samples and closes. Asking for more than :attr:`max_samples` is a
programming error, not something the hardware can absorb.
"""

from __future__ import annotations

import numpy as np
import pynq

import xvrfdc


class RFLoopOverlay(pynq.Overlay):
    """RF loopback overlay for the VRK160."""

    #: Tile and block the design enables, matching rfloop.tcl.
    DAC_TILE, DAC_BLOCK = 0, 0
    ADC_TILE, ADC_BLOCK = 3, 0

    #: Beats the PL capture gate passes per burst; must match DEPTH in
    #: hdl/adc_capture_gate.v, which is bounded by the FIFO depth.
    CAPTURE_BEATS = 8192

    #: 256-bit AXIS = 8 complex samples of 16-bit I and Q.
    SAMPLES_PER_BEAT = 8
    BYTES_PER_BEAT = 32

    #: Converter sample rate and decimation, from the IP configuration.
    FS_MSPS = 7864.32
    DECIMATION = 2

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        if self.is_loaded():
            self._bind()

    def _bind(self) -> None:
        self.rf = self.vrf_data_converter_0
        self.dma = self.axi_dma_0
        self._arm = self.axi_gpio_capture.channel1
        self._busy = self.axi_gpio_capture.channel2
        self._arm.setdirection("out")
        self._arm.setlength(1)
        self._busy.setdirection("in")
        self._busy.setlength(1)
        self._arm.write(0, 0x1)

    def download(self, *args, **kwargs) -> None:
        super().download(*args, **kwargs)
        if self.is_loaded():
            self._bind()

    @property
    def max_samples(self) -> int:
        """Complex samples in one burst."""
        return self.CAPTURE_BEATS * self.SAMPLES_PER_BEAT

    @property
    def sample_rate_msps(self) -> float:
        """Complex sample rate reaching the fabric, in MSps."""
        return self.FS_MSPS / self.DECIMATION

    def set_tone(self, freq_mhz: float, phase_deg: float = 0.0):
        """Set the DAC NCO frequency, in MHz.

        Signed: a negative value shifts the other way. The amplitude is
        fixed in the PL by ``dac_tone_src``; adjust output level through the
        converter's VOP or QMC settings instead.
        """
        return self.rf.set_mixer_freq(
            xvrfdc.DAC_TILE, self.DAC_TILE, self.DAC_BLOCK, freq_mhz, phase_deg
        )

    def get_tone(self) -> float:
        """The DAC NCO frequency currently programmed, in MHz."""
        return self.rf.get_mixer_freq(xvrfdc.DAC_TILE, self.DAC_TILE, self.DAC_BLOCK)

    def set_adc_nco(self, freq_mhz: float):
        """Set the ADC NCO, to bring a band down before capture."""
        return self.rf.set_mixer_freq(
            xvrfdc.ADC_TILE, self.ADC_TILE, self.ADC_BLOCK, freq_mhz
        )

    def capture(self, nsamples: int | None = None) -> np.ndarray:
        """Capture one burst and return it as ``complex64``.

        Parameters
        ----------
        nsamples : int, optional
            Complex samples to return, at most :attr:`max_samples`. The PL
            always transfers a whole burst; a smaller value just truncates
            what is returned.
        """
        if nsamples is None:
            nsamples = self.max_samples
        if not 0 < nsamples <= self.max_samples:
            raise ValueError(
                f"nsamples must be 1..{self.max_samples} "
                f"({self.CAPTURE_BEATS} beats); the capture gate cannot pass more "
                "in one burst than the FIFO holds."
            )

        nbytes = self.CAPTURE_BEATS * self.BYTES_PER_BEAT
        buf = pynq.allocate(shape=(nbytes // 2,), dtype=np.int16)
        try:
            # Arm the DMA first: the gate fills the FIFO far faster than the
            # DMA drains it, so the transfer has to already be waiting.
            self.dma.recvchannel.transfer(buf)
            self._arm.write(1, 0x1)
            self.dma.recvchannel.wait()
            self._arm.write(0, 0x1)

            iq = buf.view(np.int16).reshape(-1, 2)
            out = np.empty(nsamples, dtype=np.complex64)
            out.real = iq[:nsamples, 0]
            out.imag = iq[:nsamples, 1]
            return out
        finally:
            self._arm.write(0, 0x1)
            buf.freebuffer()

    @property
    def capturing(self) -> bool:
        """True while the PL gate is passing a burst."""
        return bool(self._busy.read() & 1)

    def tile_status(self) -> dict:
        """Enable, state and status for the two tiles this design uses.

        The first thing to check when a capture comes back empty: if the
        tiles are not up, nothing downstream can work.
        """
        dac = self.rf.dac_tiles[self.DAC_TILE]
        adc = self.rf.adc_tiles[self.ADC_TILE]
        return {
            "dac": {"enabled": dac.enabled, "state": dac.state, "status": dac.status},
            "adc": {"enabled": adc.enabled, "state": adc.state, "status": adc.status},
        }
