// -----------------------------------------------------------------------------
// tb_top.sv - UVM top for the MARKET-DATA SEQUENCE GAP DETECTOR. Instantiates the
// clock/reset, the interface, and the DUT, wires them together, publishes the
// virtual interface to the config DB, and calls run_test(). Select the test with
//   +UVM_TESTNAME=sgd_smoke_test | sgd_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_seq_gap_detector_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import seq_gap_detector_pkg::*;

    localparam int SEQW = 32;
    localparam int DW   = 64;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;    // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    seq_gap_detector_if #(.SEQW(SEQW), .DW(DW)) vif (.clk(clk), .rst_n(rst_n));

    seq_gap_detector #(.SEQW(SEQW), .DW(DW)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .cfg_load     (vif.cfg_load),
        .cfg_init_seq (vif.cfg_init_seq),
        .in_valid     (vif.in_valid),
        .in_seq       (vif.in_seq),
        .in_data      (vif.in_data),
        .out_valid    (vif.out_valid),
        .out_fwd      (vif.out_fwd),
        .out_action   (vif.out_action),
        .out_seq      (vif.out_seq),
        .out_data     (vif.out_data),
        .out_gap      (vif.out_gap),
        .out_expected (vif.out_expected)
    );

    initial begin
        uvm_config_db#(virtual seq_gap_detector_if)::set(null, "*", "vif", vif);
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
