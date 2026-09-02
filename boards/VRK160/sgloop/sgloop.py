#   Copyright (c) 2026, Advanced Micro Devices, Inc.
#   SPDX-License-Identifier: BSD-3-Clause

"""VRK160 sgloop overlay -- QICK's axis_signal_gen_v6 driving the RF loop.

The generator is QICK IP and is driven through QICK's own generated PYNQ
driver (``qick:ip:axis_signal_gen_v6:1.0``), which PYNQ binds automatically
by VLNV. What that driver does not carry is anything board-specific: which
DMA feeds the envelope, and how the 160-bit waveform descriptor reaches
``s1_axis``. Those live here.

In QICK the descriptor comes from the tProcessor. This design has no tProc,
so ``sg_desc_src`` assembles it from two GPIO words -- see hdl/sg_desc_src.v.

    from sgloop import SgLoop

    sg = SgLoop()                       # downloads the PDI, checks the tiles
    sg.load_envelope(env)               # complex, |value| <= 32767
    sg.play(freq=500.0, gain=20000, nsamp=200)
    x = sg.capture()                    # one burst from the ADC

Read the capture with the model in [[vrk160-rf-loopback-measurement]], but
note this overlay does NOT use the -Fs/4 / +Fs/4 pair that rfloop does: the
DAC runs real, 1x interpolation, Real->Real mixer, so there is no net
translation and no cancellation to account for.
"""

import numpy as np

FS_DAC = 7864.32          # MHz, DAC sample rate
FS_C = FS_DAC / 2        # MHz, the ADC's complex output rate after /2 decimation
N_DDS = 16               # real samples per AXI-Stream beat
B_DDS = 32               # phase accumulator width, from QICK's AxisSignalGen

# sg_desc_src control word, see hdl/sg_desc_src.v
_CTRL_WE = 1 << 8
_CTRL_GO = 1 << 16


def freq2reg(f_mhz, fs=FS_DAC):
    """Phase increment for a frequency in MHz. 2**31 is Nyquist."""
    return int(np.round(f_mhz / fs * (1 << B_DDS))) & 0xFFFFFFFF


def reg2freq(pinc, fs=FS_DAC):
    return pinc / (1 << B_DDS) * fs


# ---------------------------------------------------------------------------
# Where a tone lands in the capture
# ---------------------------------------------------------------------------
# The ADC converts its real input to I/Q with a low-power mixer in Real->I/Q
# mode at Fs/4 (ADC_Mixer_Mode30 = 0, ADC_Coarse_Mixer_Freq30 = 1). That Fs/4
# is not stray configuration, it IS the real-to-complex conversion: mix by
# Fs/4, decimate by two, and the complex output sits there.
#
# rfloop hid the term by giving the DAC an equal and opposite -Fs/4. This
# overlay cannot: its DAC runs Real->Real, where PG443 requires the coarse
# mixer to be bypassed. So the shift is structural, and the only sane place to
# deal with it is here rather than in every measurement.

ADC_SHIFT = FS_DAC / 4        # 1966.08 MHz


def fold(f, fs=FS_C):
    """Fold into +-fs/2, which is what the complex capture shows."""
    a = abs(f) % fs
    return fs - a if a > fs / 2 else a


def rf_to_capture(f_rf):
    """Where a tone at f_rf MHz appears in the capture."""
    return fold(f_rf - ADC_SHIFT)


def capture_to_rf(f_seen):
    """The RF frequencies that could produce a peak at f_seen.

    Two of them, and the fold makes more: a single capture cannot tell them
    apart. Compare against what you asked for rather than trusting the first.
    """
    out = set()
    for s in (+1, -1):
        for k in (0, 1):
            f = s * f_seen + ADC_SHIFT + k * FS_C
            if 0 <= f <= FS_DAC / 2:
                out.add(round(f, 4))
    return sorted(out)


