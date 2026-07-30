// ============================================================================
// tb_top.sv - UVM top for the seq_divider environment.
//
// Generates clock + reset, instantiates the DUT through seq_divider_if,
// publishes the virtual interface via the config DB, and launches the test
// selected by +UVM_TESTNAME (default div_smoke_test).
//
//   make vcs     UVM_TESTNAME=div_smoke_test
//   make questa  UVM_TESTNAME=div_regress_test
//
// Concurrent SVA (module `seq_divider_sva`) is bound onto the DUT under
// +define+DIV_SVA and checks the handshake-level invariants.
// ============================================================================
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import seq_divider_pkg::*;

    localparam int WIDTH = 8;

    logic clk;
    logic rst_n;

    // ---- clock / reset ----
    initial clk = 1'b0;
    always #5 clk = ~clk;             // 10 ns

    initial begin
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---- interface + DUT ----
    seq_divider_if #(.WIDTH(WIDTH)) vif (.clk(clk), .rst_n(rst_n));

    seq_divider #(.WIDTH(WIDTH)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (vif.start),
        .dividend  (vif.dividend),
        .divisor   (vif.divisor),
        .busy      (vif.busy),
        .done      (vif.done),
        .quotient  (vif.quotient),
        .remainder (vif.remainder),
        .dbz       (vif.dbz)
    );

`ifdef DIV_SVA
    bind seq_divider seq_divider_sva #(.WIDTH(WIDTH)) u_sva (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .quotient(quotient), .remainder(remainder), .dbz(dbz)
    );
`endif

    // ---- publish vif + start test ----
    initial begin
        uvm_config_db#(virtual seq_divider_if)::set(null, "*", "vif", vif);
        run_test("div_smoke_test");
    end

    // ---- global safety timeout ----
    initial begin
        #500us;
        `uvm_fatal("TIMEOUT", "global watchdog fired")
    end

    // ---- waveform ----
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end
endmodule

// ----------------------------------------------------------------------------
// Concurrent SVA checker bound onto the DUT (enabled with +define+DIV_SVA).
// Encodes the handshake contract the divider must honor.
// ----------------------------------------------------------------------------
`ifdef DIV_SVA
module seq_divider_sva #(parameter int WIDTH = 8) (
    input logic clk, input logic rst_n,
    input logic start, input logic busy, input logic done,
    input logic [WIDTH-1:0] quotient, input logic [WIDTH-1:0] remainder,
    input logic dbz
);
    // `done` is a one-cycle pulse - it must not stay high two cycles.
    a_done_pulse: assert property (@(posedge clk) disable iff (!rst_n)
        done |=> !done)
        else $error("SVA: done held more than one cycle");

    // A completed division drops busy in the same cycle done pulses.
    a_done_clears_busy: assert property (@(posedge clk) disable iff (!rst_n)
        done |-> !busy)
        else $error("SVA: busy still high at done");

    // Accepting a request (start while idle) must lead to `done` within a
    // bounded window (WIDTH iterations + handshake overhead).
    a_start_completes: assert property (@(posedge clk) disable iff (!rst_n)
        (start && !busy) |-> ##[1:WIDTH+4] done)
        else $error("SVA: division did not complete in bounded time");

    // Results are clean (no X) whenever the result is published.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        done |-> !$isunknown({quotient, remainder, dbz}))
        else $error("SVA: X on result at done");

    // While busy, the divider stays busy until it signals done (no silent drop).
    a_busy_until_done: assert property (@(posedge clk) disable iff (!rst_n)
        (busy && !done) |=> busy)
        else $error("SVA: busy dropped without done");
endmodule
`endif
