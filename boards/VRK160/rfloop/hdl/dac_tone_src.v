// Copyright (c) 2026, Advanced Micro Devices, Inc.
// SPDX-License-Identifier: BSD-3-Clause
//
// Programmable complex tone source for the DAC datapath.
//
// The converter's own fine mixer does not modulate on this part: its NCO
// registers are provably correct -- FCW scaling linearly with the requested
// frequency, phase accumulator enabled, mixer mode 0xC03 (C2R, I branch,
// COS_MINSIN) -- and the output still does not move with frequency. The tone
// is therefore generated here instead, which is also what QICK does: its
// axis_signal_gen_v6 carries its own DDS in the PL and hands the converter a
// formed waveform.
//
// SSR phases in parallel, one accumulator: lane i takes acc + i*FREQ_WORD and
// the accumulator advances by SSR*FREQ_WORD per beat, so the phase is
// continuous across beat boundaries.
//
//   f_out = FREQ_WORD / 2^32 * (SSR * 491.52 MHz)
//         = FREQ_WORD / 2^32 * 3932.16 MHz
//
// 0x08000000 is 1/32 of that, 122.88 MHz -- the frequency of the fixed table
// this replaces, so an unwritten register reproduces the previous behaviour.
//
// Phase is truncated to LUT_BITS for the table lookup. That quantisation sets
// the spur floor (about -6 dB per bit, so roughly -38 dBc here), not the
// frequency resolution, which comes from the 32-bit accumulator: 0.92 Hz.