def pack_envelope(env):
    """Complex samples -> the int32 words the generator's BRAM expects.

    I goes in [15:0] and Q in [31:16], which is what
    AbsArbSignalGen.load() does in QICK's own driver. Values are clipped
    rather than wrapped: a silent wrap looks like a working envelope with a
    glitch in it, and that is expensive to spot in a capture.
    """
    env = np.asarray(env)
    i = np.clip(np.round(env.real), -32768, 32767).astype(np.int64)
    q = np.clip(np.round(env.imag), -32768, 32767).astype(np.int64)
    return ((q & 0xFFFF) << 16 | (i & 0xFFFF)).astype(np.uint32)


def pack_descriptor(freq=0, phase=0, addr=0, gain=0, nsamp=0,
                    outsel=0, mode=0, stdysel=0, phrst=0):
    """The 160-bit s1_axis word, as five 32-bit little-endian pieces.

    Layout from the core's README section 2:

        159..149 unused      148 phrst        147 stdysel   146 mode
        145..144 outsel      143..128 nsamp   127..112 unused
        111..96  gain        95..80 unused    79..64 addr
        63..32   phase       31..0  freq

    outsel: 0 = product, 1 = DDS, 2 = envelope.

    nsamp is NOT a sample count. ctrl_sgv6 loads it into a counter that
    decrements once per aclk and returns when it reaches 2, so the burst
    lasts about nsamp output beats and each beat emits N_DDS samples.
    """
    if not 0 <= outsel <= 3:
        raise ValueError(f"outsel must be 0..3, got {outsel}")
    if not 0 <= nsamp < (1 << 16):
        raise ValueError(f"nsamp must fit in 16 bits, got {nsamp}")

    word = 0
    word |= (freq  & 0xFFFFFFFF)
    word |= (phase & 0xFFFFFFFF) << 32
    word |= (addr  & 0xFFFF)     << 64
    word |= (int(gain) & 0xFFFF) << 96      # signed, taken two's complement
    word |= (nsamp & 0xFFFF)     << 128
    word |= (outsel & 0x3)       << 144
    word |= (mode  & 0x1)        << 146
    word |= (stdysel & 0x1)      << 147
    word |= (phrst & 0x1)        << 148
    return [(word >> (32 * k)) & 0xFFFFFFFF for k in range(5)]


def nsamp_for_beats(n_beats):
    """nsamp for a burst of n_beats output beats, i.e. n_beats*N_DDS samples."""
    if n_beats < 2:
        raise ValueError("the counter returns at 2, so n_beats must be >= 2")
    return int(n_beats)


# ---------------------------------------------------------------------------
# The overlay
# ---------------------------------------------------------------------------

import os
import sys

import xvrfdc
from pynq import Overlay, allocate, MMIO

# Importing QICK's generated driver is what registers it with PYNQ: the
# bindto lookup happens when the class is defined, so an Overlay created
# before this import gets a bare DefaultIP for the generator and none of the
# register model. Import it here so callers cannot get the order wrong.
#
# The driver puts <core>/rdl on sys.path relative to its own __file__, so the
# driver/ and rdl/ directories have to stay siblings wherever they are copied.
QICK_SGV6 = os.environ.get("QICK_SGV6_DIR", "/home/xilinx/qick_sgv6")
_drv = os.path.join(QICK_SGV6, "driver")
if _drv not in sys.path:
    sys.path.insert(0, _drv)
try:
    import axis_signal_gen_v6 as _qick_sgv6      # noqa: F401  (registers bindto)
    HAVE_QICK_DRIVER = True
except Exception as _e:                          # pragma: no cover
    HAVE_QICK_DRIVER = False
    _QICK_DRIVER_ERROR = _e

PDI = "/home/xilinx/sgloop.pdi"
TILES = (("DAC0", xvrfdc.DAC_TILE, 0), ("ADC3", xvrfdc.ADC_TILE, 3))

GATE_DEPTH = 4096         # DEPTH of hdl/adc_capture_gate.v
WORDS_PER_BEAT = 16


