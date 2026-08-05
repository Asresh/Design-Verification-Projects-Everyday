// ============================================================================
// tb_top.sv - UVM top level for the 8b/10b codec.
//
// Clock, reset, the DUT, the pin interface and run_test().  Select the test
// with +UVM_TESTNAME=codec_8b10b_smoke_test or codec_8b10b_regress_test.
//
// Requires a UVM-capable simulator (VCS, Questa, or Verilator >= 5 built with
// --uvm).  Icarus implements neither the UVM class library nor a constraint
// solver; tb_codec_8b10b_dump.sv is the portable companion that runs there and
// captures the committed waveform.
// ============================================================================
`timescale 1ns/1ps

module tb_top;

    import uvm_pkg::*;
    import codec_8b10b_pkg::*;
`include "uvm_macros.svh"

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #5 clk = ~clk;      // 100 MHz

    codec_8b10b_if vif (.clk(clk), .rst_n(rst_n));

    codec_8b10b dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .in_valid     (vif.in_valid),
        .in_data      (vif.in_data),
        .in_k         (vif.in_k),
        .err_mask     (vif.err_mask),
        .enc_valid    (vif.enc_valid),
        .enc_code     (vif.enc_code),
        .wire_code    (vif.wire_code),
        .enc_rd       (vif.enc_rd),
        .enc_kerr     (vif.enc_kerr),
        .enc_comma    (vif.enc_comma),
        .out_valid    (vif.out_valid),
        .out_data     (vif.out_data),
        .out_k        (vif.out_k),
        .out_code_err (vif.out_code_err),
        .out_disp_err (vif.out_disp_err),
        .out_rd       (vif.out_rd),
        .out_comma    (vif.out_comma)
    );

    initial begin
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
    end

    initial begin
        uvm_config_db #(virtual codec_8b10b_if)::set(null, "*", "vif", vif);
        run_test();
    end

    // A hung link must fail the run rather than hang the regression.
    initial begin
        #2_000_000;
        `uvm_fatal("TIMEOUT", "simulation exceeded 2 ms without finishing")
    end

    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end

endmodule : tb_top