`timescale 1ps / 1ps

module dac_tone_src #(
    parameter integer SSR      = 8,    // complex samples per beat
    parameter integer LUT_BITS = 6     // table index width
) (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET aresetn" *)
    input  wire              aclk,
    input  wire              aresetn,

    input  wire [31:0]       freq_word,

    output reg  [32*SSR-1:0] m_axis_tdata,
    output wire              m_axis_tvalid,
    input  wire              m_axis_tready,

    // Readback, so software can tell a stalled datapath from a wrong one.
    // Every failure this design has had so far was invisible from the PS:
    // the tone was either right or absent, with no way to see which link
    // had stopped. dbg[5:0] is the top of the accumulator, so a changing
    // value proves the phase is advancing at all. Bit positions below.
    output wire [31:0]       dbg
);

    localparam integer N = 1 << LUT_BITS;

    // One cycle of a complex phasor, {Q, I} per entry, amplitude 16384.
    localparam [N*32-1:0] LUT = {
        32'hF9BA3FB1,  // 63  I= 16305 Q= -1606
        32'hF3843EC5,  // 62  I= 16069 Q= -3196
        32'hED6C3D3F,  // 61  I= 15679 Q= -4756
        32'hE7823B21,  // 60  I= 15137 Q= -6270
        32'hE1D53871,  // 59  I= 14449 Q= -7723
        32'hDC723537,  // 58  I= 13623 Q= -9102
        32'hD7663179,  // 57  I= 12665 Q=-10394
        32'hD2BF2D41,  // 56  I= 11585 Q=-11585
        32'hCE87289A,  // 55  I= 10394 Q=-12665
        32'hCAC9238E,  // 54  I=  9102 Q=-13623
        32'hC78F1E2B,  // 53  I=  7723 Q=-14449
        32'hC4DF187E,  // 52  I=  6270 Q=-15137
        32'hC2C11294,  // 51  I=  4756 Q=-15679
        32'hC13B0C7C,  // 50  I=  3196 Q=-16069
        32'hC04F0646,  // 49  I=  1606 Q=-16305
        32'hC0000000,  // 48  I=     0 Q=-16384
        32'hC04FF9BA,  // 47  I= -1606 Q=-16305
        32'hC13BF384,  // 46  I= -3196 Q=-16069
        32'hC2C1ED6C,  // 45  I= -4756 Q=-15679
        32'hC4DFE782,  // 44  I= -6270 Q=-15137
        32'hC78FE1D5,  // 43  I= -7723 Q=-14449
        32'hCAC9DC72,  // 42  I= -9102 Q=-13623
        32'hCE87D766,  // 41  I=-10394 Q=-12665
        32'hD2BFD2BF,  // 40  I=-11585 Q=-11585
        32'hD766CE87,  // 39  I=-12665 Q=-10394
        32'hDC72CAC9,  // 38  I=-13623 Q= -9102
        32'hE1D5C78F,  // 37  I=-14449 Q= -7723
        32'hE782C4DF,  // 36  I=-15137 Q= -6270
        32'hED6CC2C1,  // 35  I=-15679 Q= -4756
        32'hF384C13B,  // 34  I=-16069 Q= -3196
        32'hF9BAC04F,  // 33  I=-16305 Q= -1606
        32'h0000C000,  // 32  I=-16384 Q=     0
        32'h0646C04F,  // 31  I=-16305 Q=  1606
        32'h0C7CC13B,  // 30  I=-16069 Q=  3196
        32'h1294C2C1,  // 29  I=-15679 Q=  4756
        32'h187EC4DF,  // 28  I=-15137 Q=  6270
        32'h1E2BC78F,  // 27  I=-14449 Q=  7723
        32'h238ECAC9,  // 26  I=-13623 Q=  9102
        32'h289ACE87,  // 25  I=-12665 Q= 10394
        32'h2D41D2BF,  // 24  I=-11585 Q= 11585
        32'h3179D766,  // 23  I=-10394 Q= 12665
        32'h3537DC72,  // 22  I= -9102 Q= 13623
        32'h3871E1D5,  // 21  I= -7723 Q= 14449
        32'h3B21E782,  // 20  I= -6270 Q= 15137
        32'h3D3FED6C,  // 19  I= -4756 Q= 15679
        32'h3EC5F384,  // 18  I= -3196 Q= 16069
        32'h3FB1F9BA,  // 17  I= -1606 Q= 16305
        32'h40000000,  // 16  I=     0 Q= 16384
        32'h3FB10646,  // 15  I=  1606 Q= 16305
        32'h3EC50C7C,  // 14  I=  3196 Q= 16069
        32'h3D3F1294,  // 13  I=  4756 Q= 15679
        32'h3B21187E,  // 12  I=  6270 Q= 15137
        32'h38711E2B,  // 11  I=  7723 Q= 14449
        32'h3537238E,  // 10  I=  9102 Q= 13623
        32'h3179289A,  //  9  I= 10394 Q= 12665
        32'h2D412D41,  //  8  I= 11585 Q= 11585
        32'h289A3179,  //  7  I= 12665 Q= 10394
        32'h238E3537,  //  6  I= 13623 Q=  9102
        32'h1E2B3871,  //  5  I= 14449 Q=  7723
        32'h187E3B21,  //  4  I= 15137 Q=  6270
        32'h12943D3F,  //  3  I= 15679 Q=  4756
        32'h0C7C3EC5,  //  2  I= 16069 Q=  3196
        32'h06463FB1,  //  1  I= 16305 Q=  1606
        32'h00004000   //  0  I= 16384 Q=     0
    };

    // freq_word crosses from the AXI-Lite domain. It is a whole word read
    // asynchronously, so a torn value would be a transient wrong frequency;
    // two ranks make that a single-beat glitch instead of a metastable one.
    // The XDC false-paths the first rank -- see vrk160_rf_clocks.xdc.
    (* ASYNC_REG = "TRUE" *) reg [31:0] fw_sync [0:1];
    always @(posedge aclk) begin
        fw_sync[0] <= freq_word;
        fw_sync[1] <= fw_sync[0];
    end
    wire [31:0] fw = fw_sync[1];

    // Two stages, because a 32-bit add and a 64-entry lookup do not fit in
    // one 2.035 ns period. Stage 1 forms each lane's phase and keeps only the
    // index bits; stage 2 does the table lookup.
    reg [31:0] acc;
    reg [LUT_BITS-1:0] idx_r [0:SSR-1];

    integer j;
    always @(posedge aclk) begin
        if (!aresetn) begin
            acc <= 32'd0;
            for (j = 0; j < SSR; j = j + 1)
                idx_r[j] <= {LUT_BITS{1'b0}};
        end else if (m_axis_tready) begin
            // Lane j is the accumulator advanced by j sample periods. j is a
            // loop constant after unrolling, so fw*j is a shift-and-add, not
            // a multiplier.
            for (j = 0; j < SSR; j = j + 1)
                idx_r[j] <= (acc + fw * j) >> (32 - LUT_BITS);
            acc <= acc + (fw << $clog2(SSR));   // SSR * fw, exactly
        end
    end

    // Not gated by tready. The fixed-table version this replaced drove tdata
    // from a continuous assign, so the converter saw valid samples in reset
    // and whatever tready did; making the register conditional changed that
    // to "zeros until tready", which is a behavioural change that was not
    // part of the intended edit.
    integer k;
    always @(posedge aclk) begin
        for (k = 0; k < SSR; k = k + 1)
            m_axis_tdata[32*k +: 32] <= LUT[32*idx_r[k] +: 32];
    end

    // A slow toggle proves aclk is running even when everything else is
    // frozen, which distinguishes a stopped clock from a stalled datapath.
    reg [23:0] heartbeat;
    always @(posedge aclk) begin
        if (!aresetn) heartbeat <= 24'd0;
        else          heartbeat <= heartbeat + 1'b1;
    end

    //   [31:24] fw[31:24]         la palabra que el DDS está usando
    //   [5:0]   acc[31:26]        cambia si la fase avanza
    //   [8]      m_axis_tready     lo que el convertidor acepta
    //   [9]      aresetn           el reset del dominio de 491.52 MHz
    //   [23:16]  heartbeat[23:16]  cambia si aclk corre
    assign dbg = {fw[31:24], heartbeat[23:16], 6'd0, aresetn, m_axis_tready,
                  2'd0, acc[31:26]};

    // Held asserted, but it gates nothing: PG443 states the RF-DAC does not
    // use sXY_axis_tvalid and takes whatever is on tdata once the tile is up.
    assign m_axis_tvalid = aresetn;

endmodule
