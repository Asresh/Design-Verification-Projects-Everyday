// -----------------------------------------------------------------------------
// coalescer_if.sv - SystemVerilog interface for the GPU coalescer UVM env.
//
// Bundles the warp-request handshake and the coalesced line-transaction stream
// with clocking blocks for the request driver (source), the line-stream sink
// driver (back-pressure), and the passive monitors.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface coalescer_if #(
    parameter int NLANES = 8,
    parameter int ADDR_W = 32,
    parameter int OFF_W  = 7
) (input logic clk, input logic rst_n);

    localparam int LINE_W = ADDR_W - OFF_W;

    // ---- warp request ----
    logic                     req_valid;
    logic                     req_ready;
    logic [NLANES*ADDR_W-1:0] lane_addr;
    logic [NLANES-1:0]        lane_en;

    // ---- coalesced line stream ----
    logic                     txn_valid;
    logic                     txn_ready;
    logic [LINE_W-1:0]        txn_line;
    logic [NLANES-1:0]        txn_mask;
    logic                     txn_last;

    // Request source (drives req_valid + payload, samples req_ready).
    clocking src_cb @(posedge clk);
        default input #1step output #1;
        output req_valid, lane_addr, lane_en;
        input  req_ready;
    endclocking

    // Line-stream sink (drives txn_ready back-pressure, samples the beat).
    clocking sink_cb @(posedge clk);
        default input #1step output #1;
        output txn_ready;
        input  txn_valid, txn_line, txn_mask, txn_last;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input req_valid, req_ready, lane_addr, lane_en;
        input txn_valid, txn_ready, txn_line, txn_mask, txn_last;
    endclocking

    modport SRC  (clocking src_cb,  input clk, rst_n);
    modport SINK (clocking sink_cb, input clk, rst_n);
    modport MON  (clocking mon_cb,  input clk, rst_n);

endinterface
