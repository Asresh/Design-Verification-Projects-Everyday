// -----------------------------------------------------------------------------
// risk_gate_if.sv - SystemVerilog interface for the pre-trade RISK-CHECK GATE
// UVM environment. Bundles the risk-limit configuration bus, the streaming order
// input (side/price/qty), and the fixed-latency verdict (accept + priority-
// encoded reason + echoed order + net position), with clocking blocks for the
// stimulus driver and the passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface risk_gate_if #(
    parameter int PW   = 16,
    parameter int QW   = 16,
    parameter int POSW = 32,
    parameter int NW   = PW + QW,
    parameter int RW   = 3
) (input logic clk, input logic rst_n);

    // ---- risk-limit configuration ----
    logic                cfg_load;
    logic [QW-1:0]       cfg_max_qty;
    logic [PW-1:0]       cfg_min_price;
    logic [PW-1:0]       cfg_max_price;
    logic [NW-1:0]       cfg_max_notional;
    logic [POSW-1:0]     cfg_pos_limit;

    // ---- streaming order input ----
    logic                in_valid;
    logic                in_side;
    logic [PW-1:0]       in_price;
    logic [QW-1:0]       in_qty;

    // ---- verdict output (fixed pipeline latency) ----
    logic                out_valid;
    logic                out_accept;
    logic [RW-1:0]       out_reason;
    logic                out_side;
    logic [PW-1:0]       out_price;
    logic [QW-1:0]       out_qty;
    logic signed [POSW-1:0] out_pos;

    // Stimulus driver: programs the limits and drives the order stream.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output cfg_load, cfg_max_qty, cfg_min_price, cfg_max_price,
               cfg_max_notional, cfg_pos_limit;
        output in_valid, in_side, in_price, in_qty;
        input  out_valid, out_accept, out_reason, out_side, out_price,
               out_qty, out_pos;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input cfg_load, cfg_max_qty, cfg_min_price, cfg_max_price,
              cfg_max_notional, cfg_pos_limit;
        input in_valid, in_side, in_price, in_qty;
        input out_valid, out_accept, out_reason, out_side, out_price,
              out_qty, out_pos;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
