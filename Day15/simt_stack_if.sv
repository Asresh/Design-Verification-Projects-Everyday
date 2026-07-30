// -----------------------------------------------------------------------------
// simt_stack_if.sv - SystemVerilog interface for the SIMT reconvergence-stack
// UVM environment. Bundles the control-command handshake and the combinational
// top-of-stack status view, with clocking blocks for the command driver and the
// passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface simt_stack_if #(
    parameter int NLANES = 8,
    parameter int PC_W   = 16,
    parameter int DEPTH  = 32
) (input logic clk, input logic rst_n);

    localparam int SP_W = $clog2(DEPTH) + 1;

    // ---- command stream ----
    logic              cmd_valid;
    logic              cmd_ready;
    logic [1:0]        op;
    logic [NLANES-1:0] in_mask;
    logic [PC_W-1:0]   rpc;
    logic [PC_W-1:0]   tpc;
    logic [PC_W-1:0]   fpc;

    // ---- top-of-stack status ----
    logic [NLANES-1:0] tos_mask;
    logic [PC_W-1:0]   tos_pc;
    logic [SP_W-1:0]   sp;
    logic              empty;
    logic              full;

    // Command driver: drives the request, samples cmd_ready + resulting status.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output cmd_valid, op, in_mask, rpc, tpc, fpc;
        input  cmd_ready, tos_mask, tos_pc, sp, empty, full;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input cmd_valid, cmd_ready, op, in_mask, rpc, tpc, fpc;
        input tos_mask, tos_pc, sp, empty, full;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
