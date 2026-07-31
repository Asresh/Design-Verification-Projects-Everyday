// -----------------------------------------------------------------------------
// warp_scan_if.sv - SystemVerilog interface for the GPU warp-level parallel
// prefix-sum (scan) engine UVM environment. Bundles the streaming input vector
// and the (fixed-latency) scanned output vector, with clocking blocks for the
// stimulus driver and the passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface warp_scan_if #(
    parameter int N  = 8,
    parameter int DW = 16
) (input logic clk, input logic rst_n);

    // ---- streaming input vector ----
    logic              in_valid;
    logic              in_excl;
    logic [N*DW-1:0]   in_data;

    // ---- scanned output vector (fixed pipeline latency) ----
    logic              out_valid;
    logic              out_excl;
    logic [N*DW-1:0]   out_data;

    // Stimulus driver: drives the input vector, samples the scanned output.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output in_valid, in_excl, in_data;
        input  out_valid, out_excl, out_data;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_excl, in_data;
        input out_valid, out_excl, out_data;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
