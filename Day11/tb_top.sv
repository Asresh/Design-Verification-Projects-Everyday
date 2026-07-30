// ============================================================================
// tb_top.sv - UVM top for the spi_master environment.
//
// Generates clock + reset, instantiates the DUT through spi_master_if,
// publishes the virtual interface via the config DB, and launches the test
// selected by +UVM_TESTNAME (default spi_smoke_test).
//
//   make vcs     UVM_TESTNAME=spi_smoke_test
//   make questa  UVM_TESTNAME=spi_regress_test
//
// Concurrent SVA (module `spi_master_sva`) is bound onto the DUT under
// +define+SPI_SVA and checks the master's pin-level invariants.
// ============================================================================
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import spi_master_pkg::*;

    localparam int DATA_WIDTH = 8;
    localparam int DIV_WIDTH  = 16;

    logic clk;
    logic rst_n;

    // ---- clock / reset ----
    initial clk = 1'b0;
    always #5 clk = ~clk;             // 10 ns

    initial begin
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---- interface + DUT ----
    spi_master_if #(.DATA_WIDTH(DATA_WIDTH), .DIV_WIDTH(DIV_WIDTH))
        vif (.clk(clk), .rst_n(rst_n));

    spi_master #(.DATA_WIDTH(DATA_WIDTH), .DIV_WIDTH(DIV_WIDTH)) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (vif.start),
        .cpol    (vif.cpol),
        .cpha    (vif.cpha),
        .clk_div (vif.clk_div),
        .tx_data (vif.tx_data),
        .sclk    (vif.sclk),
        .cs_n    (vif.cs_n),
        .mosi    (vif.mosi),
        .miso    (vif.miso),
        .rx_data (vif.rx_data),
        .busy    (vif.busy),
        .done    (vif.done)
    );

`ifdef SPI_SVA
    bind spi_master spi_master_sva #(.DATA_WIDTH(DATA_WIDTH), .DIV_WIDTH(DIV_WIDTH))
        u_sva (
            .clk(clk), .rst_n(rst_n),
            .start(start), .clk_div(clk_div),
            .sclk(sclk), .cs_n(cs_n), .mosi(mosi),
            .busy(busy), .done(done)
        );
`endif

    // ---- publish vif + start test ----
    initial begin
        uvm_config_db#(virtual spi_master_if)::set(null, "*", "vif", vif);
        run_test("spi_smoke_test");
    end

    // ---- global safety timeout ----
    initial begin
        #2ms;
        `uvm_fatal("TIMEOUT", "global watchdog fired")
    end

    // ---- waveform ----
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end
endmodule

// ----------------------------------------------------------------------------
// Concurrent SVA checker bound onto the DUT (enabled with +define+SPI_SVA).
// Encodes the pin-level contract the SPI master must honor.
// ----------------------------------------------------------------------------
`ifdef SPI_SVA
module spi_master_sva #(parameter int DATA_WIDTH = 8, parameter int DIV_WIDTH = 16) (
    input logic clk, input logic rst_n,
    input logic start,
    input logic [DIV_WIDTH-1:0] clk_div,
    input logic sclk, input logic cs_n, input logic mosi,
    input logic busy, input logic done
);
    // CS_N must be de-asserted (high) whenever the master is idle.
    a_cs_idle: assert property (@(posedge clk) disable iff (!rst_n)
        (!busy && !done) |-> cs_n)
        else $error("SVA: cs_n asserted while idle");

    // `done` is a one-cycle pulse - it must not stay high two cycles.
    a_done_pulse: assert property (@(posedge clk) disable iff (!rst_n)
        done |=> !done)
        else $error("SVA: done held more than one cycle");

    // A completed transfer drops busy in the same cycle done pulses.
    a_done_clears_busy: assert property (@(posedge clk) disable iff (!rst_n)
        done |-> !busy)
        else $error("SVA: busy still high at done");

    // SCLK may only toggle while a transfer is active (CS_N low).
    a_sclk_gated: assert property (@(posedge clk) disable iff (!rst_n)
        (sclk != $past(sclk)) |-> !cs_n)
        else $error("SVA: sclk toggled while cs_n high");

    // No X on the serial output pins while a transfer is active.
    a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
        !cs_n |-> !$isunknown({sclk, mosi}))
        else $error("SVA: X on sclk/mosi during transfer");
endmodule
`endif
