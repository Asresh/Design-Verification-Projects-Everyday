// -----------------------------------------------------------------------------
// tb_top.sv - UVM top for the GPU SIMT reconvergence stack. Instantiates the
// clock/reset, the interface, and the DUT, wires them together, publishes the
// virtual interface to the config DB, and calls run_test(). Select the test
// with +UVM_TESTNAME=simt_smoke_test | simt_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_simt_stack_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import simt_stack_pkg::*;

    localparam int NLANES = 8;
    localparam int PC_W   = 16;
    localparam int DEPTH  = 32;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;    // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    simt_stack_if #(.NLANES(NLANES), .PC_W(PC_W), .DEPTH(DEPTH))
        vif (.clk(clk), .rst_n(rst_n));

    simt_stack #(.NLANES(NLANES), .PC_W(PC_W), .DEPTH(DEPTH)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .cmd_valid(vif.cmd_valid),
        .cmd_ready(vif.cmd_ready),
        .op       (vif.op),
        .in_mask  (vif.in_mask),
        .rpc      (vif.rpc),
        .tpc      (vif.tpc),
        .fpc      (vif.fpc),
        .tos_mask (vif.tos_mask),
        .tos_pc   (vif.tos_pc),
        .sp       (vif.sp),
        .empty    (vif.empty),
        .full     (vif.full)
    );

    initial begin
        uvm_config_db#(virtual simt_stack_if)::set(null, "*", "vif", vif);
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
