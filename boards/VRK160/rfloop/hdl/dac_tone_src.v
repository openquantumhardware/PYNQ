// Copyright (c) 2026, Advanced Micro Devices, Inc.
// SPDX-License-Identifier: BSD-3-Clause
//
// Constant complex DC source for the DAC datapath.
//
// There is deliberately no DDS here. The tone is produced by the converter's
// own fine mixer NCO: with a constant I and Q = 0 at the mixer input, the
// mixer multiplies by e^(j2*pi*f*t) and the DAC emits a tone at f. The
// frequency is then set at runtime from Python through
// XVRFdc_SetMixerSettings, which is also the call the QICK port depends on,
// so this design exercises it directly.
//
// A DDS would need SSR=8 parallel phases to fill a 256-bit beat at 491.52
// MHz -- eight DDS Compiler instances with staggered phase offsets -- for a
// tone the converter can generate on its own.

`timescale 1ps / 1ps

module dac_tone_src #(
    parameter integer        SSR   = 8,             // complex samples per beat
    parameter signed [15:0]  AMPL  = 16'sd16384     // -6 dBFS
) (
    input  wire              aclk,
    input  wire              aresetn,

    output wire [32*SSR-1:0] m_axis_tdata,
    output wire              m_axis_tvalid,
    input  wire              m_axis_tready
);

    // Each 32-bit lane carries one complex sample. The mixer only needs a
    // non-zero DC magnitude, so if the I/Q halves turn out to be swapped
    // relative to this the result is the same tone with a 90 degree phase
    // shift -- it does not change whether the loopback works.
    genvar i;
    generate
        for (i = 0; i < SSR; i = i + 1) begin : g_lane
            assign m_axis_tdata[32*i +: 32] = {16'sd0, AMPL};
        end
    endgenerate

    // Free-running: the converter consumes a beat every cycle.
    assign m_axis_tvalid = aresetn;

endmodule
