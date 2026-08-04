// ============================================================================
// tb_top.sv - UVM top for the self-synchronizing scrambler/descrambler link.
// Builds clock/reset + interface, instantiates the chained link
//
//     in_data -> [ scrambler SEED_TX ] --scr--> (X inject) --> [ descrambler SEED_RX ] -> des
//
// (the descrambler is deliberately seeded differently from the scrambler so the
// self-synchronization is exercised), publishes the vif to the config DB and
// calls run_test(). Select the test with
//     +UVM_TESTNAME=scrambler_smoke_test | scrambler_regress_test.
//
// Needs a UVM-capable simulator (VCS / Questa / Verilator >= 5 --uvm). For the
// open-source Icarus flow use tb_scrambler_dump.sv (see the Makefile).
// ============================================================================
`timescale 1ns/1ps

module tb_top;
    import uvm_pkg::*;
    import scrambler_pkg::*;
    `include "uvm_macros.svh"

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #5 clk = ~clk;            // 100 MHz

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    scrambler_if #(.WIDTH(WIDTH)) vif (.clk(clk), .rst_n(rst_n));

    // wire-error mask aligned to the scrambler's 1-cycle latency (so it XORs
    // the scrambled word produced from the word carrying the mask).
    logic [WIDTH-1:0] inject_mask_q;
    always @(posedge clk)
        inject_mask_q <= (rst_n && vif.in_valid) ? vif.inject_mask : '0;
    wire [WIDTH-1:0] link_data = vif.scr_data ^ inject_mask_q;

    // scrambler (TX)
    scrambler #(.WIDTH(WIDTH), .LFSR_W(LFSR_W), .TAP_A(TAP_A), .TAP_B(TAP_B),
                .MODE_DESCRAMBLE(1'b0), .SEED(SEED_TX)) u_scr (
        .clk(clk), .rst_n(rst_n),
        .in_valid(vif.in_valid), .in_data(vif.in_data),
        .out_valid(vif.scr_valid), .out_data(vif.scr_data), .state_o());

    // descrambler (RX) - fed the (possibly corrupted) wire.
    scrambler #(.WIDTH(WIDTH), .LFSR_W(LFSR_W), .TAP_A(TAP_A), .TAP_B(TAP_B),
                .MODE_DESCRAMBLE(1'b1), .SEED(SEED_RX)) u_des (
        .clk(clk), .rst_n(rst_n),
        .in_valid(vif.scr_valid), .in_data(link_data),
        .out_valid(vif.des_valid), .out_data(vif.des_data), .state_o());

    initial begin
        uvm_config_db#(virtual scrambler_if)::set(null, "*", "vif", vif);
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
        run_test();
    end

    // global watchdog independent of UVM objections.
    initial begin
        #2ms;
        `uvm_fatal("TIMEOUT", "global watchdog fired")
    end
endmodule
