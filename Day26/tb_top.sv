// ----------------------------------------------------------------------------
// tb_top.sv - UVM top for the I2C master. Builds the clock/reset, the interface,
// the DUT and a behavioral I2C slave model on a shared open-drain (pulled-up)
// bus, wires them together, publishes the virtual interface to the config DB,
// and calls run_test(). Select the test with
// +UVM_TESTNAME=i2c_smoke_test | i2c_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_i2c_master_dump.sv (see the Makefile).
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import i2c_master_pkg::*;
    `include "uvm_macros.svh"

    localparam int unsigned DIV      = 4;
    localparam logic [6:0]  SLV_ADDR = 7'h42;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;    // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    // Interface + open-drain bus with pull-ups.
    i2c_master_if vif (.clk(clk), .rst_n(rst_n));
    tri1 scl;
    tri1 sda;

    // Slave observation.
    wire [7:0] slv_wr_byte;
    wire       slv_wr_valid, slv_saw_read, slv_saw_nack;

    // DUT
    i2c_master #(.DIV(DIV)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (vif.start),
        .rw        (vif.rw),
        .dev_addr  (vif.dev_addr),
        .wr_data   (vif.wr_data),
        .busy      (vif.busy),
        .done      (vif.done),
        .ack_error (vif.ack_error),
        .rd_data   (vif.rd_data),
        .scl       (scl),
        .sda       (sda)
    );

    // Behavioral slave: returns vif.slv_mem on reads, captures writes.
    i2c_slave_model #(.ADDR7(SLV_ADDR)) slv (
        .clk       (clk),
        .rst_n     (rst_n),
        .mem_byte  (vif.slv_mem),
        .scl       (scl),
        .sda       (sda),
        .wr_byte   (slv_wr_byte),
        .wr_valid  (slv_wr_valid),
        .saw_read  (slv_saw_read),
        .saw_nack  (slv_saw_nack)
    );

    // Feed the bus + slave observation back into the interface for monitoring.
    assign vif.scl         = scl;
    assign vif.sda         = sda;
    assign vif.slv_wr_byte = slv_wr_byte;

    initial begin
        uvm_config_db#(virtual i2c_master_if)::set(null, "*", "vif", vif);
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
        run_test();
    end

    // Global watchdog independent of UVM objections.
    initial begin
        #2ms;
        `uvm_fatal("TIMEOUT", "global watchdog fired")
    end
endmodule
