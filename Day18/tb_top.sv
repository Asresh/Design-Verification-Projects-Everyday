// -----------------------------------------------------------------------------
// tb_top.sv - UVM top for the GPU warp-level parallel prefix-sum (scan) engine.
// Instantiates the clock/reset, the interface, and the DUT, wires them together,
// publishes the virtual interface to the config DB, and calls run_test(). Select
// the test with +UVM_TESTNAME=scan_smoke_test | scan_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_warp_scan_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import warp_scan_pkg::*;

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

    warp_scan_if #(.N(N), .DW(DW)) vif (.clk(clk), .rst_n(rst_n));

    warp_scan #(.N(N), .DW(DW)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (vif.in_valid),
        .in_excl  (vif.in_excl),
        .in_data  (vif.in_data),
        .out_valid(vif.out_valid),
        .out_excl (vif.out_excl),
        .out_data (vif.out_data)
    );

    initial begin
        uvm_config_db#(virtual warp_scan_if)::set(null, "*", "vif", vif);
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
