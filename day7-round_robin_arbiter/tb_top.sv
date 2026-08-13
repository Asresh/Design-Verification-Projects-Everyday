// -----------------------------------------------------------------------------
// tb_top.sv  -  UVM top-level for the round-robin arbiter environment
//
// Generates clock/reset, instantiates the interface and DUT, publishes the
// virtual interface to the config DB, and starts the UVM test selected by
// +UVM_TESTNAME. Requires a UVM-capable simulator (VCS / Questa / Verilator);
// Icarus users should run tb_arb_rr_dump.sv instead.
//
//   vcs/questa: ... +UVM_TESTNAME=arb_smoke_test
//               ... +UVM_TESTNAME=arb_regress_test
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`define ARB_RR_SVA          // enable the DUT's inline assertions

module tb_top;
    import uvm_pkg::*;
    import arb_rr_pkg::*;

    localparam int NUM_REQ = 4;

    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;      // 100 MHz

    // Interface.
    arb_if #(.NUM_REQ(NUM_REQ)) vif (.clk(clk), .rst_n(rst_n));

    // DUT.
    arb_rr #(.NUM_REQ(NUM_REQ)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (vif.en),
        .req        (vif.req),
        .grant      (vif.grant),
        .grant_valid(vif.grant_valid),
        .grant_idx  (vif.grant_idx)
    );

    // Reset: assert for a few cycles.
    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    // Publish vif and launch the test.
    initial begin
        uvm_config_db#(virtual arb_if)::set(null, "*", "vif", vif);
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
        run_test();
    end

    // Safety-net timeout.
    initial begin
        #50000;
        `uvm_fatal("TIMEOUT", "global timeout reached")
    end
endmodule
