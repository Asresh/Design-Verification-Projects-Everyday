// -----------------------------------------------------------------------------
// tb_top.sv  -  UVM top level for the apb_regfile environment
//
// Generates clock + reset, instantiates the DUT and the APB interface, wires
// the virtual interface into the config DB, and calls run_test(). Select the
// test with +UVM_TESTNAME=apb_smoke_test | apb_regress_test.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
`include "uvm_macros.svh"
    import apb_regfile_pkg::*;

    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int NUM_REGS   = 16;

    logic PCLK;
    logic PRESETn;

    // 100 MHz clock.
    initial PCLK = 1'b0;
    always #5 PCLK = ~PCLK;

    // Reset: assert for a few cycles, then release synchronously.
    initial begin
        PRESETn = 1'b0;
        repeat (3) @(posedge PCLK);
        PRESETn = 1'b1;
    end

    // Interface.
    apb_if #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH))
        vif (.PCLK(PCLK), .PRESETn(PRESETn));

    // DUT.
    apb_regfile #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_REGS  (NUM_REGS)
    ) dut (
        .PCLK   (PCLK),
        .PRESETn(PRESETn),
        .PSEL   (vif.PSEL),
        .PENABLE(vif.PENABLE),
        .PWRITE (vif.PWRITE),
        .PADDR  (vif.PADDR),
        .PWDATA (vif.PWDATA),
        .PSTRB  (vif.PSTRB),
        .PRDATA (vif.PRDATA),
        .PREADY (vif.PREADY),
        .PSLVERR(vif.PSLVERR)
    );

    // Publish the vif and launch UVM.
    initial begin
        uvm_config_db#(virtual apb_if)::set(null, "*", "vif", vif);
        run_test();
    end

    // Waveform dump + global watchdog timeout.
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end
    initial begin
        #100000;   // 100 us hard ceiling
        `uvm_fatal("TIMEOUT", "global watchdog fired - simulation hung")
    end

endmodule
