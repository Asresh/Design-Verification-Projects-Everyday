// -----------------------------------------------------------------------------
// tb_top.sv - UVM top for the STREAMING CRC-32 (Ethernet FCS) generator/checker.
// Instantiates the clock/reset, the interface, and the DUT, wires them together,
// publishes the virtual interface to the config DB, and calls run_test(). Select
// the test with +UVM_TESTNAME=crc_smoke_test | crc_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_crc32_stream_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import crc32_stream_pkg::*;

    localparam int DW   = 8;
    localparam int CRCW = 32;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;    // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    crc32_stream_if #(.DW(DW), .CRCW(CRCW)) vif (.clk(clk), .rst_n(rst_n));

    crc32_stream #(.DW(DW), .CRCW(CRCW)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (vif.in_valid),
        .in_sop    (vif.in_sop),
        .in_eop    (vif.in_eop),
        .in_mode   (vif.in_mode),
        .in_data   (vif.in_data),
        .out_valid (vif.out_valid),
        .out_crc   (vif.out_crc),
        .out_mode  (vif.out_mode),
        .out_ok    (vif.out_ok)
    );

    initial begin
        uvm_config_db#(virtual crc32_stream_if)::set(null, "*", "vif", vif);
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
