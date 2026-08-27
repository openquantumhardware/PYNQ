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
// The arm input is a level from an AXI GPIO bit; the rising edge starts a
// burst. Holding it high does not re-arm.

`timescale 1ps / 1ps

module adc_capture_gate #(
    parameter integer TDATA_WIDTH = 256,
    parameter integer DEPTH       = 8192,
    parameter integer CNT_WIDTH   = 14      // must hold DEPTH
) (
    input  wire                   aclk,
    input  wire                   aresetn,

    input  wire                   arm,

    input  wire [TDATA_WIDTH-1:0] s_axis_tdata,
    input  wire                   s_axis_tvalid,

    output wire [TDATA_WIDTH-1:0] m_axis_tdata,
    output wire                   m_axis_tvalid,
    output wire                   m_axis_tlast,
    input  wire                   m_axis_tready,

    output wire                   busy
);

    reg                  arm_d;
    reg                  open;
    reg [CNT_WIDTH-1:0]  count;

    wire beat = open && s_axis_tvalid && m_axis_tready;
    wire last = beat && (count == DEPTH[CNT_WIDTH-1:0] - 1'b1);

    always @(posedge aclk) begin
        if (!aresetn) begin
            arm_d <= 1'b0;
            open  <= 1'b0;
            count <= {CNT_WIDTH{1'b0}};
        end else begin
            arm_d <= arm;

            if (!open) begin
                // Rising edge of arm starts a burst.
                if (arm && !arm_d) begin
                    open  <= 1'b1;
                    count <= {CNT_WIDTH{1'b0}};
                end
            end else if (last) begin
                open  <= 1'b0;
            end else if (beat) begin
                count <= count + 1'b1;
            end
        end
    end

    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tvalid = open && s_axis_tvalid;
    assign m_axis_tlast  = last;
    assign busy          = open;

endmodule
