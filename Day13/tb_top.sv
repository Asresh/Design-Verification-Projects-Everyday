// -----------------------------------------------------------------------------
// tb_top.sv - UVM top level for the mac_dot dot-product engine.
//
// Instantiates the clock/reset, the DUT, the interface, wires them together,
// publishes the virtual interface to the config DB, and starts the UVM test
// named by +UVM_TESTNAME (default mac_smoke_test).
//
//   make vcs       UVM_TESTNAME=mac_smoke_test
//   make questa    UVM_TESTNAME=mac_regress_test
//   make verilator UVM_TESTNAME=mac_smoke_test
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_top;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import mac_dot_pkg::*;

    localparam int A_W   = 8;
    localparam int ACC_W = 32;

    logic clk;
    logic rst_n;

    // 100 MHz clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // reset
    initial begin
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // interface
    mac_dot_if #(.A_W(A_W), .ACC_W(ACC_W)) vif (.clk(clk), .rst_n(rst_n));

    // DUT
    mac_dot #(.A_W(A_W), .ACC_W(ACC_W)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (vif.in_valid),
        .in_a       (vif.in_a),
        .in_b       (vif.in_b),
        .in_last    (vif.in_last),
        .out_valid  (vif.out_valid),
        .out_result (vif.out_result)
    );

    // publish vif and run
    initial begin
        uvm_config_db#(virtual mac_dot_if)::set(null, "*", "vif", vif);
        run_test("mac_smoke_test");
    end

    // global watchdog
    initial begin
        #2ms;
        `uvm_fatal("TIMEOUT", "global watchdog expired")
    end

    // waveform dump for UVM runs too
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
