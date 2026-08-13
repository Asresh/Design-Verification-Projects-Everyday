// ----------------------------------------------------------------------------
// jtag_tap_if.sv - SystemVerilog interface for the JTAG TAP UVM environment.
// ----------------------------------------------------------------------------
// Bundles the four-wire TAP port (TMS/TDI/TDO plus TDO's drive enable), the
// system-side boundary and user-register pins, and the DUT's observation
// outputs (controller state, IR shift register, latched IR).
//
// JTAG is the rare protocol where the DUT genuinely uses both clock edges:
// TMS, TDI and the capture sources are sampled on the rising edge, while TDO,
// the update latches and the drive enable all change on the falling one.
//
// Every clocking block here is nevertheless on the RISING edge, which is
// deliberate and is explained in full above mon_cb: one rising-edge sample
// captures this cycle's stimulus and the previous cycle's complete result at
// once, so the scoreboard gets a whole cycle per item with no second stream to
// pair it against.
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

interface jtag_tap_if #(
    parameter int BSR_LEN  = 8,
    parameter int USER_LEN = 8
) (input logic tck);

    // ---- TAP port ----
    // trst_n lives here rather than in tb_top because it is a stimulus the
    // driver owns: asserting it mid-scan is one of the things under test, and
    // it is asynchronous, so it is driven directly rather than through a
    // clocking block.
    logic                trst_n;
    logic                tms;
    logic                tdi;
    logic                tdo;
    logic                tdo_en;

    // ---- system side ----
    logic [BSR_LEN-1:0]  pin_in;        // driven by the pin agent
    logic [USER_LEN-1:0] user_capture;  // driven by the pin agent
    logic [BSR_LEN-1:0]  pin_out;
    logic                pin_oe;
    logic [USER_LEN-1:0] user_out;

    // ---- observation ----
    logic [3:0]          state;
    logic [3:0]          ir_shift;
    logic [3:0]          ir_latched;

    // The TAP driver: drives TMS/TDI against the edge the DUT samples them on.
    clocking drv_cb @(posedge tck);
        default input #1step output #1;
        output tms, tdi;
        input  tdo, tdo_en, state, ir_shift, ir_latched;
    endclocking

    // The system-pin driver: the capture sources are sampled on the same edge.
    clocking pin_cb @(posedge tck);
        default input #1step output #1;
        output pin_in, user_capture;
        input  pin_out, pin_oe, user_out, state, ir_latched;
    endclocking

    // The monitor's view.  One clocking block, on the rising edge, is enough
    // to see the whole cycle - and that is worth spelling out, because it is
    // the reason the scoreboard can be cycle-exact without racing itself.
    //
    // Sampling at rising edge k+1 with #1step yields, in one atomic snapshot:
    //
    //   tms, tdi, pin_in, user_capture   the vector the DUT is about to sample
    //                                    at edge k+1;
    //   state, ir_shift                  what rising edge k produced;
    //   tdo, tdo_en, ir_latched,         what falling edge k produced, since
    //   pin_out, pin_oe, user_out        nothing has touched them since.
    //
    // So one item carries the stimulus for cycle k+1 and the complete result
    // of cycle k.  A second monitor on the falling edge would sample TDO
    // *before* the edge that changes it, and pairing two same-timestep streams
    // in a scoreboard is a race waiting to happen; this is both simpler and
    // more accurate.  The transaction-level view is a separate monitor that
    // reassembles whole scans, not a second copy of the pin-level one.
    clocking mon_cb @(posedge tck);
        default input #1step;
        input tms, tdi, pin_in, user_capture;
        input state, ir_shift, ir_latched, tdo, tdo_en;
        input pin_out, pin_oe, user_out;
    endclocking

    modport DRV (clocking drv_cb, input tck, output trst_n);
    modport PIN (clocking pin_cb, input tck, input trst_n);
    modport MON (clocking mon_cb, input tck, input trst_n);

