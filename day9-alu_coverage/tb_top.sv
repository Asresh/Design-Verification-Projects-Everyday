// ============================================================================
// tb_top.sv - UVM top for the ALU environment.
//
// Generates clock + reset, instantiates the DUT through alu_if, publishes the
// virtual interface via the config DB, and launches the test selected by
// +UVM_TESTNAME (default alu_smoke_test).
//
//   make vcs     UVM_TESTNAME=alu_smoke_test
//   make questa  UVM_TESTNAME=alu_regress_test
//
// Concurrent SVA (module `alu_sva`) is bound to the DUT under +define+ALU_SVA.
// ============================================================================
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import alu_pkg::*;

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
    alu_if #(.WIDTH(WIDTH)) vif (.clk(clk), .rst_n(rst_n));

    alu #(.WIDTH(WIDTH)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (vif.in_valid),
        .opcode   (vif.opcode),
        .a        (vif.a),
        .b        (vif.b),
        .out_valid(vif.out_valid),
        .result   (vif.result),
        .zero     (vif.zero),
        .carry    (vif.carry),
        .overflow (vif.overflow),
        .negative (vif.negative)
    );

`ifdef ALU_SVA
    bind alu alu_sva #(.WIDTH(WIDTH)) u_sva (
        .clk(clk), .rst_n(rst_n), .out_valid(out_valid),
        .result(result), .zero(zero), .carry(carry),
        .overflow(overflow), .negative(negative)
    );
`endif

    // ---- publish vif + start test ----
    initial begin
        uvm_config_db#(virtual alu_if)::set(null, "*", "vif", vif);
        run_test("alu_smoke_test");
    end

    // ---- global safety timeout + waveform ----
    initial begin
        #1ms;
        `uvm_fatal("TIMEOUT", "global watchdog fired")
    end

    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end
endmodule

// ----------------------------------------------------------------------------
// Concurrent SVA checker bound onto the DUT (enabled with +define+ALU_SVA).
// Checks the flag-consistency invariants that must hold for every response.
// ----------------------------------------------------------------------------
`ifdef ALU_SVA
module alu_sva #(parameter int WIDTH = 8) (
    input logic clk, input logic rst_n, input logic out_valid,
    input logic [WIDTH-1:0] result,
    input logic zero, input logic carry, input logic overflow, input logic negative
);
    // zero flag exactly reflects a zero result
    a_zero: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (zero == (result == '0)))
        else $error("SVA: zero flag inconsistent with result");

    // negative flag equals result MSB
    a_neg: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (negative == result[WIDTH-1]))
        else $error("SVA: negative flag != result MSB");

    // flags are never X while a response is valid
    a_known: assert property (@(posedge clk) disable iff (!rst_n)
        out_valid |-> (!$isunknown({result, zero, carry, overflow, negative})))
        else $error("SVA: X on response bus while out_valid");
endmodule
`endif
