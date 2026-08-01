// -----------------------------------------------------------------------------
// rate_limiter_if.sv - SystemVerilog interface for the TOKEN-BUCKET ORDER-RATE
// LIMITER UVM environment. Bundles the session-config bus, the streaming request
// input ({ts, cost}), and the fixed-latency decision (grant + reason + echoed
// request + available/remaining token levels), with clocking blocks for the
// stimulus driver and the passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface rate_limiter_if #(
    parameter int TSW   = 32,
    parameter int TOKW  = 16,
    parameter int COSTW = 8,
    parameter int RSNW  = 2
) (input logic clk, input logic rst_n);

    // ---- session configuration ----
    logic              cfg_load;
    logic [TSW-1:0]    cfg_init_ts;

    // ---- streaming request input ----
    logic              in_valid;
    logic [TSW-1:0]    in_ts;
    logic [COSTW-1:0]  in_cost;

    // ---- decision output (fixed pipeline latency) ----
    logic              out_valid;
    logic              out_grant;
    logic [RSNW-1:0]   out_reason;
    logic [TSW-1:0]    out_ts;
    logic [COSTW-1:0]  out_cost;
    logic [TOKW-1:0]   out_avail;
    logic [TOKW-1:0]   out_tokens;

    // Stimulus driver: programs the session then drives the request stream.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output cfg_load, cfg_init_ts;
        output in_valid, in_ts, in_cost;
        input  out_valid, out_grant, out_reason, out_ts, out_cost,
               out_avail, out_tokens;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input cfg_load, cfg_init_ts;
        input in_valid, in_ts, in_cost;
        input out_valid, out_grant, out_reason, out_ts, out_cost,
              out_avail, out_tokens;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
