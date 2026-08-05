// ============================================================================
// tb_top.sv - UVM top for the IEEE-754 binary32 adder / subtractor.
// Builds clock/reset + the pin interface, instantiates the DUT, publishes the
// virtual interface to the config DB and calls run_test(). Select the test with
//     +UVM_TESTNAME=fp32_add_smoke_test | fp32_add_regress_test
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_fp32_add_dump.sv (see the Makefile).
// ============================================================================
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import fp32_ref_pkg::*;
    import fp32_add_pkg::*;
    `include "uvm_macros.svh"

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;                // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    fp32_add_if #(.EW(EW), .MW(MW), .LAT(LAT)) vif (.clk(clk), .rst_n(rst_n));

    fp32_add #(.EW(EW), .MW(MW)) u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (vif.in_valid),
        .in_sub    (vif.in_sub),
        .in_a      (vif.in_a),
        .in_b      (vif.in_b),
        .out_valid (vif.out_valid),
        .out_z     (vif.out_z),
        .out_inv   (vif.out_inv),
        .out_ovf   (vif.out_ovf),
        .out_unf   (vif.out_unf),
        .out_inx   (vif.out_inx)
    );

    initial begin
        uvm_config_db#(virtual fp32_add_if)::set(null, "*", "vif", vif);
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
        run_test();
    end

    // Global watchdog, independent of UVM objections.
    initial begin
        #4ms;
        `uvm_fatal("TIMEOUT", "global watchdog fired")
    end
endmodule
