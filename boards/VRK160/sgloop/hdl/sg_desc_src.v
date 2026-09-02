// Copyright (c) 2026, Advanced Micro Devices, Inc.
// SPDX-License-Identifier: BSD-3-Clause
//
// Waveform descriptor source for axis_signal_gen_v6's s1_axis.
//
// The generator takes a 160-bit descriptor per waveform on s1_axis. In QICK
// that comes from the tProc through sg_translator; this design has no tProc,
// so software assembles the descriptor here instead: five 32-bit words are
// written one at a time, then a pulse sends them as one AXI-Stream beat.
//
// Driven by two 32-bit GPIO outputs rather than an AXI-Lite slave, because
// GPIO is already in this design and an AXI-Lite slave is a lot of code for
// five registers:
//
//   data     [31:0]  the word to write
//   ctrl     [2:0]   register index 0..4
//            [8]     write enable, rising edge latches data into reg[index]
//            [16]    go, rising edge emits the assembled 160-bit beat
//
// Both GPIO outputs are in the AXI-Lite domain (100 MHz) and this module
// runs at 491.52 MHz, so every control bit is taken through two ranks before
// use and the edges are detected on the fast side. Writing a register while
// go is asserted is a software error and is not interlocked against.
//
// dbg mirrors what the module thinks it holds, because every failure this
// design has had so far was invisible from the PS: without a readback a
// descriptor that was never latched and one that was latched wrong look the
// same. See dac_tone_src.v, which exists for the same reason.

`timescale 1ps / 1ps

module sg_desc_src (
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET aresetn" *)
    input  wire         aclk,
    input  wire         aresetn,

    input  wire [31:0]  data,
    input  wire [31:0]  ctrl,

    output reg  [159:0] m_axis_tdata,
    output reg          m_axis_tvalid,
    input  wire         m_axis_tready,

    // [4:0] words latched so far (one bit per register, so a partially
    // written descriptor is visible), [8] tready, [9] aresetn,
    // [15:12] last index written, [31:16] go counter.
    output wire [31:0]  dbg
);

    // Two ranks on everything crossing from the AXI-Lite domain.
    reg [31:0] data_s1, data_s2;
    reg [31:0] ctrl_s1, ctrl_s2;
    always @(posedge aclk) begin
        data_s1 <= data;  data_s2 <= data_s1;
        ctrl_s1 <= ctrl;  ctrl_s2 <= ctrl_s1;
    end

    wire [2:0] idx = ctrl_s2[2:0];
    wire       we  = ctrl_s2[8];
    wire       go  = ctrl_s2[16];

    reg we_d, go_d;
    always @(posedge aclk) begin
        we_d <= we;
        go_d <= go;
    end
    wire we_edge = we & ~we_d;
    wire go_edge = go & ~go_d;

    reg [31:0] word [0:4];
    reg  [4:0] loaded;
    reg  [3:0] last_idx;
    reg [15:0] go_count;

    integer i;
    always @(posedge aclk) begin
        if (!aresetn) begin
            for (i = 0; i < 5; i = i + 1) word[i] <= 32'd0;
            loaded        <= 5'd0;
            last_idx      <= 4'd0;
            go_count      <= 16'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 160'd0;
        end else begin
            if (we_edge && idx < 3'd5) begin
                word[idx]      <= data_s2;
                loaded[idx]    <= 1'b1;
                last_idx       <= {1'b0, idx};
            end

            // Hold tvalid until the generator takes the beat. A second go
            // while one is still in flight is dropped rather than queued:
            // this is a bring-up aid, not a descriptor FIFO.
            if (go_edge && !m_axis_tvalid) begin
                m_axis_tdata  <= {word[4], word[3], word[2], word[1], word[0]};
                m_axis_tvalid <= 1'b1;
                go_count      <= go_count + 16'd1;
            end else if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
            end
        end
    end

    assign dbg = {go_count, last_idx, 2'b00, aresetn, m_axis_tready,
                  3'b000, loaded};

endmodule