class SgLoop:
    """QICK's signal generator on the VRK160, without a tProcessor.

    Only one PDI download per boot works -- Versal RF devices do not support
    PL Reload, which AMD documents in the RF known issues. So this refuses to
    continue with a tile that did not come up rather than measuring noise.
    """

    @staticmethod
    def is_loaded():
        """True if this design already looks present in the PL.

        The converter's platform device only exists once a download has
        inserted the device tree overlay, so its presence is a good proxy
        for "the PDI is in and the dtbo is applied".
        """
        try:
            import glob
            return bool(glob.glob(
                "/sys/bus/platform/devices/*vrf_data_converter"))
        except Exception:
            return False

    def __init__(self, path=PDI, download=None, verbose=True):
        """Attach to the design, downloading the PDI only when needed.

        ``download=None`` (the default) downloads only if the design does not
        look loaded already. That matters here more than on other boards:
        Versal RF devices do not support PL Reload, so **only the first
        download of a boot works** and every later one leaves the DAC tile in
        STATE_OFF with no way back except a reboot.

        Once the PDI is in, everything this class does is registers and DMA,
        so a notebook can re-create SgLoop as often as it likes without
        touching the PL. Pass ``download=True`` to force one.
        """
        if download is None:
            download = not self.is_loaded()

        if download:
            # Shut the tiles down before reconfiguring. Fails harmlessly on a
            # clean boot, where there is no previous design.
            try:
                prev = Overlay(path, download=False)
                for label, tt, i in TILES:
                    try:
                        prev.vrf_data_converter_0.shutdown(tt, i)
                    except Exception:
                        pass
            except Exception:
                pass
            if verbose:
                print("    downloading the PDI (first load of this boot)")
        elif verbose:
            print("    design already loaded, attaching without a download")

        self.ov = Overlay(path, download=download)
        self.rf = self.ov.vrf_data_converter_0

        down = []
        for label, tt, i in TILES:
            t = (self.rf.dac_tiles if tt == xvrfdc.DAC_TILE
                 else self.rf.adc_tiles)[i]
            if t.state != xvrfdc.STATE_FULL and download:
                try:
                    self.rf.startup(tt, i)
                except Exception:
                    pass
            if verbose:
                print(f"    {label}: state={t.state}")
            if t.state != xvrfdc.STATE_FULL:
                down.append(label)
        if down:
            raise RuntimeError(
                f"{', '.join(down)} did not reach FULL. Reboot the board: "
                f"Versal RF devices do not support PL Reload, so only the "
                f"first download of a boot works.")

        # PYNQ binds QICK's generated driver to this by VLNV
        # (qick:ip:axis_signal_gen_v6:1.0). If it comes back as a bare
        # DefaultIP, the driver is not importable -- check that qick's
        # drivers directory and the core's rdl/ package are on the board and
        # that they are still siblings, because the driver puts rdl/ on
        # sys.path relative to its own __file__.
        self.sg = self.ov.axis_signal_gen_v6_0
        if verbose:
            if not HAVE_QICK_DRIVER:
                print(f"    NOTE: QICK's driver did not import from "
                      f"{QICK_SGV6} ({_QICK_DRIVER_ERROR}). Falling back to "
                      f"raw MMIO -- the generator still works, but this is "
                      f"not exercising QICK's software.")
            elif not hasattr(self.sg, "regs"):
                print("    NOTE: the driver imported but PYNQ did not bind it "
                      "-- check the IP's VLNV against its bindto. Falling "
                      "back to raw MMIO.")
            else:
                print("    generator: QICK driver bound, registers via .regs")

        self.dma_env = self.ov.axi_dma_gen
        self.desc = self.ov.axi_gpio_desc
        self.desc.channel1.setdirection("out"); self.desc.channel1.setlength(32)
        self.desc.channel2.setdirection("out"); self.desc.channel2.setlength(32)
        self.dbg = self.ov.axi_gpio_dbg.channel1
        self.dbg.setdirection("in"); self.dbg.setlength(32)

        self._env_buf = None
        self._cap = None

    # -- generator registers -------------------------------------------------
    #
    # Through QICK's PeakRDL model when it bound, raw MMIO otherwise. The
    # offsets are the ones in the core's RDL: START_ADDR_REG 0x00, WE_REG
    # 0x04, RNDQ_REG 0x08, STATUS_REG 0x0C, CTRL_REG 0x10.

    def _sg_write(self, name, offset, value):
        regs = getattr(self.sg, "regs", None)
        if regs is not None and hasattr(regs, name):
            getattr(regs, name).write(value)
        else:
            self.sg.mmio.write(offset, int(value) & 0xFFFFFFFF)

    def _sg_read(self, name, offset):
        regs = getattr(self.sg, "regs", None)
        if regs is not None and hasattr(regs, name):
            return getattr(regs, name).read()
        return self.sg.mmio.read(offset)

    @property
    def status(self):
        """STATUS_REG. Bit 0 is the sticky saturation flag."""
        return self._sg_read("STATUS_REG", 0x0C)

    def clear_saturation(self):
        self._sg_write("CTRL_REG", 0x10, 1)

    # -- envelope ------------------------------------------------------------

    def load_envelope(self, env, addr=0):
        """DMA a complex envelope into the generator's memory.

        Same sequence as QICK's AbsArbSignalGen.load: arm the write with
        START_ADDR and WE, stream the words in, then drop WE. Leaving WE set
        means the next DMA on this channel silently overwrites the envelope.
        """
        words = pack_envelope(env)
        if self._env_buf is None or len(self._env_buf) < len(words):
            if self._env_buf is not None:
                self._env_buf.freebuffer()
            self._env_buf = allocate(shape=(len(words),), dtype=np.uint32)
        self._env_buf[:len(words)] = words

        self._sg_write("START_ADDR_REG", 0x00, addr)
        self._sg_write("WE_REG", 0x04, 1)
        try:
            self.dma_env.sendchannel.transfer(self._env_buf,
                                              nbytes=len(words) * 4)
            self.dma_env.sendchannel.wait()
        finally:
            self._sg_write("WE_REG", 0x04, 0)
        return len(words)

    # -- descriptor ----------------------------------------------------------

    def send_descriptor(self, words):
        """Push five 32-bit words into sg_desc_src and fire one beat.

        The module latches on the rising edge of we and emits on the rising
        edge of go, so each bit is lowered again before the next use.
        """
        if len(words) != 5:
            raise ValueError(f"expected 5 words, got {len(words)}")
        for idx, w in enumerate(words):
            self.desc.channel1.write(int(w) & 0xFFFFFFFF, 0xFFFFFFFF)
            self.desc.channel2.write(idx, 0xFFFFFFFF)
            self.desc.channel2.write(idx | _CTRL_WE, 0xFFFFFFFF)
            self.desc.channel2.write(idx, 0xFFFFFFFF)
        self.desc.channel2.write(0, 0xFFFFFFFF)
        self.desc.channel2.write(_CTRL_GO, 0xFFFFFFFF)
        self.desc.channel2.write(0, 0xFFFFFFFF)

    def play(self, freq=0.0, gain=20000, nsamp=200, outsel=1, **kw):
        """Pack and fire one waveform. freq is the GENERATOR frequency in MHz.

        What comes back in a capture is rf_to_capture(freq), not freq -- see
        the note above ADC_SHIFT. Use expect() to get that number, or play()'s
        return value.
        """
        self.send_descriptor(pack_descriptor(
            freq=freq2reg(freq), gain=gain, nsamp=nsamp, outsel=outsel, **kw))
        return rf_to_capture(freq)

    @staticmethod
    def expect(freq):
        """Where a tone played at `freq` MHz will show up in the capture."""
        return rf_to_capture(freq)

    def debug(self):
        """sg_desc_src's readback -- see hdl/sg_desc_src.v for the bits."""
        d = self.dbg.read()
        return {"loaded": d & 0x1F, "tready": (d >> 8) & 1,
                "aresetn": (d >> 9) & 1, "last_idx": (d >> 12) & 0xF,
                "go_count": (d >> 16) & 0xFFFF, "raw": d}

    # -- capture -------------------------------------------------------------
    #
    # Same path rfloop validated, and the same two rules that cost days there:
    # wait with ch.wait() rather than polling ch.running (which is "not
    # halted", not "transferring"), and ask for MORE than the gate's DEPTH so
    # the transfer ends on its tlast and leaves cap_fifo empty. Requesting
    # exactly DEPTH can leave a remainder that the NEXT capture returns as if
    # it were fresh -- a measurement that never changes no matter what you
    # tune.

    def _cap_init(self, timeout=3.0):
        import signal
        self._sig = signal
        self._dma_cap = self.ov.axi_dma_0
        self._arm = self.ov.axi_gpio_capture.channel1
        self._arm.setdirection("out"); self._arm.setlength(1)
        self._arm.write(0, 0x1)
        self._ch = self._dma_cap.recvchannel
        self._timeout = timeout
        self._cap = allocate(shape=(GATE_DEPTH * 2 * WORDS_PER_BEAT,),
                             dtype=np.int16)

    def capture(self, timeout=3.0, retries=2):
        """One burst from the ADC. Returns int16 I/Q interleaved, or None.

        Retries on failure because a capture that errors leaves the DMA
        channel halted and the gate's arm/busy handshake out of step; the
        next attempt after a reset normally succeeds. Without this a
        notebook cell fails intermittently and the traceback lands on
        ``w[0::2]`` with w = None, which points nowhere useful.
        """
        for attempt in range(retries):
            w = self._capture_once(timeout)
            if w is not None:
                return w
            if attempt + 1 < retries:
                print(f"      capture: retrying ({attempt + 1}/{retries - 1})")
        return None

    def _capture_once(self, timeout=3.0):
        if self._cap is None:
            self._cap_init(timeout)
        mm, ch = self._ch._mmio, self._ch
        if not ch.running:
            mm.write(ch._offset, 0x4)
            for _ in range(1000):
                if not (mm.read(ch._offset) & 0x4):
                    break
            mm.write(ch._offset, 0x1)
            ch._first_transfer = True

        self._arm.write(0, 0x1)
        ch.transfer(self._cap)
        self._arm.write(1, 0x1)

        def _late(s, f):
            raise TimeoutError("capture did not finish in time")

        old = self._sig.signal(self._sig.SIGALRM, _late)
        self._sig.setitimer(self._sig.ITIMER_REAL, self._timeout)
        try:
            ch.wait()
        except Exception as e:
            print(f"      capture: {e}  SR=0x{mm.read(ch._offset + 4):08X}")
            return None
        finally:
            self._sig.setitimer(self._sig.ITIMER_REAL, 0)
            self._sig.signal(self._sig.SIGALRM, old)
            self._arm.write(0, 0x1)

        n = ch.transferred // 2
        if n < 64:
            print(f"      capture: only {n} samples")
            return None
        return np.array(self._cap[:n])

    def capture_settled(self, timeout=3.0):
        """A capture with the previous burst flushed first.

        The gate hands over a fixed number of beats per arm and anything the
        reader does not take stays in cap_fifo, to be returned by the NEXT
        capture as if it were fresh. The symptom is a tone at the right
        frequency but far too weak, or a window that is not contiguous in
        time -- both of which read as a hardware fault rather than a stale
        buffer. Throwing one away costs a millisecond.
        """
        self.capture(timeout)
        return self.capture(timeout)

    def spectrum(self, w=None, n_peaks=3):
        """FFT of a capture: the strongest peaks as (MHz, dB over the floor).

        The ADC hands back 3932.16 MSps complex, I on even words and Q on
        odd, so the measurement folds into +-1966.08 MHz. Unlike rfloop this
        overlay has no -Fs/4 / +Fs/4 pair, so there is no net translation to
        undo -- what comes out is the DAC frequency folded, nothing more.
        """
        if w is None:
            w = self.capture_settled()
        if w is None:
            return []
        iq = w[0::2].astype(np.float64) + 1j * w[1::2].astype(np.float64)
        n = len(iq)
        sp = np.abs(np.fft.fftshift(np.fft.fft(iq * np.hanning(n))))
        fr = np.fft.fftshift(np.fft.fftfreq(n, d=1.0 / FS_C))
        k0 = int(np.argmax(sp))
        m = np.ones(n, bool); m[max(0, k0 - 8):k0 + 9] = False
        floor = np.median(sp[m])
        out, rest = [], sp.copy()
        for _ in range(n_peaks):
            k = int(np.argmax(rest))
            out.append((abs(fr[k]),
                        20 * np.log10(rest[k] / floor) if floor > 0 else np.inf))
            rest[max(0, k - 8):k + 9] = 0.0
        return out
