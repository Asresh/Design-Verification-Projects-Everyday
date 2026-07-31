// -----------------------------------------------------------------------------
// warp_bitonic_sort_if.sv - SystemVerilog interface for the GPU warp-level
// bitonic sorting network UVM environment. Bundles the streaming input vector
// and the (fixed-latency) sorted output vector, with clocking blocks for the
// stimulus driver and the passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface warp_bitonic_sort_if #(
    parameter int N     = 8,
    parameter int KEY_W = 6,
    parameter int TAG_W = 2
) (input logic clk, input logic rst_n);

    localparam int RW = KEY_W + TAG_W;

    // ---- streaming input vector ----
    logic              in_valid;
    logic              in_dir;
    logic [N*RW-1:0]   in_data;

    // ---- sorted output vector (fixed pipeline latency) ----
    logic              out_valid;
    logic              out_dir;
    logic [N*RW-1:0]   out_data;

    // Stimulus driver: drives the input vector, samples the sorted output.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output in_valid, in_dir, in_data;
        input  out_valid, out_dir, out_data;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_dir, in_data;
        input out_valid, out_dir, out_data;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
