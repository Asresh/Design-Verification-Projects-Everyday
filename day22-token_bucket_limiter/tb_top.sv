// -----------------------------------------------------------------------------
// tb_top.sv - UVM top for the TOKEN-BUCKET ORDER-RATE LIMITER. Instantiates the
// clock/reset, the interface, and the DUT, wires them together, publishes the
// virtual interface to the config DB, and calls run_test(). Select the test with
//   +UVM_TESTNAME=rl_smoke_test | rl_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_rate_limiter_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import rate_limiter_pkg::*;

    localparam int TSW   = 32;
    localparam int TOKW  = 16;
    localparam int COSTW = 8;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;    // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    rate_limiter_if #(.TSW(TSW), .TOKW(TOKW), .COSTW(COSTW)) vif (.clk(clk), .rst_n(rst_n));

    rate_limiter #(.TSW(TSW), .TOKW(TOKW), .COSTW(COSTW)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .cfg_load    (vif.cfg_load),
        .cfg_init_ts (vif.cfg_init_ts),
        .in_valid    (vif.in_valid),
        .in_ts       (vif.in_ts),
        .in_cost     (vif.in_cost),
        .out_valid   (vif.out_valid),
        .out_grant   (vif.out_grant),
        .out_reason  (vif.out_reason),
        .out_ts      (vif.out_ts),
        .out_cost    (vif.out_cost),
        .out_avail   (vif.out_avail),
        .out_tokens  (vif.out_tokens)
    );

    initial begin
        uvm_config_db#(virtual rate_limiter_if)::set(null, "*", "vif", vif);
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
