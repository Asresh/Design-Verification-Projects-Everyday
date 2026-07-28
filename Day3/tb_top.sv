// -----------------------------------------------------------------------------
// tb_top.sv  -  UVM top level for the axil_regfile environment
//
// Generates clock + reset, instantiates the DUT and the AXI4-Lite interface,
// wires the virtual interface into the config DB, and calls run_test(). Select
// the test with +UVM_TESTNAME=axil_smoke_test | axil_regress_test.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
`include "uvm_macros.svh"
    import axil_regfile_pkg::*;

    localparam int ADDR_WIDTH = 8;
    localparam int DATA_WIDTH = 32;
    localparam int NUM_REGS   = 16;

    logic ACLK;
    logic ARESETn;

    // 100 MHz clock.
    initial ACLK = 1'b0;
    always #5 ACLK = ~ACLK;

    // Reset: assert for a few cycles, then release synchronously.
    initial begin
        ARESETn = 1'b0;
        repeat (4) @(posedge ACLK);
        ARESETn = 1'b1;
    end

    // Interface.
    axil_if #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH))
        vif (.ACLK(ACLK), .ARESETn(ARESETn));

    // DUT.
    axil_regfile #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_REGS  (NUM_REGS)
    ) dut (
        .ACLK   (ACLK),
        .ARESETn(ARESETn),
        .AWADDR (vif.AWADDR),
        .AWVALID(vif.AWVALID),
        .AWREADY(vif.AWREADY),
        .WDATA  (vif.WDATA),
        .WSTRB  (vif.WSTRB),
        .WVALID (vif.WVALID),
        .WREADY (vif.WREADY),
        .BRESP  (vif.BRESP),
        .BVALID (vif.BVALID),
        .BREADY (vif.BREADY),
        .ARADDR (vif.ARADDR),
        .ARVALID(vif.ARVALID),
        .ARREADY(vif.ARREADY),
        .RDATA  (vif.RDATA),
        .RRESP  (vif.RRESP),
        .RVALID (vif.RVALID),
        .RREADY (vif.RREADY)
    );

    // Publish the vif and launch UVM.
    initial begin
        uvm_config_db#(virtual axil_if)::set(null, "*", "vif", vif);
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
