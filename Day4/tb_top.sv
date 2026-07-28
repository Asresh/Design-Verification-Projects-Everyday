// -----------------------------------------------------------------------------
// tb_top.sv  -  UVM top level for the uart environment
//
// Generates clock + reset, instantiates the DUT and the UART interface, wires
// the virtual interface into the config DB, and calls run_test(). Unlike the
// portable loopback testbench, here the TX line (tx_serial) and the RX line
// (rx_serial) are NOT tied together: the RX agent bit-bangs rx_serial itself,
// so the TX and RX paths are verified independently.
//
// Select the test with +UVM_TESTNAME=uart_smoke_test | uart_regress_test.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
`include "uvm_macros.svh"
    import uart_pkg::*;

    logic clk;
    logic rst_n;

    // 100 MHz clock.
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Reset: assert for a few cycles, then release synchronously.
    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    // Interface.
    uart_if vif (.clk(clk), .rst_n(rst_n));

    // Default baud (the virtual sequence reprograms this per phase).
    initial vif.cfg_clks_per_bit = 16'd16;

    // DUT.
    uart dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .cfg_clks_per_bit(vif.cfg_clks_per_bit),
        .tx_start        (vif.tx_start),
        .tx_data         (vif.tx_data),
        .tx_serial       (vif.tx_serial),
        .tx_busy         (vif.tx_busy),
        .tx_done         (vif.tx_done),
        .rx_serial       (vif.rx_serial),
        .rx_data         (vif.rx_data),
        .rx_valid        (vif.rx_valid),
        .framing_err     (vif.framing_err)
    );

    // Publish the vif and launch UVM.
    initial begin
        uvm_config_db#(virtual uart_if)::set(null, "*", "vif", vif);
        run_test();
    end

    // Waveform dump + global watchdog timeout.
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end
    initial begin
        #5000000;   // 5 ms hard ceiling
        `uvm_fatal("TIMEOUT", "global watchdog fired - simulation hung")
    end

endmodule
