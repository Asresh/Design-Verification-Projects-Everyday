// ============================================================================
// seq_divider_if.sv - interface bundling the seq_divider pins for the UVM env.
//
// The request side (start, dividend, divisor) is driven by the divider agent's
// driver; the status/result side (busy, done, quotient, remainder, dbz) is
// sampled by the monitor. Two clocking blocks give the driver and monitor the
// correct input-skew / output-skew discipline.
// ============================================================================
`timescale 1ns/1ps

interface seq_divider_if #(
    parameter int WIDTH = 8
) (
    input logic clk,
    input logic rst_n
);
    // ---- request ----
    logic             start;
    logic [WIDTH-1:0] dividend;
    logic [WIDTH-1:0] divisor;
    // ---- status / result ----
    logic             busy;
    logic             done;
    logic [WIDTH-1:0] quotient;
    logic [WIDTH-1:0] remainder;
    logic             dbz;

    // Driver clocking block: launches division requests.
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output start, dividend, divisor;
        input  busy, done, quotient, remainder, dbz;
    endclocking

    // Monitor clocking block: observes request + result.
    clocking mon_cb @(posedge clk);
        default input #1step;
        input start, dividend, divisor, busy, done, quotient, remainder, dbz;
    endclocking

    modport drv (clocking drv_cb, input clk, rst_n);
    modport mon (clocking mon_cb, input clk, rst_n);
endinterface
