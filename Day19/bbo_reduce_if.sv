// -----------------------------------------------------------------------------
// bbo_reduce_if.sv - SystemVerilog interface for the streaming Best-Bid/Best-
// Offer (BBO) top-of-book reduction-tree UVM environment. Bundles the streaming
// price-ladder input (prices + populated-level mask) and the fixed-latency BBO
// result (best bid + best offer, each value + level index), with clocking blocks
// for the stimulus driver and the passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface bbo_reduce_if #(
    parameter int N  = 8,
    parameter int DW = 16,
    parameter int IW = (N > 1) ? $clog2(N) : 1
) (input logic clk, input logic rst_n);

    // ---- streaming price-ladder input ----
    logic              in_valid;
    logic [N*DW-1:0]   in_price;
    logic [N-1:0]      in_mask;

    // ---- BBO result (fixed pipeline latency) ----
    logic              out_valid;
    logic              out_any;
    logic [DW-1:0]     out_max_val;
    logic [IW-1:0]     out_max_idx;
    logic [DW-1:0]     out_min_val;
    logic [IW-1:0]     out_min_idx;

    // Stimulus driver: drives the price ladder, samples the BBO result.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output in_valid, in_price, in_mask;
        input  out_valid, out_any, out_max_val, out_max_idx, out_min_val, out_min_idx;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_price, in_mask;
        input out_valid, out_any, out_max_val, out_max_idx, out_min_val, out_min_idx;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
