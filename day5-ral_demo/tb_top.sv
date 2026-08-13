// -----------------------------------------------------------------------------
// tb_top.sv  -  UVM top level for the RAL environment
//
// Generates clock + reset, instantiates the DUT and the APB interface, wires
// the virtual interface into the config DB, and calls run_test(). The DUT
// instance is named `dut`, matching the back-door HDL root "tb_top.dut" set on
// the register model (env.hdl_root), so peek/poke reach dut.ctrl_q / status_q /
// intf_q / scratch_q.
//
// Select the test with:
//   +UVM_TESTNAME=ral_hw_reset_test | ral_bit_bash_test | ral_frontback_test
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
`include "uvm_macros.svh"
    import ral_pkg::*;

    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;

    logic PCLK;
    logic PRESETn;
    logic [DATA_WIDTH-1:0] hw_event;

    // 100 MHz clock.
    initial PCLK = 1'b0;
    always #5 PCLK = ~PCLK;

    // Reset: assert for a few cycles, then release synchronously.
    initial begin
        PRESETn = 1'b0;
        repeat (3) @(posedge PCLK);
        PRESETn = 1'b1;
    end

    // No hardware interrupt events by default (the W1C reg stays 0 unless a
    // directed test drives this); keeps the built-in reg sequences clean.
    initial hw_event = '0;

    // Interface.
    apb_if #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH))
        vif (.PCLK(PCLK), .PRESETn(PRESETn));

    // DUT (named `dut` to match the back-door HDL root).
    ral_regblock #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) dut (
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
        .PSLVERR(vif.PSLVERR),
        .hw_event(hw_event)
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
        #200000;   // 200 us hard ceiling
        `uvm_fatal("TIMEOUT", "global watchdog fired - simulation hung")
    end

endmodule
