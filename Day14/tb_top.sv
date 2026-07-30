// -----------------------------------------------------------------------------
// tb_top.sv - UVM top for the GPU memory-coalescing unit. Instantiates the
// clock/reset, the interface, and the DUT, wires them together, publishes the
// virtual interface to the config DB, and calls run_test(). Select the test
// with +UVM_TESTNAME=coal_smoke_test | coal_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_coalescer_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import coalescer_pkg::*;

    localparam int NLANES = 8;
    localparam int ADDR_W = 32;
    localparam int OFF_W  = 7;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;    // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    coalescer_if #(.NLANES(NLANES), .ADDR_W(ADDR_W), .OFF_W(OFF_W))
        vif (.clk(clk), .rst_n(rst_n));

    coalescer #(.NLANES(NLANES), .ADDR_W(ADDR_W), .OFF_W(OFF_W)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_valid (vif.req_valid),
        .req_ready (vif.req_ready),
        .lane_addr (vif.lane_addr),
        .lane_en   (vif.lane_en),
        .txn_valid (vif.txn_valid),
        .txn_ready (vif.txn_ready),
        .txn_line  (vif.txn_line),
        .txn_mask  (vif.txn_mask),
        .txn_last  (vif.txn_last)
    );

    initial begin
        uvm_config_db#(virtual coalescer_if)::set(null, "*", "vif", vif);
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
