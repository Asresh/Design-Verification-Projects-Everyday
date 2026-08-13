// -----------------------------------------------------------------------------
// seq_gap_detector_if.sv - SystemVerilog interface for the MARKET-DATA SEQUENCE
// GAP DETECTOR UVM environment. Bundles the session-config bus, the streaming
// message input (seq/data), and the fixed-latency decision (fwd + action + echoed
// message + gap count + next-expected state), with clocking blocks for the
// stimulus driver and the passive monitor.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface seq_gap_detector_if #(
    parameter int SEQW = 32,
    parameter int DW   = 64,
    parameter int ACTW = 2
) (input logic clk, input logic rst_n);

    // ---- session configuration ----
    logic              cfg_load;
    logic [SEQW-1:0]   cfg_init_seq;

    // ---- streaming message input ----
    logic              in_valid;
    logic [SEQW-1:0]   in_seq;
    logic [DW-1:0]     in_data;

    // ---- decision output (fixed pipeline latency) ----
    logic              out_valid;
    logic              out_fwd;
    logic [ACTW-1:0]   out_action;
    logic [SEQW-1:0]   out_seq;
    logic [DW-1:0]     out_data;
    logic [SEQW-1:0]   out_gap;
    logic [SEQW-1:0]   out_expected;

    // Stimulus driver: programs the session then drives the message stream.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output cfg_load, cfg_init_seq;
        output in_valid, in_seq, in_data;
        input  out_valid, out_fwd, out_action, out_seq, out_data,
               out_gap, out_expected;
    endclocking

    // Passive monitor view of everything.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input cfg_load, cfg_init_seq;
        input in_valid, in_seq, in_data;
        input out_valid, out_fwd, out_action, out_seq, out_data,
              out_gap, out_expected;
    endclocking

    modport DRV (clocking drv_cb, input clk, rst_n);
    modport MON (clocking mon_cb, input clk, rst_n);

endinterface
