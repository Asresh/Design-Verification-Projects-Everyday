// -----------------------------------------------------------------------------
// tb_top.sv - UVM top for the streaming Best-Bid/Best-Offer (BBO) top-of-book
// reduction tree. Instantiates the clock/reset, the interface, and the DUT,
// wires them together, publishes the virtual interface to the config DB, and
// calls run_test(). Select the test with
//   +UVM_TESTNAME=bbo_smoke_test | bbo_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_bbo_reduce_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import bbo_reduce_pkg::*;

    localparam int N  = 8;
    localparam int DW = 16;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;    // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    bbo_reduce_if #(.N(N), .DW(DW)) vif (.clk(clk), .rst_n(rst_n));

    bbo_reduce #(.N(N), .DW(DW)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (vif.in_valid),
        .in_price   (vif.in_price),
        .in_mask    (vif.in_mask),
        .out_valid  (vif.out_valid),
        .out_any    (vif.out_any),
        .out_max_val(vif.out_max_val),
        .out_max_idx(vif.out_max_idx),
        .out_min_val(vif.out_min_val),
        .out_min_idx(vif.out_min_idx)
    );

    initial begin
        uvm_config_db#(virtual bbo_reduce_if)::set(null, "*", "vif", vif);
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
        run_test();
    end

    // Global watchdog independent of UVM objections.
    initial begin
        #1ms;
        `uvm_fatal("TIMEOUT", "global watchdog fired")
    end
endmodule
