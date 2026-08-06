// ----------------------------------------------------------------------------
// tb_top.sv - UVM top level for the IEEE 1149.1 TAP controller environment.
// ----------------------------------------------------------------------------
// Generates TCK, instantiates the interface and the DUT, publishes the virtual
// interface, and starts the test named by +UVM_TESTNAME.
//
// TRST_n is NOT driven here: it belongs to the driver, because asserting it in
// the middle of a scan is one of the behaviours under test.  See jtag_tap_if.sv.
//
//   make vcs    UVM_TESTNAME=jtag_tap_smoke_test
//   make questa UVM_TESTNAME=jtag_tap_regress_test
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;

    import uvm_pkg::*;
    import jtag_tap_ref_pkg::*;
    import jtag_tap_pkg::*;
`include "uvm_macros.svh"

    localparam int BSR_LEN  = REF_BSR_LEN;
    localparam int USER_LEN = REF_USER_LEN;

    // TCK: 20 ns period.  JTAG is deliberately slow and the design uses both
    // edges, so a symmetric clock with room either side of each edge is what
    // the clocking blocks are written against.
    logic tck = 1'b0;
    always #10 tck = ~tck;

    jtag_tap_if #(.BSR_LEN(BSR_LEN), .USER_LEN(USER_LEN)) vif (.tck(tck));

    jtag_tap #(
        .IDCODE   (REF_IDCODE),
        .BSR_LEN  (BSR_LEN),
        .USER_LEN (USER_LEN)
    ) dut (
        .tck          (tck),
        .trst_n       (vif.trst_n),
        .tms          (vif.tms),
        .tdi          (vif.tdi),
        .tdo          (vif.tdo),
        .tdo_en       (vif.tdo_en),
        .pin_in       (vif.pin_in),
        .pin_out      (vif.pin_out),
        .pin_oe       (vif.pin_oe),
        .user_capture (vif.user_capture),
        .user_out     (vif.user_out),
        .state_o      (vif.state),
        .ir_shift_o   (vif.ir_shift),
        .ir_latched_o (vif.ir_latched)
    );

    initial begin
        uvm_config_db#(virtual jtag_tap_if #(BSR_LEN, USER_LEN))::set(
            null, "*", "vif", vif);
        run_test();
    end

    // Waveform capture for the UVM flow.  The committed PNG is rendered from
    // the Icarus run instead (see the Makefile), because that is the flow that
    // runs on any machine.
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end

    // Backstop timeout: a TAP that stops advancing would otherwise hang a
    // sequence waiting on an edge that never means anything.
    initial begin
        #20_000_000;
        `uvm_fatal("TIMEOUT", "the simulation did not finish in 20 ms of TCK")
    end

endmodule
