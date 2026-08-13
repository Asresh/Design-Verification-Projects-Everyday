// -----------------------------------------------------------------------------
// mac_dot_if.sv - SystemVerilog interface for the mac_dot dot-product engine.
//
// Bundles the operand-input stream and the result-output stream together with
// clocking blocks for the driver (inputs) and the monitors (inputs + outputs).
// Used by the UVM environment in mac_dot_pkg.sv.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

interface mac_dot_if #(
    parameter int A_W   = 8,
    parameter int ACC_W = 32
) (
    input logic clk,
    input logic rst_n
);

    // ---- operand input stream ----
    logic                     in_valid;
    logic signed [A_W-1:0]    in_a;
    logic signed [A_W-1:0]    in_b;
    logic                     in_last;

    // ---- result stream ----
    logic                     out_valid;
    logic signed [ACC_W-1:0]  out_result;

    // Driver drives the input stream synchronous to the clock.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output in_valid, in_a, in_b, in_last;
    endclocking

    // Input monitor samples the operand stream.
    clocking in_mon_cb @(posedge clk);
        default input #1step;
        input in_valid, in_a, in_b, in_last;
    endclocking

    // Output monitor samples the result stream.
    clocking out_mon_cb @(posedge clk);
        default input #1step;
        input out_valid, out_result;
    endclocking

    modport drv    (clocking drv_cb,    input clk, rst_n);
    modport in_mon (clocking in_mon_cb, input clk, rst_n);
    modport out_mon(clocking out_mon_cb,input clk, rst_n);

endinterface

`default_nettype wire
