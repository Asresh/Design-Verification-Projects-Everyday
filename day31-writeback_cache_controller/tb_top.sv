// ----------------------------------------------------------------------------
// tb_top.sv - UVM top level for the write-back cache-controller environment.
// ----------------------------------------------------------------------------
// Generates the clock, instantiates the interface and the DUT, publishes the
// virtual interface, and starts the test named by +UVM_TESTNAME.
//
// rst_n is NOT driven here: it belongs to the CPU-side driver, because
// resetting a cache that is full of dirty lines is one of the behaviours under
// test, and a reset that could only happen at time zero would never reach it.
//
//   make vcs    UVM_TESTNAME=cache_ctrl_smoke_test
//   make questa UVM_TESTNAME=cache_ctrl_regress_test
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;

    import uvm_pkg::*;
    import cache_ref_pkg::*;
    import cache_ctrl_pkg::*;
`include "uvm_macros.svh"

    logic clk = 1'b0;
    always #5 clk = ~clk;              // 100 MHz

    cache_ctrl_if vif (.clk(clk));

    cache_ctrl #(
        .ADDR_W     (32),
        .DATA_W     (32),
        .LINE_WORDS (REF_LINE_WORDS),
        .SETS       (REF_SETS)
    ) dut (
        .clk           (clk),
        .rst_n         (vif.rst_n),
        .cpu_req_valid (vif.cpu_req_valid),
        .cpu_req_ready (vif.cpu_req_ready),
        .cpu_req_addr  (vif.cpu_req_addr),
        .cpu_req_we    (vif.cpu_req_we),
        .cpu_req_wdata (vif.cpu_req_wdata),
        .cpu_req_wstrb (vif.cpu_req_wstrb),
        .cpu_rsp_valid (vif.cpu_rsp_valid),
        .cpu_rsp_rdata (vif.cpu_rsp_rdata),
        .cpu_rsp_hit   (vif.cpu_rsp_hit),
        .flush_req     (vif.flush_req),
        .flush_busy    (vif.flush_busy),
        .flush_done    (vif.flush_done),
        .mem_req_valid (vif.mem_req_valid),
        .mem_req_ready (vif.mem_req_ready),
        .mem_req_we    (vif.mem_req_we),
        .mem_req_addr  (vif.mem_req_addr),
        .mem_req_wdata (vif.mem_req_wdata),
        .mem_rsp_valid (vif.mem_rsp_valid),
        .mem_rsp_rdata (vif.mem_rsp_rdata),
        .state_o       (vif.state),
        .stat_hit      (vif.stat_hit),
        .stat_miss     (vif.stat_miss),
        .stat_wb       (vif.stat_wb)
    );

    initial begin
        // Prove the reference model before letting it judge the DUT.  If the
        // model cannot satisfy its own invariants, a mismatch later says
        // nothing about the design.
        if (ref_selfcheck(1'b1) != 0)
            `uvm_fatal("REFMODEL",
                       "the reference model failed its own self-check")

        uvm_config_db#(virtual cache_ctrl_if)::set(null, "*", "vif", vif);
        run_test();
    end

    // Waveform capture for the UVM flow.  The committed PNG is rendered from
    // the Icarus run instead (see the Makefile), because that is the flow that
    // runs on any machine.
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end

    // Backstop timeout: a cache that stops making progress would otherwise
    // hang a driver waiting for a response that never comes.
    initial begin
        #50_000_000;
        `uvm_fatal("TIMEOUT", "the simulation did not finish in 50 ms")
    end

endmodule
