// -----------------------------------------------------------------------------
// tb_top.sv - UVM top for the GPU shared-memory bank-conflict serializer.
// Instantiates the clock/reset, the interface, and the DUT, wires them together,
// publishes the virtual interface to the config DB, and calls run_test(). Select
// the test with +UVM_TESTNAME=smem_smoke_test | smem_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_smem_bank_arb_dump.sv (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import smem_bank_arb_pkg::*;

    localparam int NLANES = 8;
    localparam int NBANKS = 8;
    localparam int ADDR_W = 16;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;    // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    smem_bank_arb_if #(.NLANES(NLANES), .NBANKS(NBANKS), .ADDR_W(ADDR_W))
        vif (.clk(clk), .rst_n(rst_n));

    smem_bank_arb #(.NLANES(NLANES), .NBANKS(NBANKS), .ADDR_W(ADDR_W)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .req_valid  (vif.req_valid),
        .req_ready  (vif.req_ready),
        .req_mask   (vif.req_mask),
        .req_addr   (vif.req_addr),
        .ph_valid   (vif.ph_valid),
        .ph_served  (vif.ph_served),
        .ph_bank_use(vif.ph_bank_use),
        .ph_last    (vif.ph_last),
        .ph_index   (vif.ph_index),
        .busy       (vif.busy)
    );

    initial begin
        uvm_config_db#(virtual smem_bank_arb_if)::set(null, "*", "vif", vif);
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
