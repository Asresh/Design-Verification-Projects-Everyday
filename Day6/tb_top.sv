// -----------------------------------------------------------------------------
// tb_top.sv  -  UVM top-level for the packet-router environment
//
// Generates clock/reset, instantiates the interface and DUT, publishes the
// virtual interface to the config DB, and starts the UVM test selected by
// +UVM_TESTNAME. Requires a UVM-capable simulator (VCS / Questa / Verilator);
// Icarus users should run tb_router_pkt_dump.sv instead.
//
//   vcs/questa: ... +UVM_TESTNAME=router_smoke_test
//               ... +UVM_TESTNAME=router_regress_test
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`define ROUTER_PKT_SVA        // enable the DUT's inline assertions

module tb_top;
    import uvm_pkg::*;
    import router_pkt_pkg::*;

    localparam int NUM_OUT = 4;
    localparam int DW      = 8;
    localparam int DEPTH   = 4;

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;         // 100 MHz

    // Interface.
    router_if #(.NUM_OUT(NUM_OUT), .DW(DW)) vif (.clk(clk), .rst_n(rst_n));

    // DUT.
    router_pkt #(.NUM_OUT(NUM_OUT), .DW(DW), .DEPTH(DEPTH)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (vif.in_valid),
        .in_ready (vif.in_ready),
        .in_dest  (vif.in_dest),
        .in_data  (vif.in_data),
        .in_last  (vif.in_last),
        .out_valid(vif.out_valid),
        .out_ready(vif.out_ready),
        .out_data (vif.out_data),
        .out_last (vif.out_last)
    );

    // Reset: assert for a few cycles.
    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    // Publish vif and launch the test.
    initial begin
        uvm_config_db#(virtual router_if)::set(null, "*", "vif", vif);
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
        run_test();
    end

    // Safety net timeout.
    initial begin
        #50000;
        `uvm_fatal("TIMEOUT", "global timeout reached")
    end
endmodule
