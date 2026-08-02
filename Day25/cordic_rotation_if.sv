// -----------------------------------------------------------------------------
// cordic_rotation_if.sv - SystemVerilog interface for the rotation-mode CORDIC
// UVM environment. Bundles the request ({valid, x, y, angle}) and the
// fixed-latency result ({valid, x, y, angle}), with clocking blocks for the
// stimulus driver and the passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface cordic_rotation_if #(
    parameter int DW = 16,
    parameter int AW = 16
) (input logic clk, input logic rst_n);

    // ---- request ----
    logic                 in_valid;
    logic signed [DW-1:0] in_x;
    logic signed [DW-1:0] in_y;
    logic signed [AW-1:0] in_angle;

    // ---- result (fixed pipeline latency) ----
    logic                 out_valid;
    logic signed [DW-1:0] out_x;
    logic signed [DW-1:0] out_y;
    logic signed [AW-1:0] out_angle;

    // Stimulus driver: drives the request, samples the result.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output in_valid, in_x, in_y, in_angle;
        input  out_valid, out_x, out_y, out_angle;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_x, in_y, in_angle;
        input out_valid, out_x, out_y, out_angle;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
