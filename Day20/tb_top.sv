// -----------------------------------------------------------------------------
// tb_top.sv - UVM top for the pre-trade RISK-CHECK GATE. Instantiates the clock/
// reset, the interface, and the DUT, wires them together, publishes the virtual
// interface to the config DB, and calls run_test(). Select the test with
//   +UVM_TESTNAME=risk_smoke_test | risk_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_risk_gate_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import risk_gate_pkg::*;

    localparam int PW   = 16;
    localparam int QW   = 16;
    localparam int POSW = 32;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;    // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    risk_gate_if #(.PW(PW), .QW(QW), .POSW(POSW)) vif (.clk(clk), .rst_n(rst_n));

    risk_gate #(.PW(PW), .QW(QW), .POSW(POSW)) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .cfg_load         (vif.cfg_load),
        .cfg_max_qty      (vif.cfg_max_qty),
        .cfg_min_price    (vif.cfg_min_price),
        .cfg_max_price    (vif.cfg_max_price),
        .cfg_max_notional (vif.cfg_max_notional),
        .cfg_pos_limit    (vif.cfg_pos_limit),
        .in_valid         (vif.in_valid),
        .in_side          (vif.in_side),
        .in_price         (vif.in_price),
        .in_qty           (vif.in_qty),
        .out_valid        (vif.out_valid),
        .out_accept       (vif.out_accept),
        .out_reason       (vif.out_reason),
        .out_side         (vif.out_side),
        .out_price        (vif.out_price),
        .out_qty          (vif.out_qty),
        .out_pos          (vif.out_pos)
    );

    initial begin
        uvm_config_db#(virtual risk_gate_if)::set(null, "*", "vif", vif);
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