`ifdef JTAG_SVA
    // ------------------------------------------------------------------------
    // Protocol-level assertions, kept out of the DUT.  Enabled with
    // +define+JTAG_SVA on a simulator with SVA support.
    // ------------------------------------------------------------------------
    localparam logic [3:0] A_SHIFT_DR = 4'h2;
    localparam logic [3:0] A_SHIFT_IR = 4'hA;
    localparam logic [3:0] A_RESET    = 4'hF;
    localparam logic [3:0] A_IDLE     = 4'hC;
    localparam logic [3:0] A_UPDATE_DR= 4'h5;
    localparam logic [3:0] A_UPDATE_IR= 4'hD;
    localparam logic [3:0] A_CAPTURE_DR = 4'h6;
    localparam logic [3:0] A_CAPTURE_IR = 4'hE;
    localparam logic [3:0] A_PAUSE_DR = 4'h3;
    localparam logic [3:0] A_PAUSE_IR = 4'hB;
    localparam logic [3:0] A_EXIT1_DR = 4'h1;
    localparam logic [3:0] A_EXIT2_DR = 4'h0;
    localparam logic [3:0] A_EXIT2_IR = 4'h8;

    // TMS and TDI must be stable at the sampling edge - the pins the DUT
    // samples may never be X once reset is released.
    a_no_x_inputs: assert property (@(posedge tck) disable iff (!trst_n)
        !$isunknown(tms) && !$isunknown(tdi));

    // Test-Logic-Reset is sticky while TMS is held high.
    a_reset_sticky: assert property (@(posedge tck) disable iff (!trst_n)
        (state == A_RESET) && tms |=> (state == A_RESET));

    // TMS=0 out of Test-Logic-Reset always lands in Run-Test/Idle.
    a_reset_exit: assert property (@(posedge tck) disable iff (!trst_n)
        (state == A_RESET) && !tms |=> (state == A_IDLE));

    // Pause-DR and Pause-IR hold indefinitely while TMS stays low - the
    // property that lets a slow tester park a scan mid-chain.
    a_pause_dr_holds: assert property (@(posedge tck) disable iff (!trst_n)
        (state == A_PAUSE_DR) && !tms |=> (state == A_PAUSE_DR));
    a_pause_ir_holds: assert property (@(posedge tck) disable iff (!trst_n)
        (state == A_PAUSE_IR) && !tms |=> (state == A_PAUSE_IR));

    // Parking a DR scan in Pause-DR must not disturb the shift register: no
    // bits are lost while the tester is away.
    a_pause_dr_no_shift: assert property (@(posedge tck) disable iff (!trst_n)
        (state == A_PAUSE_DR) |=> $stable(pin_out));

    // The IR shift register only ever moves in Shift-IR or Capture-IR.
    a_ir_stable_outside_ir_path: assert property (@(posedge tck) disable iff (!trst_n)
        !(state inside {A_SHIFT_IR, A_CAPTURE_IR}) |=> $stable(ir_shift));

    // The latched instruction changes only leaving Update-IR or in reset.
    a_ir_latch_only_on_update: assert property (@(posedge tck) disable iff (!trst_n)
        !(state inside {A_UPDATE_IR, A_RESET}) |-> $stable(ir_latched));

    // Boundary and user update latches change only out of Update-DR.
    a_pin_out_only_on_update: assert property (@(posedge tck) disable iff (!trst_n)
        (state != A_UPDATE_DR) |-> $stable(pin_out));
    a_user_out_only_on_update: assert property (@(posedge tck) disable iff (!trst_n)
        (state != A_UPDATE_DR) |-> $stable(user_out));

    // TDO must be quiet - not driven - outside the two shift states.
    a_tdo_quiet: assert property (@(posedge tck) disable iff (!trst_n)
        !(state inside {A_SHIFT_IR, A_SHIFT_DR}) |-> !tdo_en);

    // A DR scan always passes through Capture-DR before Shift-DR: there is no
    // path into the shift path that skips the capture.
    a_capture_before_shift: assert property (@(posedge tck) disable iff (!trst_n)
        $rose(state == A_SHIFT_DR) |-> $past(state) inside {A_CAPTURE_DR, A_EXIT1_DR,
                                                           A_PAUSE_DR, A_EXIT2_DR});

    // Cover: the interesting places a directed test tends to skip.
    c_pause_dr:  cover property (@(posedge tck) state == A_PAUSE_DR);
    c_pause_ir:  cover property (@(posedge tck) state == A_PAUSE_IR);
    c_exit2_dr:  cover property (@(posedge tck) state == A_EXIT2_DR);
    c_exit2_ir:  cover property (@(posedge tck) state == A_EXIT2_IR);
    c_extest_on: cover property (@(posedge tck) pin_oe);
    c_back_to_back_scan: cover property (@(posedge tck)
        (state == A_UPDATE_DR) ##1 (state != A_IDLE));
`endif

endinterface
