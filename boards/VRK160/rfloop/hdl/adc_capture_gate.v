// Copyright (c) 2026, Advanced Micro Devices, Inc.
// SPDX-License-Identifier: BSD-3-Clause
//
// Burst capture gate for the ADC stream.
//
// The ADC delivers 256 bits every cycle at 491.52 MHz -- 15.7 GB/s -- and
// the path to DDR is a 128-bit AXI DMA on the 100 MHz pl0_ref_clk, about
// 1.6 GB/s. The converter cannot be back-pressured, so the stream can only
// be captured in bursts: this gate passes exactly DEPTH beats after an arm
// pulse and then closes, asserting tlast on the last one so the DMA's S2MM
// transfer terminates cleanly.
//
// DEPTH must not exceed the downstream FIFO depth. While the gate is open
// the FIFO fills far faster than the DMA drains it, so anything longer is
// silently lost -- the counter is what bounds the burst, not back-pressure.
//
// Two things here exist because the first version of this module missed
// timing by 3.9 ns at 491.52 MHz, every failing path starting at the
// register that sampled `arm`:
//
//   * `arm` comes from an AXI GPIO in the 100 MHz domain and was sampled
//     straight into this one. That is an unsynchronised clock-domain
//     crossing; it needs a synchroniser, not a single flop borrowed from
//     the edge detector.
//   * The terminal count was a full-width compare feeding both `open` and
//     the synchronous reset of every counter bit. At 2.035 ns that fan-out
//     does not close. The counter now counts down with the terminal
//     condition registered a cycle ahead, and nothing drives a wide reset.

`timescale 1ps / 1ps

module adc_capture_gate #(
    parameter integer TDATA_WIDTH = 256,
    parameter integer DEPTH       = 8192,
    parameter integer CNT_WIDTH   = 14      // must hold DEPTH
) (
    input  wire                   aclk,
    input  wire                   aresetn,

    // Asynchronous to aclk: driven from the AXI-Lite clock domain.
    input  wire                   arm,

    input  wire [TDATA_WIDTH-1:0] s_axis_tdata,
    input  wire                   s_axis_tvalid,

    output wire [TDATA_WIDTH-1:0] m_axis_tdata,
    output wire                   m_axis_tvalid,
    output wire                   m_axis_tlast,
    input  wire                   m_axis_tready,

    output wire                   busy
);

    (* ASYNC_REG = "TRUE" *) reg [2:0] arm_sync;

    always @(posedge aclk) begin
        if (!aresetn) arm_sync <= 3'b000;
        else          arm_sync <= {arm_sync[1:0], arm};
    end

    wire arm_rise = arm_sync[1] & ~arm_sync[2];

    reg                  open;
    reg                  last_r;
    reg [CNT_WIDTH-1:0]  remaining;

    wire beat = open & s_axis_tvalid & m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            open      <= 1'b0;
            last_r    <= 1'b0;
            remaining <= {CNT_WIDTH{1'b0}};
        end else if (!open) begin
            if (arm_rise) begin
                open      <= 1'b1;
                remaining <= DEPTH[CNT_WIDTH-1:0] - 2'd2;
                last_r    <= (DEPTH <= 1);
            end
        end else if (beat) begin
            if (last_r) begin
                open   <= 1'b0;
                last_r <= 1'b0;
            end else begin
                remaining <= remaining - 1'b1;
                // Registered one beat ahead, so the comparison is against a
                // constant and never sits in the same cycle as the decision
                // it feeds.
                last_r    <= ~(|remaining);
            end
        end
    end

    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tvalid = open & s_axis_tvalid;
    assign m_axis_tlast  = beat & last_r;
    assign busy          = open;

endmodule
