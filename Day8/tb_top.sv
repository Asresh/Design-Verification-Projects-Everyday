// ============================================================================
// tb_top.sv - UVM top-level harness for the dual-clock async_fifo
// ----------------------------------------------------------------------------
// Generates the two independent clocks and asynchronous resets, instantiates
// the DUT + interface, publishes the virtual interface to the UVM config DB,
// and starts the test named by +UVM_TESTNAME.
//
//   make vcs       UVM_TESTNAME=fifo_smoke_test
//   make questa    UVM_TESTNAME=fifo_regress_test
//   make verilator UVM_TESTNAME=fifo_smoke_test
//
// The two clocks use non-commensurate half-periods (5.0 ns wr, 6.5 ns rd) so
// their edges do not line up - a realistic CDC scenario.
// ============================================================================
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
`include "uvm_macros.svh"
    import async_fifo_pkg::*;

    logic wr_clk, wr_rst_n;
    logic rd_clk, rd_rst_n;

    // Independent clocks (see header for periods).
    initial begin wr_clk = 1'b0; forever #5.0 wr_clk = ~wr_clk; end
    initial begin rd_clk = 1'b0; forever #6.5 rd_clk = ~rd_clk; end

    // Asynchronous, staggered reset release.
    initial begin
        wr_rst_n = 1'b0;
        rd_rst_n = 1'b0;
        #23 wr_rst_n = 1'b1;
        #7  rd_rst_n = 1'b1;
    end

    // Interface + DUT
    async_fifo_if #(.DW(DW)) vif (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n)
    );

    async_fifo #(.DW(DW), .AW(AW)) dut (
        .wr_clk (wr_clk),   .wr_rst_n(wr_rst_n),
        .wr_en  (vif.wr_en), .wr_data(vif.wr_data), .wr_full(vif.wr_full),
        .rd_clk (rd_clk),   .rd_rst_n(rd_rst_n),
        .rd_en  (vif.rd_en), .rd_data(vif.rd_data), .rd_empty(vif.rd_empty)
    );

    // Publish config to the environment.
    initial begin
        fifo_cfg cfg = fifo_cfg::type_id::create("cfg");
        cfg.vif = vif;
        uvm_config_db#(fifo_cfg)::set(null, "uvm_test_top.env.*", "cfg", cfg);
        // Global watchdog independent of objections.
        uvm_top.set_timeout(50us, 1);
        run_test();
    end

    // Waveform dump for UVM runs too.
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end
endmodule
